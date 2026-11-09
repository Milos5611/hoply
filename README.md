# Hoply

A macOS menu bar app that shows what your AI coding agents are doing: Claude Code, GitHub Copilot (CLI and JetBrains), Qwen Code on your local model, and the vLLM server behind it. It is one Swift app with a small listener built in, so there is no separate daemon to run.

```
Claude Code ── hooks + OTel logs ──┐
Copilot CLI ── hooks (+ OTel) ─────┤
Copilot in JetBrains ── OTel ──────┼──▶ Hoply (127.0.0.1:4318) ──▶ menu bar panel
Qwen Code ── OTel ─────────────────┘      │
vLLM on the ZGX ◀── polls /metrics ───────┤
Claude 5-hour / weekly limits ◀── polls ──┘
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

Requires macOS 26+ and Xcode 26+ (Swift 6.2 toolchain).

```bash
scripts/install.sh              # build Hoply.app into ~/Applications, open it, connect Claude Code + Copilot CLI
scripts/install.sh --uninstall  # disconnect the agents again
```

That's all. `install.sh` connects whichever of Claude Code and Copilot CLI it finds:
- **Claude Code:** hooks and OTel log export, written to `~/.claude/settings.json` (backed up first). Restart running sessions afterwards.
- **Copilot CLI:** hooks in `~/.copilot/hooks/hoply.json`.

Re-running it is safe. Set `HOPLY_PORT` if you change the port in the app.

By default the app is signed ad-hoc, which gives every build a new identity, so macOS asks again for Keychain and other permissions after each install. To avoid that, create a self-signed code-signing certificate once: Keychain Access → Certificate Assistant → Create a Certificate…, name it `Hoply Dev`, Identity Type "Self Signed Root", Certificate Type "Code Signing". Then install with `HOPLY_SIGN_IDENTITY="Hoply Dev" scripts/install.sh`.

For development:

```bash
swift test                # unit tests, using real OTLP payloads as fixtures
swift run Hoply           # run without bundling (no notifications or launch at login)
scripts/simulate.sh       # with Hoply running: fake agent activity to see the panel work
```

**Copilot in JetBrains:** open Settings → Tools → GitHub Copilot → Chat, turn on the OpenTelemetry export, and set the OTLP endpoint to `http://127.0.0.1:4318` (HTTP). Hoply accepts both JSON and protobuf.

**Local model (vLLM or tensorfold):** open the panel → gear icon → Server URL: the server's base URL without `/metrics`, for example `http://<zgx-ip>:8888`. Hoply reads `<url>/metrics` every 5 seconds. Private-range IPs are allowed through App Transport Security in `Info.plist`; macOS will ask once for Local Network access.

**Claude limits:** click Connect in the Claude plan card. macOS asks once whether `security` may read the "Claude Code-credentials" Keychain item; choose Always Allow. If it says the login expired, open Claude Code once and it refreshes the token.

## Check that events arrive

```bash
curl -s http://127.0.0.1:4318/health
echo '{"hook_event_name":"UserPromptSubmit","session_id":"t1","cwd":"'$PWD'","prompt":"hello"}' \
  | curl -s -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:4318/hooks/claude-code
```

The footer shows "Listening on 127.0.0.1:4318", or why it isn't (for example, the port is already taken by an OpenTelemetry collector; change it in settings and re-run `HOPLY_PORT=<port> scripts/install.sh`).

**Qwen Code** (not connected automatically): add `"telemetry": {"enabled": true, "otlpEndpoint": "http://127.0.0.1:4318", "otlpProtocol": "http"}` to `~/.qwen/settings.json`.

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
  Settings/            AppSettings with lenient per-key decoding
  Usage/               usage records, Claude transcript parser, ledger value types
  Pricing/             price table (bundled as a string literal), cost-state calibration
  Projects/            cwd → project resolver (repo, worktree, folder, home, scratch)
Sources/AgentSystem/   macOS I/O adapters
  Store/               SQLite schema + migrations, Store (writer), StoreReader (queries)
  Ingest/              file tailer, FSEvents watcher, Claude transcript ingester, coordinator
Sources/Hoply/         SwiftUI menu bar app: App/, Services/, Panel/, Components/
Tests/AgentKitTests/   tests; fixtures were produced by the official OpenTelemetry JS exporters
Tests/AgentSystemTests/  adapter tests (in-memory SQLite, temp directories)
scripts/               install.sh (build, install, connect agents), simulate.sh (dev)
```

## Usage history

Hoply keeps its own usage ledger in `~/Library/Application Support/Hoply/hoply.sqlite`. For Claude Code it reads the transcripts under `~/.claude/projects` (read-only), including subagents, so it has history from before Hoply was installed and works with OTel off. Claude Code deletes transcripts after about 30 days; the ledger never deletes rows, so it outlives them.

Costs are API-equivalent list prices from a table bundled in the app. Local models (any model whose name contains `qwen`, configurable) cost $0 and are also priced at a reference model (default `claude-sonnet-5-5`) to show what they saved. Unknown models show as unpriced, not $0. To add or correct a price, put the same shape as the bundled table in `~/Library/Application Support/Hoply/pricing.json`, in USD per million tokens:

```json
{ "models": { "claude-opus-4-5": { "input": 5, "output": 25 } } }
```

Cache prices default to 0.1× input (read), 1.25× (5 minute write) and 2× (1 hour write); `cacheRead`, `cacheWrite5m`, `cacheWrite1h`, `fast` and `longContext` can be set per model.

## Known gaps

- `api.anthropic.com/api/oauth/usage` is the undocumented endpoint Claude Code's `/usage` uses; it can change without notice.
- Copilot CLI's OTel service name and encoding aren't documented in detail. If its tokens appear as a separate "Copilot IDE" row, adjust `TelemetryMapper.source(of:)`.
- JetBrains Copilot and Qwen Code have no hooks here, so they can't show "needs permission" or "your turn", only working and idle.
- OTLP over gRPC and gzip-compressed bodies aren't supported; use HTTP and no compression.
- Claude Code's own `cost-state` totals include calls it never writes to the transcript (title generation, web search, and in subagent-heavy sessions much more), so per-session ledger totals are usually a few percent below it.
