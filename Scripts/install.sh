#!/bin/bash
# Install a built Lock In.app to /Applications, replacing any existing copy, and link the `lockin` CLI.
# Usage: install.sh <path to Lock In.app>. The app is moved there, not copied.
#
# Run by install-app.sh after building from source, and by `lockin upgrade` with a downloaded
# release; it ships inside the app as Contents/Resources/install.sh.
# A running copy is asked to quit via lockin://update: it pauses an in-progress
# session ("Updating Lock In"), quits, and resumes the session when relaunched.
# If it refuses (Hardcore Mode), the install is aborted rather than force-killing it.
# The CLI is linked from the installed app into $LOCKIN_BIN_DIR (default ~/.local/bin).
set -euo pipefail

APP_NAME="Lock In"
BUNDLE_ID="app.lockin.mac"
SOURCE="${1:?Usage: install.sh <path to Lock In.app>}"
DEST="/Applications/$APP_NAME.app"

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

# Move the new app next to the destination first, so a failed move never leaves
# /Applications without the app.
STAGING="/Applications/.$APP_NAME.app.installing"
rm -rf "$STAGING"
mv "$SOURCE" "$STAGING"
rm -rf "$DEST"
mv "$STAGING" "$DEST"
printf 'Installed %s\n' "$DEST"

# A link into the app, so updating the app updates the CLI too.
BIN_DIR="${LOCKIN_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"
ln -sfn "$DEST/Contents/Helpers/lockin" "$BIN_DIR/lockin"
printf 'Linked %s/lockin\n' "$BIN_DIR"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) printf 'Add %s to your PATH to run lockin.\n' "$BIN_DIR" >&2 ;; esac

if $was_running; then open "$DEST"; fi
