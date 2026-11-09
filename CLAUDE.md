# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Hoply is a macOS 26+ menu bar app (SwiftPM tools 6.2, Swift 6 language mode, no package dependencies). It contains its own HTTP listener on `127.0.0.1:4318`, which receives hook calls and OTLP exports from AI coding agents (Claude Code, Copilot CLI, Copilot in JetBrains, Qwen Code). It also polls a local model server's Prometheus `/metrics` (vLLM, or tensorfold, which uses vLLM's metric names under its own prefix) and Claude's plan-usage endpoint.

## Roadmap

The v2 plan is in `.claude/memory/v2-plan.md`: decisions, schema, ingestion rules and milestones M0–M8. Read it before working on v2 features, stay inside the milestone at hand, and update its status line as milestones land.

## Commands

```bash
swift build
swift test                                                    # all tests (AgentKitTests + AgentSystemTests)
swift test --filter SessionBoardTests                         # one test class
swift test --filter SessionBoardTests/testClaudeLifecycle     # one test
HOPLY_REAL_TRANSCRIPTS=1 swift test --filter RealTranscriptsTests  # opt-in: ingest the real ~/.claude (read-only) into a temp DB, compare with cost-state
HOPLY_REAL_COPILOT=1 swift test --filter RealCopilotTests          # opt-in: ingest a temp copy of ~/.copilot/session-store.db, compare with its own sums
swift run Hoply                                               # run unbundled; icon appears in the menu bar
swift run Hoply --snapshot build/snapshots                    # render sample data to PNGs: panel (light, dark, full height, settings, full settings) + Dashboard pages + Limits empty state
scripts/simulate.sh                                           # with the app running: post fake hook/OTLP traffic (DELAY=0 for no pauses); its Qwen/Copilot IDE usage becomes permanent ledger rows (sim-* sessions)
scripts/install.sh [--uninstall]                              # release build → ~/Applications/Hoply.app, open it, connect Claude Code + Copilot CLI
HOPLY_SIGN_IDENTITY="Hoply Dev" scripts/install.sh            # sign with a stable self-signed cert instead of ad-hoc
curl -s http://127.0.0.1:4318/health
```

Notifications and "Launch at login" only work in the bundled `.app` (`AppModel.isBundledApp`), not under `swift run`.

## Architecture

Three targets:

- **`AgentKit`**: platform-neutral core: HTTP parsing, routing, OTLP decoding, event mapping, the session state machine, Prometheus/vLLM, Claude limits, `AppSettings` (tolerant decoding). No UI and no new I/O. `HubServer` (wrapped in `#if canImport(Network)`) and `ClaudeLimitsClient` are the existing I/O exceptions.
  - `Usage/`: `UsageRecord`/`TokenCounts`, `UsageAuthority` (which ledger each source uses), `ClaudeTranscriptParser` (+ `ClaudeTranscriptBatch`), `CopilotUsageMapper` (Copilot store rows → ledger rows), `TelemetryUsage` (OTLP records → ledger rows), `LedgerBatch` (the Store's write unit), `CopilotAllowance` (monthly premium-request allowance, UTC months) and the read-API value types (`LedgerTotals`, `SessionSummary`, `ProjectSummary`/`ProjectFilter`, `DailySpendSeries`, `SpendSlice`, `SpendOverview`, `IngestProgress`/`CopilotStoreStatus`).
  - `Pricing/`: `PricingTable`, `BundledPricing` (JSON in a Swift string literal), `PricingCalibration`. `Projects/`: `ProjectResolver` (filesystem injected through `ProjectFileSystem`) and `SessionGrouping`. `Support/`: `Timestamps`, `FNV1a`, `JSONLines`.
  - `Notifications/`: `NotificationPolicy` (which notifications to post and withdraw: session, Claude limit and local-model-offline alerts; cooldowns, quiet hours, muted projects). `Metrics/`: `RollingSeries`, `LimitSample`/`LimitKind` and `LimitsProjection` (current window, burn rate, projection at reset).
- **`AgentSystem`**: macOS I/O adapters that feed AgentKit types. No UI.
  - `SQLite/SQLiteConnection` (prepared statements, transactions, read-only in-memory snapshots). `Store/`: `Schema` (migrations + `VACUUM INTO` backups), the `Store` actor (the only writer; also Claude `limit_samples`) and the `StoreReader` actor (read-only connection, all read queries).
  - `Ingest/`: `FileTailer`, `DirectoryWatcher` (FSEvents), `ClaudeTranscriptIngester`, `CopilotStoreIngester`, `IngestCoordinator`. `Projects/ProjectRegistry` (+ `LocalProjectFileSystem`). `Processes/ProcessDirectory` (a pid's cwd through libproc). `Pricing/PricingOverrides` loads `pricing.json`. `Ledger` bundles store, reader and coordinator for the app.
- **`Hoply`**: the menu bar app (SwiftUI views in AppKit hosts), built with default `MainActor` isolation. `StatusItemController` owns an `NSStatusItem` and an `NSPopover` hosting `PanelView`. It replaced `MenuBarExtra`, which code can't open or close and which draws an opaque window. `AppModel` (`@Observable`) owns all state and is injected with `.environment(model)`; views read it through `@Environment(AppModel.self)`. Folders:
  - `App/`: entry point, `AppModel`, `StatusItemController`, `DashboardWindowController` (one reusable `NSWindow`; activation policy `.regular` while open, `.accessory` after), settings storage, and `PreviewData` + `Snapshot` for `--snapshot` (preview ledger data never opens the real DB).
  - `Models/`: `History`, the app's view of the usage ledger (see "Usage ledger" below).
  - `Services/`: `Notifier` (posts and withdraws `NotificationRequest`s; its `UNUserNotificationCenterDelegate`, set at launch, shows banners while Hoply is active and turns a click into a `NotificationTarget`), `WorkspaceActions` (Finder, Terminal, pasteboard).
  - `Panel/`: the 448×600 panel. Header (Dashboard, notifications, settings), a stat strip, then "Waiting on you", project cards (`SessionGrouping` over `AppModel.projectsByCwd`, so a repo's worktrees and subfolders share a card; rows name the worktree or subfolder; a bell button mutes the card's root in `mutedProjectRoots`), and a widget strip (Claude limits, which opens the Limits page, local model, Today). Session rows and Today show ledger totals, plus premium requests and AIU for Copilot; a session row falls back to live OTel numbers only while it has no ledger rows. The footer shows backfill progress. Settings live here too: Notifications (quiet hours, limit and local-model alerts, muted projects), History (status, Copilot store status, Reindex, local model patterns, reference model, Claude dir, Copilot dir) and Copilot plan (allowance, $ per extra request).
  - `Dashboard/`: `DashboardView` (`NavigationSplitView`) with the Overview, Projects (tile list, then a detail with chart, breakdowns and sessions), Sessions, Spending and Limits pages, `SpendChart` (Swift Charts, `chartXSelection` hover) and shared Dashboard components. Overview "Top projects" and Spending "By project" rows open a project's detail (`History.openProject`). Limits (`LimitsPage`) shows a card per Claude window (gauge, reset, burn rate, `LimitsProjection` outlook, Claude Code's API-equivalent $ since the window started), a 7 / 30 day utilization chart with resets and the 80/95% alert lines, and Copilot CLI's premium requests against `copilotMonthlyAllowance`. A session notification opens Sessions with that session selected (`History.openSession`, even outside the page's range).
  - `Components/`: `Card` (the white rounded surface), `StatTile`, `WidgetTile`, `RingGauge`, `MiniBars`, `StackedBar`, `IconTile`, `SourceBadge`, `StatePill`, `CountChip`, `TileButtonStyle`, `SectionTitle`, `Hint`, `LabeledRow`, `Meter`, `Metric`, `Format`.
  - v2 adds `Palette/` (M8).

The panel follows Mizu's look: system popover material behind it, white `Card`s on top (prominent = solid with a soft shadow), 16 pt corners, 10 pt gaps, 12.5–15 pt text and 24 pt figures. Check UI changes with `--snapshot`. It needs no Screen Recording permission, but it can't show glass or vibrancy because the window server composites those; for the same reason Dashboard snapshots draw a plain stand-in for the sidebar (`DashboardView(plainSidebar:)`).

Tests: `AgentKitTests` (pure, fixtures) and `AgentSystemTests` (temp directories, in-memory DB). The app target has no tests, so keep testable logic out of it.

### Request → panel data flow

1. `HubServer`: an `NWListener` restricted to the loopback interface; it also rejects non-loopback peers. It buffers bytes until `HTTPRequestParser` (Content-Length and chunked, handles `Expect: 100-continue`) returns a complete request. Each connection serves one request, then closes.
2. `HubRouter.handle` is pure: request in, `Outcome` (response + `[AgentEvent]` + `[UsageRecord]` to persist + optional note) out.
   - `POST /v1/logs|traces` → `OTLPDecoder` (JSON or protobuf, sniffed when Content-Type is missing) → flat `[TelemetryRecord]` (with lowercase-hex `traceID`/`spanID` and the exact `timeUnixNano`) → `TelemetryMapper` → events, and `TelemetryUsage` → ledger rows for telemetry-ledger sources only. `/v1/metrics` is accepted and ignored. Compressed bodies get 415; gRPC is not supported.
   - `POST /hooks/<source>[/<event>]` → `HookMapper`. Claude Code sends `hook_event_name` in the body. Copilot CLI payloads have no event name, so its setup script puts the event in the URL path. The path name wins.
3. `HubServer` callbacks (`onEvents`, `onUsage`, `onStatus`, `onNote`) fire on a private dispatch queue. `AppModel` hops to the main actor and feeds events to `SessionBoard`; `onUsage` batches go through `History.record` (in arrival order, held while the ledger opens) to `Ledger.record`.
4. `SessionBoard` (a pure value type) applies each `AgentEvent` to an `AgentSession` keyed by `(AgentSource, sessionID)` and returns a `StateChange`. `AppModel` feeds every change from `apply` and `tick` to its `NotificationPolicy` (AgentKit), with the session cwd's ledger project, and hands the returned `NotificationActions` (post / withdraw) to `Notifier`. The policy also gets each Claude limits fetch and each model-server poll; it has no clock or I/O of its own.

`AgentEvent` is the normalization boundary. Every source, whether hook or telemetry, maps into its `Kind` cases. `SessionBoard` never sees raw payloads.

### Usage ledger (v2, M2–M3)

SQLite at `~/Library/Application Support/Hoply/hoply.sqlite` (WAL). One source of truth per agent (`UsageAuthority.ledger(for:)`): Claude Code = its transcripts, Copilot CLI = its `session-store.db`, Copilot IDE and Qwen Code = their OTel, persisted by Hoply. Claude Code and Copilot CLI OTel is live display only and never persisted.

Claude Code:

1. `IngestCoordinator` discovers `<claude config>/projects/*/*.jsonl` and `*/*/subagents/*.jsonl`, backfills newest first, then tails on FSEvents (0.5 s), on a 60 s stat-only rescan, and at once when a hook carries `transcript_path` (`AgentEvent.transcriptPath` → `tailTranscript(atPath:)`). One file at a time.
2. `FileTailer` reads complete lines past an `ingest_cursors` row (inode, size, offset, FNV of the first 512 bytes) and restarts at 0 on rotation, truncation or a rewritten head.
3. `ClaudeTranscriptParser` skips known bulky types by prefix (`api-request*`, `file-history-*`, `last-prompt`…), merges repeated content blocks per `cc:<message.id>:<requestId>` (field-wise max), drops `<synthetic>`, and never keeps prompt text.
4. `Store.apply` writes a `LedgerBatch` plus its cursor in one transaction.

Copilot CLI (`CopilotStoreIngester`, `<copilotHome>/session-store.db`, `copilotHome` setting, `""` = `$COPILOT_HOME` or `~/.copilot`):
1. `IngestCoordinator.pollCopilot()` runs at start, every 10 s, and on request (`Ledger.pollCopilot()`, for Copilot CLI hooks). It skips the read unless the db or `-wal` changed (inode, size, mtime). One poll at a time; a fresh connection per poll, so Copilot's own last close can still checkpoint.
2. With a `-wal` present the db is opened in place with `file:…?mode=ro` + `query_only` (never `immutable`, which hides WAL content); SQLite may create a missing `-shm` (its wal-index). Without a `-wal` (Copilot's SQLite removes it on a clean close) macOS's SQLite refuses `mode=ro`, so the main file is read into a read-only in-memory snapshot (`SQLiteConnection(snapshot:)`) and nothing is created in `~/.copilot`.
3. `PRAGMA table_info` checks the required columns (`schema_version` 7 known); missing ones → `CopilotStoreStatus.unsupported`, no read, no crash. Optional columns read as NULL.
4. Events are read `WHERE id > cursor ORDER BY id` in batches of 500; each batch + its cursor (`ingest_cursors`, source `copilot-cli`, path = db path, `offset` = last event id) is one `Store.apply`. A lower `MAX(id)` or a new inode restarts at 0. After the events, session rows whose cwd/branch/summary/turn count moved are rewritten.
5. `CopilotUsageMapper`: uncached input = the `input` entry of `token_details_json`, else `input_tokens − cache_read − cache_write` (Copilot's `input_tokens` includes both). Cache writes count as 5 minute writes. Dedupe key `cp:<session>:<id>:<created_at>`. Title = first line of `summary` (not empty, not `<…>`), turns = rows in `turns`.

Telemetry (Copilot IDE, Qwen Code): `TelemetryUsage` keys spans `otel:<trace>:<span>` and Qwen `api_response` logs `qw:<session>:<prompt_id>:<timeUnixNano>`, so re-sent batches upsert onto the same rows; records without a stable identity are skipped. `Ledger.record` fills a missing cwd from the session's earlier records, else from `process.pid` (`ProcessDirectory`, rejecting `/` and pids started after the record), else the row stays "Unassigned" (`project_id` NULL). The `hoply.cwd` resource attribute (user-set through `OTEL_RESOURCE_ATTRIBUTES`) always wins.

Every ingest path (transcripts, Copilot polls, `Ledger.record`) reports through the single `IngestCoordinator.updates` stream.

In the app:
5. `History` opens the `Ledger` at launch (failure → "History off", the rest keeps working), is the single consumer of `IngestCoordinator.updates`, and re-queries `StoreReader` at most once a second during backfill (150 ms otherwise). It serves the live sessions' totals, today by source and the visible Dashboard page. `AppModel.ingest` forwards hook `transcriptPath`s to `History.tail` and calls `History.pollCopilot` on Copilot CLI hooks. `AppModel` resolves unseen live-session cwds through `History.resolveProjects` in the background and caches them in `projectsByCwd`; with History off the panel groups per cwd. A `claudeConfigDir` or `copilotHome` change reopens the ledger; local-pattern or reference-model changes call `Ledger.updatePricing`. Each Claude limits fetch goes through `History.recordLimits`, which waits while the ledger opens and returns `Ledger.recordLimits`' result (each window's sample from before the write) as `previous` for `NotificationPolicy.limitsUpdated`, or nil with History off. Never take `previous` from `latestLimitSamples()` after recording: that is the fetch itself, and alerts never fire.

Rules (easy to break):
- The panel and the Dashboard read the same ledger totals and plot `apiEquivUSD`. `hasUnpriced` renders as "unpriced" (or "$x+"), never $0 (`Format.spend`).
- Usage rows are upserted (`ON CONFLICT(dedupe_key)` with `max(…)`), never deleted. "Reindex" only resets cursors. Totals are always `GROUP BY` over `usage`.
- Cost is computed in Swift after the upsert (`RETURNING`), so a call whose blocks arrive in two reads is priced on the merged counts. A new `pricing_rev` (content hash of table + local patterns + reference model) re-prices every row in one transaction.
- Unknown non-local model → `cost_usd` NULL (unpriced), never $0. Local models (`AppSettings.localModelPatterns`) → $0, with `api_equiv_usd` at `referenceModel`.
- Native pricing: a row with `native_usd` (Copilot CLI: `total_nano_aiu ÷ 1e11`, since 1 AIU = $0.01 at API list price) uses it as both cost and API-equivalent, carries `pricing_rev = 'native'`, and is never re-priced. `native_cost` holds the AIU. A NULL `total_nano_aiu` falls back to the price table.
- `premium_requests` books each Copilot turn's premium requests (the highest `request_multiplier` among its calls) on the turn's earliest call and 0 on the rest; `Store.apply` recomputes the touched turns. `LedgerTotals.aiu`/`.premiumRequests` are plain sums, so they are right for any range, project or session.
- `sessions.turns` counts typed prompts. A batch that starts at offset 0 of a main transcript replaces the count, a tail adds to it; subagent files never touch it.
- Claude Code copies earlier calls into a continued session's file. The session with the earlier `first_at` keeps such a call, whatever the read order.
- `~/.claude` and `~/.copilot` are read-only. Tests use temp directories only.

### SessionBoard rules (easy to break)

- Once any hook event arrives for a session (`fromHook`), `hasLiveState` is set. From then on, telemetry only adds token/cost usage and never changes state, because OTLP arrives in delayed batches.
- Telemetry-only sessions (JetBrains Copilot, Qwen) can only be `working`/`idle`. They fall back to `idle` after `idleAfter` (45 s) of silence in `tick()`.
- An `ended` session ignores everything except a new `sessionStarted`. Ended sessions are dropped after 10 min, and any session is dropped after 4 h of silence.
- `AppModel` runs three loops: `tick` every 5 s, vLLM poll every 5 s, Claude limits every 180 s.

### Source detection

`SessionGrouping(sessions:projects:)` (AgentKit) splits sessions into waiting-on-you plus project groups. `projects` maps each session cwd to its ledger project (`Ledger.resolveProjects`, so worktrees and subfolders of a repo share one group, id `project:<id>`); a cwd not in the map groups on its own, so the panel never waits for the ledger. `RollingSeries` keeps the in-memory sparkline buckets until the `samples` table lands (M5).

`TelemetryMapper.source(of:)` picks the `AgentSource` from `service.name` and the record name. Session IDs come from a list of candidate attribute keys (`sessionKeys`). To add a source, update `AgentSource`, `TelemetryMapper` and/or `HookMapper`, and add a connect/disconnect pair to `scripts/install.sh`.

### Other pieces

- `Package.swift` embeds `Sources/Hoply/Info.plist` into the executable through linker `-sectcreate`, so `swift run` gets the same App Transport Security exceptions (plain HTTP to private-range IPs for vLLM) as the bundle. `install.sh` also copies it into the `.app`.
- `ClaudeLimitsClient` reads Claude Code's OAuth token from the Keychain item "Claude Code-credentials" by shelling out to `/usr/bin/security`. It then calls the undocumented `api.anthropic.com/api/oauth/usage`.
- Settings (`AppSettings`, in AgentKit) are stored as JSON in `UserDefaults` under the key `HoplySettings`. Decoding is per key and lenient: a missing or wrongly typed key falls back to its default, so adding a field never resets saved settings. New fields must follow the same pattern in `init(from:)`.

## Tests and fixtures

`Tests/AgentKitTests/Fixtures/` holds real payloads captured from the official OpenTelemetry JS exporters. Several come as `.json` + `.pb` pairs, and tests assert both decode identically, trace/span ids and `timeUnixNano` included (`copilot_spans.json` carries the `.pb` capture's ids). Load fixtures with the `Fixture` helper in `Support.swift`. Hook fixtures are a JSON dictionary of named payloads (`Fixture.hookPayloads`).

`claude_transcript.jsonl` is real transcript line shapes with synthetic ids and `"x"` for all text (it ends in a deliberately partial line). `claude_calibration.jsonl` is one real session's assistant lines stripped to ids and usage, plus its `cost-state`; `PricingTests` checks the ledger total lands within 2%. `AgentSystemTests` build their transcripts inline in temp directories (`TempDirectory` in `Support.swift`), and Copilot stores with `CopilotDatabase` (`CopilotStoreTests.swift`), which uses Copilot's schema_version 7 DDL verbatim. Apple's SQLite keeps `-wal`/`-shm` after the last close, so a test that needs them absent copies only the main file.

## Setup scripts

`scripts/install.sh` is the only setup entry point. It builds and installs the `.app`, then connects each agent it finds:
- **Claude Code:** hooks plus OTel log env in `~/.claude/settings.json`, backed up first. Hook commands carry a `# hoply` marker, and the env keys are matched by value, so re-runs and `--uninstall` touch only Hoply's own entries.
- **Copilot CLI:** `~/.copilot/hooks/hoply.json`. `--uninstall` renames that file rather than deleting it.

`CLAUDE_CONFIG_DIR` and `COPILOT_HOME` redirect it to scratch copies for testing. Qwen Code is not auto-connected; README shows its manual settings. If you change routes or the hook event list, keep `install.sh` and `simulate.sh` in sync.

## Working in this repo

- **Subagents:** use `swift-core-dev` for AgentKit, the v2 `AgentSystem` target, `scripts/` and tests. Use `macos-ui-dev` for the `Hoply` app target (panel, Dashboard, palette, components). When you delegate, name the v2 milestone and tell the subagent to read `.claude/memory/v2-plan.md`.
- **Skills:** project skills go in `.claude/skills/<name>/SKILL.md`. There are none yet; add one only when the knowledge is reusable and not already in this file.
- **Never commit or push on the user's behalf.** Leave changes in the working tree and report them; the user reviews and commits. Creating a new branch is the most git writing allowed.
- **Memory:** `.claude/memory/` is Claude Code's auto-memory directory, set through `autoMemoryDirectory` in the gitignored `.claude/settings.local.json`. `MEMORY.md` is the index: one line per memory, one fact per file, frontmatter as in the existing files. Memory is versioned with the repo.
- **Copilot mirror:** Copilot reads the same configuration through these paths:
  - `.github/copilot-instructions.md` is a symlink to this file. The Edit tool refuses symlinks, so edit `CLAUDE.md` itself.
  - `.github/agents/*.md` are real copies, not symlinks. Edit agent bodies in both `.claude/agents/` and `.github/agents/`.
  - Each new skill also gets a symlink `.github/skills/<name>` pointing to `../../.claude/skills/<name>`.
- **`.mcp.json`:** `context7` provides current library docs. Swift 6.2, macOS 26 SwiftUI, Liquid Glass and Swift Charts are newer than training data, so check `context7` before guessing an API.
