#!/bin/bash
# Build dist/Lock In.app.
#
# Signs ad-hoc by default, for local use. Set CODESIGN_IDENTITY to a
# "Developer ID Application: …" identity (as the release workflow does) to
# sign for distribution: that adds the Hardened Runtime and a secure
# timestamp, both required for notarization.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${CODESIGN_IDENTITY:--}"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="dist/Lock In.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LockIn" "$APP/Contents/MacOS/LockIn"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/blocked.html "$APP/Contents/Resources/blocked.html"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

SIGN_FLAGS=(--force --sign "$IDENTITY" --entitlements Resources/LockIn.entitlements)
if [ "$IDENTITY" != "-" ]; then SIGN_FLAGS+=(--options runtime --timestamp); fi
codesign "${SIGN_FLAGS[@]}" "$APP"
printf 'Built %s\n' "$APP"
