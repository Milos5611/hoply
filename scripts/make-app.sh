#!/usr/bin/env bash
# Builds AgentBar.app (release, ad-hoc signed) into ./build.
# Usage: scripts/make-app.sh [--install]   (--install copies it to ~/Applications and opens it)
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release --product AgentBar
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="build/AgentBar.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AgentBar" "$APP/Contents/MacOS/AgentBar"
cp Sources/AgentBar/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  pkill -x AgentBar 2>/dev/null || true
  rm -rf "$HOME/Applications/AgentBar.app"
  ditto "$APP" "$HOME/Applications/AgentBar.app"
  open "$HOME/Applications/AgentBar.app"
  echo "Installed to ~/Applications/AgentBar.app and launched it"
fi
