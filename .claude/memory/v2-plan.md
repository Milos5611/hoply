---
name: v2-plan
description: "AgentBar v2 plan drafted 2026-11-09 (not yet approved) — Liquid Glass panel + Dashboard window, SQLite usage ledger (one source of truth per agent), Claude/Copilot backfill, Cloudflare Access, GPU, dev servers, clean up, palette; milestones M0–M8"
metadata:
  node_type: memory
  type: project
  originSessionId: 65b7a48e-4bed-4913-a456-69fcc04298ea
  modified: 2026-11-09T14:02:01.000Z
---

# AgentBar v2: history, spending, projects, and a Mizu-quality UI

Status (2026-11-09): plan drafted, not yet approved by the user; implementation not started. Work milestone by milestone (M0 first) and update this status line as milestones land.

## Context

Today AgentBar only shows live status. `SessionBoard` lives in memory, so there is no persistence, no history, no per-project view and no spending over time. The UI is plain cards (`Sources/AgentBar/Views.swift`, 613 lines).

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
- **Qwen Code and Copilot JetBrains:** no local history. The only data is the OTel that reaches AgentBar, so we must persist it ourselves.
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
- **`AgentBar`** (UI) is organized into folders:
  - `App/`: `AppModel` moves to `@Observable`, plus `AppSettings` and `DashboardWindowController`.
  - `Models/`: LiveSessions, History, LocalModel, Limits, DevServers, Cleanup.
  - `Services/`: Notifier, HotKey, Trash, TerminalLauncher.
  - `Panel/`, `Dashboard/`, `Palette/`.
  - `Components/`: the existing `Card`, `Meter`, `SourceBadge`, `StatePill`, `Metric`, `Hint`, `LabeledRow` and `Format`, moved unchanged from `Views.swift`/`Formatting.swift`.
- **Tests:** `AgentKitTests` (pure, fixtures) and a new `AgentSystemTests` (temp directories, in-memory DB).

### Persistence

The DB is `~/Library/Application Support/AgentBar/agentbar.sqlite`, opened with WAL, `synchronous=NORMAL` and `busy_timeout=2000`. Versions are tracked in `PRAGMA user_version`, with an array of migration SQL applied in transactions. Before each migration and once a week, run `VACUUM INTO …bak` (keep 2).

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
  - The project comes from the `agentbar.cwd` resource attribute, which `setup-qwen-code.sh --add-alias` exports through `OTEL_RESOURCE_ATTRIBUTES`. The fallback is `process.pid` → cwd via libproc. Otherwise the session goes under "Unassigned", with a manual Assign action.
- **Projects:** `ProjectResolver` is pure and doesn't run git.
  - It walks up from the cwd's realpath looking for `.git`.
  - A `.git` file means a worktree: `gitdir` plus `commondir` lead to the main repo, which becomes the project, and the worktree is recorded.
  - If no repo is found it uses `folder`; `$HOME` becomes `home` and the Claude scratch workspace becomes `scratch`.
  - Results are cached in `ProjectRegistry` and in `path_map`.

### Pricing and "spending"

- **Bundled table:** `BundledPricing` is a Swift string literal, because `make-app.sh` copies only the binary, so a resource bundle would be missing. Per model: input, output, cacheWrite5m (default 1.25×), cacheWrite1h (2×), cacheRead (0.1×), optional long-context tiers and fast-mode prices.
- **Model matching:** exact first, then with date, `[1m]` and `anthropic.` prefixes stripped, then by prefix.
- **Overrides:** `~/Library/Application Support/AgentBar/pricing.json`.
- **Seed and calibration:** take seed prices from the `claude-api` skill's pricing reference, not from memory. Calibrate against `cost-state`: Settings → Pricing flags any model that is off by more than 2% from Claude Code's own `totalCostUSD`. An unknown non-local model shows as "unpriced", never as $0.
- **Meaning per source:**
  - **Claude:** "API-equivalent $", since the user is on a subscription. It is shown next to 5-hour and weekly limit usage.
  - **Copilot:** AIU and premium requests, with a monthly allowance setting and an optional $ per premium request.
  - **Local (Qwen/vLLM):** $0. `api_equiv_usd` is priced at a reference model, so the UI can show "saved vs API". Optional energy cost = GPU energy × $/kWh.

## Features

- **Cloudflare Access (M1):**
  - `EndpointConfig {baseURL, name, accessClientID}` is used for both the vLLM and the GPU exporter.
  - The secret is a SecItem generic password stored under service `…agentbar.cf-access`.
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
| **M0 Foundation** | tools 6.2 / macOS 26 / Swift 6; `AgentSystem` target; `Views.swift` split into folders with no behavior change; `@Observable` AppModel; **tolerant `AppSettings` decoding** (`decodeIfPresent`; today any new field silently resets settings); `AGENTBAR_SIGN_IDENTITY` in `make-app.sh` (a stable self-signed cert stops Keychain/TCC re-prompts after each ad-hoc rebuild); spikes for the hotkey and the glass MenuBarExtra | old settings JSON still decodes; existing 40 tests green |
| **M1 Cloudflare Access** | endpoint settings, Keychain, CF headers, error classification, Test button. Ships early so the tunnel move doesn't break the vLLM card | `RemoteEndpointTests` (headers, 302/403/HTML) |
| **M2 Store + Claude history** | SQLite + migrations, ProjectResolver, transcript backfill and tailing, pricing; ledger cost per session in the panel; Dashboard with Overview, Sessions, Spending | `ClaudeTranscriptParserTests` (stripped real lines: repeated blocks, sidechain, `<synthetic>`, Qwen model, title, cost-state, partial last line); `PricingTests` with **cost-state calibration**; `ProjectResolverTests` (temp repo + worktree); ingesting twice gives the same totals; tailer append/truncate/rotate; migrations |
| **M3 Copilot + OTel persistence + Projects** | CopilotStoreIngester, UsageAuthority filter, OTel IDs, Projects page and project grouping | `CopilotUsageMapperTests`; a temp DB built with the Copilot schema; OTel JSON/protobuf ID parity; `UsageAuthorityTests` |
| **M4 Panel redesign + notifications + Limits** | 448×600 glass panel, waiting-first, widgets, `NotificationPolicy`, `limit_samples`, Limits page | `NotificationPolicyTests`, `LimitsProjectionTests` |
| **M5 Local model + GPU** | `SampleAggregator` with rollups, GPU parsing, Local model page, saved vs API, energy | `SampleAggregatorTests` (counter reset), `GPUSnapshotTests` (captured ZGX `/metrics`) |
| **M6 Dev servers** | scanner, classifier, panel pills, Dev servers page, Stop | `DevServerClassifierTests`, `LsofParserTests`; integration test opening a listening socket in-process |
| **M7 Clean up** | worktrees, caches, transcripts, orphans; review sheet; Trash + log | `CleanupRulesTests`, `ProcessLineageTests`, `GitClientTests` (temp repo with a merged worktree) |
| **M8 Palette** | NSPanel, providers, fuzzy ranking, Resume | `FuzzyMatcherTests` |

**Keep in sync along the way:**
- `simulate.sh`: send `transcript_path` and Qwen resource attributes.
- `setup-qwen-code.sh --add-alias`.
- `setup-claude-code.sh`: OTel becomes optional.
- `CLAUDE.md` and `README.md`: the new targets and the ledger rule.
- Fixtures are stripped to the needed keys, with no prompt or response content.

**Main risks:**
- Swift 6 strict concurrency around the `HubServer` callbacks (M0).
- The ⌥Space restriction.
- Transcript and Copilot schema drift: keep the parsers lenient and version-checked.
- Clean up must never trash unmerged or dirty work.
- Scanning `~/Documents` triggers TCC prompts.
- Which GPU exporter works on the GB10.

**User actions needed:**
- Create the self-signed signing cert (M0).
- Create the Cloudflare service token (M1).
- Install a DCGM or node exporter on the ZGX (M5).
- Optionally set `cleanupPeriodDays` in `~/.claude/settings.json` to keep transcripts longer.

## Verification

- `swift test` passes after every milestone. New pure logic is covered in `AgentKitTests` with fixtures; DB, tailer, scanner and git are covered in `AgentSystemTests`.
- **M2 acceptance:** a cold start backfills all 122 transcripts with progress shown. Then:
  - For at least 5 sessions, Spending totals match `cost-state.totalCostUSD` within 2%.
  - Re-launching doesn't change any totals (idempotent).
  - A live Claude session's cost updates within about 1 s of each turn (hook `transcript_path` → tail).
- **M3:** Copilot CLI totals match `SELECT SUM(...) FROM assistant_usage_events` in `~/.copilot/session-store.db`.
- **M1:** with the endpoint behind Cloudflare Access, a valid token shows metrics. A wrong token shows "Access rejected", not "No vLLM metrics".
- **UI:** `scripts/make-app.sh --install`, then `scripts/simulate.sh` to drive the panel. Check light and dark mode, Reduce Transparency, and Dashboard pages against real data.
- **M6/M7:** run `npm run dev` in a project and see it named under that project, and Stop works. In a temp repo with a merged clean worktree, Clean up proposes it, and a dirty worktree is never proposed. Trashed items can be put back from Finder.
