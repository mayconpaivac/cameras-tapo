#ifndef CSTREAM_H
#define CSTREAM_H

#include <CoreVideo/CoreVideo.h>

typedef struct TCStream TCStream;

/// Opens an RTSP stream. Returns NULL on failure and writes a message to `err`.
/// When `*cancel` becomes non-zero (from any thread) the open gives up right away.
TCStream *tc_open(const char *url, int timeout_sec, volatile int *cancel, char *err, int errlen);

/// Blocks until the next decoded frame.
/// Returns 1 with a retained CVPixelBuffer in *out (caller releases) and the
/// camera's timestamp in seconds in *pts (NAN if unknown),
/// 0 when no frame is ready yet (call again), -1 on error/end of stream.
int tc_read(TCStream *s, CVPixelBufferRef *out, double *pts, char *err, int errlen);

/// Makes any blocking call on this stream return quickly. Thread-safe.
void tc_abort(TCStream *s);

void tc_close(TCStream *s);

#endif
