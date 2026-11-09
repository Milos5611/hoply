#!/usr/bin/env bash
# Sends fake agent activity to a running AgentBar so you can see the panel work
# before wiring up real agents. Usage: scripts/simulate.sh   (DELAY=0 for no pauses)
set -euo pipefail

PORT="${AGENTBAR_PORT:-4318}"
URL="http://127.0.0.1:${PORT}"
DELAY="${DELAY:-1.5}"

curl -s -m 2 -o /dev/null "$URL/health" || { echo "AgentBar is not listening on $URL. Start it first." >&2; exit 1; }

post() {
  local status
  status=$(curl -s -m 3 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' --data-binary "$2" "$URL$1")
  [ "$status" = "200" ] || echo "   ! $1 answered HTTP $status" >&2
}
step() { echo "→ $1"; sleep "$DELAY"; }
now_ns() { echo "$(date +%s)000000000"; }

otlp_log() { # service, session, event name, extra attributes JSON (array items)
  printf '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"%s"}}]},"scopeLogs":[{"scope":{"name":"sim"},"logRecords":[{"timeUnixNano":"%s","eventName":"%s","attributes":[{"key":"session.id","value":{"stringValue":"%s"}}%s]}]}]}]}' \
    "$1" "$(now_ns)" "$3" "$2" "${4:-}"
}

CLAUDE_CWD="$HOME/Project/fiba"
COPILOT_CWD="$HOME/Project/yasm-backend"

post /hooks/claude-code "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"sim-claude\",\"cwd\":\"$CLAUDE_CWD\",\"source\":\"startup\",\"model\":\"claude-opus-5\"}"
post /hooks/claude-code "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"sim-claude\",\"cwd\":\"$CLAUDE_CWD\",\"prompt\":\"Refactor the auth middleware to use refresh tokens\"}"
post /hooks/claude-code "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"sim-claude\",\"cwd\":\"$CLAUDE_CWD\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm test\"}}"
post /v1/logs "$(otlp_log claude-code sim-claude api_request ',{"key":"model","value":{"stringValue":"claude-opus-5"}},{"key":"input_tokens","value":{"intValue":"5200"}},{"key":"output_tokens","value":{"intValue":"830"}},{"key":"cache_read_tokens","value":{"intValue":"48000"}},{"key":"cost_usd","value":{"doubleValue":0.21}}')"
step "Claude Code is working (Bash)"

post /hooks/copilot-cli/sessionStart "{\"sessionId\":\"sim-copilot\",\"timestamp\":$(date +%s)000,\"cwd\":\"$COPILOT_CWD\",\"source\":\"new\",\"initialPrompt\":\"Add pagination to the orders endpoint\"}"
post /hooks/copilot-cli/preToolUse "{\"sessionId\":\"sim-copilot\",\"timestamp\":$(date +%s)000,\"cwd\":\"$COPILOT_CWD\",\"toolName\":\"bash\",\"toolArgs\":\"{}\"}"
step "Copilot CLI is working"

post /v1/logs "$(otlp_log qwen-code sim-qwen qwen-code.user_prompt ',{"key":"prompt","value":{"stringValue":"Write unit tests for the Prometheus parser"}}')"
post /v1/logs "$(otlp_log qwen-code sim-qwen qwen-code.api_response ',{"key":"model","value":{"stringValue":"qwen3-coder"}},{"key":"input_token_count","value":{"intValue":"2400"}},{"key":"output_token_count","value":{"intValue":"610"}}')"
step "Qwen Code is working (goes idle after ~45 s of silence)"

post /hooks/claude-code "{\"hook_event_name\":\"Notification\",\"session_id\":\"sim-claude\",\"cwd\":\"$CLAUDE_CWD\",\"notification_type\":\"permission_prompt\",\"message\":\"Claude needs your permission to use Bash\"}"
step "Claude Code needs permission"

post /hooks/copilot-cli/agentStop "{\"sessionId\":\"sim-copilot\",\"timestamp\":$(date +%s)000,\"cwd\":\"$COPILOT_CWD\",\"stopReason\":\"end_turn\"}"
step "Copilot CLI finished its turn"

post /hooks/claude-code "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"sim-claude\",\"cwd\":\"$CLAUDE_CWD\",\"tool_name\":\"Bash\"}"
post /hooks/claude-code "{\"hook_event_name\":\"Stop\",\"session_id\":\"sim-claude\",\"cwd\":\"$CLAUDE_CWD\",\"last_assistant_message\":\"Middleware now refreshes tokens; all 214 tests pass.\"}"
echo "→ Claude Code finished its turn"
echo "Done. Right-click a row → Dismiss to clear the demo sessions."
