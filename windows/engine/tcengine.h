#ifndef TCENGINE_H
#define TCENGINE_H

#include <stdint.h>

#ifdef _WIN32
#define TC_API __declspec(dllexport)
#else
#define TC_API __attribute__((visibility("default")))
#endif

typedef struct TCEngine TCEngine;

/// Opens an RTSP stream (TCP). Returns NULL on failure and writes a message to `err` (UTF-8).
/// When `*cancel` becomes non-zero (from any thread) the open gives up right away.
TC_API TCEngine *tce_open(const char *url, int timeout_sec, volatile int *cancel, char *err, int errlen);

/// Blocks until the next decoded frame.
/// Returns 1 with a BGRA image in *data (valid until the next call), 0 when no frame
/// is ready yet (call again), -1 on error or end of stream.
TC_API int tce_read(TCEngine *s, uint8_t **data, int *width, int *height, int *stride,
                    char *err, int errlen);

/// 1 if frames are decoded on the GPU, 0 if on the CPU.
TC_API int tce_hardware(TCEngine *s);

/// Makes any blocking call on this stream return quickly. Thread-safe.
TC_API void tce_abort(TCEngine *s);

TC_API void tce_close(TCEngine *s);

/// Writes FFmpeg and engine messages (with counters every 5 s per stream) to a UTF-8 file.
TC_API void tce_set_log_file(const char *path);

/// One-line counters for this stream (packets, keyframes, images, failures).
TC_API void tce_stats(TCEngine *s, char *buf, int len);

#endif
