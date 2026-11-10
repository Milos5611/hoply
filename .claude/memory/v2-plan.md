---
name: v2-plan
description: "Hoply v2 plan (approved 2026-11-09) — Liquid Glass panel + Dashboard window, SQLite usage ledger (one source of truth per agent), Claude/Copilot backfill, Cloudflare Access, GPU, dev servers, clean up, palette; milestones M0–M8"
metadata:
  node_type: memory
  type: project
  originSessionId: 65b7a48e-4bed-4913-a456-69fcc04298ea
  modified: 2026-11-09T19:52:20.957Z
---

# Hoply v2: history, spending, projects, and a Mizu-quality UI

Status (2026-11-09): plan approved by the user. **M0**, **M0.5 panel look** and **M2** are done and committed (user live check of M2 passed on real data; glass look deferred, see "Known issues"). **M3** is done and committed. **M4** is built, including its limits polish: pace, model-scoped windows, extra usage/spend. **M5** is built without GPU/energy/memory, which the user skipped until a sparkDash capture exists: model-server samples + rollups, Local model page, saved vs API, 5 s/30 s cadence, Keychain/`RemoteEndpoint` plumbing. Both are committed (2026-11-10, `6c36b3b` and `bb3d25d`); notifications, click-through, the Limits and Local model pages on real data, and the cadence switch are still unverified live. **2026-11-10 (uncommitted):** M4 + M5 review fixes and the **M5.5** core half are done; **M5.5** is built, core and UI. Review fixes and M5.5 are committed (`166e164`). **M6** is built, core and UI (uncommitted). **Next:** M7 Clean up. Still open: the user's live check (re-run `scripts/install.sh` for the new hooks). The deferred glass polish pass (live, see "Known issues") is still open. GPU joins M5 when a capture arrives (routes listed in "M5 core outcome"). **Build order (user, 2026-11-09): M2 → M3 → M4 → M5 → M5.5 → M6 → M7 → M8 → M1.** M5.5 holds the T3 Code ideas. Cloudflare Access moved to the end; IDs kept so references stay valid. Work milestone by milestone and update this status line as milestones land.

## Context

Today Hoply only shows live status. `SessionBoard` lives in memory, so there is no persistence, no history, no per-project view and no spending over time. The UI is plain cards (`Sources/Hoply/Views.swift`, 613 lines).

The user wants a polished app, at least as good as Mizu (usemizu.com, a menu bar app for macOS 26). It should watch Claude Code, Copilot (CLI and JetBrains) and Qwen Code running on the local vLLM. The vLLM runs on an HP ZGX that is moving behind Cloudflare. The app should show spending, projects, sessions and limits, plus Mizu's extras.

**Decisions made with the user:**
- **UI:** a redesigned Liquid Glass menu bar panel for live status, plus a full Dashboard window. The window has a sidebar (Overview, Projects, Sessions, Spending, Local model, Limits, Dev servers, Clean up) and Swift Charts.
- **Extras in scope:** the ⌥Space command palette, ZGX GPU stats, dev servers and Clean up.
- **Cloudflare:** a Tunnel protected by an Access service token. The app sends `CF-Access-Client-Id` / `CF-Access-Client-Secret`, with the secret kept in the Keychain.

**Local data checked on this Mac.** It allows a full history backfill without OTel:
- **Claude Code transcripts:** `~/.claude/projects/<dashed-cwd>/<sessionId>.jsonl`. There are 122 files, 261 MB in total.
  - 42 of them are subagent files under `<sessionId>/subagents/agent-*.jsonl`.
  - Each assistant line carries `message.model`, `message.id`, `requestId`, `message.usage` (input, output, cache_creation 5m/1h, cache_read, speed), `cwd`, `gitBranch`, `timestamp`, `isSidechain` and `agentId`.
  - The same message repeats once per content block, so lines must be deduped.
  - 78 files contain `cost-state` lines with Claude Code's own `totalCostUSD`, `modelUsage` and `totalLinesAdded/Removed`. This gives a ground truth to calibrate pricing against.
  - Claude Code is also pointed at the vLLM: 385 lines use model `Qwen…`.
  - Claude Code deletes transcripts after about 30 days by default. That makes our DB the long-term history, so it must never drop rows.
- **Copilot CLI:** `~/.copilot/session-store.db` (SQLite in WAL mode, read-only for us).
  - `sessions` has cwd, repository, branch and summary.
  - `assistant_usage_events` has model, tokens, cache, reasoning, `total_nano_aiu`, `request_multiplier` and `created_at`.
  - `turns` holds the turns. Note that `input_tokens` includes cache reads.
- **Qwen Code and Copilot JetBrains:** no local history. The only data is the OTel that reaches Hoply, so we must persist it ourselves.
- **Toolchain:** macOS 27.2, Xcode 27.2, Swift 6.4.2.

## Architecture

### Targets (still zero package dependencies)

`Package.swift` moves to swift-tools-version **6.2**, `.macOS(.v26)` and Swift 6 language mode. `LSMinimumSystemVersion` becomes 26.0.

- **`AgentKit`** stays pure and testable.
  - New folders: `Usage/` (UsageRecord, UsageAuthority, ClaudeTranscriptParser, CopilotUsageMapper, TelemetryUsage), `Pricing/` (PricingTable, with BundledPricing as a Swift string literal), `Projects/ProjectResolver`, `Metrics/` (GPUSnapshot, SampleAggregator, LimitsProjection), `Remote/RemoteEndpoint`, `Processes/` (DevServerClassifier, ProcessLineage, LsofParser), `Cleanup/CleanupRules`, `Palette/FuzzyMatcher`, `Notifications/NotificationPolicy` (moved out of `AppModel.shouldNotify`) and `Support/Timestamps`.
  - `Timestamps` is promoted from `ClaudeLimits.date(_:)` and caches its formatter.
- **`AgentSystem`** (new) holds the macOS I/O adapters. It has no UI and links `SQLite3`.
  - `SQLite/SQLiteConnection` and `Store/` (Schema, a `Store` actor that writes, a `StoreReader` actor that reads through a read-only connection).
  - `Ingest/` (FileTailer, DirectoryWatcher using FSEvents, ClaudeTranscriptIngester, CopilotStoreIngester, IngestCoordinator).
  - `ProjectRegistry`, `Remote/MetricsClient` and `Keychain`, `ProcessScanner` (libproc), `GitClient`, `CleanupScanner`.
- **`Hoply`** (UI) is organized into folders:
  - `App/`: `AppModel` moves to `@Observable`, plus `AppSettings` and `DashboardWindowController`.
  - `Models/`: LiveSessions, History, LocalModel, Limits, DevServers, Cleanup.
  - `Services/`: Notifier, HotKey, Trash, TerminalLauncher.
  - `Panel/`, `Dashboard/`, `Palette/`.
  - `Components/`: the existing `Card`, `Meter`, `SourceBadge`, `StatePill`, `Metric`, `Hint`, `LabeledRow` and `Format`, moved unchanged from `Views.swift`/`Formatting.swift`.
- **Tests:** `AgentKitTests` (pure, fixtures) and a new `AgentSystemTests` (temp directories, in-memory DB).

### Persistence

The DB is `~/Library/Application Support/Hoply/hoply.sqlite`, opened with WAL, `synchronous=NORMAL` and `busy_timeout=2000`. Versions are tracked in `PRAGMA user_version`, with an array of migration SQL applied in transactions. Before each migration and once a week, run `VACUUM INTO …bak` (keep 2).

Schema v1 tables:
- `projects`: root (unique), name, display_name, kind (`repo`/`folder`/`home`/`scratch`), pinned, hidden, last_active.
- `path_map`: cwd → project_id plus worktree. Its `origin` column distinguishes `auto` from `user` (manual merges).
- `sessions`: (source, id) as primary key, project_id, cwd, branch, worktree, title, pr_url, first_at, last_at, ended_at, turns, native_cost, lines_added/removed, transcript_path.
- `usage`: one row per model call. `dedupe_key` is UNIQUE. Other columns: source, session_id, project_id, ts, model, is_local, sidechain, agent_id, input (always uncached), output, reasoning, cache_read, cache_write_5m, cache_write_1h, cost_usd, api_equiv_usd, native_cost (Copilot AIU), request_multiplier, turn_index, pricing_rev.
  - Indexes on ts, (source, session_id) and (project_id, ts).
- `ingest_cursors`: (source, path) → inode, size, offset (bytes, or last rowid for Copilot), head_hash.
- `samples`: (series, res, bucket) → n/sum/min/max. Used for vLLM and GPU series, rolled up from 60 s to 900 s after 7 days and to 3600 s after 90 days.
- `limit_samples`, `state_spans` (for the time-in-state timeline) and `cleanup_log`.

Rules for the data:
- Totals are always `GROUP BY` over `usage`; nothing is denormalized.
- Writes are upserts with `ON CONFLICT(dedupe_key) DO UPDATE … max(…)`.
- When the pricing hash changes, all rows are re-priced in one transaction.
- "Reindex" resets cursors only and never deletes rows.

**One source of truth per agent** (`UsageAuthority.ledger(for:)`, pure and tested). This prevents double counting:

| Source | Ledger | Live OTel |
|---|---|---|
| Claude Code | transcripts (backfill, subagents, works with OTel off) | not persisted |
| Copilot CLI | `session-store.db` | not persisted |
| Copilot IDE, Qwen Code | OTel (persisted) | is the ledger |
| vLLM | its own `samples` series | never added to agent totals |

`HubRouter.Outcome` gains `usage: [UsageRecord]` and `HubServer` gains `onUsage`. Only records whose ledger is telemetry get persisted. The panel shows ledger totals for each live session, so the panel and the Dashboard always agree. `SessionBoard.apply` stays as it is, and hooks still own live state.

### Ingestion

- **Claude:**
  - **Discovery:** `projects/*/*.jsonl` plus `*/*/subagents/*.jsonl`. The config dir is a setting, default `~/.claude`.
  - **Backfill:** newest files first, with byte progress shown in the panel and on the Overview page.
  - **Tailing:** `FileTailer` stores (inode, size, offset, FNV hash of the first 512 bytes). It reads only complete lines. If the inode changed, the file shrank or the head hash differs, it re-reads from 0, which the upserts make safe.
  - **Parser:** `ClaudeTranscriptParser` skips `api-request-blob` and `file-history-*` lines by checking their prefix. It emits usage, `ai-title`, `cost-state`, `pr-link`, `agent-name` and user-prompt items, and skips `<synthetic>` rows.
  - **Dedupe key:** `cc:<message.id>:<requestId>`.
  - **Live updates:** FSEvents on `projects/` with 0.5 s latency. Each hook's `transcript_path` triggers an immediate tail of that file; this needs a new `AgentEvent.transcriptPath` set by `HookMapper`. A stat-only rescan runs every 60 s as a safety net.
- **Copilot CLI:**
  - Open with `mode=ro` (not `immutable`, so WAL content is visible) and `query_only`.
  - Poll every 10 s, skipping the query when the db and `-wal` mtimes haven't changed. A Copilot hook triggers a poll right away.
  - Read `WHERE e.id > cursor`, joined to `sessions`.
  - Uncached input comes from `token_details_json`, falling back to `input - cache_read`. AIU = nano ÷ 1e9. Premium requests = sum over turns of `MAX(request_multiplier)`.
  - Check `schema_version` and `table_info`, and degrade gracefully on an unknown version.
  - Dedupe key: `cp:<session>:<id>:<created_at>`.
- **OTel:**
  - `OTLPDecoder` keeps `traceId`/`spanId`/`timeUnixNano`.
  - Dedupe keys: `otel:<trace>:<span>` and `qw:<session>:<prompt_id>:<ts>`.
  - The project comes from the `hoply.cwd` resource attribute, which the user sets through `OTEL_RESOURCE_ATTRIBUTES` (Qwen is configured manually, see README). The fallback is `process.pid` → cwd via libproc. Otherwise the session goes under "Unassigned", with a manual Assign action.
- **Projects:** `ProjectResolver` is pure and doesn't run git.
  - It walks up from the cwd's realpath looking for `.git`.
  - A `.git` file means a worktree: `gitdir` plus `commondir` lead to the main repo, which becomes the project, and the worktree is recorded.
  - If no repo is found it uses `folder`; `$HOME` becomes `home` and the Claude scratch workspace becomes `scratch`.
  - Results are cached in `ProjectRegistry` and in `path_map`.

### Pricing and "spending"

- **Bundled table:** `BundledPricing` is a Swift string literal, because `install.sh` copies only the binary, so a resource bundle would be missing. Per model: input, output, cacheWrite5m (default 1.25×), cacheWrite1h (2×), cacheRead (0.1×), optional long-context tiers and fast-mode prices.
- **Model matching:** exact first, then with date, `[1m]` and `anthropic.` prefixes stripped, then by prefix.
- **Overrides:** `~/Library/Application Support/Hoply/pricing.json`.
- **Seed and calibration:** take seed prices from the `claude-api` skill's pricing reference, not from memory. Calibrate against `cost-state`: Settings → Pricing flags any model that is off by more than 2% from Claude Code's own `totalCostUSD`. An unknown non-local model shows as "unpriced", never as $0.
- **Meaning per source:**
  - **Claude:** "API-equivalent $", since the user is on a subscription. It is shown next to 5-hour and weekly limit usage.
  - **Copilot:** AIU and premium requests, with a monthly allowance setting and an optional $ per premium request.
  - **Local (Qwen/vLLM):** $0. `api_equiv_usd` is priced at a reference model, so the UI can show "saved vs API". Optional energy cost = GPU energy × $/kWh.

## Features

- **Cloudflare Access (M1):**
  - `EndpointConfig {baseURL, name, accessClientID}` is used for both the vLLM and the GPU exporter.
  - The secret is a SecItem generic password stored under service `…hoply.cf-access`.
  - `RemoteEndpoint.makeRequest` adds the headers. `MetricsClient` refuses redirects, and `classify()` maps a 302 to `*.cloudflareaccess.com`, a 403 or an HTML body to "Access rejected the service token".
  - Settings gets a "Test connection" button.
- **GPU stats:** `GPUSnapshot` parses DCGM (`DCGM_FI_DEV_GPU_UTIL/_GPU_TEMP/_POWER_USAGE/_TOTAL_ENERGY_CONSUMPTION`), nvidia_smi_exporter and node_exporter. node_exporter supplies host memory, because the GB10 has unified memory and DCGM's framebuffer fields may be empty. Needs an exporter installed on the ZGX (user action).
- **Dev servers:**
  - `ProcessScanner` uses only libproc, so no root is needed:
    - `proc_listallpids` lists processes, filtered to our uid.
    - `PROC_PIDFDSOCKETINFO` finds sockets in TCP LISTEN.
    - `PROC_PIDVNODEPATHINFO` gives the cwd.
    - `proc_pid_rusage` phys_footprint gives memory.
    - `KERN_PROCARGS2` gives the command line.
  - An `lsof -F` fallback goes through the pure `LsofParser`.
  - `DevServerClassifier`:
    - Excludes system ports and our own.
    - Maps cwd → project.
    - Detects the framework (Next, Vite, Astro, uvicorn, rails, dotnet, bun, deno…).
    - Names each server like "fiba · Next.js :3000 · 412 MB".
  - Actions: Open, Copy URL, Reveal, and Stop. Stop sends SIGTERM to the process group after confirmation, then SIGKILL after 5 s, and only when the group leader's cwd is inside the project.
  - Scan every 10 s while visible, 60 s otherwise.
- **Clean up.** The pure `CleanupRules` decide; `CleanupScanner` gathers the inputs. The user always reviews a checklist first. Move to Trash uses `NSWorkspace.recycle` (Put Back works) and logs to `cleanup_log`.
  - **Worktrees** are eligible only if all of these hold: not the main worktree, not locked, `git status --porcelain` empty, branch merged into the default branch, no live session or dev server inside it, idle more than 7 days. Afterwards, run `git worktree prune`.
  - **Build caches** (`.next`, `.vite`, `.turbo`, `.parcel-cache`, `.svelte-kit`, `.build`…) in projects idle more than 14 days, with no dev server running, and over 50 MB. `node_modules` is opt-in.
  - **Claude transcripts** older than 90 days, and only if fully ingested (cursor equals file size).
  - **Orphan processes:** `ProcessLineage` tracks descendants of agent processes. Once the agent is gone, any of them reparented to pid 1 is flagged. The action is Terminate, not Trash.
- **Command palette:**
  - **Hotkey:** Carbon `RegisterEventHotKey`, which needs no Accessibility permission.
    - **Risk:** macOS 15 and later reject hotkeys whose only modifier is ⌥, so ⌥Space may not register. Spike this in M0. Fallbacks: a user-chosen combo (default ⌃⌥Space), or an opt-in CGEventTap mode that needs Input Monitoring.
  - **Window:** a non-activating floating `NSPanel` with a glass `PaletteView`.
  - **Content:** providers for sessions, projects, dev servers, Dashboard pages and actions, ranked by `FuzzyMatcher` plus recency.
  - **Resume:** writes a `.command` file (`cd <cwd> && claude --resume <id>`) and opens it. This avoids the Automation permission prompt.
- **Panel (448×600):**
  - Header: counts, Dashboard button, palette hint.
  - "Waiting on you" comes first, with wait timers.
  - Working and recent sessions are grouped by project, with dev-server pills in each project header.
  - A 2×2 widget strip: today's API-equivalent $, a 5-hour ring with reset time, weekly usage, and ZGX tokens/s with a GPU sparkline.
  - Footer: listener status and "X GB reclaimable".
  - Glass goes only on the controls and tiles (`GlassEffectContainer`, `.buttonStyle(.glass)`). Respect Reduce Transparency.
  - If `MenuBarExtra` limits get in the way, the fallback is an `NSStatusItem` with an `NSPanel` hosting the same `PanelView`.
- **Dashboard:**
  - An AppKit `DashboardWindowController` (`NSWindow` + `NSHostingController`), so the panel, the palette and notifications can all open it.
  - The activation policy switches to `.regular` while the window is open, then back to `.accessory`.
  - Charts use `chartXSelection` for hover. Sessions get a time-in-state timeline from `state_spans`.
  - Limits page: history plus `LimitsProjection` ETA.
  - Local model page: tokens/s, KV cache, GPU utilization/temperature/power, tokens per day, saved vs API.
- **Notifications** (`NotificationPolicy`):
  - Permission requests are `.active`. Your-turn is `.passive` and keeps the existing rule (only after at least 30 s of work).
  - Threads per project, quiet hours, per-project mute, and at most one per session every 2 minutes.
  - Limit alerts at 80% and 95%, once per window. Alerts for vLLM offline more than 2 minutes and for GPU too hot.
  - Clicking a notification opens the Dashboard on that session.
- **Out of scope:** WidgetKit widgets. They need an Xcode extension target and an App Group, which SwiftPM can't build.

## Milestones (each ships and is tested)

| # | Ships | Key tests |
|---|---|---|
| **M0 Foundation** | tools 6.2 / macOS 26 / Swift 6; `AgentSystem` target; `Views.swift` split into folders with no behavior change; `@Observable` AppModel; **tolerant `AppSettings` decoding** (`decodeIfPresent`; today any new field silently resets settings); `HOPLY_SIGN_IDENTITY` in `install.sh` (a stable self-signed cert stops Keychain/TCC re-prompts after each ad-hoc rebuild); spikes for the hotkey and the glass MenuBarExtra | old settings JSON still decodes; existing 40 tests green |
| **M2 Store + Claude history** | SQLite + migrations, ProjectResolver, transcript backfill and tailing, pricing; ledger cost per session in the panel; Dashboard with Overview, Sessions, Spending | `ClaudeTranscriptParserTests` (stripped real lines: repeated blocks, sidechain, `<synthetic>`, Qwen model, title, cost-state, partial last line); `PricingTests` with **cost-state calibration**; `ProjectResolverTests` (temp repo + worktree); ingesting twice gives the same totals; tailer append/truncate/rotate; migrations |
| **M3 Copilot + OTel persistence + Projects** | CopilotStoreIngester, UsageAuthority filter, OTel IDs, Projects page and project grouping | `CopilotUsageMapperTests`; a temp DB built with the Copilot schema; OTel JSON/protobuf ID parity; `UsageAuthorityTests` |
| **M4 Notifications + Limits** (panel visuals done in M0.5) | panel numbers from the ledger, `NotificationPolicy`, `limit_samples`, Limits page | `NotificationPolicyTests`, `LimitsProjectionTests` |
| **M5 Local model + GPU** | `SampleAggregator` with rollups; GPU, energy and memory from sparkDash (JSON API with a Bearer token; the Keychain item and `RemoteEndpoint` request building move here from M1); Local model page, saved vs API | `SampleAggregatorTests` (counter reset), `GPUSnapshotTests` (captured sparkDash JSON), Bearer header test |
| **M5.5 Session insight** (ideas from T3 Code, see "T3 Code review") | context-window gauge, subagent lineage, Input and Limited states, live diff stat per session, status priority + recede + pulse, project monograms, Open in editor, cache hit rate and $/Mtok, unpriced-model "Price as" | `ContextWindowTests`, `StatusPriorityTests`, `HookMapper` input cases, `MonogramTests`, `GitClientTests` (shortstat in a temp repo), alias re-pricing in `PricingTests` |
| **M6 Dev servers** | scanner, classifier, panel pills, Dev servers page, Stop | `DevServerClassifierTests`, `LsofParserTests`; integration test opening a listening socket in-process |
| **M7 Clean up** | worktrees, caches, transcripts, orphans; review sheet; Trash + log | `CleanupRulesTests`, `ProcessLineageTests`, `GitClientTests` (temp repo with a merged worktree) |
| **M8 Palette** | NSPanel, providers, fuzzy ranking, Resume | `FuzzyMatcherTests` |
| **M1 Cloudflare Access** (built last, by user decision) | endpoint settings, CF headers on top of M5's Keychain/`RemoteEndpoint`, error classification, Test button. Until it lands, moving the ZGX behind the tunnel breaks the local model card and sparkDash | `RemoteEndpointTests` (headers, 302/403/HTML) |

**Keep in sync along the way:**
- `simulate.sh`: send `transcript_path` and Qwen resource attributes.
- `install.sh`: Claude OTel becomes optional (transcripts are the ledger).
- `CLAUDE.md` and `README.md`: the new targets and the ledger rule.
- Fixtures are stripped to the needed keys, with no prompt or response content.

**M0 outcome (2026-11-09):**
- Package: tools 6.2, `.macOS(.v26)`, Swift 6 mode everywhere; `Hoply` uses `.defaultIsolation(MainActor.self)`. AgentKit needed no concurrency changes.
- `AgentSystem` holds only a minimal `SQLiteConnection` (open, execute, `user_version`). M2 builds the Store on it.
- Deviation: `AppSettings` lives in AgentKit (`Settings/AppSettings.swift`), so the settings-compat test can run there. UserDefaults storage is `Hoply/App/AppSettings+Storage.swift`. Each key decodes leniently: a missing or wrongly typed key falls back to its default.
- The panel's main view was renamed `DashboardView` → `PanelContent`, to free the name for the v2 Dashboard window. `AppModel.launchAtLogin` is now stored and refreshed when Settings opens.
- Tests: 45 in AgentKitTests (40 existing + 5 `AppSettingsTests`) and 3 in AgentSystemTests, all green.
- `swift run` shares the installed app's UserDefaults domain, because the embedded Info.plist carries the same bundle id. A dev build can't run on another port without changing the installed app's settings.
- **Hotkey spike:** on macOS 27.2, `RegisterEventHotKey` returns 0 for ⌥Space, ⌥⇧Space, ⌃⌥Space, ⌘⌥Space and ⌃⌥⌘Space. Delivery is **unverified**: synthetic key events need Accessibility (the terminal lacks it), and no real key press arrived during the 90 s manual window. M8 must check at runtime whether the hotkey fires, and keep the ⌃⌥Space fallback and the user-chosen combo.
- **Glass spike:**
  - `glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)` and AppKit's `NSGlassEffectView` compile and run in both a `MenuBarExtra(.window)` and a borderless non-activating `NSPanel`.
  - `MenuBarExtra`'s status button has no target or action, so the panel **cannot be opened or closed programmatically** without private hacks.
  - The `NSPanel` path shows and closes on command.
  - No visual check was possible, because the terminal lacks Screen Recording permission.
  - Recommendation for M4: move to `NSStatusItem` + `NSPanel` if anything has to show the panel (the palette, a hotkey, a notification), or if custom chrome or size animation is needed. Otherwise keep `MenuBarExtra`.

**M0.5 outcome (2026-11-09):** the user found the M0 panel "far from the glass and how usemizu looks". So the panel visuals moved ahead of M1. Mizu's own screenshots (usemizu.com `/img/resources/guide-panel.webp`, `widgets-1-0.webp`) were the reference.
- **Container:** `NSStatusItem` + `NSPopover` (`App/StatusItemController`). It has an arrow, system material, `.transient` close, and code can open it. Right-click gives Open / Settings… / Quit. The status icon updates through `withObservationTracking`. This settles the M4 container question.
- **Layout, 448×600:**
  - Header: name, a bell (pause notifications) and a gear.
  - Stat strip: Agents with an activity sparkline, Need you with the oldest wait, and the local model's tok/s with a sparkline.
  - A "Waiting on you" card.
  - Project cards. Each has an icon tile, its sessions, and Terminal / Finder / Copy path buttons.
  - Widget strip: a Claude 5-hour ring plus Week, a KV cache ring plus queue, and live usage with a per-source stacked bar.
  - Footer: listener status and a power button.
- **Interim data:**
  - Projects are grouped per cwd by `SessionGrouping` (AgentKit, tested). M3's ProjectResolver replaces this.
  - Sparklines are in-memory `RollingSeries` (AgentKit, tested). M5's `samples` table replaces them.
  - "Live usage" sums the open sessions' OTel tokens and cost. M2's ledger "Today" replaces it.
- **Verification:** `Hoply --snapshot <dir>` renders `PreviewData` to PNGs in light, dark, full height and settings, without Screen Recording permission. Glass and vibrancy don't show in snapshots. The user still has to check the live popover material in both appearances and with Reduce Transparency.
- **Buttons:** they use system `.bordered` / `.borderedProminent` styles, which get the glass look on macOS 26 automatically. `.buttonStyle(.glass)` rendered black labels in dark-mode snapshots, so it is avoided until verified live.
- **Unused for now:** `Meter` and `Metric` are kept for the Dashboard Limits and Local model pages.
- **Still in M4:** `NotificationPolicy`, `limit_samples`, the Limits page, and switching panel numbers to ledger totals.

**M2 core outcome (2026-11-09):**
- Entry point: `AgentSystem.Ledger.open(LedgerConfiguration(settings:))` bundles `Store`, `StoreReader` and `IngestCoordinator`. Read-API value types live in `AgentKit/Usage/LedgerSummaries.swift`. Charts plot `apiEquivUSD`.
- New `AppSettings` keys: `localModelPatterns` (default `["qwen"]`), `referenceModel` (`claude-sonnet-5-5`), `claudeConfigDir` (`""` = `~/.claude`).
- Tests: AgentKitTests 80, AgentSystemTests 30 (one opt-in: `HOPLY_REAL_TRANSCRIPTS=1` ingests the real `~/.claude` into a temp DB).
- Real data: 132 files / 290 MB ingest in 3.7 s. Pricing reproduces each cost-state's per-model totals exactly (Opus 5.5, Haiku 5.5). Ledger vs `cost-state.totalCostUSD`: 41 of 77 sessions within 2% (bar was 5). Outliers run low because Claude Code bills calls it never writes to the transcript (title generation, some subagent calls); continuations carry the parent's cost-state over.
- Pricing: web search $10/1k; cache writes without a 5m/1h split are treated as unknown split; Opus 4.8 fast priced at $10/$50 (from the skill's platform-availability table); fast-mode cache prices scaled by the fast/standard ratio (assumption). Opus 4.5 / Sonnet 4.5 unpriced (add via `pricing.json`).
- Schema v1 deviations: `usage.speed`, `sessions.title_rank`, `limit_samples.kind` (not `window`), extra indexes on `sessions(last_at)` / `sessions(project_id)`. `turn_index` and `ended_at` stay NULL in M2. Reindex resets cursors via `UPDATE`. Hook tails are limited to the configured Claude dir.

**M2 UI outcome (2026-11-09):**
- `Hoply/Models/History.swift` (`@Observable`) owns the Ledger: single `updates` consumer, re-queries ≤1/s during backfill, generation counters drop stale results. Open failure shows "History off" and the app keeps working.
- Panel: "Live usage" became **Today** (ledger, API-equiv $); session rows show ledger cost, falling back to live OTel numbers (tooltip) for sources without ledger rows yet (Qwen, Copilot until M3); footer backfill indicator; header Dashboard button.
- `DashboardWindowController` (single `NSWindow`, `.regular` policy while open) with Overview, Sessions, Spending; also "Open Dashboard" in the status item's right-click menu. Settings gains a History section (status, Reindex, local patterns, reference model, Claude dir).
- Snapshots render the Dashboard with a stand-in sidebar (`DashboardView(plainSidebar: true)`): the real `NavigationSplitView` draws black offscreen. Money grouping fixed to `en_US`.
- Live run on real data: 133 files backfilled in ~8 s; 82 sessions, $578 API-equiv, 0 unpriced.
- Cleanup: `stop()` ends in-flight reads after the current batch and drops queued files (tested); `SpendChartData` (ranking, "Other" fold, unpriced days) is pure AgentKit; `ModelName.display` gives "Opus 5.5"-style labels (`ModelName.family` exists but is unused so far). Harness-injected prompts (`<…>`) no longer name sessions.
- Unverified (user): live glass sidebar/toolbar, hover, Reduce Transparency, Dock icon on open/close, ⌘W, ~1 s hook→tail cost update, app-menu "Settings…" opens the empty SwiftUI `Settings` scene under `.regular`.

**M3 core outcome (2026-11-09):** AgentKit, AgentSystem, tests, `simulate.sh` and docs. The UI half (wiring and the Projects page) is pending.
- **API for the UI:** `Ledger.record(_:)` (feed it `HubServer.onUsage`), `Ledger.pollCopilot()` (call on Copilot CLI hooks), `Ledger.resolveProjects(_ cwds:) -> [String: ProjectRef]`, then `SessionGrouping(sessions:projects:)`. `StoreReader.projects(in:topModels:) -> [ProjectSummary]`, `dailySpend(…, project: ProjectFilter?)`, `sessions(in:source:project:…)` (`projectID:` became `project: .project(id)` or `.unassigned`). `LedgerTotals` gained `aiu` and `premiumRequests`, so every totals query returns them. `IngestProgress.copilot: CopilotStoreStatus`. Setting `copilotHome` (`""` = `$COPILOT_HOME`, else `~/.copilot`), carried by `LedgerConfiguration(settings:)`.
- **Schema v2** (migration 2, with the usual `VACUUM INTO` backup): `usage.native_usd` (the agent's own USD; such rows have `pricing_rev = 'native'` and are never re-priced), `usage.premium_requests` (a turn's highest multiplier, booked on its earliest call so totals stay plain sums; recomputed for the turns a batch touches), and a partial index `usage_turn`.
- **Copilot store access:** macOS's SQLite refuses `mode=ro` when `-wal`/`-shm` are absent, and creates nothing. Copilot's own (Node-bundled) SQLite removes them on a clean close. In that state the main file is read into a read-only in-memory snapshot (`sqlite3_deserialize`, header patched to rollback mode in the copy). With a `-wal`, the file is opened in place with `mode=ro`; SQLite then creates a missing `-shm` itself. Connections are opened per poll, so Hoply never blocks Copilot's checkpoint-on-close. A test checks that the db and WAL bytes stay unchanged.
- **Deviations:**
  - The uncached-input fallback subtracts cache reads **and** cache writes: in all 284 real rows, `input_tokens = input + cache_read + cache_write`.
  - `PricingTable.normalize` maps `claude-haiku-4.5` to `claude-haiku-4-5`, so NULL-AIU rows price through the table. Copilot's native USD equals the bundled list price exactly (tested on real Haiku 4.5 and Opus 5 rows).
  - Copilot sessions without any usage event stay out of the ledger.
  - Qwen `input_token_count` includes cached tokens, which are subtracted. Thoughts are added to the output only when `total_token_count` shows they come on top of it (Gemini style).
  - GenAI spans: uncached input = input − cache read − cache creation.
  - The pid fallback ignores cwd `/` (GUI apps such as an IDE) and pids started after the record. Telemetry sessions get no turn count.
  - `copilot_spans.json` now carries the `.pb` capture's trace/span ids, so the parity test covers ids.
- **Real data (`HOPLY_REAL_COPILOT=1`, temp copy of `~/.copilot/session-store.db`):** 284 events, 5 sessions with usage (8 rows in `sessions`), $28.5927 = 2859.27 AIU, 182.66 premium requests. The ledger matches exactly. Read in 0.01 s. Projects: fiba $18.35, FIBA3x3.RuleEngine $10.16, Home $0.09. `HOPLY_REAL_TRANSCRIPTS=1` is unchanged: 138 files in 4.1 s, 42 of 79 within 2%.
- **Tests:** AgentKitTests 112 (+21), AgentSystemTests 54 (+23, 2 opt-in skips), all green.
- **Deferred:** manual Assign/merge of projects (`path_map.origin = 'user'`), which also covers re-homing Unassigned telemetry. Copilot monthly allowance and $ per premium request settings (M4 with Limits). Qwen turn counts from `user_prompt` logs.

**M3 UI outcome (2026-11-09):**
- **Wiring:** `HubServer.onUsage` → `History.record` → `Ledger.record`. Batches are chained in arrival order (a record without a cwd borrows its session's earlier cwd). While the ledger opens they wait in a bounded backlog (5,000 records); if it fails to open they are dropped. Copilot CLI hook events call `History.pollCopilot`. A `copilotHome` change reopens the ledger, like `claudeConfigDir`.
- **Panel grouping:** `AppModel.projectsByCwd` caches `Ledger.resolveProjects` results. Unseen live-session cwds resolve in a background task on every publish (at least every 5 s), so cwds seen before the ledger opened resolve later. Misses are not retried until the next reopen. With History off, `grouping` gets an empty map, so sessions group per cwd. Project cards use the project title, root and kind icon. Rows inside a card name their linked worktree (branch glyph) or subfolder instead of the source name, so the state never truncates. "Waiting on you" rows show the resolved project title.
- **Projects page** (`Dashboard/ProjectsPage.swift`, sidebar between Overview and Sessions):
  - The list has a 7 / 30 / 90 days / All picker and two-column tiles: kind icon, title, root (+ worktree count), spend with share of range, per-source stacked bar with legend, tokens / sessions / branches / last active, top models, and Copilot units. Unassigned is a separate, quieter full-width row at the end, with the `hoply.cwd` hint.
  - The detail has a back button, the range picker, Reveal in Finder / Open in Terminal / Copy path (hidden for Unassigned), and four tiles (Spend, Sessions, Tokens, then Copilot, Ran locally or Branches, whichever applies). Below them: a daily spend chart by model (`dailySpend(project:)`), By source and By model breakdowns, and the project's sessions (`SessionTable` + `Pager` + `SessionDetail`).
  - Overview "Top projects" and Spending "By project" rows open the detail and carry their range over (`History.openProject(_:range:)`).
- **Copilot units** (`Format.copilot`, "182.7 premium req · 2,859 AIU") appear on panel session rows (compact "req"), the Sessions table cost column, the session detail caption, project and model breakdown rows, project tiles, source legends and the detail's Copilot tile.
- **Settings → History:** "Copilot dir" (placeholder `~/.copilot`) and a Copilot CLI status line from `IngestProgress.copilot` (not read yet / no session store found / up to date / unsupported schema / last read failed; details in the tooltip). Reindex help now names the Copilot store.
- **Deviations:**
  - Core change: `ProjectSummary.firstActive` (`MIN(ts)` in `StoreReader.projects`, asserted in `TelemetryLedgerTests`). With it, the "All" chart starts at the project's first usage, with a 30-day minimum. Without it the UI would have had to guess a day count.
  - The Sessions table gained a source badge. Untitled (telemetry) sessions read "<Source> session", and an unknown turn count shows "–".
  - `BreakdownList` rows were factored into `BreakdownRow`; `RowButtonStyle` (`.row`) adds the hover highlight for clickable rows.
- **Snapshots** (`build/snapshots/`, light + dark): `panel-*` (fiba card holds a `landing-hero` worktree session; hoply holds a Copilot CLI session in `Sources/AgentSystem` with premium req / AIU; Qwen ledger totals), `panel-settings-*` (Copilot dir and status), `dashboard-projects-*` (6 projects + Unassigned), `dashboard-project-detail-*` (fiba, 1180×1260), plus overview, sessions and spending. `PreviewData` builds every Dashboard figure from one set of usage streams (Claude, Qwen, Copilot CLI, Copilot IDE × project shares), so Overview, Spending and Projects agree.
- **Tests:** AgentKitTests 112, AgentSystemTests 54 (2 opt-in skips), all green.
- **Unverified live:**
  - `simulate.sh` was not run, because the user's own `swift run` instance was listening, and since M3 its Qwen and Copilot IDE spans become permanent ledger rows (fake `sim-*` sessions under `~/Project/fiba`) that Hoply never deletes. Run it only against a throwaway ledger, or accept those rows.
  - Hover highlight on tiles and rows; the panel's project grouping on real hooks (worktree / subfolder merge); `pollCopilot` on a live Copilot CLI turn; the Projects pages on real data. A read-only check of the real ledger showed Copilot CLI at $28.59 / 2,859.27 AIU / 182.66 premium req, and fiba, FIBA3x3.RuleEngine and Home mixing Copilot and Claude.

**M4 core outcome (2026-11-09):** AgentKit, AgentSystem, tests and docs. The UI half (AppModel/Notifier wiring, Limits page, Settings) is pending.
- **API for the UI:**
  - `NotificationPolicy(preferences: NotificationPreferences(settings:), calendar: .current)`, owned by `AppModel`; reassign `preferences` on every settings change. Each call returns `NotificationActions` (`post: [NotificationRequest]`, `withdraw: [String]` delivered ids): `sessionChanged(_:project:now:)` for every `StateChange` from `SessionBoard.apply` and `tick` (replaces `AppModel.shouldNotify`), `sessionDismissed(_:)`, `limitsUpdated(_:previous:now:)`, `localModelChecked(server:name:online:now:)` on every model-server poll. `NotificationRequest`: `id` (the UN identifier; stable per session, `session:<source>:<id>`), `kind`, `interruption` (`.active`/`.passive`), `title`, `body`, `threadID`, `session` (click-through), `playsSound`.
  - Limits: `ClaudeLimits.samples(at:)`; `Ledger.recordLimits(_:at:) -> [LimitKind: LimitSample]` returns each window's last stored sample from before the write, which is the `previous` for `limitsUpdated` (nil when History is off). Reads: `Ledger.limitHistory(days:now:bucket:)` (bucket keeps each window's peak), `Ledger.limitProjections(now:)`, `Ledger.latestLimitSamples()`, or `StoreReader.limitSamples(_:in:bucket:)` / `latestLimitSamples()`. `LimitsProjection`: `utilization`, `resetsAt`, `windowStart` (sum ledger spend from here), `windowSamples`, `burnRatePerHour`, `projectedUtilization`, `limitReachedAt`, `isAtLimit`.
  - Copilot: `Ledger.copilotAllowance(settings:now:)` reuses `totalsBySource(in:)` over the UTC month and returns `CopilotAllowance` (`used`, `remaining`, `fraction`, `overageRequests`, `overageUSD`, all nil when the allowance is 0; `month`, `nextReset`).
  - New `AppSettings` keys: `quietHoursEnabled` (false), `quietHoursStart` / `quietHoursEnd` (minutes, 1320 / 480), `mutedProjectRoots`, `limitAlertsEnabled`, `localModelAlertsEnabled` (true), `copilotMonthlyAllowance` (300), `copilotUSDPerPremiumRequest` (0.04).
- **No schema change:** v1's `limit_samples` is used as is. A repeat (same utilization, reset within tolerance) is stored at most every 15 min.
- **Decisions:**
  - Interruption: permission and local-model-offline active; your-turn and the 80% limit passive; 95% active.
  - `resets_at` tolerance is 300 s (the API jitters; windows of one kind reset at least 5 h apart). Limit ids round `resets_at` to 10 min. With no previous sample at all, the first fetch counts as a new window (85% at first launch alerts at 80%). Posted limit ids are also remembered for the run, so a dip and re-rise in one window can't repeat.
  - An offline alert held back by quiet hours or switched-off preferences posts once they allow it, if the server is still offline: it is a state, while a missed limit crossing is dropped. Coming back online withdraws it; changing or clearing the URL resets the watch.
  - Withdrawals are reported even with notifications off. Mutes match the exact project root (or cwd while unresolved), never subfolders, so muting Home doesn't mute every repo under it. Quiet hours with start = end are never quiet.
  - Copilot IDE premium requests never reach the ledger (telemetry has no multiplier), so the allowance counts Copilot CLI only.
- **UI must:** evaluate limits only once History is ready (or failed, then `previous: nil`), and take `previous` from `recordLimits`, never from `latestLimitSamples()` after recording. Update CLAUDE.md data-flow step 4 when `shouldNotify` goes.
- **Tests:** AgentKitTests 146 (+34: 19 `NotificationPolicyTests`, 9 `LimitsProjectionTests`, 5 `CopilotAllowanceTests`, 1 `AppSettingsTests`), AgentSystemTests 58 (+4 `LimitSamplesTests`, 2 opt-in skips), all green.

**M4 UI outcome (2026-11-09):** the Hoply target only; no AgentKit/AgentSystem change.
- **Wiring:** `AppModel` owns the `NotificationPolicy` and reassigns its `preferences` in `apply`. Every `StateChange` from `SessionBoard.apply` and `tick` goes through `sessionChanged` with `projectsByCwd[cwd]`; `dismiss` withdraws; every model-server poll (blank URL and errors included) calls `localModelChecked`. `shouldNotify` is gone. Limits: fetch → `History.recordLimits` (awaits the open task while the ledger opens, returns `Ledger.recordLimits`' result, nil when History is off or the write fails) → `limitsUpdated(limits.samples(at: fetchTime), previous:)`.
- **Notifier:** `post(NotificationRequest)` uses `request.id` as the UN identifier, maps `interruption` to `.active`/`.passive`, sets `threadIdentifier`, a sound only when `playsSound`, and `kind` / `source` / `session` in `userInfo`; `withdraw` calls `removeDeliveredNotifications`. It is its own `UNUserNotificationCenterDelegate`, set in `AppModel.init` (inside `applicationDidFinishLaunching`, bundled app only, nonisolated async delegate methods): `willPresent` → banner + list + sound; a default-action click → `NotificationTarget` → a session opens the Dashboard's Sessions page with that session selected (`History.openSession`: `reader.session(key)` when it falls outside the page's range or isn't on the current page), a limit alert opens Limits, local-model-offline opens the panel.
- **Limits page** (`Dashboard/LimitsPage.swift`, sidebar after Spending):
  - A card per window present (5-hour, Weekly, Opus/Sonnet when the API sends them), two columns: ring, reset time and countdown, a bar with the used part, the projected part and ticks at 80/95%, the outlook ("At this pace: 100% at 20:55, 1 h 8 min before reset" in orange, or "Projected 52% at reset"), a chip (On track / Tight ≥ 90% / Hits limit / At limit / Measuring / Reset), and burn rate (%/h for 5-hour, %/day for weekly), at-reset % and Claude Code's API-equivalent $ from `windowStart` to `min(now, resetsAt)`. A stale reading says "last reading …".
  - "Utilization history": 7 / 30 days (`limitHistory` with `bucket` 600 s / 3600 s), a line + gradient area per window, split at each reset so windows don't join; 5-hour resets as short ticks on the baseline, weekly resets as dashed rules labelled "Week reset"; dashed alert lines at 80/95%; `chartXSelection` tooltip with each running window's value.
  - Copilot card: premium requests this UTC month vs allowance (`Meter`), remaining, overage requests and $, AIU and API-equivalent (Copilot CLI's `totalsBySource` over `CopilotAllowance.month`), reset date in UTC. Allowance 0 shows used only with a pointer to Settings.
  - Empty states: not connected (Connect button), loading / fetch error (Try again), History off (the window cards fall back to the live fetch, without burn rate; chart and Copilot card say the ledger is off), no readings yet.
- **Panel:** the Claude limits widget is a button to Limits (the Connect state stays a plain tile). Project cards gained a fourth action tile, bell / bell.slash, which toggles `group.path` (the project root, or the cwd while unresolved) in `mutedProjectRoots` at once; a muted card shows a small bell.slash next to its activity dot. The header bell's tooltip reads "Pause notifications · Quiet hours until 08:00" while quiet hours hold notifications back.
- **Settings:** a Notifications card (the master switch moved there from Behaviour; limit alerts; local model offline; quiet hours with two hour:minute `DatePicker` fields; muted projects with Unmute, edited in the draft) and a Copilot plan card (allowance field with a Plan menu: Free 50, Pro 300, Pro+ 1,500, Business 300, Enterprise 1,000; $ per extra request, "$" and "," accepted, invalid input keeps the saved value). No new setting keys beyond the core's.
- **Panel numbers:** confirmed ledger-only where ledger totals exist. Session rows show `History.sessionTotals` and fall back to live OTel only while the session has no ledger rows (History off, or before its first ingest); Today is ledger; the stat strip shows counts and vLLM throughput, not usage.
- **Snapshots** (`build/snapshots/`): `dashboard-limits-{light,dark}` (5-hour at 62% heading for the limit, week on track, a week reset, Copilot 28.5 of 300), `dashboard-limits-empty-*` (not connected, allowance 0), `panel-settings-full-*` (every settings card), and the panel's muted hoply card. `PreviewData.limitSamples` builds a week of 15-minute readings that ends at the panel's 62% / 25%, with the week climbing only while 5-hour windows run; window spend comes from the preview Claude Code stream and the Copilot numbers from the Copilot CLI stream.
- **Small additions:** `Format.clock`, `.span`, `.timeOfDay(minutes:)`, `.date(minutesAfterMidnight:)` (DST-safe), `.utcDay`, `.utcMonth`; `AppModel.panelOpener`, `showPreview(settings:)` (snapshots only).
- **Tests:** AgentKitTests 146, AgentSystemTests 58 (2 opt-in skips), all green.
- **Unverified live** (only the bundled `.app` posts notifications, and the user's own instance was listening on 4318, so neither `install.sh` nor `simulate.sh` ran; `simulate.sh` would also write permanent `sim-*` rows):
  - Posting, replacing by id, withdrawing when a session leaves Waiting, threads per project, passive vs active (sound), banners while the Dashboard is in front, quiet hours and mutes in practice, the limit alerts at 80/95% across a restart, the local-model offline alert after 2 minutes.
  - Click-through, including a click that launches Hoply (the delegate is set during `applicationDidFinishLaunching`).
  - The Limits page on real `limit_samples` (one reading per 3 min) and hover smoothness at 30 days; the `DatePicker` fields and Plan menu inside the popover; the mute tile; light/dark/Reduce Transparency live. The glass polish pass is still open (Known issues).

**M4 polish core (2026-11-09):** AgentKit, AgentSystem and tests. The UI half (pace marker, scoped window cards, discovery of unknown keys) is pending.
- **API for the UI:**
  - Pace: `LimitPace` (`elapsedPercent`, `delta` = used% − elapsed%, `band` `.ahead` / `.onTrack` / `.under`, ±5 points inclusive is on track; nil without `resets_at` or once the window has reset). From `limits.fiveHour?.pace(.fiveHour, at: fetchTime)` (panel ring, one live reading), `LimitSample.pace(at:)` or `LimitsProjection.pace(at:)`.
  - `ClaudeLimits`: `scoped: [ScopedWindow]` (`displayName`, `kind`, `window`), `extraUsage` (`isEnabled`, `usedCredits`, `monthlyLimit`, `utilization`, `percentUsed`; raw numbers, no unit), `spend` (`enabled`, `used`/`limit` as `Money(amountMinor, currency as sent, exponent)`, `percentUsed` only for matching currency and exponent), `unrecognizedKeys` (sorted top-level keys not decoded), `windows` (fixed then scoped, deduped) and `window(_:)`. `samples(at:)` now includes scoped windows, so `Ledger.recordLimits` persists them and `limitProjections` projects them.
  - `LimitKind` is now an open struct (`RawRepresentable`, `Comparable`: fixed windows first, then scoped by name). `allCases` stays the 4 fixed windows. `LimitKind.scoped(displayName:)`, `isFixed`, `scopeName`, `displayName` ("Weekly Sonnet 4.5", rebuilt from the slug; prefer `ScopedWindow.displayName` while a fetch has it).
- **Decisions:**
  - Scoped kinds are `seven_day_<slug>` (lowercase ASCII letters and digits, other runs → `_`), T3's id scheme, so a scoped "Opus" is the same kind as `seven_day_opus`; the fixed key wins when both are present. Stored rows keep decoding: `LimitKind(rawValue:)` accepts `five_hour`, `seven_day` and any well-formed `seven_day_<slug>`; anything else (e.g. `monthly_spend`) is still skipped.
  - Two scoped shapes are decoded: the Agent SDK's `model_scoped: [{display_name, utilization, resets_at}]`, and `limits: [{kind: "weekly_scoped", percent, resets_at, scope: {model: {display_name}}}]`, which is what T3 Code's cliproxy integration reads from `/api/oauth/usage` itself. Both are unverified against our endpoint. The SDK's `rate_limits` wrapper is unwrapped like `usage`.
  - Top-level `seven_day_*` keys other than opus/sonnet are listed in `unrecognizedKeys`, not guessed as windows. Booleans never count as numbers.
  - Scoped windows get limit alerts like the fixed ones ("Claude weekly Fable limit at 80%").
- **Deviation:** `Sources/Hoply/Dashboard/LimitsPage.swift` got one line, `default: return .indigo` in `LimitsStyle.color`, because an exhaustive switch over the old enum can't compile against an open set. The UI half must also switch the Limits page from `LimitKind.allCases` to the projections' own kinds (`projections.keys.sorted()`), or scoped windows stay hidden.
- **Tests:** AgentKitTests +15 (7 `LimitPaceTests`, 8 `ClaudeLimitsDecodeTests`), AgentSystemTests +1 (`LimitSamplesTests`: scoped windows persist and project; the unknown-kind test now expects `seven_day_haiku` to decode).

**M5 core outcome (2026-11-09):** AgentKit, AgentSystem, tests and docs; no GPU parser. The UI half (recording polls, sparkline seeding, Local model page, sparkDash settings and token field) is pending. **`GPUSnapshot` is pending a captured sparkDash response** (with a token): `/api/sparks/zgx-ff24/metrics`, `/api/sparks/zgx-ff24/gpu-history`, `/api/sparks/zgx-ff24/llm/daily` and `/api/fleet-energy`.
- **API for the UI:**
  - Model-server series: after each successful `/metrics` poll, `Ledger.recordModelSamples(status)` with the `VLLMStatus` the app already computes. Reads: `Ledger.recentModelSamples(since:)` → `[series: [SampleBucket]]` (60 s buckets; seed `throughput` from `ModelServerSeries.generationTokensPerSecond` maxes), `Ledger.samples(_:resolution:in:)` (merged up to `resolution`; older stretches come back at 900/3600 s), `Ledger.modelTokensPerDay(days:)` → `[ModelTokenDay]` (`generated`, `prompt`, `observed`), `Ledger.localModelSpend(days:split:)` → `DailySpendSeries` of `is_local` usage (tokens, `apiEquivUSD` = saved vs API). Generic: `Ledger.recordSamples(_:)`, `StoreReader.samples`, `recentSamples`, `dailySums` (`[DailySampleSum]`: `sum`, `readings`), `dailySpend(…, localOnly:)`.
  - Series (`ModelServerSeries`): `model.generation_tps`, `model.prompt_tps`, `model.kv_cache_pct` (0…100), `model.running`, `model.waiting` (gauges), `model.generation_tokens`, `model.prompt_tokens` (counters).
  - Remote: `SparkDash.endpoint(settings:)` → `RemoteEndpoint?`; `MetricsClient(endpoint:)` (Keychain by default) `.fetch(SparkDash.sparkPath(name, "metrics")!)` → `Data`, or throws `RemoteError` (`kind`: `missingToken`, `invalidToken`, `tokenRejected(status:message:)`, `htmlPage`, `redirected(status:host:)`, `http`, `transport`, `invalidURL`; `errorDescription` e.g. "sparkDash rejected the token (HTTP 401)"). Token: `Keychain().setBearerToken(_:for:)` (blank deletes), `bearerToken(for:)`, `deleteBearerToken(for:)`; service `com.coolcraftcoders.hoply.sparkdash`, account = endpoint host. Store `RemoteEndpoint.sanitizedBaseURL(input)` as the URL setting.
  - New `AppSettings` keys: `sparkDashURL` (""), `sparkDashName` ("", the spark id), `energyPricePerKWh` (0 = off).
- **No schema change:** v1's `samples(series, res, bucket, n, sum, min, max)` as is.
- **Decisions:**
  - Writes merge into their bucket (n and sum add, min/max widen), so each poll counts once. Gauges: `sum`/`n` = mean. Counters: `sum` = increase in the bucket, `min`/`max` = raw readings; a drop is a restart (the new value counts from 0); the first reading after launch takes its baseline from the latest stored bucket's `max`; an increase across more than 6 h of silence starts a new baseline instead of landing as one spike (`counterGapLimit`).
  - The generated-token counter is the engine's own counter (`VLLMSnapshot.generationTokensCounter`, new), not `generationTokensTotal`: tensorfold's live-stream tokens make that dip when a stream is cancelled, which would read as a restart and double count. tok/s still uses the live total.
  - Rollups move rows past 7 days to 900 s and past 90 days to 3600 s, then delete the moved fine rows (sample rows only, never usage), in one transaction. Cutoffs are floored to the coarse resolution, so a coarse bucket never splits across two resolutions; a re-run changes nothing. They run in `Store.init` and on the first sample write a day after the last run.
  - Live check: the ZGX's `/metrics` also has `device_memory_bytes`, `prompt_tokens_cached_total`, MTP and latency histograms; left out of the stable set for now. sparkDash answers a missing or wrong token with 401 `{"error":"Authentication required"}` (→ `tokenRejected`), and any non-`/api` path with its HTML app (→ `htmlPage`).
  - `RemoteEndpoint` drops query, fragment and user info from the base URL and credential-like query items (`token`, `access_token`, `api_key`, `apikey`, `secret`) from paths; header values must be printable ASCII. `RemoteCredentials.headers` is where M1's CF Access headers go; M1 also adds the `*.cloudflareaccess.com` redirect and HTML 403 cases to `classify`. The redirect refusal is a per-task `URLSessionTaskDelegate`, checked against a loopback server.
- **Tests:** AgentKitTests 179 (+33 over M4: the 15 above, 8 `SampleAggregatorTests`, 3 `ModelServerSeriesTests`, 6 `RemoteEndpointTests`, 1 `AppSettingsTests`), AgentSystemTests 71 (+13: the 1 above, 7 `SamplesStoreTests`, 5 `MetricsClientTests`; 2 opt-in skips), all green.
- **Still open in M5:** sample at a fast cadence only while the panel or Dashboard is visible (UI), `GPUSnapshot` + its series, energy cost (GPU energy × `energyPricePerKWh`), the Local model page.

**M4 polish UI + M5 UI outcome (2026-11-09):** the Hoply target only; no AgentKit/AgentSystem change. GPU, energy and memory are skipped by user decision (no sparkDash capture): no sparkDash settings, token field or GPU cards; the Keychain/`MetricsClient` plumbing stays unused.
- **Pace:** Limits cards get a chip (Ahead of pace orange, On pace blue, Under pace teal; tooltip with used vs elapsed and the delta), a dark tick at the elapsed share on the projection bar and on the ring, and "48% of the window gone" in the reset line. Pace is measured at the reading's time (`projection.pace(at: current.ts)`), so a stale reading isn't compared with later time; hidden once the window has reset. Panel: the 5-hour ring gets the same tick (2 pt, readable at 54 pt in both appearances); the band goes in the tile's tooltip, not the footer ("Resets 22:07" already fills its ~110 pt). New `AppModel.claudeLimitsFetchedAt` (also used for the History-off fallback's sample time).
- **Scoped windows:** cards and chart series come from the projections' own kinds (sorted), limited to the windows the latest fetch returned, so a window the API dropped isn't kept alive by older readings. Names use `ScopedWindow.displayName` while a fetch has it. Colors: a model family keeps a hue next to its fixed window (Opus → indigo, Sonnet → cyan, Haiku → mint); other models get a stable FNV pick from pink, green, brown, lavender (never Claude orange or the alert colors). Coinciding weekly resets of several kinds merge into one "Week reset" rule. Windows other than 5-hour and weekly label their spend "API equiv, all models": the ledger has no per-model Claude Code split per window.
- **Extra usage / spend:** `PlanExtrasCard`, only when the fetch has them: extra usage as a share with On/Off; spend in its own currency (`Format.money`, decimals from the exponent, en_US grouping) with a % only when `percentUsed` exists. It fills the empty grid cell next to an odd window card (stacked), else spans the width. **Discovery:** a quiet, selectable footnote "Anthropic also returned: …" when `unrecognizedKeys` isn't empty.
- **Wiring:** each successful poll → `History.recordModelSamples` (writes chained so counters stay in order, dropped while no ledger is open; the visible Local model page re-reads at most every 30 s). At launch `History.recentModelSamples` (waits for the open, like `recordLimits`) seeds `throughput`: each 60 s bucket's `max` fills both 30 s sparkline bars. New `AppModel.vllmLastSeen`.
- **Cadence:** 5 s while the popover (`NSPopoverDelegate` willShow/didClose) or the Dashboard (show, close, `windowDidChangeOcclusionState`) is on screen, 30 s otherwise; becoming visible polls at once if the last poll is ≥ 4 s old. A running poll is never cancelled (a cancelled fetch would read as offline): a wake-up during one sets a flag and the loop polls again right after. Offline alert: after the first failed poll the loop stays at 5 s until `offlineAlertAfter + 10 s`, so the alert fires 2 min after the first miss (that miss itself can be up to 30 s after the outage began). A URL change resets the watch and polls now.
- **Local model page** (`Dashboard/LocalModelPage.swift`, `DashboardPage.localModel` = "local-model", sidebar between Spending and Limits): live card (name, model · engine · host, Live/Offline/Error chip; Generating tok/s with the sparkline and its 10-minute peak, Prompt tok/s, KV cache with a bar, Requests running/waiting); "Generation speed" (average line plus a band up to each bucket's peak) and "KV cache" charts with `chartXSelection` tooltips; gaps over 2 buckets break the lines. `LocalModelRange` 24 h / 7 d / 30 d → 300 / 1800 / 3600 s points; the daily cards show 7, 7 and 30 days. "Tokens per day" (grouped prompt vs generated bars, unobserved days as a faint band with a tooltip, never zero) and "Saved vs API" (`localModelSpend(split: .source)` through `SpendChart`, total, tokens, calls, "priced at <reference model>", Settings pointer in the tooltip). Empty states: no server (Open Settings → `AppModel.openSettings()` opens the popover on Settings), offline ("Last seen 19:53, 47m ago": this run's last poll, else the end of the latest `model.running` bucket, 60 s over a day then 3600 s over 90 days), History off (one note card). `History.localModel`, `setLocalModelRange`.
- **Shared chart change:** `SpendChart` (and the new daily charts) place weekly date labels counted back from three days before the last day (`SpendChart.labelDays`), so in a half-width card the last label no longer runs off the right edge ("8…"). Overview, Spending and project detail charts now label e.g. 15 / 22 / 29 Oct / 5 Nov instead of 11 / 18 / 25 Oct / 1 / 8 Nov.
- **Panel:** the local model widget is a button to Local model (the "Add server" state stays a plain tile). Settings' model server hint states the new cadence. No new setting keys.
- **Preview:** the served model is `Qwen/Qwen3.8-Flash-Next`, like the ledger's local stream. A new local stream (Claude Code on Qwen, appended last so the other streams keep their numbers) gives the saved chart two sources; local streams skip one day 4 days ago, which is the server-off day in Tokens per day. Saved vs API and Spending's "Ran locally" read the same entries (`costUSD == 0 && apiEquivUSD > 0`). Limits preview adds a "Sonnet 4.5" scoped window at 48% of the week, `extra_usage`, `spend` and two unknown keys (`seven_day_oauth_apps`, `iguana_necktie`).
- **Snapshots** (`build/snapshots/`): `dashboard-local-model-{light,dark}`, `dashboard-local-model-offline-*`, `dashboard-local-model-empty-*` (no server), `dashboard-limits-*` (three windows, extras in the odd cell, footnote), and the panel's ring tick in `panel-full-*`.
- **Tests:** AgentKitTests 179, AgentSystemTests 71 (2 opt-in skips), all green; `swift build` without warnings.
- **Fixed afterwards (main session):**
  - **Counter baselines:** changing the model server URL used to keep the old server's counter baselines, so the new server's first reading could book a bogus increase into today's tokens. Now `AppModel.apply` calls `History.resetModelCounters()` (chained behind pending sample writes) → `Ledger.resetModelCounters()` → `Store.resetCounterBaselines`. That clears the in-memory baseline and skips re-seeding from stored buckets, so the new server's first reading only sets a baseline (`SamplesStoreTests.testResettingABaselineIgnoresTheNewServersFirstReading`).
  - **Remaining edge:** quitting Hoply after a URL change but before the new server's first reading still re-seeds from the old server's last bucket.
  - **Offline alert click:** clicking a local-model-offline notification now opens the Local model page.
  - **Tests:** AgentSystemTests 72.
- **Unverified live** (the user's own `swift run` instance was listening on 4318, so neither `install.sh` nor `simulate.sh` ran):
  - the 5 s / 30 s switch on popover open/close, Dashboard minimize/occlusion, and the offline alert timing under the slow cadence;
  - sample recording and sparkline seeding against the real tensorfold (no `model_name` label, so the identity line reads "tensorfold · 192.168.40.141:8888"); the Local model page on real `samples`, its 30-day hover;
  - scoped windows, extra usage, spend and the footnote against the real `/api/oauth/usage` (the scoped shapes are still unverified in the core); the pace tooltip and ring tick live;
  - light, dark and Reduce Transparency in the live popover and window. A notification click on local-model-offline now opens the Local model page (fixed afterwards, unverified live).

**M4 + M5 review fixes (2026-11-10, uncommitted):** two read-only reviews (core, app target), then fixes. AgentKitTests 182, AgentSystemTests 75 (2 opt-in skips), all green.
- **Core:**
  - Offline alert: a gap over 90 s between consecutive checks (`NotificationPolicy.offlineCheckGap`, e.g. sleep) restarts the offline clock, so one miss before sleep and one after wake no longer alert at once.
  - `Store` sample writes: the aggregator and `seededCounters` are restored only when the seed query or bucket transaction fails. A rollup failure is swallowed and retried on the next write (`lastRollup` is set on success only).
  - `StoreReader.limitSamples(bucket:)` keeps one peak per bucket **and window**, so a reset inside a bucket no longer hides the new window's first readings.
  - `SessionBoard.sweep(now:)` returns `Sweep(changes, dropped)`; `AppModel.tick` withdraws the dropped sessions' notifications. `tick(now:)` still returns the changes.
  - Mutes: a resolved project still matches its root exactly. An **unresolved** cwd is now muted when it equals or lies under a muted root (by path component), which replaces "or cwd while unresolved" in the M4 decisions.
- **App:**
  - Coming on screen under 4 s after a poll restarts the loop's wait at `5 s − elapsed`.
  - A poll that returns after a URL change is dropped (`modelServerEpoch`). `History` repeats an unsettled counter reset when a ledger attaches.
  - Settings Save writes only the fields edited in the draft (`AppSettings.applying(_:since:)`, a JSON diff, so new Codable fields need nothing; a new text-backed field needs a line in `SettingsView.texts`/`rebase`).
  - A minimized Dashboard counts as off screen.
  - "Saved vs API" reads "unpriced" when the reference model has no price.
  - Double→Int on poll values is guarded (`Format.whole`).
  - `Notifier` posts and withdrawals run in call order.
  - One limits fetch at a time; a result that arrives after limits were disabled is dropped (`limitsEpoch`).
- **Left as is:**
  - The per-session 2-minute cooldown survives a withdraw, so a second permission prompt inside it posts nothing (plan rule; user decision).
  - Counters are summed over label sets, so one model unloading on a multi-model server would read as a restart.
  - Quitting after a URL change but before the new server's first reading still re-seeds from the old server's bucket.
- **Unverified live:** all of the app fixes (cadence, mid-poll URL change, miniaturize, notification ordering).

**M5.5 core outcome (2026-11-10, uncommitted):** AgentKit, AgentSystem, tests and scripts. AgentKitTests 213, AgentSystemTests 88 (2 opt-in skips), all green. Nothing ran live.
- **Decisions:**
  - **Input** is `state == .yourTurn` plus `AgentSession.awaitsInput`. **Limited** is never stored: the pure `SessionStatus` / `LimitedSessions` (`AgentKit/SessionStatus.swift`) derive it from the session and the limit samples, so `SessionBoard` still knows nothing about limits. `SessionState` and `NotificationKind` are unchanged.
  - Notifications: `NotificationRequest.cause` (`permission, input, yourTurn, limit, limitReset, localModelOffline`); `kind` stays the click-routing family (input → `.permission`, limitReset → `.limit`). Limit reset is `.active`, and is dropped (not deferred) in quiet hours or with limit alerts off.
  - Recede = limited, idle, ended.
  - Context window: 1M for Fable, Sonnet ≥ 5, Haiku ≥ 5.5, Opus ≥ 4.7 and any `[1m]` name; a prompt over 200k also proves 1M; other Claude models 200k; local and non-Claude models nil.
  - A scoped weekly window limits a session only when its model id contains the family name.
- **API for the UI:**
  - `AgentSession`: `awaitsInput`, `failure` (StopFailure error type), `turnEnded`, `subagents: [LiveSubagent]`, `workingSubagentCount`.
  - `SessionStatus` (`.permission, .input, .limited(until:), .yourTurn, .working, .idle, .ended`; `priority`, `needsAction`, `recedes`, `label`). `SessionGrouping(sessions:projects:limits:localModelPatterns:now:)` sorts waiting by priority and has `.limitedUntil` and `.status(of:)`.
  - `NotificationPolicy.limitedSessionsChecked(_:limits:localModelPatterns:now:)`, called on every tick and after each limits fetch.
  - `Monogram.letters(for:)` / `.paletteIndex(for:count:)`.
  - `GitClient.diffStat(worktree:)` (blocking) and `actor GitStatCache`; they stand alone, so they work with History off.
  - `Ledger`: `lastMainCalls(for:)`, `contextWindows(for:)`, `subagents(of:)`, `subagentCounts(for:)`, `modelEfficiency(in:project:)` (`cacheHitRate`, `usdPerMillionTokens`, `fastCalls`, `fastUSD`, `fastPremiumUSD`), `unpricedModels()`, `pricedModels()`, `updatePricing(…priceAliases:)`.
- **Settings:** `priceAliases: [String: String]`; with none, the `pricing_rev` hash is unchanged.
- **Schema v3:** table `subagents(source, session_id, agent_id, agent_type, description)`. The real data has no `agent-name` lines; names come from `subagents/agent-<id>.meta.json`, read when a subagent file is ingested from offset 0, so already-ingested subagents stay unnamed until Reindex.
- **Hooks:** `install.sh` also installs `Elicitation`, `ElicitationResult`, `SubagentStart`, `SubagentStop`, `StopFailure` (users re-run it); `simulate.sh` plays two subagents and a question.
- **Behaviour changes:**
  - `StopFailure` ends the turn (Your turn). Before, a rate-limited session stayed "working".
  - Hooks fired inside a subagent (`agent_id` present) no longer change the session's cwd or model, or reopen a finished turn.
  - Notifications `elicitation_response`, `elicitation_complete` and `quota_auto_resume_fired` mean working.
  - Advisor iterations become rows keyed `cc:<id>:<req>:advisor:<n>`, left out of the last-main-call query.
- **Unverified:**
  - Hook payload shapes come from the public hooks docs, not captures.
  - Whether `PermissionRequest` fires for `AskUserQuestion` (both paths map to Input).
  - Whether the limits API reports exactly 100 for a full window.
  - `ask_user` as Copilot's question tool name is a guess.
  - Older Claude Code versions may warn about unknown hook names.

**M5.5 UI outcome (2026-11-10, uncommitted):** the Hoply target only. `swift build` warning-free, snapshots render; nothing ran live.
- **Wiring:** `AppModel.limitSamples` feeds `SessionGrouping(…limits:)`; `limitedSessionsChecked` runs on every tick and after each limits fetch; `History.track` takes `[AgentSession]` and refreshes context windows and subagent counts with the session totals; `GitStatCache` refreshes a cwd when a session appears, changes cwd or settles, and forgets it when no live session uses it (`AppModel.gitStats`); a `priceAliases` change calls `Ledger.updatePricing`.
- **Panel rows:** `StatePill` takes a `SessionStatus` and sits in a fixed right column. Permission orange, Input indigo, Limited grey ("Limited · resets 12:36"), Your turn green, Failed red, Working blue with a pulsing dot (off under Reduce Motion), Idle/Ended grey. Receding rows are dimmed to 0.6. Line 2 is "place · age · model". Inline extras: "3 subagents · 2 working", "+120 −34" (or "2 new"), "ctx 86%" from 80%.
- **Counts:** "Need you", the menu bar count and the Waiting chip count only `needsAction` sessions. Limited sessions stay in the Waiting card, dimmed and uncounted.
- **Monograms:** `ProjectIcon` / `MonogramTile` (9 hashed colours keyed on the project root) on panel cards, Projects tiles, project detail and "By project" rows. Home, scratch and Unassigned keep their icons.
- **Open in editor:** `Services/Editor.swift`; a tile on panel cards, a button on project and session detail, a row context-menu entry; right-click lists the other installed editors. Settings → Behaviour "Editor" picker, stored in UserDefaults `HoplyDefaultEditor` (not an `AppSettings` key). Hidden when no editor is installed.
- **Dashboard:** the session detail has a "Context window" card and a "Subagents" card; Spending has "Model efficiency" (cache hit rate, $/Mtok, fast-mode line). Settings → Pricing lists unpriced models with a "Price as" picker.
- **Snapshots:** `panel-full-*`, `panel-settings-full-*`, `panel-settings-pricing-empty-*` (new), `dashboard-sessions-*`, `dashboard-spending-*`, `dashboard-projects-*`, `dashboard-project-detail-*`.
- **Unverified live:**
  - Git stat refresh on real Stop hooks.
  - The Limited status and the limit-reset notification (its click opens Limits, since `kind == .limit`).
  - The pulse and Reduce Motion.
  - Editor bundle ids, which are from memory (e.g. Cursor `com.todesktop.230313mzl4w4u92`).
  - "Price as" inside the popover and the re-price after Save.
  - Insight loading on real ledger data.

**M6 core outcome (2026-11-10, uncommitted):** `AgentKit/Processes/` and `AgentSystem/Processes/`. AgentKitTests 239, AgentSystemTests 99 (3 opt-in skips), all green.
- **API for the UI:** `actor DevServerMonitor`: `refresh(hubPort:sessions:resolveProjects:) -> DevServerScan` (resolver nil with History off), `stop(_:sessions:) -> ProcessTerminator.Outcome` (`.terminated`, `.killed`, `.refused`, `.failed(errno:)`; it rescans and re-decides first), `latest`. `DevServer` carries `id` (`pid:startMicros:port`), `groupKey` (= `ProjectGroup.id`), `frameworkName`, `portLabel`, `memoryLabel`, `displayName`, `url`, `isReachableFromNetwork`, `session` + `sessionMatch` (`.lineage` / `.directory`), `stopRefusal`, `canStop`. `DevServerClassifier.Session(key:pid:cwd:)`: no pid is available today.
- **Classifier rules:**
  - Ports excluded: below 1024, the hub port, a fixed list (databases, brokers, Docker, adb, VNC, Ollama, OTLP 4317, Node inspector), and 49152+ unless a framework is recognised.
  - Processes excluded: Hoply; cwd `/`, missing or under `~/Library`; executables under `/System`, `/usr/libexec`, `/usr/sbin`, `/sbin`, `/Library/Apple`; an executable inside an installed `.app` unless its cwd maps to a repo project or a framework is detected.
  - Listeners on one port that share a group or ancestry collapse into the topmost one; memory sums that tree plus same-group launchers.
  - Session tie: a supplied pid among the ancestors, else an agent process among the ancestors plus a matching session cwd (`.lineage`), else the deepest session cwd containing the server (`.directory`). Only `.lineage` shows on session rows.
  - Stop is refused unless identity (pid + start time) and uid match, the group leader is alive with its cwd inside the project root, and the group holds no Hoply ancestor, agent process or session pid.
- **Deviations:** `GitClient`'s runner moved into an internal `Subprocess` helper shared with lsof. Argv stays in memory; `DevServer` exposes only the process name. Opt-in `HOPLY_REAL_PROCESSES=1 swift test --filter ProcessScannerTests/testRealProcesses`.
- **Live on this Mac:** a scan takes about 30 ms (656 processes, 30 listening ports); the lsof fallback returned the same port set in 60 ms. A throwaway `python3 -m http.server` was found, tied to its session by lineage and stoppable; started as `( … & )` it was refused (`leaderGone`).
- **Unverified:** `npm run dev` and the JS frameworks live (argv shapes only), Copilot CLI and Qwen process names, the lsof path on a real libproc failure, Stop on a real multi-process server.

**M6 UI outcome (2026-11-10, uncommitted):** the Hoply target only. `swift build` warning-free, snapshots render; no real scan or Stop was exercised from the app.
- **Model:** `Models/DevServers.swift` (`@Observable`, `AppModel.devServers`): one loop, 10 s while the panel or Dashboard is on screen, 60 s otherwise; one scan at a time; passes the non-ended sessions (key + cwd) and `history.resolveProjects`, or nil while History isn't ready. `DevServers(live: false)` for previews.
- **Panel:** pills ("Next.js :3000", an orange globe when reachable from the network) in a wrapping row under each project card's header; click opens the URL; context menu Open in Browser, Copy URL, Reveal in Finder, Stop…. A lineage-tied server shows on its session row instead and is not repeated. Servers without a live session's project go in a compact "Dev servers" card under the project cards.
- **Dashboard:** `DashboardPage.devServers` ("dev-servers", after Limits), `Dashboard/DevServersPage.swift`: a card per project, rows with framework, port, URL, memory, folder, tied session and the four actions; empty state, last-scan time, Refresh.
- **Stop:** confirmation is inline (a dialog would close the transient popover), then a spinner, then a rescan. A refusal or failure shows its reason on the row; success shows an 8 s notice. An unstoppable server has a disabled Stop with the reason.
- **Added:** `WorkspaceActions.openInBrowser`, `Components/FlowLayout.swift`. No new setting keys.
- **Fixed afterwards (main session):** a server in a linked worktree outside the repo root was refused (`leaderOutsideProject`); `DevServer.stopRoot` now falls back to the server's own cwd there (`testAServerInALinkedWorktreeOutsideTheRepoRootCanBeStopped`).
- **Known gaps:** the app has no session pids, so two sessions of one agent in one folder tie by `.directory`, not `.lineage`. `DevServer` has no public init; the preview goes through the classifier.
- **Snapshots:** `dashboard-dev-servers-*`, `dashboard-dev-servers-empty-*`, `dashboard-dev-servers-stop-*`, `panel-*`, `panel-full-*`, `panel-dev-servers-stop-*`. The red Stop button renders grey in snapshots.
- **Unverified live:** everything in the app (scan cadence, pills on real servers, Stop on a real `npm run dev`, menus, tooltips).

**Comments (2026-11-10, user):** about 700 comment lines removed from `Sources/` (every `///` doc comment in the core targets, 140 lines in the app target). See the `comments-only-complex` memory; the agent definitions carry the stricter rule.

**T3 Code review (2026-11-09, user asked):** `pingdotgg/t3code` (MIT; read-only clone at `~/Project/t3code`, commit `dc727058`) is an "agent harness control surface": Electron/web/mobile, Tailwind + Base UI. It runs the agents itself through `@anthropic-ai/claude-agent-sdk` and answers permission prompts in the SDK's `canUseTool`. Hoply watches agents passively, so its chat, composer, per-turn diffs, remote/mobile relay, MCP "outside agents" and context handoffs don't transfer. What does transfer:
- **M5.5 Session insight** (new, after M5; the user chose to plan rather than build now):
  - **Context window per session:** the last call's input + cache read + cache write against the model's window (200k, or 1M for `[1m]`/1M models). Gauge in the session detail; the panel row warns from 80%. Pure `ContextWindow` in AgentKit plus a last-call query in `StoreReader`.
  - **Subagent lineage:** "3 subagents · 2 working" on the row, and a list in the session detail with name, model, duration and cost. Data: `usage.agent_id`, `agent-name` lines, subagent transcripts. Check the `SubagentStart`/`SubagentStop` hook payloads first (claude-code-guide).
  - **New states:**
    - **Input:** the agent asked a question (`AskUserQuestion` / elicitation), distinct from Permission. It gets its own notification kind (active).
    - **Limited:** a Claude session that is waiting while a plan window is at 100% shows "Limited · resets 22:07". One notification fires when that window resets.
  - **Live diff stat:** "+120 −34" per live session's worktree from `git diff --shortstat HEAD` plus the untracked file count, refreshed on Stop hooks and cached. Build `GitClient` here; M7 reuses it.
  - **Panel look:**
    - Status priority order: Permission > Input > Limited > Your turn > Working > Idle > Ended.
    - "Recede": dim rows with nothing to act on.
    - A pulsing working dot (`symbolEffect(.pulse)`, off under Reduce Motion).
    - Project monogram tiles with a stable hashed color in place of the generic folder icon.
    - "Open in editor" next to Terminal/Finder (Cursor, VS Code, Zed, JetBrains found by bundle id; default editor setting).
    - Status colors follow T3's meaning where Hoply has the state: amber permission, indigo input, blue working, red failed, green done. Mizu stays the overall look; T3's black, dense Electron styling has no vibrancy and isn't the bar.
  - **Spending:** cache hit rate and $/Mtok per model, plus a fast-mode premium line (`usage.speed`).
  - **Pricing:** Settings lists unpriced models with a "Price as" picker. The alias is stored as an override and re-priced through the existing `pricing_rev` path. Opus 4.5 and Sonnet 4.5 are unpriced today.
  - **Parser:** count advisor `iterations` (`type: "advisor_message"`) as separate rows under their own model, as T3's `Drivers/claudeUsage.ts` does. Real data has 0 of them today (all 12,960 iterations are `type: "message"`), so this is only future-proofing.
- **M4 polish (with the glass pass):** a pace marker on Limits cards and the panel ring: used% − elapsed% of the window, more than +5 is "ahead", under −5 is "under". It works from a single sample, before the burn rate has enough history. Log the live `/api/oauth/usage` keys once, and decode model-scoped weekly windows and extra-usage spend if they're present.
- **Folded into later milestones:**
  - **M5:** sample at a fast cadence only while the panel or Dashboard is visible, slow otherwise; cap history by age and bytes.
  - **M6:** identify a process by pid + start time. Tie listening ports to the agent session whose process tree started them, so the pill sits on the session row as well as the project.
  - **M7:** after a run, a cleanup report of what was removed and what was kept, and why. Orphan worktree folders are listed with their size but never deleted.
  - **M8:** frecency ranking; a `>` prefix shows actions only.
  - **Deferred project merge:** group clones of one repo by git remote, as T3's `RepositoryIdentityResolver` does.
- **Option for later, needs a user decision (it changes Hoply from a monitor to a control surface):** "Approve from Hoply". Answer Claude Code `PermissionRequest` hooks (and Copilot CLI `preToolUse`) from the panel or notification action buttons by holding the hook's HTTP response.
  - It needs a longer curl timeout for that one event (today `-m 2`).
  - On a timeout, or with Hoply not running, Claude falls back to the terminal prompt.
  - Loopback only, and decisions come only from the UI.
  - Opt-in.

**Known issues (deferred bug fixes):**
- **Not glass (user, 2026-11-09, live screenshots):** the panel draws as a flat light-grey popover with white cards, and the Dashboard sidebar/toolbar look like plain opaque chrome, not Liquid Glass. The user said it "doesn't look bad", so it waits; fix it in the M4 polish pass, checking live rather than with `--snapshot` (which can't show glass).

**Copilot CLI facts (checked 2026-11-09, `~/.copilot/session-store.db`, `schema_version` 7):** 8 sessions, 284 `assistant_usage_events` (2026-09-11 → 09-17), 16 turns, 182.66 premium requests. `token_details_json` lists `{tokenType, tokenCount, costPerBatch, batchSize}` per input / cache_read / cache_write / output, where `costPerBatch` is nano-AIU per 1M tokens. **1 AIU = $0.01 at API list price** (Haiku 4.5: 100 / 500 AIU per 1M = $1 / $5), so `total_nano_aiu / 1e11` is Copilot's own API-equivalent USD, ≈ $28.6 in total. `input_tokens` includes cache reads; the `input` detail is the uncached count.

**ZGX facts (checked 2026-11-09 from this Mac):**
- Host `zgx-ff24` is at 192.168.40.141.
- **Model server:** `http://192.168.40.141:8888`, OpenAI API, no auth. The engine is **tensorfold**, not vLLM. Model `Qwen3.8-Flash-Next`, 262k context.
- **Its `/metrics`:** vLLM metric names under a `tensorfold:` prefix, with no `model_name` label. `generation_tokens_total` counts finished requests only; `generation_tokens_running` holds live streams. `VLLMSnapshot` handles both engines.
- **sparkDash** on `:5555` serves GPU, CPU, RAM, storage, network, energy and LLM stats as JSON, e.g. `/api/sparks/zgx-ff24/metrics`, `/gpu-history`, `/llm/daily`, `/api/fleet-energy`.
  - It needs `Authorization: Bearer <token>` (or `?token=`). The token lives in `~/sparkDash/.env` on the ZGX and must go to the Keychain, never into settings or URLs.
  - Its Prometheus `/metrics` and `/history` are off until enabled in sparkDash Settings.
  - sparkDash replaces "install DCGM/node exporter" as the M5 GPU source. M5 builds the Keychain and request plumbing for its Bearer token; M1 later adds the CF Access headers to the same requests.

**Main risks:**
- Swift 6 strict concurrency around the `HubServer` callbacks (M0).
- The ⌥Space restriction.
- Transcript and Copilot schema drift: keep the parsers lenient and version-checked.
- Clean up must never trash unmerged or dirty work.
- Scanning `~/Documents` triggers TCC prompts.
- Which GPU exporter works on the GB10.

**User actions needed:**
- Create the self-signed signing cert (M0).
- Create the Cloudflare service token (M1, now last).
- Optionally enable sparkDash Prometheus/history in its Settings (M5). The DCGM/node exporter is no longer needed.
- Optionally set `cleanupPeriodDays` in `~/.claude/settings.json` to keep transcripts longer.

## Verification

- `swift test` passes after every milestone. New pure logic is covered in `AgentKitTests` with fixtures; DB, tailer, scanner and git are covered in `AgentSystemTests`.
- **M2 acceptance:** a cold start backfills all 122 transcripts with progress shown. Then:
  - For at least 5 sessions, Spending totals match `cost-state.totalCostUSD` within 2%.
  - Re-launching doesn't change any totals (idempotent).
  - A live Claude session's cost updates within about 1 s of each turn (hook `transcript_path` → tail).
- **M3:** Copilot CLI totals match `SELECT SUM(...) FROM assistant_usage_events` in `~/.copilot/session-store.db`.
- **M1:** with the endpoint behind Cloudflare Access, a valid token shows metrics. A wrong token shows "Access rejected", not "No vLLM metrics".
- **UI:** `scripts/install.sh`, then `scripts/simulate.sh` to drive the panel. Check light and dark mode, Reduce Transparency, and Dashboard pages against real data.
- **M6/M7:** run `npm run dev` in a project and see it named under that project, and Stop works. In a temp repo with a merged clean worktree, Clean up proposes it, and a dirty worktree is never proposed. Trashed items can be put back from Finder.
