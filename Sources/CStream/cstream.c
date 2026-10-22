#include "cstream.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <time.h>

struct TCStream {
    AVFormatContext *fmt;
    AVCodecContext *dec;
    AVBufferRef *hw_device;
    AVPacket *pkt;
    AVFrame *frame;
    struct SwsContext *sws;
    CVPixelBufferPoolRef pool;
    int pool_w, pool_h;
    int video_index;
    int timeout_sec;
    int need_key;    // skip packets until a keyframe (hardware decoders need one first)
    int bad_frames;  // consecutive decode errors
    atomic_int aborted;
    volatile int *cancel;
    atomic_llong last_io; // seconds, monotonic
};

static long long now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec;
}

// Called by FFmpeg during blocking I/O. Non-zero aborts the operation.
static int interrupt_cb(void *opaque) {
    TCStream *s = opaque;
    if (atomic_load(&s->aborted) || (s->cancel && *s->cancel)) return 1;
    return now_sec() - atomic_load(&s->last_io) > s->timeout_sec;
}

static enum AVPixelFormat pick_format(AVCodecContext *ctx, const enum AVPixelFormat *fmts) {
    (void)ctx;
    for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++)
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
    return fmts[0]; // software fallback
}

static void set_err(char *err, int errlen, const char *what, int code) {
    if (!err || errlen <= 0) return;
    char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
    if (code) av_strerror(code, buf, sizeof buf);
    snprintf(err, errlen, "%s%s%s", what, code ? ": " : "", buf);
}

TCStream *tc_open(const char *url, int timeout_sec, volatile int *cancel, char *err, int errlen) {
    TCStream *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    s->cancel = cancel;
    s->timeout_sec = timeout_sec > 0 ? timeout_sec : 10;
    atomic_store(&s->last_io, now_sec());

    s->fmt = avformat_alloc_context();
    s->fmt->interrupt_callback.callback = interrupt_cb;
    s->fmt->interrupt_callback.opaque = s;

    AVDictionary *opts = NULL;
    av_dict_set(&opts, "rtsp_transport", "tcp", 0); // works through VPNs and NAT
    av_dict_set(&opts, "flags", "low_delay", 0);
    char us[32];
    snprintf(us, sizeof us, "%lld", (long long)s->timeout_sec * 1000000LL);
    av_dict_set(&opts, "timeout", us, 0);

    int r = avformat_open_input(&s->fmt, url, NULL, &opts);
    av_dict_free(&opts);
    if (r < 0) {
        if (r == AVERROR(EPERM) || r == AVERROR_HTTP_UNAUTHORIZED)
            set_err(err, errlen, "A câmera recusou: senha errada ou muitas conexões ao mesmo tempo (feche outros apps vendo esta câmera)", 0);
        else if (r == AVERROR_HTTP_NOT_FOUND)
            set_err(err, errlen, "Vídeo não encontrado nessa câmera", 0);
        else if (r == AVERROR(EHOSTUNREACH))
            set_err(err, errlen, "Sem acesso à rede: libere o app em Ajustes → Privacidade e Segurança → Rede Local (ou ligue o Tailscale, se estiver fora de casa)", 0);
        else if (r == AVERROR_EXIT || r == AVERROR(ETIMEDOUT))
            set_err(err, errlen, "Câmera não responde (desligada ou fora da rede?)", 0);
        else
            set_err(err, errlen, "Não conectou", r);
        s->fmt = NULL; // freed by avformat_open_input on failure
        tc_close(s);
        return NULL;
    }

    s->fmt->max_analyze_duration = 2 * AV_TIME_BASE;
    atomic_store(&s->last_io, now_sec());
    if ((r = avformat_find_stream_info(s->fmt, NULL)) < 0) {
        set_err(err, errlen, "Sem informação do vídeo", r);
        tc_close(s);
        return NULL;
    }

    const AVCodec *codec = NULL;
    s->video_index = av_find_best_stream(s->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    if (s->video_index < 0 || !codec) {
        set_err(err, errlen, "Stream sem vídeo", s->video_index);
        tc_close(s);
        return NULL;
    }

    s->dec = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(s->dec, s->fmt->streams[s->video_index]->codecpar);
    s->dec->flags |= AV_CODEC_FLAG_LOW_DELAY;
    if (av_hwdevice_ctx_create(&s->hw_device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) == 0) {
        s->dec->hw_device_ctx = av_buffer_ref(s->hw_device);
        s->dec->get_format = pick_format;
    }
    if ((r = avcodec_open2(s->dec, codec, NULL)) < 0) {
        set_err(err, errlen, "Decodificador falhou", r);
        tc_close(s);
        return NULL;
    }

    s->need_key = 1;
    s->pkt = av_packet_alloc();
    s->frame = av_frame_alloc();
    return s;
}

// Converts a software frame to a BGRA CVPixelBuffer.
static CVPixelBufferRef sw_to_pixelbuffer(TCStream *s, AVFrame *f) {
    if (!s->pool || s->pool_w != f->width || s->pool_h != f->height) {
        if (s->pool) CVPixelBufferPoolRelease(s->pool);
        s->pool = NULL;
        CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        int fmt = kCVPixelFormatType_32BGRA;
        CFNumberRef n_fmt = CFNumberCreate(NULL, kCFNumberIntType, &fmt);
        CFNumberRef n_w = CFNumberCreate(NULL, kCFNumberIntType, &f->width);
        CFNumberRef n_h = CFNumberCreate(NULL, kCFNumberIntType, &f->height);
        CFDictionaryRef io = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(attrs, kCVPixelBufferPixelFormatTypeKey, n_fmt);
        CFDictionarySetValue(attrs, kCVPixelBufferWidthKey, n_w);
        CFDictionarySetValue(attrs, kCVPixelBufferHeightKey, n_h);
        CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, io);
        CVPixelBufferPoolCreate(NULL, NULL, attrs, &s->pool);
        CFRelease(n_fmt); CFRelease(n_w); CFRelease(n_h); CFRelease(io); CFRelease(attrs);
        s->pool_w = f->width;
        s->pool_h = f->height;
        if (!s->pool) return NULL;
    }

    s->sws = sws_getCachedContext(s->sws, f->width, f->height, f->format,
                                  f->width, f->height, AV_PIX_FMT_BGRA,
                                  SWS_BILINEAR, NULL, NULL, NULL);
    if (!s->sws) return NULL;

    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, s->pool, &pb) != kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *dst[4] = {CVPixelBufferGetBaseAddress(pb)};
    int dst_stride[4] = {(int)CVPixelBufferGetBytesPerRow(pb)};
    sws_scale(s->sws, (const uint8_t *const *)f->data, f->linesize, 0, f->height, dst, dst_stride);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

int tc_read(TCStream *s, CVPixelBufferRef *out, double *pts, char *err, int errlen) {
    *out = NULL;
    *pts = NAN;
    for (;;) {
        int r = avcodec_receive_frame(s->dec, s->frame);
        if (r == 0) {
            CVPixelBufferRef pb = NULL;
            int64_t ts = s->frame->best_effort_timestamp;
            if (ts != AV_NOPTS_VALUE)
                *pts = ts * av_q2d(s->fmt->streams[s->video_index]->time_base);
            if (s->frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
                pb = (CVPixelBufferRef)s->frame->data[3];
                if (pb) CVPixelBufferRetain(pb);
            } else {
                pb = sw_to_pixelbuffer(s, s->frame);
            }
            av_frame_unref(s->frame);
            s->bad_frames = 0;
            if (!pb) return 0;
            *out = pb;
            return 1;
        }
        if (r != AVERROR(EAGAIN)) {
            // A damaged frame is common on Wi-Fi: wait for the next keyframe.
            if (++s->bad_frames > 50) {
                set_err(err, errlen, "Erro ao decodificar", r);
                return -1;
            }
            avcodec_flush_buffers(s->dec);
            s->need_key = 1;
        }

        atomic_store(&s->last_io, now_sec());
        r = av_read_frame(s->fmt, s->pkt);
        if (r < 0) {
            set_err(err, errlen, atomic_load(&s->aborted) ? "Parado" : "Conexão perdida", r);
            return -1;
        }
        if (s->pkt->stream_index == s->video_index) {
            if (s->need_key && !(s->pkt->flags & AV_PKT_FLAG_KEY)) {
                av_packet_unref(s->pkt);
                continue;
            }
            s->need_key = 0;
            r = avcodec_send_packet(s->dec, s->pkt);
            if (r < 0 && r != AVERROR(EAGAIN)) {
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

void tc_abort(TCStream *s) {
    if (s) atomic_store(&s->aborted, 1);
}

void tc_close(TCStream *s) {
    if (!s) return;
    if (s->frame) av_frame_free(&s->frame);
    if (s->pkt) av_packet_free(&s->pkt);
    if (s->dec) avcodec_free_context(&s->dec);
    if (s->hw_device) av_buffer_unref(&s->hw_device);
    if (s->fmt) avformat_close_input(&s->fmt);
    if (s->sws) sws_freeContext(s->sws);
    if (s->pool) CVPixelBufferPoolRelease(s->pool);
    free(s);
}
