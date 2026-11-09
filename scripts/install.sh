#!/usr/bin/env bash
# Usage: scripts/install.sh [--uninstall]
#   Builds Hoply.app into ~/Applications, opens it, and connects Claude Code and Copilot CLI.
#   --uninstall disconnects both agents; the app stays in ~/Applications.
# Env: HOPLY_PORT (default 4318), CLAUDE_CONFIG_DIR (default ~/.claude), COPILOT_HOME (default ~/.copilot)
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${HOPLY_PORT:-4318}"
ENDPOINT="http://127.0.0.1:${PORT}"
MARKER="# hoply"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
COPILOT_DIR="${COPILOT_HOME:-$HOME/.copilot}"
COPILOT_HOOKS="$COPILOT_DIR/hooks/hoply.json"

case "${1:-}" in
  "") UNINSTALL=0 ;;
  --uninstall) UNINSTALL=1 ;;
  *) echo "Usage: scripts/install.sh [--uninstall]" >&2; exit 2 ;;
esac

command -v jq >/dev/null || { echo "jq is required (macOS 15+ ships /usr/bin/jq, or: brew install jq)" >&2; exit 1; }

has_claude() { command -v claude >/dev/null || [ -d "$CLAUDE_DIR" ]; }
has_copilot() { command -v copilot >/dev/null || [ -d "$COPILOT_DIR" ]; }

CLAUDE_EVENTS='["SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","PermissionRequest","Notification","Stop","SessionEnd"]'
CLAUDE_HOOK="curl -s -m 2 -o /dev/null -H 'Expect:' -H 'Content-Type: application/json' --data-binary @- ${ENDPOINT}/hooks/claude-code || true ${MARKER}"
# Logs-only, signal-specific OTel variables, so any other OpenTelemetry export (metrics, traces) keeps working.
CLAUDE_ENV=$(jq -n --arg logs "${ENDPOINT}/v1/logs" '{
  CLAUDE_CODE_ENABLE_TELEMETRY: "1",
  OTEL_LOGS_EXPORTER: "otlp",
  OTEL_EXPORTER_OTLP_LOGS_PROTOCOL: "http/json",
  OTEL_EXPORTER_OTLP_LOGS_ENDPOINT: $logs,
  OTEL_LOGS_EXPORT_INTERVAL: "2000"
}')
CLAUDE_STRIP='
  def strip_hoply:
    if (.hooks | type) == "object" then
      .hooks |= with_entries(
        .value |= ( map(if (.hooks | type) == "array"
                        then .hooks |= map(select((.command // "") | contains($marker) | not))
                        else . end)
                    | map(select((.hooks | type) != "array" or (.hooks | length) > 0)) ))
      | .hooks |= with_entries(select((.value | length) > 0))
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end
    | if (.env | type) == "object" then
        .env |= with_entries(select(.key as $k | ($ours[$k] == null) or (.value != $ours[$k])))
        | if (.env | length) == 0 then del(.env) else . end
      else . end;
'

edit_claude_settings() {
  mkdir -p "$CLAUDE_DIR"
  [ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"
  jq empty "$CLAUDE_SETTINGS" 2>/dev/null || { echo "$CLAUDE_SETTINGS is not valid JSON; fix it first." >&2; exit 1; }
  local backup
  backup="$CLAUDE_SETTINGS.hoply-backup-$(date +%Y%m%d%H%M%S)"
  cp "$CLAUDE_SETTINGS" "$backup"
  jq --arg marker "$MARKER" --arg cmd "$CLAUDE_HOOK" --argjson events "$CLAUDE_EVENTS" \
     --argjson ours "$CLAUDE_ENV" "$CLAUDE_STRIP$1" "$backup" > "$CLAUDE_SETTINGS"
  echo "Claude Code: $2 ($CLAUDE_SETTINGS, backup: $backup)"
}

connect_claude() {
  edit_claude_settings '
    strip_hoply
    | .hooks = (.hooks // {})
    | reduce $events[] as $e (.;
        .hooks[$e] = ((.hooks[$e] // []) + [{hooks: [{type: "command", command: $cmd, timeout: 5}]}]))
    | .env = ((.env // {}) + $ours)' "connected; restart running sessions"
}

disconnect_claude() {
  edit_claude_settings 'strip_hoply' "disconnected"
}

# Copilot CLI hook payloads carry no event name, so each hook posts to /hooks/copilot-cli/<event>.
connect_copilot() {
  mkdir -p "$(dirname "$COPILOT_HOOKS")"
  jq -n --arg endpoint "$ENDPOINT" '{
    version: 1,
    hooks: (reduce ["sessionStart","userPromptSubmitted","preToolUse","postToolUse","permissionRequest",
                    "notification","agentStop","sessionEnd","errorOccurred"][] as $e ({};
      .[$e] = [{
        type: "command",
        bash: ("curl -s -m 2 -o /dev/null -H '\''Expect:'\'' -H '\''Content-Type: application/json'\'' --data-binary @- "
               + $endpoint + "/hooks/copilot-cli/" + $e + " || true")
      }]))
  }' > "$COPILOT_HOOKS"
  echo "Copilot CLI: connected ($COPILOT_HOOKS)"
}

disconnect_copilot() {
  [ -f "$COPILOT_HOOKS" ] || return 0
  mv "$COPILOT_HOOKS" "$COPILOT_HOOKS.removed-$(date +%Y%m%d%H%M%S)"
  echo "Copilot CLI: disconnected ($COPILOT_HOOKS renamed)"
}

install_app() {
  swift build -c release --product Hoply
  local bin app=build/Hoply.app target="$HOME/Applications/Hoply.app"
  bin="$(swift build -c release --show-bin-path)/Hoply"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$bin" "$app/Contents/MacOS/Hoply"
  cp Sources/Hoply/Info.plist "$app/Contents/Info.plist"
  codesign --force --sign - "$app"
  mkdir -p "$HOME/Applications"
  pkill -x Hoply 2>/dev/null || true
  rm -rf "$target"
  ditto "$app" "$target"
  open "$target"
  echo "Hoply: installed to $target and opened"
}

if [ "$UNINSTALL" = 1 ]; then
  has_claude && disconnect_claude
  disconnect_copilot
  exit 0
fi

install_app
if has_claude; then connect_claude; else echo "Claude Code: not found, skipped"; fi
if has_copilot; then connect_copilot; else echo "Copilot CLI: not found, skipped"; fi
echo "Done. Hoply listens on ${ENDPOINT}."
