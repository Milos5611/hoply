#!/usr/bin/env bash
# Connects GitHub Copilot CLI to AgentBar with user-level hooks (~/.copilot/hooks/agentbar.json).
# Copilot's camelCase hook payloads carry no event name, so each hook posts to
# /hooks/copilot-cli/<event>.
#
# Usage: scripts/setup-copilot-cli.sh [--uninstall] [--add-alias]
#   --add-alias  also appends a `copilot` alias to ~/.zshrc that turns on Copilot's
#                OpenTelemetry export to AgentBar (adds token counts)
# Env:   AGENTBAR_PORT (default 4318), COPILOT_HOME (default ~/.copilot)
set -euo pipefail

PORT="${AGENTBAR_PORT:-4318}"
ENDPOINT="http://127.0.0.1:${PORT}"
HOOKS_DIR="${COPILOT_HOME:-$HOME/.copilot}/hooks"
HOOK_FILE="$HOOKS_DIR/agentbar.json"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
ALIAS_MARKER="# agentbar copilot telemetry"
UNINSTALL=0
ADD_ALIAS=0

for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL=1 ;;
    --add-alias) ADD_ALIAS=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

remove_alias() {
  if [ -f "$ZSHRC" ] && grep -qF "$ALIAS_MARKER" "$ZSHRC"; then
    local tmp
    tmp="$(mktemp)"
    grep -vF "$ALIAS_MARKER" "$ZSHRC" > "$tmp" || true  # grep exits 1 when no lines remain
    cat "$tmp" > "$ZSHRC"
    rm -f "$tmp"
    echo "Removed the copilot alias from $ZSHRC"
  fi
}

if [ "$UNINSTALL" = 1 ]; then
  if [ -f "$HOOK_FILE" ]; then
    mv "$HOOK_FILE" "$HOOK_FILE.removed-$(date +%Y%m%d%H%M%S)"
    echo "Disabled $HOOK_FILE (renamed, delete it whenever you like)"
  fi
  remove_alias
  exit 0
fi

command -v jq >/dev/null || { echo "jq is required (macOS 15+ ships /usr/bin/jq, or: brew install jq)" >&2; exit 1; }
mkdir -p "$HOOKS_DIR"

EVENTS='["sessionStart","userPromptSubmitted","preToolUse","postToolUse","permissionRequest","notification","agentStop","sessionEnd","errorOccurred"]'
jq -n --arg endpoint "$ENDPOINT" --argjson events "$EVENTS" '{
  version: 1,
  hooks: (reduce $events[] as $e ({};
    .[$e] = [{
      type: "command",
      bash: ("curl -s -m 2 -o /dev/null -H '\''Expect:'\'' -H '\''Content-Type: application/json'\'' --data-binary @- "
             + $endpoint + "/hooks/copilot-cli/" + $e + " || true")
    }]))
}' > "$HOOK_FILE"

echo "Copilot CLI → AgentBar on ${ENDPOINT}"
echo "  hooks: $HOOK_FILE"

ALIAS_LINE="alias copilot='COPILOT_OTEL_ENABLED=true OTEL_EXPORTER_OTLP_ENDPOINT=${ENDPOINT} OTEL_EXPORTER_OTLP_PROTOCOL=http/json command copilot' ${ALIAS_MARKER}"
if [ "$ADD_ALIAS" = 1 ]; then
  remove_alias >/dev/null
  echo "$ALIAS_LINE" >> "$ZSHRC"
  echo "  telemetry: alias added to $ZSHRC (open a new terminal)"
else
  echo "  telemetry (optional, adds token counts): add this to $ZSHRC or re-run with --add-alias"
  echo "    $ALIAS_LINE"
fi
echo "New Copilot CLI sessions pick up the hooks automatically."
