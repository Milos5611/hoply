# AgentBar

A macOS menu bar app that shows what your AI coding agents are doing: Claude Code, GitHub Copilot (CLI and JetBrains), Qwen Code on your local model, and the vLLM server behind it. It is one Swift app with a small listener built in, so there is no separate daemon to run.

```
Claude Code ── hooks + OTel logs ──┐
Copilot CLI ── hooks (+ OTel) ─────┤
Copilot in JetBrains ── OTel ──────┼──▶ AgentBar (127.0.0.1:4318) ──▶ menu bar panel
Qwen Code ── OTel ─────────────────┘          │
vLLM on the ZGX ◀── polls /metrics ───────────┤
Claude 5-hour / weekly limits ◀── polls ──────┘
```

## What each source gives you

| Source | How it reports | What you see |
|---|---|---|
| Claude Code | hooks (state) + OpenTelemetry logs (tokens, cost) | working / needs permission / your turn, task title, last tool, tokens, cost |
| Copilot CLI | hooks (state), optional OpenTelemetry (tokens) | working / needs permission / your turn, task title, last tool |
| Copilot in JetBrains | OpenTelemetry only (Copilot hooks aren't supported in JetBrains or Visual Studio) | working / idle, tokens |
| Qwen Code | OpenTelemetry | working / idle, prompt title, tokens |
| vLLM (ZGX) | Prometheus `/metrics` | model, running and queued requests, tokens/s, KV cache |
| Claude plan | Claude Code's own login, read from the Keychain | 5-hour and weekly usage with reset times |

Your chat UI talks to vLLM directly, so its activity shows up in the vLLM card.

## Run it

Requires macOS 14+ and Xcode (for `swift test`).

```bash
swift test                      # unit tests, using real OTLP payloads as fixtures
swift run AgentBar              # quick try: the icon appears in the menu bar
scripts/simulate.sh             # in another terminal: fake activity to see the panel work
scripts/make-app.sh --install   # real use: builds AgentBar.app into ~/Applications and opens it
```

Notifications and "Launch at login" only work in the bundled app.

## Connect your agents

Each script backs up the file it changes and supports `--uninstall`. Set `AGENTBAR_PORT` if you change the port in the app.

```bash
scripts/setup-claude-code.sh        # hooks + OTel logs in ~/.claude/settings.json
scripts/setup-copilot-cli.sh        # hooks in ~/.copilot/hooks/agentbar.json
scripts/setup-copilot-cli.sh --add-alias   # optional: copilot alias with OTel on, for token counts
scripts/setup-qwen-code.sh          # telemetry block in ~/.qwen/settings.json
```

If `~/.claude/settings.json` already sends OpenTelemetry somewhere (a company collector, for example), the Claude script leaves that alone and installs hooks only. Pass `--force` to override.

**Copilot in JetBrains:** open Settings → Tools → GitHub Copilot → Chat, turn on the OpenTelemetry export, and set the OTLP endpoint to `http://127.0.0.1:4318` (HTTP). AgentBar accepts both JSON and protobuf.

**vLLM:** open the panel → gear icon → Server URL, for example `http://<zgx-ip>:8000`. AgentBar reads `<url>/metrics` every 5 seconds. Private-range IPs are allowed through App Transport Security in `Info.plist`; macOS will ask once for Local Network access.

**Claude limits:** click Connect in the Claude plan card. macOS asks once whether `security` may read the "Claude Code-credentials" Keychain item; choose Always Allow. If it says the login expired, open Claude Code once and it refreshes the token.

## Check that events arrive

```bash
curl -s http://127.0.0.1:4318/health
echo '{"hook_event_name":"UserPromptSubmit","session_id":"t1","cwd":"'$PWD'","prompt":"hello"}' \
  | curl -s -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:4318/hooks/claude-code
```

The footer shows "Listening on 127.0.0.1:4318", or why it isn't (for example, the port is already taken by an OpenTelemetry collector; change it in settings and re-run the setup scripts with `AGENTBAR_PORT`).

## Layout

```
Sources/AgentKit/      platform-neutral core
  HubServer.swift      Network.framework listener, loopback only
  HTTP.swift           HTTP/1.1 parser (Content-Length and chunked)
  HubRouter.swift      routes /v1/{logs,traces,metrics} and /hooks/<source>/<event>
  OTLPDecoder.swift    OTLP JSON + protobuf (hand-rolled wire reader, no dependencies)
  HookMapper.swift     Claude Code / Copilot CLI hook payloads → events
  TelemetryMapper.swift  Claude, Qwen, Copilot (GenAI conventions) telemetry → events
  SessionBoard.swift   session state machine
  VLLM.swift           Prometheus parser + vLLM snapshot and rates
  ClaudeLimits.swift   plan limits decode + Keychain/HTTP client
Sources/AgentBar/      SwiftUI menu bar app
Tests/AgentKitTests/   tests; fixtures were produced by the official OpenTelemetry JS exporters
scripts/               setup, simulate, make-app
```

## Known gaps

- `api.anthropic.com/api/oauth/usage` is the undocumented endpoint Claude Code's `/usage` uses; it can change without notice.
- Copilot CLI's OTel service name and encoding aren't documented in detail. If its tokens appear as a separate "Copilot IDE" row, adjust `TelemetryMapper.source(of:)`.
- JetBrains Copilot and Qwen Code have no hooks here, so they can't show "needs permission" or "your turn", only working and idle.
- OTLP over gRPC and gzip-compressed bodies aren't supported; use HTTP and no compression.
