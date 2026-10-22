#!/bin/bash
# Cross-compiles a minimal, static, LGPL FFmpeg for Windows x64 (needs: brew install mingw-w64).
# Same feature set as the Mac build, with D3D11VA hardware decoding.
# Output: Vendor/ffmpeg/windows/{include,lib}
set -euo pipefail
cd "$(dirname "$0")"

VERSION="9.0.2"
OUT="$PWD/windows"
WORK="${TMPDIR:-/tmp}/ffmpeg-build-windows"

rm -rf "$WORK" && mkdir -p "$WORK"
curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o "$WORK/src.tar.xz"
tar -xf "$WORK/src.tar.xz" -C "$WORK"
cd "$WORK/ffmpeg-$VERSION"

./configure \
    --prefix="$OUT" \
    --arch=x86_64 --target-os=mingw32 --cross-prefix=x86_64-w64-mingw32- \
    --enable-static --disable-shared \
    --disable-programs --disable-doc --disable-debug \
    --disable-autodetect --enable-w32threads --enable-d3d11va \
    --disable-everything \
    --disable-avdevice --disable-avfilter --disable-swresample \
    --enable-network \
    --enable-protocol=tcp,udp,rtp,file \
    --enable-demuxer=rtsp,rtp,sdp,h264,hevc,mov \
    --enable-parser=h264,hevc \
    --enable-decoder=h264,hevc \
    --enable-hwaccel=h264_d3d11va,hevc_d3d11va

make -j"$(sysctl -n hw.ncpu)"
rm -rf "$OUT"
make install
rm -rf "$OUT/share" "$OUT/lib/pkgconfig"
echo "FFmpeg $VERSION (Windows) -> $OUT"
du -sh "$OUT/lib"
