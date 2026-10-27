#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
VERIFY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/menucam-verify.XXXXXX")
trap 'rm -rf "$VERIFY_DIR"' EXIT
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/menucam-module-cache"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 Sources/AdaptiveWriter.swift Sources/CameraFrameReadiness.swift Sources/SpeechEnhancer.swift Tests/AdaptiveWriterTests.swift -o "$VERIFY_DIR/writer" -framework AVFoundation -framework CoreImage -framework AudioToolbox
"$VERIFY_DIR/writer" "$VERIFY_DIR/test.mov"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 Sources/RemoteServer.swift Sources/WebIcon.swift Tests/RemoteServerTests.swift -o "$VERIFY_DIR/remote" -framework Network -framework Security
"$VERIFY_DIR/remote"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 Sources/AdaptiveWriter.swift Sources/CameraFrameReadiness.swift Tests/PhotoPreviewTests.swift -o "$VERIFY_DIR/photo" -framework AVFoundation -framework CoreImage
"$VERIFY_DIR/photo"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 Sources/DisplayDimmer.swift Tests/DisplayDimmerTests.swift -o "$VERIFY_DIR/display" -framework AppKit
"$VERIFY_DIR/display"
if [[ "${1:-}" == "--hardware" ]]; then
  xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 Sources/QuietMode.swift Tests/QuietModeTests.swift -o "$VERIFY_DIR/quiet" -framework CoreAudio
  "$VERIFY_DIR/quiet"
  "$VERIFY_DIR/display" --hardware
fi

if [[ "${1:-}" == "--blackout" ]]; then
  xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 Sources/DisplayDimmer.swift Sources/BlackoutMode.swift Sources/RemoteServer.swift Sources/WebIcon.swift Tests/BlackoutModeTests.swift -o "$VERIFY_DIR/blackout" -framework AppKit -framework Network -framework Security
  "$VERIFY_DIR/blackout"
fi

xcrun swiftc -swift-version 5 Sources/CameraFrameReadiness.swift Tests/CameraFrameReadinessTests.swift -o "$VERIFY_DIR/readiness" -framework CoreImage
"$VERIFY_DIR/readiness"

xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 Sources/AdaptiveWriter.swift Sources/CameraFrameReadiness.swift Sources/RemoteServer.swift Sources/WebIcon.swift Tests/RecordingSnapshotTests.swift -o "$VERIFY_DIR/live-photos" -framework AVFoundation -framework CoreImage -framework Network -framework Security
"$VERIFY_DIR/live-photos"
