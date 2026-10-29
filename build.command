#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
APP="$PWD/MenuCam.app"
mkdir -p "$APP/Contents/MacOS"
CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/menucam-module-cache" xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 Sources/*.swift -o "$APP/Contents/MacOS/MenuCam" -framework AppKit -framework SwiftUI -framework AVFoundation -framework IOKit -framework CoreAudio -framework Network -framework Security
if [ -f "$PWD/AppIcon.icns" ]; then
  mkdir -p "$APP/Contents/Resources"
  cp "$PWD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MenuCam</string>
<key>CFBundleIdentifier</key><string>local.junxian.MenuCam</string>
<key>CFBundleName</key><string>MenuCam</string>
<key>CFBundleDisplayName</key><string>MenuCam</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.6.0</string>
<key>CFBundleVersion</key><string>30</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSCameraUsageDescription</key><string>MenuCam uses the camera for recordings and on-demand photos. Recordings are saved to your chosen local folder; photos stay in memory.</string>
<key>NSMicrophoneUsageDescription</key><string>MenuCam uses the microphone to add audio to videos saved on this Mac. Audio is not streamed over the network.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built: $APP"
