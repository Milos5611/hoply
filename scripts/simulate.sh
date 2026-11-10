#!/usr/bin/env bash
# Sends fake agent activity to a running Hoply so you can see the panel work
# before wiring up real agents. Usage: scripts/simulate.sh   (DELAY=0 for no pauses)
set -euo pipefail

PORT="${HOPLY_PORT:-4318}"
URL="http://127.0.0.1:${PORT}"
DELAY="${DELAY:-1.5}"

curl -s -m 2 -o /dev/null "$URL/health" || { echo "Hoply is not listening on $URL. Start it first." >&2; exit 1; }

post() {
  local status
  # Real hooks send their agent's pid; this shell is no agent, so Hoply reads the header and trusts nothing.
  status=$(curl -s -m 3 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H "X-Hoply-Pid: $$" --data-binary "$2" "$URL$1")
  [ "$status" = "200" ] || echo "   ! $1 answered HTTP $status" >&2
}
step() { echo "→ $1"; sleep "$DELAY"; }
now_ns() { echo "$(date +%s)000000000"; }
hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; } # random bytes as lowercase hex, like OTel trace/span ids
attr() { printf ',{"key":"%s","value":{"%s":"%s"}}' "$1" "$2" "$3"; } # key, stringValue|intValue, value

otlp_log() { # service, session, event name, extra attributes JSON (array items), extra resource attributes JSON
  printf '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"%s"}}%s]},"scopeLogs":[{"scope":{"name":"sim"},"logRecords":[{"timeUnixNano":"%s","eventName":"%s","attributes":[{"key":"session.id","value":{"stringValue":"%s"}}%s]}]}]}]}' \
    "$1" "${5:-}" "$(now_ns)" "$3" "$2" "${4:-}"
}

otlp_chat_span() { # service, conversation id, model, input tokens, output tokens
  local start; start="$(now_ns)"
  printf '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"%s"}}]},"scopeSpans":[{"scope":{"name":"sim"},"spans":[{"traceId":"%s","spanId":"%s","name":"chat %s","kind":3,"startTimeUnixNano":"%s","endTimeUnixNano":"%s","attributes":[{"key":"gen_ai.operation.name","value":{"stringValue":"chat"}}%s%s%s%s]}]}]}]}' \
    "$1" "$(hex 16)" "$(hex 8)" "$3" "$start" "$start" "$(attr gen_ai.conversation.id stringValue "$2")" \
    "$(attr gen_ai.request.model stringValue "$3")" "$(attr gen_ai.usage.input_tokens intValue "$4")" \
    "$(attr gen_ai.usage.output_tokens intValue "$5")"
}

CLAUDE_CWD="$HOME/Project/fiba"
# Real Claude Code hooks always send transcript_path; this one doesn't exist, so the ledger ignores it.
CLAUDE_TRANSCRIPT="${TMPDIR:-/tmp}/hoply-sim/sim-claude.jsonl"
COPILOT_CWD="$HOME/Project/yasm-backend"

post /hooks/claude-code "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"sim-claude\",\"transcript_path\":\"$CLAUDE_TRANSCRIPT\",\"cwd\":\"$CLAUDE_CWD\",\"source\":\"startup\",\"model\":\"claude-opus-5\"}"
post /hooks/claude-code "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"sim-claude\",\"transcript_path\":\"$CLAUDE_TRANSCRIPT\",\"cwd\":\"$CLAUDE_CWD\",\"prompt\":\"Refactor the auth middleware to use refresh tokens\"}"
post /hooks/claude-code "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"sim-claude\",\"transcript_path\":\"$CLAUDE_TRANSCRIPT\",\"cwd\":\"$CLAUDE_CWD\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm test\"}}"
post /v1/logs "$(otlp_log claude-code sim-claude api_request ',{"key":"model","value":{"stringValue":"claude-opus-5"}},{"key":"input_tokens","value":{"intValue":"5200"}},{"key":"output_tokens","value":{"intValue":"830"}},{"key":"cache_read_tokens","value":{"intValue":"48000"}},{"key":"cost_usd","value":{"doubleValue":0.21}}')"
step "Claude Code is working (Bash)"

post /hooks/copilot-cli/sessionStart "{\"sessionId\":\"sim-copilot\",\"timestamp\":$(date +%s)000,\"cwd\":\"$COPILOT_CWD\",\"source\":\"new\",\"initialPrompt\":\"Add pagination to the orders endpoint\"}"
post /hooks/copilot-cli/preToolUse "{\"sessionId\":\"sim-copilot\",\"timestamp\":$(date +%s)000,\"cwd\":\"$COPILOT_CWD\",\"toolName\":\"bash\",\"toolArgs\":\"{}\"}"
step "Copilot CLI is working"

# Qwen Code and Copilot IDE have no local history: their OTel is the ledger. hoply.cwd (set by the user through
# OTEL_RESOURCE_ATTRIBUTES) names the project; without it Hoply asks the process.pid for its cwd.
QWEN_RESOURCE="$(attr hoply.cwd stringValue "$CLAUDE_CWD")$(attr process.pid intValue $$)"
post /v1/logs "$(otlp_log qwen-code sim-qwen qwen-code.user_prompt "$(attr prompt stringValue 'Write unit tests for the Prometheus parser')" "$QWEN_RESOURCE")"
QWEN_RESPONSE="$(otlp_log qwen-code sim-qwen qwen-code.api_response "$(attr model stringValue qwen3-coder)$(attr prompt_id stringValue sim-p1)$(attr input_token_count intValue 2400)$(attr output_token_count intValue 610)" "$QWEN_RESOURCE")"
post /v1/logs "$QWEN_RESPONSE"
post /v1/logs "$QWEN_RESPONSE" # re-sent batch: same prompt_id and timeUnixNano, so the ledger keeps one row
post /v1/logs "$(otlp_log qwen-code sim-qwen-pid qwen-code.api_response "$(attr model stringValue qwen3-coder)$(attr prompt_id stringValue sim-p2)$(attr input_token_count intValue 900)$(attr output_token_count intValue 120)" "$(attr process.pid intValue $$)")"
step "Qwen Code is working (sim-qwen in $CLAUDE_CWD; sim-qwen-pid in this shell's cwd via process.pid)"

COPILOT_IDE_SPAN="$(otlp_chat_span copilot-chat sim-copilot-ide claude-sonnet-5 18400 920)"
post /v1/traces "$COPILOT_IDE_SPAN"
post /v1/traces "$COPILOT_IDE_SPAN" # re-sent batch: same trace and span id, so the ledger keeps one row
post /v1/traces "$(otlp_chat_span copilot-chat sim-copilot-ide claude-sonnet-5 21000 450)"
step "Copilot in the IDE made two model calls (Unassigned: no hoply.cwd)"

post /hooks/claude-code "{\"hook_event_name\":\"Notification\",\"session_id\":\"sim-claude\",\"transcript_path\":\"$CLAUDE_TRANSCRIPT\",\"cwd\":\"$CLAUDE_CWD\",\"notification_type\":\"permission_prompt\",\"message\":\"Claude needs your permission to use Bash\"}"
step "Claude Code needs permission"

claude_hook() { # event name, extra JSON fields (start with a comma)
  post /hooks/claude-code "{\"hook_event_name\":\"$1\",\"session_id\":\"sim-claude\",\"transcript_path\":\"$CLAUDE_TRANSCRIPT\",\"cwd\":\"$CLAUDE_CWD\"${2:-}}"
}
claude_hook PostToolUse ',"tool_name":"Bash"'
claude_hook SubagentStart ',"agent_id":"sim-agent-1","agent_type":"Explore"'
claude_hook SubagentStart ',"agent_id":"sim-agent-2","agent_type":"general-purpose"'
claude_hook PreToolUse ',"tool_name":"Grep","agent_id":"sim-agent-1","agent_type":"Explore"'
step "Claude Code runs two subagents"

claude_hook SubagentStop ',"agent_id":"sim-agent-1","agent_type":"Explore"'
claude_hook PreToolUse ',"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Rotate refresh tokens on every use?","header":"Rotation","options":[{"label":"Yes"},{"label":"No"}]}]}'
step "Claude Code asks a question (Input), one subagent still working"

claude_hook PostToolUse ',"tool_name":"AskUserQuestion"'
claude_hook SubagentStop ',"agent_id":"sim-agent-2","agent_type":"general-purpose"'
step "Claude Code got its answer"

post /hooks/copilot-cli/agentStop "{\"sessionId\":\"sim-copilot\",\"timestamp\":$(date +%s)000,\"cwd\":\"$COPILOT_CWD\",\"stopReason\":\"end_turn\"}"
step "Copilot CLI finished its turn"

post /hooks/claude-code "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"sim-claude\",\"transcript_path\":\"$CLAUDE_TRANSCRIPT\",\"cwd\":\"$CLAUDE_CWD\",\"tool_name\":\"Bash\"}"
post /hooks/claude-code "{\"hook_event_name\":\"Stop\",\"session_id\":\"sim-claude\",\"transcript_path\":\"$CLAUDE_TRANSCRIPT\",\"cwd\":\"$CLAUDE_CWD\",\"last_assistant_message\":\"Middleware now refreshes tokens; all 214 tests pass.\"}"
echo "→ Claude Code finished its turn"
echo "Done. Right-click a row → Dismiss to clear the demo sessions."
