#!/usr/bin/env bash
# Run from Windows (Git Bash): push the current branch, then build + launch it
# on the Mac over SSH. Compiler errors stream back to this terminal.
#
#   scripts/remote-build.sh              # tvOS simulator
#   scripts/remote-build.sh device       # paired Apple TV
#
# Configure once via environment (or a .env file next to this script):
#   MAC_HOST          ssh target, e.g. jj@macbook.local
#   MAC_REPO          repo path on the Mac, e.g. ~/Projects/NuvioTVOS
#   TVOS_DEVICE_NAME  Apple TV name as shown in Xcode > Devices (device only)
#   DEVELOPMENT_TEAM  10-char team id from Xcode > Signing (device only)
#
# The Mac clone is a build mirror: it is force-reset to whatever was pushed.
# Do not edit files on the Mac; edit here and re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && . "$SCRIPT_DIR/.env"

: "${MAC_HOST:?set MAC_HOST, e.g. jj@macbook.local}"

# On Windows, prefer the system OpenSSH client over Git Bash's: only the
# system one can reach the Windows agent pipe (1Password's SSH agent).
SSH_BIN="${SSH_BIN:-ssh}"
if [ -x /c/Windows/System32/OpenSSH/ssh.exe ]; then
  SSH_BIN=/c/Windows/System32/OpenSSH/ssh.exe
fi
MAC_REPO="${MAC_REPO:-~/Projects/NuvioTVOS}"
TARGET="${1:-simulator}"
BRANCH="$(git -C "$SCRIPT_DIR/.." rev-parse --abbrev-ref HEAD)"

echo ">> pushing $BRANCH"
git -C "$SCRIPT_DIR/.." push -q -u origin "$BRANCH"

echo ">> building $BRANCH on $MAC_HOST ($TARGET)"
# zsh -l so xcodebuild/xcrun resolve the same way they do in a Terminal window.
# Local env values are forwarded explicitly since ssh does not pass them.
"$SSH_BIN" -t "$MAC_HOST" "zsh -lc '
  set -e
  cd $MAC_REPO
  git fetch -q origin
  # Mirror is disposable: drop any local edits/untracked files before syncing.
  git reset -q --hard && git clean -qfd
  git checkout -q -B $BRANCH origin/$BRANCH
  git submodule update --init --recursive
  TVOS_DEVICE_NAME=\"${TVOS_DEVICE_NAME:-}\" DEVELOPMENT_TEAM=\"${DEVELOPMENT_TEAM:-}\" \
    bash scripts/mac-build.sh $TARGET
'"
