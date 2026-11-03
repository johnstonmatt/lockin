#!/bin/bash
# Build Lock In and install it to /Applications, replacing any existing copy.
# Quits a running copy first and relaunches it afterwards. If the app refuses to
# quit (an active session asks for a pause reason; Hardcore Mode blocks quitting),
# the install is aborted rather than force-killing it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Lock In"
BUNDLE_ID="app.lockin.mac"
SOURCE="dist/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

bash Scripts/build-app.sh

is_running() { pgrep -xq LockIn; }

was_running=false
if is_running; then
    was_running=true
    printf 'Quitting running %s…\n' "$APP_NAME"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in {1..20}; do is_running || break; sleep 0.5; done
    if is_running; then
        printf '%s did not quit. It may be in a session (pause or end it first) or in Hardcore Mode.\n' "$APP_NAME" >&2
        printf 'Nothing was installed. The new build is at %s.\n' "$SOURCE" >&2
        exit 1
    fi
fi

# Move the build next to the destination first, so a failed move never leaves
# /Applications without the app. The build is moved, not copied: dist/ won't hold it afterwards.
STAGING="/Applications/.$APP_NAME.app.installing"
rm -rf "$STAGING"
mv "$SOURCE" "$STAGING"
rm -rf "$DEST"
mv "$STAGING" "$DEST"
printf 'Installed %s\n' "$DEST"

if $was_running; then open "$DEST"; fi
