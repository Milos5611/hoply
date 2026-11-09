---
name: v2-plan
description: "Hoply v2 plan (approved 2026-11-09) — Liquid Glass panel + Dashboard window, SQLite usage ledger (one source of truth per agent), Claude/Copilot backfill, Cloudflare Access, GPU, dev servers, clean up, palette; milestones M0–M8"
metadata:
  node_type: memory
  type: project
  originSessionId: 65b7a48e-4bed-4913-a456-69fcc04298ea
  modified: 2026-11-09T16:56:16.264Z
---

# Hoply v2: history, spending, projects, and a Mizu-quality UI

Status (2026-11-09): plan approved by the user. **M0**, **M0.5 panel look** and **M2** are done and committed (user live check of M2 passed on real data; glass look deferred, see "Known issues"). **M3** is done (core + UI, uncommitted until the user reviews it). **Next: M4.** **Build order (user, 2026-11-09): M2 → M3 → M4 → M5 → M6 → M7 → M8 → M1.** Cloudflare Access moved to the end; IDs kept so references stay valid. Work milestone by milestone and update this status line as milestones land.

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
