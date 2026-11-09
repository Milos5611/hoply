#!/usr/bin/env bash
# Connects Claude Code to AgentBar.
#   - hooks in ~/.claude/settings.json report live state (working / needs permission / your turn)
#   - OpenTelemetry log export adds per-session tokens and cost
#
# Usage: scripts/setup-claude-code.sh [--uninstall] [--no-telemetry] [--force]
# Env:   AGENTBAR_PORT (default 4318), CLAUDE_CONFIG_DIR (default ~/.claude)
set -euo pipefail

PORT="${AGENTBAR_PORT:-4318}"
ENDPOINT="http://127.0.0.1:${PORT}"
SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
MARKER="# agentbar"
UNINSTALL=0
TELEMETRY=1
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL=1 ;;
    --no-telemetry) TELEMETRY=0 ;;
    --force) FORCE=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "jq is required (macOS 15+ ships /usr/bin/jq, or: brew install jq)" >&2; exit 1; }

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq empty "$SETTINGS" 2>/dev/null || { echo "$SETTINGS is not valid JSON; fix it first." >&2; exit 1; }

BACKUP="$SETTINGS.agentbar-backup-$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$BACKUP"

HOOK_CMD="curl -s -m 2 -o /dev/null -H 'Expect:' -H 'Content-Type: application/json' --data-binary @- ${ENDPOINT}/hooks/claude-code || true ${MARKER}"
EVENTS='["SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","PermissionRequest","Notification","Stop","SessionEnd"]'

# Telemetry: logs only, sent as OTLP/JSON to AgentBar. Signal-specific variables leave any
# other OpenTelemetry setup (metrics, traces) alone.
TELEMETRY_ENV=$(jq -n --arg logs "${ENDPOINT}/v1/logs" '{
  CLAUDE_CODE_ENABLE_TELEMETRY: "1",
  OTEL_LOGS_EXPORTER: "otlp",
  OTEL_EXPORTER_OTLP_LOGS_PROTOCOL: "http/json",
  OTEL_EXPORTER_OTLP_LOGS_ENDPOINT: $logs,
  OTEL_LOGS_EXPORT_INTERVAL: "2000"
}')

STRIP='
  def strip_agentbar:
    if (.hooks | type) == "object" then
      .hooks |= with_entries(
        .value |= ( map(if (.hooks | type) == "array"
                        then .hooks |= map(select(((.command // "") | contains($marker)) | not))
                        else . end)
                    | map(select((.hooks | type) != "array" or (.hooks | length) > 0)) ))
      | .hooks |= with_entries(select((.value | length) > 0))
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end;
  def strip_telemetry($ours):
    if (.env | type) == "object" then
      .env |= with_entries(select(.key as $k | ($ours[$k] == null) or (.value != $ours[$k])))
      | if (.env | length) == 0 then del(.env) else . end
    else . end;
'

if [ "$UNINSTALL" = 1 ]; then
  jq --arg marker "$MARKER" --argjson ours "$TELEMETRY_ENV" "$STRIP"' strip_agentbar | strip_telemetry($ours)' \
    "$BACKUP" > "$SETTINGS"
  echo "Removed AgentBar hooks and telemetry from $SETTINGS (backup: $BACKUP)"
  exit 0
fi

if [ "$TELEMETRY" = 1 ] && [ "$FORCE" = 0 ]; then
  CONFLICT=$(jq -r '
    (.env // {}) as $e
    | [ (if ($e.OTEL_EXPORTER_OTLP_ENDPOINT // "") != "" then "OTEL_EXPORTER_OTLP_ENDPOINT" else empty end),
        (if ($e.OTEL_LOGS_EXPORTER // "otlp") != "otlp" then "OTEL_LOGS_EXPORTER" else empty end),
        (if (($e.OTEL_EXPORTER_OTLP_LOGS_ENDPOINT // "") != "") and (($e.OTEL_EXPORTER_OTLP_LOGS_ENDPOINT | test("127\\.0\\.0\\.1|localhost")) | not)
         then "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT" else empty end) ]
    | join(", ")' "$SETTINGS")
  if [ -n "$CONFLICT" ]; then
    echo "Your settings already configure OpenTelemetry ($CONFLICT)."
    echo "Skipping telemetry so that setup is not overwritten. Re-run with --force to replace it."
    TELEMETRY=0
  fi
fi

jq --arg marker "$MARKER" --arg cmd "$HOOK_CMD" --argjson events "$EVENTS" \
   --argjson ours "$TELEMETRY_ENV" --argjson telemetry "$TELEMETRY" "$STRIP"'
  strip_agentbar
  | .hooks = (.hooks // {})
  | reduce $events[] as $e (.;
      .hooks[$e] = ((.hooks[$e] // []) + [{hooks: [{type: "command", command: $cmd, timeout: 5}]}]))
  | if $telemetry == 1 then .env = ((.env // {}) + $ours) else . end
' "$BACKUP" > "$SETTINGS"

echo "Claude Code → AgentBar on ${ENDPOINT}"
echo "  hooks:     $(jq -r --argjson events "$EVENTS" '$events | join(", ")' <<<'{}')"
if [ "$TELEMETRY" = 1 ]; then echo "  telemetry: OTLP/JSON logs → ${ENDPOINT}/v1/logs"; else echo "  telemetry: skipped"; fi
echo "  settings:  $SETTINGS (backup: $BACKUP)"
echo "Restart running Claude Code sessions to pick this up."
