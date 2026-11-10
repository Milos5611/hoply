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
HOPLY_REAL_PROCESSES=1 swift test --filter ProcessScannerTests/testRealProcesses  # opt-in: time a real process scan, print counts
swift run Hoply                                               # run unbundled; icon appears in the menu bar
HOPLY_OPEN=panel swift run Hoply                              # open a surface at launch: panel | dashboard | palette (add HOPLY_HOLD_OPEN=1 to keep the panel up)
swift run Hoply --snapshot build/snapshots                    # render sample data to PNGs: panel (light, dark, full height, settings, full settings) + Dashboard pages + Limits empty state + Local model offline and no-server states + Clean up page, report and review sheet + palette (empty, query, actions, no results) and its settings card
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
  - `Cleanup/`: `CleanupCandidate`/`CleanupScan`, `CleanupRules` (thresholds; worktree, cache and transcript facts → `CleanupKeepReason`s), `BuildCache` (the catalogue), `TrashGuard` (which paths may ever be trashed), `CleanupReport` (+ `CleanupLogEntry`). `Git/`: `GitDiffStat`, `GitWorktree` (porcelain parser). `Processes/` also holds `OrphanTracker` and `OrphanStop`. `Palette/`: see M8 below.
  - `Notifications/`: `NotificationPolicy` (which notifications to post and withdraw: session, Claude limit and local-model-offline alerts; cooldowns, quiet hours, muted projects). `Metrics/`: `RollingSeries`, `LimitSample`/`LimitKind` (an open set: the fixed windows plus model-scoped `seven_day_<slug>` ones), `LimitsProjection` (current window, burn rate, projection at reset) and `LimitPace` (used% − elapsed%, from one reading), `SampleAggregator` (60 s `samples` buckets, counter increases, rollups) and `ModelServerSeries` (model-server poll → sample observations). `Remote/`: `RemoteEndpoint` (requests with a Bearer header, never a token in the URL; response classification) and `SparkDash` routes.
- **`AgentSystem`**: macOS I/O adapters that feed AgentKit types. No UI.
  - `SQLite/SQLiteConnection` (prepared statements, transactions, read-only in-memory snapshots). `Store/`: `Schema` (migrations + `VACUUM INTO` backups), the `Store` actor (the only writer; also Claude `limit_samples` and the `samples` series) and the `StoreReader` actor (read-only connection, all read queries).
  - `Ingest/`: `FileTailer`, `DirectoryWatcher` (FSEvents), `ClaudeTranscriptIngester`, `CopilotStoreIngester`, `IngestCoordinator`. `Projects/ProjectRegistry` (+ `LocalProjectFileSystem`). `Processes/ProcessDirectory` (a pid's cwd through libproc). `Pricing/PricingOverrides` loads `pricing.json`. `Remote/`: `Keychain` (behind `SecretStore`; generic passwords under `com.coolcraftcoders.hoply.sparkdash`, account = endpoint host) and `MetricsClient` (ephemeral `URLSession`, refuses redirects, returns raw data or a `RemoteError`). `Cleanup/`: `CleanupScanner` (a `CleanupPass` per scan, split by kind), `CleanupService` (actor: scan, run, orphans), `DirectorySizer`, `TrashBin` (protocol; the app supplies `NSWorkspace.recycle`), `CleanupInventory` (what the ledger knows: projects, worktrees, transcript cursors). `Ledger` bundles store, reader and coordinator for the app.
- **`Hoply`**: the menu bar app (SwiftUI views in AppKit hosts), built with default `MainActor` isolation. `StatusItemController` owns an `NSStatusItem` and an `NSPopover` hosting `PanelView`. It replaced `MenuBarExtra`, which code can't open or close and which draws an opaque window. `AppModel` (`@Observable`) owns all state and is injected with `.environment(model)`; views read it through `@Environment(AppModel.self)`. Folders:
  - `App/`: entry point, `AppModel`, `StatusItemController`, `DashboardWindowController` (one reusable `NSWindow`; activation policy `.regular` while open, `.accessory` after), settings storage, and `PreviewData` + `Snapshot` for `--snapshot` (preview ledger data never opens the real DB).
  - `Models/`: `History`, the app's view of the usage ledger (see "Usage ledger" below).
  - `Services/`: `Notifier` (posts and withdraws `NotificationRequest`s; its `UNUserNotificationCenterDelegate`, set at launch, shows banners while Hoply is active and turns a click into a `NotificationTarget`), `WorkspaceActions` (Finder, Terminal, pasteboard).
  - `Panel/`: the 448×600 panel. Header (Dashboard, notifications, settings), a stat strip, then "Waiting on you", project cards (`SessionGrouping` over `AppModel.projectsByCwd`, so a repo's worktrees and subfolders share a card; rows name the worktree or subfolder; a bell button mutes the card's root in `mutedProjectRoots`), and a widget strip (Claude limits: the 5-hour ring carries a tick at the window's elapsed share, the pace is in the tooltip, and it opens the Limits page; local model, which opens the Local model page; Today). Session rows and Today show ledger totals, plus premium requests and AIU for Copilot; a session row falls back to live OTel numbers only while it has no ledger rows. The footer shows backfill progress. Settings live here too: Notifications (quiet hours, limit and local-model alerts, muted projects), History (status, Copilot store status, Reindex, local model patterns, reference model, Claude dir, Copilot dir) and Copilot plan (allowance, $ per extra request).
  - `Dashboard/`: `DashboardView` (`NavigationSplitView`) with the Overview, Projects (tile list, then a detail with chart, breakdowns and sessions), Sessions, Spending, Local model and Limits pages, `SpendChart` (Swift Charts, `chartXSelection` hover) and shared Dashboard components. Overview "Top projects" and Spending "By project" rows open a project's detail (`History.openProject`). Limits (`LimitsPage`) shows a card per Claude window present, model-scoped weekly ones included (built from `projections.keys.sorted()`, limited to the windows the latest fetch returned; gauge and bar with a tick at the elapsed share, a `LimitPace` chip, reset, burn rate, `LimitsProjection` outlook, Claude Code's API-equivalent $ since the window started), extra usage (share only, the API gives no unit) and spend when the API returns them, a 7 / 30 day utilization chart with resets and the 80/95% alert lines, Copilot CLI's premium requests against `copilotMonthlyAllowance`, and a footnote with `ClaudeLimits.unrecognizedKeys`. Local model (`LocalModelPage`) shows a live strip (tok/s, prompt tok/s, KV cache, running/waiting, engine and model), 24 h / 7 d / 30 d charts of generation speed (average plus a band up to the peak) and KV cache from `samples` (300 / 1800 / 3600 s points, gaps break the line), tokens per day from the server's counters (unobserved days are gaps, not zero) and saved vs API (`Ledger.localModelSpend`, priced at `referenceModel`), with empty states for no server, offline (last seen) and History off. A session notification opens Sessions with that session selected (`History.openSession`, even outside the page's range).
  - `Components/`: `Card` (the white rounded surface), `StatTile`, `WidgetTile`, `RingGauge`, `MiniBars`, `StackedBar`, `IconTile`, `SourceBadge`, `StatePill`, `CountChip`, `TileButtonStyle`, `SectionTitle`, `Hint`, `LabeledRow`, `Meter`, `Metric`, `Format`.
  - M5.5 session insight: `SessionStatus` (AgentKit) derives what a row shows (Permission > Input > Limited > Your turn > Working > Idle > Ended) from the session plus the Claude limit samples; `SessionBoard` stores neither Input (`yourTurn` + `awaitsInput`) nor Limited. Rows also show live subagents (`AgentSession.subagents`), a context-window warning (`Ledger.contextWindows`) and a git diff stat (`GitStatCache`, off the main actor, works with History off). `ProjectIcon` draws project monograms, `Services/Editor` finds installed editors (default in UserDefaults `HoplyDefaultEditor`). The session detail has Context window and Subagents cards, Spending has Model efficiency, Settings has Pricing ("Price as" → `AppSettings.priceAliases` → `Ledger.updatePricing`).
  - M6 dev servers: `ProcessScanner` (AgentSystem, libproc; `lsof` fallback through the pure `LsofParser`) → `DevServerClassifier` (AgentKit: which listeners count, framework, project, session tie, Stop eligibility) → `DevServerMonitor` (actor). `Models/DevServers` scans every 10 s while the panel or Dashboard is on screen, 60 s otherwise. Pills on project cards and session rows, the Dev servers page, inline Stop (SIGTERM to the process group, SIGKILL after 5 s).
  - M7 clean up: `Models/Cleanup` (`AppModel.cleanup`) scans 2 minutes after launch, daily, and when the Clean up page asks; it gets every process snapshot from `DevServers.onSnapshot`, so there is one process scan loop. `Dashboard/Cleanup/` holds the page (a card per kind with the kept items and why), the review sheet and the report card; the panel footer links to it from 100 MB reclaimable. `Services/Trash` is the `TrashBin`.
  - M8 palette: `AgentKit/Palette/` holds the pure parts (`FuzzyMatcher`, `PaletteItem`, `PaletteRanker` with `>` = actions only, `Frecency`, `ResumeScript`, `HotKeyCombo`). `Models/Palette` (`AppModel.palette`) builds the items when the palette opens (live sessions, `Ledger.recentSessions`/`recentProjects`, dev servers, Dashboard pages, actions), ranks them and runs the pick; frecency is JSON in UserDefaults `HoplyPaletteFrecency`. `Palette/` has `PaletteWindowController` (a non-activating floating `NSPanel` that takes key without activating Hoply; arrows, Return, ⌘Return and Esc are handled in the panel) and `PaletteView`. `Services/HotKey` registers `paletteHotKey` through Carbon and reports whether it has fired; `Services/ResumeLauncher` writes the `.command` script under Application Support `Hoply/Resume/` and opens it. Palette settings (`Panel/PaletteSettings`) apply at once, not with Save. A live session is never resumed; Resume exists for Claude Code only.

The panel follows Mizu's look: the popover's own system glass behind it (nothing of ours covers it, and no glass is added inside: that would be glass on glass), translucent white `Card`s on top (prominent = solid with a soft shadow; in the panel only the emphasised stat tile), 18 pt corners, 10 pt gaps, 12.5–15 pt text and 24 pt figures. With Reduce Transparency or Increase Contrast, `Card` uses opaque tones that keep the same layering. The Dashboard draws `DashboardBackground` under the glass sidebar and toolbar; `PageHeader` puts the page title in `navigationTitle` and its controls in `.toolbar` (every page needs a toolbar item, or the window has no toolbar there), and falls back to an in-content header in snapshots (`\.dashboardStandIn`). Check UI changes with `--snapshot`. It needs no Screen Recording permission, but it can't show glass or vibrancy because the window server composites those; for the same reason Dashboard snapshots draw a plain stand-in for the sidebar (`DashboardView(plainSidebar:)`).

Tests: `AgentKitTests` (pure, fixtures) and `AgentSystemTests` (temp directories, in-memory DB). The app target has no tests, so keep testable logic out of it.

### Request → panel data flow

1. `HubServer`: an `NWListener` restricted to the loopback interface; it also rejects non-loopback peers. It buffers bytes until `HTTPRequestParser` (Content-Length and chunked, handles `Expect: 100-continue`) returns a complete request. Each connection serves one request, then closes.
2. `HubRouter.handle` is pure: request in, `Outcome` (response + `[AgentEvent]` + `[UsageRecord]` to persist + optional note) out.
   - `POST /v1/logs|traces` → `OTLPDecoder` (JSON or protobuf, sniffed when Content-Type is missing) → flat `[TelemetryRecord]` (with lowercase-hex `traceID`/`spanID` and the exact `timeUnixNano`) → `TelemetryMapper` → events, and `TelemetryUsage` → ledger rows for telemetry-ledger sources only. `/v1/metrics` is accepted and ignored. Compressed bodies get 415; gRPC is not supported.
   - `POST /hooks/<source>[/<event>]` → `HookMapper`. Claude Code sends `hook_event_name` in the body. Copilot CLI payloads have no event name, so its setup script puts the event in the URL path. The path name wins.
3. `HubServer` callbacks (`onEvents`, `onUsage`, `onStatus`, `onNote`) fire on a private dispatch queue. `AppModel` hops to the main actor and feeds events to `SessionBoard`; `onUsage` batches go through `History.record` (in arrival order, held while the ledger opens) to `Ledger.record`.
4. `SessionBoard` (a pure value type) applies each `AgentEvent` to an `AgentSession` keyed by `(AgentSource, sessionID)` and returns a `StateChange`. `AppModel` feeds every change from `apply` and `sweep` (the 5 s tick) to its `NotificationPolicy` (AgentKit), with the session cwd's ledger project, and hands the returned `NotificationActions` (post / withdraw) to `Notifier`. Sessions that `sweep` drops produce no change, so `AppModel` passes them to `sessionDismissed`. The policy also gets each Claude limits fetch and each model-server poll; it has no clock or I/O of its own.

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
- `samples` (M5, the model server's own series, never added to agent totals): each poll is merged into its 60 s bucket (n and sum add); a counter bucket's `sum` is its increase (a drop is a restart, counted from 0) and its `max` the raw reading, which re-seeds the baseline after a relaunch. Rollups (60 s → 900 s after 7 days, → 3600 s after 90, fine rows removed) run when the Store opens and then daily.
- Cost is computed in Swift after the upsert (`RETURNING`), so a call whose blocks arrive in two reads is priced on the merged counts. A new `pricing_rev` (content hash of table + local patterns + reference model) re-prices every row in one transaction.
- Unknown non-local model → `cost_usd` NULL (unpriced), never $0. Local models (`AppSettings.localModelPatterns`) → $0, with `api_equiv_usd` at `referenceModel`.
- Native pricing: a row with `native_usd` (Copilot CLI: `total_nano_aiu ÷ 1e11`, since 1 AIU = $0.01 at API list price) uses it as both cost and API-equivalent, carries `pricing_rev = 'native'`, and is never re-priced. `native_cost` holds the AIU. A NULL `total_nano_aiu` falls back to the price table.
- `premium_requests` books each Copilot turn's premium requests (the highest `request_multiplier` among its calls) on the turn's earliest call and 0 on the rest; `Store.apply` recomputes the touched turns. `LedgerTotals.aiu`/`.premiumRequests` are plain sums, so they are right for any range, project or session.
- `sessions.turns` counts typed prompts. A batch that starts at offset 0 of a main transcript replaces the count, a tail adds to it; subagent files never touch it.
- Claude Code copies earlier calls into a continued session's file. The session with the earlier `first_at` keeps such a call, whatever the read order.
- Subagent names (schema v3 `subagents`) come from `subagents/agent-<id>.meta.json`, read when a subagent file is ingested from offset 0; older ones stay unnamed until Reindex.
- A price alias (`priceAliases`) is part of `pricing_rev`; with no aliases the hash is unchanged.
- `~/.claude` and `~/.copilot` are read-only. The one exception: Clean up moves Claude transcripts the user ticked to the Trash. Tests use temp directories only.

### SessionBoard rules (easy to break)

- Once any hook event arrives for a session (`fromHook`), `hasLiveState` is set. From then on, telemetry only adds token/cost usage and never changes state, because OTLP arrives in delayed batches.
- Telemetry-only sessions (JetBrains Copilot, Qwen) can only be `working`/`idle`. They fall back to `idle` after `idleAfter` (45 s) of silence in `tick()`.
- Hooks that fire inside a subagent (`agent_id` present) never change the session's cwd or model and never reopen a finished turn. `StopFailure` ends the turn (`failure` set).
- An `ended` session ignores everything except a new `sessionStarted`. Ended sessions are dropped after 10 min, and any session is dropped after 4 h of silence.
- `AppModel` runs `tick` every 5 s and Claude limits every 180 s. It polls the model server every 5 s while the panel popover or the Dashboard window is on screen (`setPanelOnScreen` / `setDashboardOnScreen`, which also poll at once), every 30 s otherwise. After a failed poll it keeps the 5 s pace until the offline alert's 2 minutes have passed, so the alert isn't up to 30 s late. A running poll is never cancelled (that would read as offline); a wake-up during one polls again right after it. A poll that returns after the server URL changed is dropped (`modelServerEpoch`).
- Settings Save writes only the fields edited in the draft onto the current settings (`AppSettings.applying(_:since:)`), because the header bell, the mute tile and Limits "Connect" change settings while a draft is open.

### Dev server rules (easy to break)

- A process is identified by pid + start time, never the pid alone; `ProcessTerminator` re-checks it before each signal.
- Stop is refused unless the uid is ours, the group leader is alive with its cwd inside the project root (the server's own cwd for home, scratch, no project, or a worktree outside the root), and the group holds no agent process, Hoply or a Hoply ancestor.
- Tests signal only child processes they spawn themselves. Argv stays in memory and is never stored or shown.

### Clean up rules (easy to break)

- Nothing is removed without the review sheet, and `CleanupService.run` re-checks every item with fresh facts right before acting; what changed is skipped with its reason.
- A worktree is offered only when it is linked, unlocked, clean, merged into the default branch (local or `origin/`), idle 7 days and free of live sessions and dev servers. Any git call that fails means "unknown", which is never eligible. Branches are never deleted; `git worktree prune` is the only git write.
- A build cache in a repo must be gitignored with no tracked files inside. `node_modules` needs `cleanupIncludesNodeModules`.
- A transcript is offered only when every `.jsonl` of the session is older than 90 days and fully ingested (cursor inode and offset match). Usage rows stay.
- `TrashGuard` is the last check: never home, a project root or the Claude `projects` folders themselves; only paths inside a known project, worktree or session.
- A scan nobody asked for skips `~/Documents`, `~/Desktop`, `~/Downloads` and iCloud Drive (TCC prompts) until the user has scanned once.
- Orphans are signalled per pid after a pid + start time check, never by process group. Only build caches are pre-ticked.
- Tests use a folder as the trash, never the real Trash.

### Source detection

`SessionGrouping(sessions:projects:)` (AgentKit) splits sessions into waiting-on-you plus project groups. `projects` maps each session cwd to its ledger project (`Ledger.resolveProjects`, so worktrees and subfolders of a repo share one group, id `project:<id>`); a cwd not in the map groups on its own, so the panel never waits for the ledger. `RollingSeries` keeps the in-memory sparkline buckets. `AppModel` records each successful model-server poll to `samples` through `History.recordModelSamples` (chained, dropped while no ledger is open) and seeds the throughput sparkline from `Ledger.recentModelSamples` at launch.

`TelemetryMapper.source(of:)` picks the `AgentSource` from `service.name` and the record name. Session IDs come from a list of candidate attribute keys (`sessionKeys`). To add a source, update `AgentSource`, `TelemetryMapper` and/or `HookMapper`, and add a connect/disconnect pair to `scripts/install.sh`.

### Other pieces

- `Package.swift` embeds `Sources/Hoply/Info.plist` into the executable through linker `-sectcreate`, so `swift run` gets the same App Transport Security exceptions (plain HTTP to private-range IPs for vLLM) as the bundle. `install.sh` also copies it into the `.app`.
- `ClaudeLimitsClient` reads Claude Code's OAuth token from the Keychain item "Claude Code-credentials" by shelling out to `/usr/bin/security`. It then calls the undocumented `api.anthropic.com/api/oauth/usage`. Everything beyond `five_hour`/`seven_day` is decoded only when present (scoped windows, `extra_usage`, `spend`), and other top-level keys are listed in `ClaudeLimits.unrecognizedKeys`.
- The sparkDash token (GPU stats, M5) lives only in the Keychain, never in settings, URLs or logs.
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
- **Comments:** default to none. No doc comments; a one-line `//` only where a reader would otherwise simplify the code into a bug.
- **Never commit or push on the user's behalf.** Leave changes in the working tree and report them; the user reviews and commits. Creating a new branch is the most git writing allowed.
- **Memory:** `.claude/memory/` is Claude Code's auto-memory directory, set through `autoMemoryDirectory` in the gitignored `.claude/settings.local.json`. `MEMORY.md` is the index: one line per memory, one fact per file, frontmatter as in the existing files. Memory is versioned with the repo.
- **Copilot mirror:** Copilot reads the same configuration through these paths:
  - `.github/copilot-instructions.md` is a symlink to this file. The Edit tool refuses symlinks, so edit `CLAUDE.md` itself.
  - `.github/agents/*.md` are real copies, not symlinks. Edit agent bodies in both `.claude/agents/` and `.github/agents/`.
  - Each new skill also gets a symlink `.github/skills/<name>` pointing to `../../.claude/skills/<name>`.
- **`.mcp.json`:** `context7` provides current library docs. Swift 6.2, macOS 26 SwiftUI, Liquid Glass and Swift Charts are newer than training data, so check `context7` before guessing an API.
