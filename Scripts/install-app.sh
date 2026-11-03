#!/bin/bash
# Build Lock In and install it to /Applications, replacing any existing copy.
# A running copy is asked to quit via lockin://update: it pauses an in-progress
# session ("Updating Lock In"), quits, and resumes the session when relaunched.
# If it refuses (Hardcore Mode), the install is aborted rather than force-killing it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Lock In"
BUNDLE_ID="app.lockin.mac"
SOURCE="dist/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

bash Scripts/build-app.sh

is_running() { pgrep -xq LockIn; }
wait_for_quit() { for _ in {1..20}; do is_running || return 0; sleep 0.5; done; ! is_running; }

was_running=false
if is_running; then
    was_running=true
    printf 'Quitting running %s…\n' "$APP_NAME"
    open -g -b "$BUNDLE_ID" "lockin://update"
    if ! wait_for_quit; then
        # Builds older than lockin://update ignore it; fall back to a normal quit.
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        wait_for_quit || true
    fi
    if is_running; then
        printf '%s did not quit. Hardcore Mode blocks quitting until the session ends; builds without\n' "$APP_NAME" >&2
        printf 'lockin://update instead wait for a pause reason in the Lock In window.\n' >&2
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
