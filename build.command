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
<key>CFBundleShortVersionString</key><string>1.5.6</string>
<key>CFBundleVersion</key><string>23</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSCameraUsageDescription</key><string>MenuCam 使用摄像头，将你主动开始的录像保存在你选择的本地文件夹。</string>
<key>NSMicrophoneUsageDescription</key><string>MenuCam 使用麦克风，把声音一起录进保存在本机的视频；音频不连接网络。</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "已构建：$APP"
