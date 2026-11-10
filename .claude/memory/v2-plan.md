---
name: v2-plan
description: "Hoply v2 plan — M0, M2–M8 and the glass pass are committed and checked live; in progress: Model servers (replaces M1 Cloudflare Access; multi-server, engines, auth) and the deferred items; GPU stats dropped; plus ZGX/Copilot facts"
metadata:
  node_type: memory
  type: project
  originSessionId: 65b7a48e-4bed-4913-a456-69fcc04298ea
  modified: 2026-11-10T12:30:00.000Z
---

# Hoply v2: what is left

Status (2026-11-10): **M0, M0.5, M2–M8 and the glass pass are built and committed** (`b530aff`); the user checked them live and they are OK. The architecture and rules are in `CLAUDE.md`; the per-milestone outcomes are in this file's git history up to `b530aff`. **In progress (uncommitted):** Model servers (replaces M1) and the deferred items: both cores are built and merged in the working tree (AgentKitTests 343, AgentSystemTests 151, green); their UI halves are being built. **Dropped by the user:** GPU stats / sparkDash, and M1 as a Cloudflare-only milestone. Update this status line as things land.

## 1. Model servers (replaces M1 Cloudflare Access; user, 2026-11-10)

The user wants adding a local model to be dynamic and configurable for other people's setups, local or remote.

- **Core (built, uncommitted):** `AppSettings.modelServers: [ModelServer]` (id, name, base URL, enabled, engine or auto, metrics path override, auth, offline-alert switch). The old `vllmBaseURL`/`vllmName` migrate into a server with id `default`, which keeps the un-keyed `model.*` sample series; the legacy keys are decoded only when `modelServers` is absent and no longer encoded. Engines: vLLM, tensorfold, llama.cpp, SGLang, TGI (Prometheus) and Ollama, LM Studio, any OpenAI-compatible server (model lists). Auth: none, Bearer, Basic, Cloudflare Access service token, custom headers on top of any kind; one Keychain item per server (service `com.coolcraftcoders.hoply.model-server`, account = server id). `ModelServerClient` (AgentSystem): `poll`, `probe` (Test connection), `discover` (loopback ports, on click only). Status carries a capability set so the UI hides what an engine doesn't report. Samples, counter baselines and offline alerts are per server id. Served models are never treated as local automatically (a proxy can list cloud models); `PricingTable.treatingAsLocal` and the exact pattern form `=<id>` back a per-model toggle. Offline = unreachable only (transport, 502–504); a 401, a blocked plain-http load or a wrong URL is "blocked" and never starts an outage alert.
- **Verified vs not:** only vLLM and tensorfold rest on real captures. llama.cpp, SGLang, TGI metric names, the Ollama / LM Studio shapes and the Cloudflare Access responses are from memory (fixtures are marked synthetic). The ZGX did not answer during the work.
- **App Transport Security (measured):** `NSAllowsLocalNetworking` allows plain http to loopback, private ranges, single-label names and `*.local`. Tailscale (`100.64.0.0/10`, `*.ts.net`) and `*.lan`, `*.home.arpa`, `*.internal` need plist exceptions (UI half adds them). Public hosts are https-only.
- **UI (in progress):** per-server polling in the app, Settings server list and editor with Test connection and "Find servers on this Mac", multi-server panel widget, capability-driven Local model page, plist exceptions, snapshots.
- **Left out on purpose:** self-signed TLS trust, mDNS / LAN discovery, per-server poll intervals, pruning orphaned Keychain items.
- **Dead code left in place** (GPU dropped): `sparkDashURL`, `sparkDashName`, `energyPricePerKWh`, the `SparkDash` enum, `MetricsClient` (its `RedirectRefusal` is reused), `KeychainService.sparkDash`. Also to remove once the UI no longer calls them: `vllmBaseURL`/`vllmName` accessors, `VLLMStatus`, the un-keyed sample reads. The user decides whether to delete.

## 2. Deferred items (user asked for them, 2026-11-10)

- **Core (built, uncommitted), schema v4** (`projects.merged_into`, `sessions.project_origin`, `session_prompts`, `dismissed_suggestions`, an index on open `state_spans`):
  - Manual project assign / merge / session assign with undo (`Ledger+Projects`); user rules beat automatic resolution, also after Reindex. Undo re-derives from each session's cwd, so it is approximate for sessions that moved between folders.
  - Merge suggestions for clones sharing a git `origin` (never automatic; dismissals persist).
  - Resume for Copilot CLI (`copilot --resume <id>`, GitHub docs) and Qwen Code (`qwen --resume <id>`, third-party doc mirrors); neither run here.
  - Qwen turn counts from `user_prompt` logs (`HubServer.onPrompts`; the log shape is assumed, no fixture has one).
  - Session pids: hooks send `X-Hoply-Pid: $PPID`, validated on each scan (exists, our uid, started before the report, it or an ancestor looks like the agent). Needs a re-run of `scripts/install.sh`. Unverified on a real hook. Once a session has a pid, a server started by hand in its folder no longer ties to it by directory.
  - `state_spans`: written on each real state change, 30-day retention, leftovers closed at Store open.
  - `ResumeScript.staleFileNames` (7 days) for pruning.
- **UI (pending):** `onPrompts` and state-span wiring in `AppModel`/`History`, Projects assign / merge / suggestions UI, the session-detail timeline, Resume folder pruning, clipping tables to card corners.
- **Left as is by decision:** the 2-minute per-session notification cooldown survives a withdraw; model-server counters are summed over label sets; squash-merged worktree branches count as unmerged and are kept.

## 3. Needs a user decision

- **"Approve from Hoply":** Allow / Deny buttons in the panel and on the notification for an agent's permission prompt, by holding the hook's HTTP response. It turns Hoply from a monitor into a control surface. Needs a longer curl timeout for that event (today `-m 2`), falls back to the terminal prompt on timeout, loopback only, opt-in.
- **Out of scope:** WidgetKit widgets (SwiftPM can't build the extension target).

## Facts worth keeping

**ZGX (checked 2026-11-09):** host `zgx-ff24`, 192.168.40.141.
- Model server `http://192.168.40.141:8888`, OpenAI API, no auth. Engine **tensorfold** (vLLM metric names under a `tensorfold:` prefix, no `model_name` label), model `Qwen3.8-Flash-Next`, 262k context. `generation_tokens_total` counts finished requests only; `generation_tokens_running` holds live streams.
- sparkDash on `:5555` serves GPU and energy stats; GPU stats were dropped by the user (2026-11-10).

**Copilot CLI (checked 2026-11-09, `schema_version` 7):** `token_details_json` lists `{tokenType, tokenCount, costPerBatch, batchSize}`; **1 AIU = $0.01 at API list price**, so `total_nano_aiu / 1e11` is USD. `input_tokens` = input + cache read + cache write. Copilot's own SQLite removes `-wal`/`-shm` on a clean close, and macOS's SQLite then refuses `mode=ro`.

**Claude Code:** transcripts are deleted after about 30 days by default (`cleanupPeriodDays` in `~/.claude/settings.json` keeps them longer), so Hoply's DB is the long-term history and never drops usage rows. Its `cost-state` totals include calls never written to the transcript, so ledger totals run a few percent below it. `claude --help` lists `-r, --resume [value]`.

**Pricing:** seed prices come from the `claude-api` skill's pricing reference, not from memory. Opus 4.5 and Sonnet 4.5 are unpriced (use "Price as" or `pricing.json`). Fast-mode cache prices are scaled by the fast/standard ratio (assumption).

**Unverified assumptions in the core:** hook payload shapes for the M5.5 hooks come from the public docs, not captures; whether `PermissionRequest` fires for `AskUserQuestion`; whether the limits API reports exactly 100 for a full window; `ask_user` as Copilot's question tool name.

**Verification tools:** `--snapshot` can't show glass or vibrancy, and this terminal has no Screen Recording permission, so anything about materials needs the user's eyes or a view-hierarchy dump from a temporary in-process self-test.
