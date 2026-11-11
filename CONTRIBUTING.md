# Contributing to Hoply

Thanks for helping. Bug reports, fixes and new agent integrations are all welcome. For anything bigger than a fix,
please open an issue first so we can agree on the approach before you spend time on it. Security problems go by
email, not in issues: see [SECURITY.md](SECURITY.md).

By contributing you agree that your work is released under the [MIT License](LICENSE). The license covers the
code, not the Hoply name or app icon (`Sources/Hoply/Hoply.icon` and the `HoplyMark` glyph): a fork you ship gets
its own name and icon.

## Set up

- macOS 26 or newer and **Xcode 27** (CI uses 27.2). The package declares Swift tools 6.2, but Xcode 26's compiler
  resolves some names differently and doesn't build it.
- It's a Swift package with no Xcode project. Open `Package.swift` in Xcode, or work from the terminal.
- One package dependency: [Sparkle 2](https://github.com/sparkle-project/Sparkle) for updates, linked into the app
  target only. Everything else uses system frameworks (`Network`, `SQLite3`, libproc, `Security`).

```bash
swift build
swift test                                                    # all tests (AgentKitTests + AgentSystemTests)
swift test --filter SessionBoardTests                         # one test class
swift test --filter SessionBoardTests/testClaudeLifecycle     # one test
swift run Hoply                                               # run unbundled; the icon appears in the menu bar
HOPLY_OPEN=panel swift run Hoply                              # open a surface at launch: panel | dashboard | palette (HOPLY_HOLD_OPEN=1 keeps the panel up)
swift run Hoply --snapshot build/snapshots                    # render sample data to PNGs (see Snapshots)
scripts/simulate.sh                                           # with Hoply running: fake agent traffic (see Simulate traffic)
```

Opt-in tests that read your real data (read-only) and compare Hoply's totals with the agents' own:

```bash
HOPLY_REAL_TRANSCRIPTS=1 swift test --filter RealTranscriptsTests  # ingest the real ~/.claude into a temp DB, compare with cost-state
HOPLY_REAL_COPILOT=1 swift test --filter RealCopilotTests          # ingest a temp copy of ~/.copilot/session-store.db, compare with its own sums
HOPLY_REAL_PROCESSES=1 swift test --filter ProcessScannerTests/testRealProcesses  # time a real process scan, print counts
```

## Run a bundled build

`swift run Hoply` runs without a bundle, so there are no notifications, no launch at login and no updates. For those,
install a real `.app`:

```bash
scripts/install.sh              # build Hoply.app into ~/Applications, connect Claude Code, Codex CLI and Copilot CLI, open it
scripts/install.sh --uninstall  # disconnect the agents again
```

`install.sh` builds the app with `scripts/build-app.sh` (the same script release builds use), then runs
`Hoply --connect`, which connects whichever of Claude Code, Codex CLI and Copilot CLI it finds. No `jq` needed.

- **Claude Code:** hooks and OTel log export, written to `~/.claude/settings.json` (backed up first). Restart running
  sessions afterwards.
- **Codex CLI:** hooks added to `~/.codex/hooks.json` (or `$CODEX_HOME`; backed up first, your own hooks stay). Codex
  runs a hook only after you trust it: open Codex, run `/hooks` and trust Hoply's hooks, then restart running
  sessions. After a port change, Update rewrites them and Codex asks again.
- **Copilot CLI:** hooks in `~/.copilot/hooks/hoply.json`.

Re-running it is safe. The app's Settings → Agents card connects, updates and disconnects the same hooks, and says
when they need an update, for example after a port change.

The same code runs without the UI, which is handy against scratch copies of the agent folders:

```bash
swift run Hoply --connect [claude-code] [copilot-cli] [codex-cli]    # --disconnect undoes it; no names = every agent found
CLAUDE_CONFIG_DIR=/tmp/claude COPILOT_HOME=/tmp/copilot CODEX_HOME=/tmp/codex swift run Hoply --connect
```

The port comes from `HOPLY_PORT`, else the saved setting, else 4318.

By default the app is signed ad-hoc, which gives every build a new identity, so macOS asks again for Keychain and
other permissions after each install. To avoid that, create a self-signed code-signing certificate once: Keychain
Access → Certificate Assistant → Create a Certificate…, name it `Hoply Dev`, Identity Type "Self Signed Root",
Certificate Type "Code Signing" (macOS 27 no longer ships Keychain Access, so this works only where it still exists).
Then install with `HOPLY_SIGN_IDENTITY="Hoply Dev" scripts/install.sh`.

## Snapshots

The app target has no tests, so UI changes are checked with snapshots:

```bash
swift run Hoply --snapshot build/snapshots
```

It renders sample data (never your real database) to PNGs: the panel (light, dark, full height, settings, full
settings), every Dashboard page, the Limits empty state, the Local model offline and no-server states, the Clean up
page, report and review sheet, the palette (empty, query, actions, no results) and its settings card, the Agents card
states and the panel's connect and update nudges, and the footer's update button and the Updates card. It needs no
Screen Recording permission, but it can't show Liquid Glass or vibrancy, because the window server draws those; the
Dashboard snapshots draw a plain stand-in for the sidebar for the same reason.

hoply.dev uses some of these images by file name (`panel`, `panel-approval`, `palette-query` and the Dashboard pages).
If your change renames or drops one, say so in the pull request.

## Simulate traffic

With Hoply running, `scripts/simulate.sh` posts fake hook and OpenTelemetry traffic so you can watch the panel work
before wiring up real agents. `DELAY=0` skips the pauses, and `HOPLY_PORT` points it at another port. Its Qwen and
Copilot IDE usage becomes permanent rows in your usage history (sessions named `sim-*`), so run it against a build
whose history you don't mind.

To post a single event by hand:

```bash
curl -s http://127.0.0.1:4318/health
echo '{"hook_event_name":"UserPromptSubmit","session_id":"t1","cwd":"'$PWD'","prompt":"hello"}' \
  | curl -s -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:4318/hooks/claude-code
```

The installed hooks also send `X-Hoply-Pid: $PPID` (the agent's process id), which ties a session to the dev servers
it started. Hoply uses it only after checking that the process is yours, was running before the hook fired and is
the agent (or a shell under it).

## How it fits together

```
Claude Code ─────────── hooks + OTel logs ──┐
Codex CLI ───────────── hooks (+ OTel) ─────┤
Copilot CLI ─────────── hooks (+ OTel) ─────┤
Copilot in JetBrains ── OTel ───────────────┼──▶ Hoply (127.0.0.1:4318) ──▶ panel, Dashboard, notifications
Qwen Code ───────────── OTel ───────────────┘       │
Model servers ◀── polls /metrics or model list ─────┤
Claude plan limits ◀── polls Anthropic ─────────────┤
Agent records ◀── reads into the ledger ────────────┘
```

Agent records are Claude Code's transcripts, Codex's session files and Copilot CLI's session store. Hoply is one
app with its own small HTTP listener, so there is no daemon. The code is split into three targets, and
the split is the main rule: **logic that can be tested lives outside the app target.**

- **`AgentKit`** is the platform-neutral core: HTTP parsing, routing, OTLP decoding (JSON and protobuf, with a
  hand-rolled wire reader), hook and telemetry mapping, the session state machine, usage parsing, pricing, the model
  server and Prometheus parsers, notification rules, Clean up rules and the palette's ranking. It has no UI and does no
  I/O of its own; `HubServer` (the listener) and `ClaudeLimitsClient` are the only exceptions. `AgentSourceInfo` is the
  one descriptor per agent (name, symbol, colour, where its usage comes from, its resume command, its process names).
- **`AgentSystem`** holds the macOS adapters that feed AgentKit types: the SQLite store and its migrations, file
  tailing and FSEvents, the transcript, Codex and Copilot ingesters, the agent connector, process scans through
  libproc, the Keychain, and the model server client. No UI.
- **`Hoply`** is the menu bar app: SwiftUI views in AppKit hosts, with default `MainActor` isolation.
  `StatusItemController` owns the status item and the popover; `AppModel` owns all state and is passed down through the
  environment.

A request travels like this: `HubServer` (loopback only, one request per connection) → `HTTPRequestParser` →
`HubRouter`, which is pure (request in, response plus events plus usage rows out) → `HookMapper` for
`/hooks/<source>[/<event>]`, or `OTLPDecoder` and `TelemetryMapper` for `/v1/logs` and `/v1/traces` → `AgentEvent` →
`SessionBoard`, which keeps each session's state. `AgentEvent` is the normalization boundary: `SessionBoard` never sees
a raw payload. Once a session has sent a hook, hooks own its state and telemetry only adds usage, because OTLP arrives
in delayed batches.

The usage ledger is a SQLite file in `~/Library/Application Support/Hoply/`. Each agent has exactly one source of
truth (Claude Code: transcripts; Codex CLI: its session files; Copilot CLI: its `session-store.db`; Copilot in
JetBrains and Qwen Code: the OpenTelemetry Hoply receives), so nothing is counted twice. Every row has a stable dedupe
key, writes are idempotent upserts, and rows are never deleted: the agents delete their own records after a while, so
Hoply's file is the long-term history. Unknown models are stored unpriced, never as $0.

### Layout

```
Sources/AgentKit/          platform-neutral core
  HubServer.swift          Network.framework listener, loopback only
  HTTP.swift               HTTP/1.1 parser (Content-Length and chunked)
  HubRouter.swift          routes /v1/{logs,traces,metrics} and /hooks/<source>[/<event>]
  OTLPDecoder.swift        OTLP JSON + protobuf (hand-rolled wire reader, no dependencies)
  HookMapper.swift         Claude Code / Codex CLI / Copilot CLI hook payloads → events
  TelemetryMapper.swift    Claude, Codex, Qwen, Copilot (GenAI conventions) telemetry → events
  SessionBoard.swift       session state machine
  AgentSourceInfo.swift    one descriptor per agent
  PrometheusParser.swift   Prometheus text parser (snapshots and rates live in ModelServers/)
  ClaudeLimits.swift       plan limits decoding + Keychain/HTTP client
  Approvals/               Approve from Hoply (held permission requests)
  Connect/                 agent hook config: event lists, commands, transforms
  Settings/                AppSettings with lenient per-key decoding
  Usage/                   usage records, Claude transcript and Codex rollout parsers, Copilot and OTel usage mappers
  Pricing/                 price table (bundled as a string literal), cost-state calibration
  Projects/                cwd → project resolver (repo, worktree, folder, home, scratch), session grouping
  ModelServers/            servers, engines, per-engine metric names, detection
  Cleanup/ Git/ Metrics/ Notifications/ Palette/ Processes/ Remote/ Support/ Updates/
Sources/AgentSystem/       macOS I/O adapters
  SQLite/ Store/           SQLite wrapper, schema + migrations, Store (the only writer), StoreReader (queries)
  Ingest/                  file tailer, FSEvents watcher, transcript / Codex / Copilot store ingesters, coordinator
  Connect/                 AgentConnector (writes agent config) and the --connect CLI
  Processes/               process scans through libproc, process cwd (the OTel `process.pid` fallback), dev servers
  Remote/                  Keychain, model server client
  Cleanup/ Git/ Pricing/ Projects/
  Ledger.swift             store, reader and coordinator bundled for the app
Sources/Hoply/             SwiftUI menu bar app
  App/                     entry point, AppModel, status item, Dashboard window, --snapshot
  Models/                  History (the app's view of the ledger), model servers, dev servers, clean up, palette, updates, agent connections
  Panel/ Dashboard/ Palette/ Components/ Services/
Tests/AgentKitTests/       pure tests against fixtures
Tests/AgentSystemTests/    adapter tests (in-memory SQLite, temp directories)
scripts/                   install.sh, build-app.sh, package.sh, cask.sh, simulate.sh
```

### Adding an agent

Add an `AgentSource` case and its `AgentSourceInfo`, then teach `TelemetryMapper` and/or `HookMapper` about it
(Claude-shaped hook payloads, as Codex's are, need nothing there). If it keeps its own usage records, add a ledger
path with one source of truth. If it has hooks, add a `ConnectableAgent` case with its hooks type in `Connect/`. A
change to routes, hook events or the port also updates `Sources/AgentKit/Connect/`, `scripts/simulate.sh` and the
README in the same pull request.

## Tests and fixtures

- `AgentKitTests` are pure and run against fixtures in `Tests/AgentKitTests/Fixtures/`, loaded with the `Fixture`
  helper in `Support.swift`. The OpenTelemetry fixtures are real payloads captured from the official OpenTelemetry JS
  exporters. Hook fixtures are a JSON dictionary of named payloads (`Fixture.hookPayloads`). Several
  OpenTelemetry fixtures come as `.json` + `.pb` pairs, and the tests check that both decode identically.
- `AgentSystemTests` use temp directories (`TempDirectory`) and in-memory SQLite. Apart from the opt-in
  `HOPLY_REAL_*` tests, which only read, they never touch your real `~/.claude`, `~/.codex` or `~/.copilot`; they
  use a folder as the Trash and only signal child processes they start themselves.
- **Fixtures come from real payloads, stripped to the keys the test needs.** No prompt or response text (use `"x"`),
  no tokens or credentials, and no paths or names from your machine. A fixture written by hand rather than captured
  gets a `synthetic_` name prefix, like the ones already there, so nobody mistakes it for a real capture.

Known gap worth a test if you can capture it: Copilot CLI's OpenTelemetry service name and encoding aren't documented
in detail. If its tokens appear as a separate "Copilot IDE" row, `TelemetryMapper.source(of:)` needs adjusting.

## Code style

- Swift 6 language mode with strict concurrency. Mirror the closest existing pattern before inventing a new one (for
  example `PrometheusParser` for a new text parser).
- **Comments: default to none.** No `///` doc comments. Write a one- or two-line `//` only where a reader would
  otherwise "simplify" the code into a bug: a format quirk, a workaround, an ordering rule.
- No new package dependencies without discussing it in an issue first.
- New `AppSettings` fields decode leniently, key by key, in `init(from:)`, so a missing or wrongly typed key falls
  back to its default and never resets saved settings.
- `~/.claude`, `~/.codex` and `~/.copilot` are read-only to Hoply. The only exceptions are connecting an agent (which
  edits its hook config, after a backup) and Clean up (which moves items the user ticked to the Trash). Copilot's
  database is opened with `mode=ro`, never `immutable=1`.

## Pull requests

- `swift build` and `swift test` pass. CI runs both on every pull request that touches the code or scripts.
- Keep testable logic out of the `Hoply` target: put it in `AgentKit` (pure) or `AgentSystem` (I/O) with tests.
- UI changes: attach before and after images from `--snapshot`, light and dark.
- Route, hook event or port changes: update `Connect/`, `scripts/simulate.sh` and the README together.
- One topic per pull request, and say what you checked by hand (against which agent and version) beyond the tests.

## Releasing

Maintainers: the release procedure is in [docs/RELEASING.md](docs/RELEASING.md).
