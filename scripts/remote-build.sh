#!/usr/bin/env bash
# Run from Windows (Git Bash): build + launch the app on the Mac over SSH.
#
# The Mac's working tree is a live mirror of this one (Mutagen), so there is
# no git step here: whatever is on disk in this repo right now is what gets
# built there, committed or not.
#
#   scripts/remote-build.sh              # tvOS simulator
#   scripts/remote-build.sh device       # paired Apple TV
#
# Configure once via environment (or a .env file next to this script):
#   MAC_HOST          ssh target or ~/.ssh/config alias, e.g. mac
#   MAC_REPO          repo path on the Mac; quote it: '~/Projects/NuvioTVOS'
#   TVOS_DEVICE_NAME  Apple TV name as shown in Xcode > Devices (device only)
#   DEVELOPMENT_TEAM  10-char team id from Xcode > Signing (device only)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && . "$SCRIPT_DIR/.env"

: "${MAC_HOST:?set MAC_HOST, e.g. mac}"
MAC_REPO="${MAC_REPO:-~/Projects/NuvioTVOS}"
# If the local shell tilde-expanded MAC_REPO to the *Windows* home, undo it:
# the path must be expanded by the Mac, not here.
MAC_REPO="${MAC_REPO/#$HOME/~}"
TARGET="${1:-simulator}"

# On Windows, prefer the system OpenSSH client over Git Bash's: only the
# system one can reach the Windows agent pipe (1Password's SSH agent).
SSH_BIN="${SSH_BIN:-ssh}"
[ -x /c/Windows/System32/OpenSSH/ssh.exe ] && SSH_BIN=/c/Windows/System32/OpenSSH/ssh.exe
# Allocate a TTY only when we have one (interactive run); background runs get none.
TTY_FLAG=""; [ -t 0 ] && TTY_FLAG="-t"

echo ">> building $TARGET on $MAC_HOST ($MAC_REPO)"
# zsh -l so xcodebuild/xcrun resolve the same way they do in a Terminal window.
"$SSH_BIN" $TTY_FLAG "$MAC_HOST" "zsh -lc '
  set -e
  cd $MAC_REPO
  TVOS_DEVICE_NAME=\"${TVOS_DEVICE_NAME:-}\" DEVELOPMENT_TEAM=\"${DEVELOPMENT_TEAM:-}\" \
  BUNDLE_ID=\"${BUNDLE_ID:-}\" \
    bash scripts/mac-build.sh $TARGET
'"
