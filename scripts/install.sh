#!/usr/bin/env bash
# Usage: scripts/install.sh [--uninstall]
#   Builds Hoply.app into ~/Applications, connects Claude Code and Copilot CLI (`Hoply --connect`), and opens it.
#   --uninstall disconnects both agents (`Hoply --disconnect`); the app stays in ~/Applications.
# Env: HOPLY_PORT (default: the app's saved port, else 4318), CLAUDE_CONFIG_DIR (default ~/.claude),
#      COPILOT_HOME (default ~/.copilot), HOPLY_SIGN_IDENTITY (codesign identity name; default "-" = ad-hoc)
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="$HOME/Applications/Hoply.app"
# Ad-hoc signatures change on every build, so Keychain and TCC grants are asked for again after each install.
# A stable self-signed identity keeps them.
SIGN_IDENTITY="${HOPLY_SIGN_IDENTITY:--}"

case "${1:-}" in
  "") UNINSTALL=0 ;;
  --uninstall) UNINSTALL=1 ;;
  *) echo "Usage: scripts/install.sh [--uninstall]" >&2; exit 2 ;;
esac

install_app() {
  local app
  app="$(HOPLY_SIGN_IDENTITY="$SIGN_IDENTITY" scripts/build-app.sh)"
  mkdir -p "$HOME/Applications"
  pkill -x Hoply 2>/dev/null || true
  rm -rf "$TARGET"
  ditto "$app" "$TARGET"
  # Re-register so Finder and Notification Center pick up a changed icon.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET" || true
  echo "Hoply: installed to $TARGET (signed with: $SIGN_IDENTITY)"
}

if [ "$UNINSTALL" = 1 ]; then
  bin="$TARGET/Contents/MacOS/Hoply"
  # An app from before `--disconnect` existed would ignore the flag and start its UI instead of exiting.
  if [ ! -x "$bin" ] || ! grep -qaF -- "--disconnect" "$bin"; then
    swift build -c release --product Hoply >&2
    bin="$(swift build -c release --show-bin-path)/Hoply"
  fi
  "$bin" --disconnect
  exit 0
fi

install_app
connected=0
"$TARGET/Contents/MacOS/Hoply" --connect || connected=$?
open "$TARGET"
echo "Hoply: opened."
exit "$connected"
