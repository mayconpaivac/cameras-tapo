#!/bin/bash
# Builds the Windows app: dist/CamerasTapo-windows.zip (one .exe, FFmpeg inside).
# Needs: brew install mingw-w64, and the .NET SDK (~/.dotnet or PATH).
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.dotnet:$PATH" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

VERSION="1.4.0"

engine/build.sh windows

# go2rtc (MIT) restreams the cameras on the home PC; fetched once and checked.
G2R=vendor/go2rtc
if [ ! -f "$G2R/go2rtc.exe" ]; then
    curl -fsSL https://github.com/AlexxIT/go2rtc/releases/download/v1.9.14/go2rtc_win64.zip -o "$G2R/g.zip"
    unzip -o -q "$G2R/g.zip" go2rtc.exe -d "$G2R" && rm -f "$G2R/g.zip"
fi
(cd "$G2R" && shasum -a 256 -c SHA256)
rm -rf dist/publish
dotnet publish app/CamerasTapo.csproj -c Release -r win-x64 -o dist/publish
cp bridge/cameras-tapo.ps1 dist/publish/ 2>/dev/null || true
rm -f dist/publish/*.pdb
rm -f dist/CamerasTapo-windows.zip
(cd dist/publish && zip -qr ../CamerasTapo-windows.zip .)
makensis -V2 -INPUTCHARSET UTF8 -DVERSION="$VERSION" installer/CamerasTapo.nsi
ls -la dist/CamerasTapo-Setup.exe dist/CamerasTapo-windows.zip
echo "Pronto: windows/dist/CamerasTapo-Setup.exe (instalador) e CamerasTapo-windows.zip (portátil)"
