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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_DIR/LockIn" "$APP/Contents/MacOS/LockIn"
# The `lockin` command line tool. install-app.sh links it onto your PATH.
cp "$BIN_DIR/lockin-cli" "$APP/Contents/Helpers/lockin"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/blocked.html "$APP/Contents/Resources/blocked.html"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ships with the app so `lockin upgrade` installs a release with that release's own install steps.
cp Scripts/install.sh "$APP/Contents/Resources/install.sh"

SIGN_FLAGS=(--force --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then SIGN_FLAGS+=(--options runtime --timestamp); fi
# Nested code is signed first, inside out; the CLI needs no entitlements.
codesign "${SIGN_FLAGS[@]}" --identifier app.lockin.mac.cli "$APP/Contents/Helpers/lockin"
codesign "${SIGN_FLAGS[@]}" --entitlements Resources/LockIn.entitlements "$APP"
printf 'Built %s\n' "$APP"
