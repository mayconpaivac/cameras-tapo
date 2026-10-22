#!/bin/bash
# Builds TapoCam.app in ./build
set -euo pipefail
cd "$(dirname "$0")"

# One fixed identity for every build: macOS ties Keychain access to it.
BUNDLE_ID="br.com.mayconpaiva.cameras-tapo"
IDENTITY="Apple Development: Maycon Paiva (55UWJV3A6U)"
if ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
    echo "Erro: certificado '$IDENTITY' não encontrado no Keychain." >&2
    exit 1
fi

if [ ! -f Vendor/ffmpeg/mac/lib/libavcodec.a ]; then
    echo "Compilando o FFmpeg embutido (só na primeira vez)..."
    Vendor/ffmpeg/build-mac.sh
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/TapoCam"

APP="build/TapoCam.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TapoCam"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TapoCam</string>
    <key>CFBundleDisplayName</key><string>Câmeras</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>TapoCam</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- Cameras (RTSP/ONVIF) and the home PC bridge speak plain HTTP inside the LAN or the
         Tailscale tunnel (already encrypted), so App Transport Security must allow it.
         (Only NSAllowsArbitraryLoads: adding NSAllowsLocalNetworking makes macOS ignore it.) -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
    <key>NSLocalNetworkUsageDescription</key>
    <string>O app precisa acessar a rede local para mostrar as câmeras.</string>
</dict>
</plist>
PLIST

if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi

codesign --force --sign "$IDENTITY" "$APP"
echo "Pronto: $APP"
