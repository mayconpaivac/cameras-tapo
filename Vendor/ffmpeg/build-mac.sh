#!/bin/bash
# Builds a minimal, static, LGPL FFmpeg for the macOS app (Apple Silicon).
# Only what the app needs: RTSP over TCP, H.264/H.265 decode, VideoToolbox, swscale.
# Output: Vendor/ffmpeg/mac/{include,lib}
set -euo pipefail
cd "$(dirname "$0")"

VERSION="9.0.2"
OUT="$PWD/mac"
WORK="${TMPDIR:-/tmp}/ffmpeg-build-mac"

rm -rf "$WORK" && mkdir -p "$WORK"
curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o "$WORK/src.tar.xz"
tar -xf "$WORK/src.tar.xz" -C "$WORK"
cd "$WORK/ffmpeg-$VERSION"

./configure \
    --prefix="$OUT" \
    --arch=arm64 --target-os=darwin --cc=clang \
    --extra-cflags="-mmacosx-version-min=15.0" --extra-ldflags="-mmacosx-version-min=15.0" \
    --enable-static --disable-shared --enable-pic \
    --disable-programs --disable-doc --disable-debug \
    --disable-autodetect --enable-videotoolbox \
    --disable-everything \
    --disable-avdevice --disable-avfilter --disable-swresample \
    --enable-network \
    --enable-protocol=tcp,udp,rtp,file \
    --enable-demuxer=rtsp,rtp,sdp,h264,hevc,mov \
    --enable-parser=h264,hevc \
    --enable-decoder=h264,hevc \
    --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox

make -j"$(sysctl -n hw.ncpu)"
rm -rf "$OUT"
make install
rm -rf "$OUT/share" "$OUT/lib/pkgconfig"
echo "FFmpeg $VERSION -> $OUT"
du -sh "$OUT/lib"
