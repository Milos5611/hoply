#!/usr/bin/env bash
# Connects Qwen Code to AgentBar by turning on its OpenTelemetry export in ~/.qwen/settings.json.
# otlpProtocol "http" sends OTLP/JSON to <endpoint>/v1/{logs,traces,metrics}.
#
# Usage: scripts/setup-qwen-code.sh [--uninstall] [--force]
# Env:   AGENTBAR_PORT (default 4318)
set -euo pipefail

PORT="${AGENTBAR_PORT:-4318}"
ENDPOINT="http://127.0.0.1:${PORT}"
SETTINGS="$HOME/.qwen/settings.json"
UNINSTALL=0
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL=1 ;;
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

if [ "$UNINSTALL" = 1 ]; then
  jq --arg endpoint "$ENDPOINT" '
    if (.telemetry.otlpEndpoint // "") == $endpoint
    then del(.telemetry.enabled, .telemetry.otlpEndpoint, .telemetry.otlpProtocol)
         | if (.telemetry | length) == 0 then del(.telemetry) else . end
    else . end' "$BACKUP" > "$SETTINGS"
  echo "Removed AgentBar telemetry from $SETTINGS (backup: $BACKUP)"
  exit 0
fi

if [ "$FORCE" = 0 ]; then
  CURRENT=$(jq -r '(.telemetry.otlpEndpoint // "") + "|" + (.telemetry.outfile // "")' "$SETTINGS")
  CURRENT_ENDPOINT="${CURRENT%%|*}"
  CURRENT_OUTFILE="${CURRENT#*|}"
  if { [ -n "$CURRENT_ENDPOINT" ] && [ "$CURRENT_ENDPOINT" != "$ENDPOINT" ]; } || [ -n "$CURRENT_OUTFILE" ]; then
    echo "Qwen Code telemetry already points somewhere else (endpoint: ${CURRENT_ENDPOINT:-none}, outfile: ${CURRENT_OUTFILE:-none})."
    echo "Re-run with --force to send it to AgentBar instead."
    exit 1
  fi
fi

jq --arg endpoint "$ENDPOINT" '
  .telemetry = ((.telemetry // {}) | del(.outfile) + {
    enabled: true,
    otlpEndpoint: $endpoint,
    otlpProtocol: "http"
  })' "$BACKUP" > "$SETTINGS"

echo "Qwen Code → AgentBar on ${ENDPOINT}"
echo "  telemetry: OTLP/JSON (logs give prompts, tokens and tool calls)"
echo "  settings:  $SETTINGS (backup: $BACKUP)"
echo "Restart Qwen Code to pick this up."
