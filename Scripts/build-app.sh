#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="dist/Lock In.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LockIn" "$APP/Contents/MacOS/LockIn"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/blocked.html "$APP/Contents/Resources/blocked.html"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --entitlements Resources/LockIn.entitlements "$APP"
printf 'Built %s\n' "$APP"
