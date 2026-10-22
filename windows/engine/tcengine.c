// Portable RTSP decoder for the Windows app (and a macOS build for testing).
// Same behaviour as the Mac app's CStream: TCP transport, wait for a keyframe,
// tolerate damaged frames. Output is BGRA so C# can copy it into a bitmap.
#include "tcengine.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
#include <windows.h>
#define HW_TYPE AV_HWDEVICE_TYPE_D3D11VA
#define HW_FMT AV_PIX_FMT_D3D11
#else
#define HW_TYPE AV_HWDEVICE_TYPE_VIDEOTOOLBOX
#define HW_FMT AV_PIX_FMT_VIDEOTOOLBOX
#endif

struct TCEngine {
    AVFormatContext *fmt;
    AVCodecContext *dec;
    AVBufferRef *hw_device;
    AVPacket *pkt;
    AVFrame *frame;
    AVFrame *sw_frame;
    struct SwsContext *sws;
    uint8_t *bgra;
    int bgra_w, bgra_h, bgra_stride;
    int video_index;
    int timeout_sec;
    int need_key;
    int bad_frames;
    int hw_failures;      // GPU frames we could not copy out
    int packets_no_frame; // packets sent since the last decoded frame
    atomic_int aborted;
    volatile int *cancel;
    atomic_llong last_io;
    // Counters for the log / diagnostics.
    long long pkts, video_pkts, key_pkts, skipped, sent, frames, bgra_fail, dec_errors, fallbacks;
    long long last_stats;
    char url_host[64];
};

static long long now_sec(void);

// --- Log file -----------------------------------------------------------------

static FILE *log_file;
static atomic_flag log_lock = ATOMIC_FLAG_INIT;

static void log_cb(void *avcl, int level, const char *fmt, va_list vl) {
    if (!log_file || level > AV_LOG_INFO) return;
    char line[1024];
    int print_prefix = 1;
    av_log_format_line2(avcl, level, fmt, vl, line, sizeof line, &print_prefix);
    time_t t = time(NULL);
    char ts[32];
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&t));
    while (atomic_flag_test_and_set(&log_lock)) {}
    fprintf(log_file, "%s  %s", ts, line);
    size_t n = strlen(line);
    if (n == 0 || line[n - 1] != '\n') fputc('\n', log_file);
    fflush(log_file);
    atomic_flag_clear(&log_lock);
}

TC_API void tce_set_log_file(const char *path) {
    FILE *f = fopen(path, "w");
    if (!f) return;
    log_file = f;
    av_log_set_level(AV_LOG_INFO);
    av_log_set_callback(log_cb);
}

TC_API void tce_stats(TCEngine *s, char *buf, int len) {
    if (!s || !buf || len <= 0) return;
    snprintf(buf, len,
             "%s: pacotes=%lld video=%lld chave=%lld descartados_esperando_chave=%lld enviados=%lld "
             "imagens=%lld falhas_conversao=%lld erros_decodificacao=%lld trocas_pra_cpu=%lld decodificador=%s",
             s->url_host, s->pkts, s->video_pkts, s->key_pkts, s->skipped, s->sent, s->frames,
             s->bgra_fail, s->dec_errors, s->fallbacks, s->hw_device ? "GPU" : "CPU");
}

static void maybe_log_stats(TCEngine *s) {
    long long now = now_sec();
    if (!log_file || now - s->last_stats < 5) return;
    s->last_stats = now;
    char buf[512];
    tce_stats(s, buf, sizeof buf);
    av_log(NULL, AV_LOG_INFO, "%s\n", buf);
}

static long long now_sec(void) {
#ifdef _WIN32
    return (long long)(GetTickCount64() / 1000);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec;
#endif
}

static int interrupt_cb(void *opaque) {
    TCEngine *s = opaque;
    if (atomic_load(&s->aborted) || (s->cancel && *s->cancel)) return 1;
    return now_sec() - atomic_load(&s->last_io) > s->timeout_sec;
}

static enum AVPixelFormat pick_format(AVCodecContext *ctx, const enum AVPixelFormat *fmts) {
    (void)ctx;
    for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++)
        if (*p == HW_FMT) return *p;
    return fmts[0];
}

static void set_err(char *err, int errlen, const char *what, int code) {
    if (!err || errlen <= 0) return;
    char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
    if (code) av_strerror(code, buf, sizeof buf);
    snprintf(err, errlen, "%s%s%s", what, code ? ": " : "", buf);
}

static void open_error(char *err, int errlen, int r) {
    if (r == AVERROR(EPERM) || r == AVERROR_HTTP_UNAUTHORIZED)
        set_err(err, errlen, "A câmera recusou: senha errada ou muitas conexões ao mesmo tempo (feche outros apps vendo esta câmera)", 0);
    else if (r == AVERROR_HTTP_NOT_FOUND)
        set_err(err, errlen, "Vídeo não encontrado nessa câmera", 0);
    else if (r == AVERROR(EHOSTUNREACH) || r == AVERROR(ENETUNREACH))
        set_err(err, errlen, "Sem rota até a câmera (fora de casa? confira o Tailscale)", 0);
    else if (r == AVERROR_EXIT || r == AVERROR(ETIMEDOUT))
        set_err(err, errlen, "Câmera não responde (desligada ou fora da rede?)", 0);
    else
        set_err(err, errlen, "Não conectou", r);
}

// Creates the decoder, on the GPU when `hardware` and available, else on the CPU.
static int open_decoder(TCEngine *s, int hardware) {
    if (s->dec) avcodec_free_context(&s->dec);
    if (s->hw_device) av_buffer_unref(&s->hw_device);
    AVCodecParameters *par = s->fmt->streams[s->video_index]->codecpar;
    const AVCodec *codec = avcodec_find_decoder(par->codec_id);
    if (!codec) return AVERROR_DECODER_NOT_FOUND;
    s->dec = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(s->dec, par);
#ifdef _WIN32
    // GPU decoding on Windows is opt-in (TAPOCAM_HW=1) until it is proven on real machines.
    const char *hw_env = getenv("TAPOCAM_HW");
    if (!hw_env || strcmp(hw_env, "1") != 0) hardware = 0;
#endif
    if (hardware && !getenv("TAPOCAM_NO_HW") &&
        av_hwdevice_ctx_create(&s->hw_device, HW_TYPE, NULL, NULL, 0) == 0) {
        s->dec->hw_device_ctx = av_buffer_ref(s->hw_device);
        s->dec->get_format = pick_format;
    } else {
        // Software: threads inside each frame only. Frame threading would hold back
        // one frame per core, which delays the first image and adds live latency.
        s->dec->thread_count = 0;
        s->dec->thread_type = FF_THREAD_SLICE;
        s->dec->flags |= AV_CODEC_FLAG_LOW_DELAY;
    }
    s->need_key = 1;
    s->hw_failures = 0;
    s->packets_no_frame = 0;
    return avcodec_open2(s->dec, codec, NULL);
}

// The GPU path failed on this machine: continue on the CPU.
static int fall_back_to_software(TCEngine *s) {
    s->fallbacks++;
    av_log(NULL, AV_LOG_WARNING, "tcengine %s: GPU sem imagem, trocando pra CPU\n", s->url_host);
    return open_decoder(s, 0);
}

TC_API TCEngine *tce_open(const char *url, int timeout_sec, volatile int *cancel, char *err, int errlen) {
    static int net_ready = 0;
    if (!net_ready) { avformat_network_init(); net_ready = 1; }

    TCEngine *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    s->cancel = cancel;
    {   // "host:port/path" without user:password, for the log
        const char *at = strrchr(url, '@');
        const char *start = at ? at + 1 : (strstr(url, "://") ? strstr(url, "://") + 3 : url);
        snprintf(s->url_host, sizeof s->url_host, "%s", start);
    }
    s->timeout_sec = timeout_sec > 0 ? timeout_sec : 10;
    atomic_store(&s->last_io, now_sec());

    s->fmt = avformat_alloc_context();
    s->fmt->interrupt_callback.callback = interrupt_cb;
    s->fmt->interrupt_callback.opaque = s;

    AVDictionary *opts = NULL;
    av_dict_set(&opts, "rtsp_transport", "tcp", 0);
    char us[32];
    snprintf(us, sizeof us, "%lld", (long long)s->timeout_sec * 1000000LL);
    av_dict_set(&opts, "timeout", us, 0);
    // Start fast: Tapo describes the stream in the RTSP handshake, so little probing is needed.
    av_dict_set(&opts, "analyzeduration", "500000", 0);
    av_dict_set(&opts, "probesize", "262144", 0);

    int r = avformat_open_input(&s->fmt, url, NULL, &opts);
    av_dict_free(&opts);
    if (r < 0) {
        open_error(err, errlen, r);
        av_log(NULL, AV_LOG_WARNING, "tcengine %s: %s\n", s->url_host, err ? err : "");
        s->fmt = NULL;
        tce_close(s);
        return NULL;
    }

    s->fmt->max_analyze_duration = AV_TIME_BASE / 2;
    atomic_store(&s->last_io, now_sec());
    if ((r = avformat_find_stream_info(s->fmt, NULL)) < 0) {
        set_err(err, errlen, "Sem informação do vídeo", r);
        tce_close(s);
        return NULL;
    }

    const AVCodec *codec = NULL;
    s->video_index = av_find_best_stream(s->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    if (s->video_index < 0 || !codec) {
        set_err(err, errlen, "Stream sem vídeo", s->video_index);
        tce_close(s);
        return NULL;
    }

    if ((r = open_decoder(s, 1)) < 0 && (r = open_decoder(s, 0)) < 0) {
        set_err(err, errlen, "Decodificador falhou", r);
        tce_close(s);
        return NULL;
    }

    av_log(NULL, AV_LOG_INFO, "tcengine %s: conectado, %s %dx%d, decodificador %s\n", s->url_host,
           avcodec_get_name(s->dec->codec_id), s->dec->width, s->dec->height, s->hw_device ? "GPU" : "CPU");
    s->pkt = av_packet_alloc();
    s->frame = av_frame_alloc();
    s->sw_frame = av_frame_alloc();
    return s;
}

static int to_bgra(TCEngine *s, AVFrame *f) {
    AVFrame *src = f;
    if (f->hw_frames_ctx) { // GPU frame: copy to memory first
        av_frame_unref(s->sw_frame);
        if (av_hwframe_transfer_data(s->sw_frame, f, 0) < 0) return -1;
        src = s->sw_frame;
    }
    if (!s->bgra || s->bgra_w != src->width || s->bgra_h != src->height) {
        av_freep(&s->bgra);
        s->bgra_stride = FFALIGN(src->width * 4, 64);
        s->bgra = av_malloc((size_t)s->bgra_stride * src->height);
        if (!s->bgra) return -1;
        s->bgra_w = src->width;
        s->bgra_h = src->height;
    }
    s->sws = sws_getCachedContext(s->sws, src->width, src->height, src->format,
                                  src->width, src->height, AV_PIX_FMT_BGRA,
                                  SWS_BILINEAR, NULL, NULL, NULL);
    if (!s->sws) return -1;
    uint8_t *dst[4] = {s->bgra};
    int dst_stride[4] = {s->bgra_stride};
    sws_scale(s->sws, (const uint8_t *const *)src->data, src->linesize, 0, src->height, dst, dst_stride);
    return 0;
}

TC_API int tce_read(TCEngine *s, uint8_t **data, int *width, int *height, int *stride,
                    char *err, int errlen) {
    *data = NULL;
    for (;;) {
        int r = avcodec_receive_frame(s->dec, s->frame);
        if (r == 0) {
            int was_hw = s->frame->hw_frames_ctx != NULL;
            int ok = to_bgra(s, s->frame);
            av_frame_unref(s->frame);
            if (ok < 0) {
                s->bgra_fail++;
                if (was_hw && ++s->hw_failures >= 3 && fall_back_to_software(s) < 0) {
                    set_err(err, errlen, "Decodificador falhou", 0);
                    return -1;
                }
                continue;
            }
            s->bad_frames = 0;
            s->packets_no_frame = 0;
            if (s->frames++ == 0) av_log(NULL, AV_LOG_INFO, "tcengine %s: primeira imagem\n", s->url_host);
            maybe_log_stats(s);
            *data = s->bgra;
            *width = s->bgra_w;
            *height = s->bgra_h;
            *stride = s->bgra_stride;
            return 1;
        }
        if (r != AVERROR(EAGAIN)) {
            s->dec_errors++;
            if (++s->bad_frames > 50) {
                set_err(err, errlen, "Erro ao decodificar", r);
                return -1;
            }
            avcodec_flush_buffers(s->dec);
            s->need_key = 1;
        }

        atomic_store(&s->last_io, now_sec());
        r = av_read_frame(s->fmt, s->pkt);
        maybe_log_stats(s);
        if (r < 0) {
            set_err(err, errlen, atomic_load(&s->aborted) ? "Parado" : "Conexão perdida", r);
            return -1;
        }
        s->pkts++;
        if (s->pkt->stream_index == s->video_index) {
            s->video_pkts++;
            if (s->pkt->flags & AV_PKT_FLAG_KEY) s->key_pkts++;
            if (s->need_key && !(s->pkt->flags & AV_PKT_FLAG_KEY)) {
                s->skipped++;
                av_packet_unref(s->pkt);
                continue;
            }
            s->need_key = 0;
            // ~3 s of video into the GPU decoder without one image out: use the CPU.
            if (s->hw_device && ++s->packets_no_frame > 45) {
                av_packet_unref(s->pkt);
                if (fall_back_to_software(s) < 0) {
                    set_err(err, errlen, "Decodificador falhou", 0);
                    return -1;
                }
                continue;
            }
            r = avcodec_send_packet(s->dec, s->pkt);
            s->sent++;
            if (r < 0 && r != AVERROR(EAGAIN)) {
                s->dec_errors++;
                if (s->dec_errors <= 5) {
                    char e[AV_ERROR_MAX_STRING_SIZE] = {0};
                    av_strerror(r, e, sizeof e);
                    av_log(NULL, AV_LOG_WARNING, "tcengine %s: erro ao decodificar: %s\n", s->url_host, e);
                }
                if (++s->bad_frames > 50) {
                    av_packet_unref(s->pkt);
                    set_err(err, errlen, "Erro ao decodificar", r);
                    return -1;
                }
                avcodec_flush_buffers(s->dec);
                s->need_key = 1;
            }
        }
        av_packet_unref(s->pkt);
    }
}

TC_API int tce_hardware(TCEngine *s) { return s && s->hw_device ? 1 : 0; }

TC_API void tce_abort(TCEngine *s) {
    if (s) atomic_store(&s->aborted, 1);
}

TC_API void tce_close(TCEngine *s) {
    if (!s) return;
    if (s->pkt) {
        char buf[512];
        tce_stats(s, buf, sizeof buf);
        av_log(NULL, AV_LOG_INFO, "tcengine fechado %s\n", buf);
    }
    if (s->frame) av_frame_free(&s->frame);
    if (s->sw_frame) av_frame_free(&s->sw_frame);
    if (s->pkt) av_packet_free(&s->pkt);
    if (s->dec) avcodec_free_context(&s->dec);
    if (s->hw_device) av_buffer_unref(&s->hw_device);
    if (s->fmt) avformat_close_input(&s->fmt);
    if (s->sws) sws_freeContext(s->sws);
    av_freep(&s->bgra);
    free(s);
}
