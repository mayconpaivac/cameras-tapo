#!/bin/bash
# Builds the video engine with FFmpeg linked in statically.
#   build.sh windows -> tcengine.dll        (Windows x64, needs mingw-w64)
#   build.sh mac     -> libtcengine.dylib   (for running the app on a Mac while developing)
set -euo pipefail
cd "$(dirname "$0")"
FF=../../Vendor/ffmpeg
OUT=out
mkdir -p "$OUT"

case "${1:-windows}" in
windows)
    [ -f "$FF/windows/lib/libavcodec.a" ] || "$FF/build-windows.sh"
    x86_64-w64-mingw32-gcc -O2 -shared -std=c11 -I"$FF/windows/include" tcengine.c \
        "$FF/windows/lib/libavformat.a" "$FF/windows/lib/libavcodec.a" \
        "$FF/windows/lib/libswscale.a" "$FF/windows/lib/libavutil.a" \
        -lws2_32 -lsecur32 -lbcrypt -lole32 -luser32 -lm \
        -static -static-libgcc -Wl,--no-insert-timestamp -s \
        -o "$OUT/tcengine.dll"
    echo "$OUT/tcengine.dll"
    ;;
mac)
    [ -f "$FF/mac/lib/libavcodec.a" ] || "$FF/build-mac.sh"
    clang -O2 -dynamiclib -fvisibility=hidden -mmacosx-version-min=15.0 -I"$FF/mac/include" tcengine.c \
        "$FF/mac/lib/libavformat.a" "$FF/mac/lib/libavcodec.a" \
        "$FF/mac/lib/libswscale.a" "$FF/mac/lib/libavutil.a" \
        -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
        -framework CoreFoundation -framework CoreServices -framework Security \
        -install_name @rpath/libtcengine.dylib -o "$OUT/libtcengine.dylib"
    echo "$OUT/libtcengine.dylib"
    ;;
esac
