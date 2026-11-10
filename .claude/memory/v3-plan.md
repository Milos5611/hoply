---
name: v3-plan
description: "Hoply v3 plan — ship it (Developer ID DMG, in-app Connect, Sparkle updates), cover every mainstream model provider, plus the v2 live checks and facts carried over"
metadata:
  node_type: memory
  type: project
  modified: 2026-11-10T17:57:34.902Z
  originSessionId: 0061c9ef-f9fa-450e-b275-f8fe8c24f267
---

# Hoply v3: what has to be done

Status (2026-11-10): **v2 is built and its plan is retired.** Everything up to the release pipeline is committed (`7cd9eb6`). M0 started: its code items are done and uncommitted (tests green: AgentKitTests 353, AgentSystemTests 146, 3 opt-in skipped); its live checks are with the user. **Nothing from M1 on is built yet** except where a line says so. The user joined the Apple Developer Program on 2026-11-10. Update this line as things land.

Suggested order: M0 alongside everything, then M1 → M2 → M3 (testers can install and get updates), then M4.

## M0. Live checks carried over from v2 (user)

The user agreed to all of M0 (2026-11-10).

- **Approve from Hoply:** that the terminal prompt stays answerable while the hook is held (the docs imply it, they don't say it); whether Claude Code kills the hook when the prompt is answered in the terminal (Hoply copes either way); that Deny works, since its JSON shape is inferred from the docs' field table (they only show an allow example). Needs the new PermissionRequest hook from `scripts/install.sh`: on 2026-11-10 the installed hooks in `~/.claude/settings.json` were older and had no `X-Hoply-Approve` command, so `install.sh` has to run again first.
- **Model servers:** only vLLM and tensorfold rest on real captures. llama.cpp, SGLang and TGI metric names, the Ollama and LM Studio shapes, and Cloudflare Access responses are from memory (fixtures marked synthetic).
- **Deferred items:** `X-Hoply-Pid` validation on a real hook; Resume for Copilot CLI and Qwen Code (`qwen --resume <id>`), neither run here; the Qwen `user_prompt` log shape (no fixture). Copilot CLI 1.0.83's `--help` lists `-r, --resume[=value]` (an optional value), so `ResumeScript` now passes `--resume=<id>` as one argument (done 2026-11-10); `--session-id <id>` also exists but starts a new session when the id is unknown. Qwen Code is not installed on the user's Mac, so its two checks need it installed first.
- **This session's UI:** menu bar mark size next to the system icons (14 pt glyph; tweak `insetBy` in `HoplyMark.statusBarImage` if off); app icon in Finder, Dock and notifications after `install.sh`; instant tooltips above the popover and in the Dashboard; Settings text fields saving on Return, leaving the field, and closing Settings or the panel.
- **Small decisions:** `NotificationPolicy.localModelChecked` is deleted; its tests call `modelServerChecked` with the `default` server (done 2026-11-10). The old sparkDash Keychain item (`com.coolcraftcoders.hoply.sparkdash`) stays until the user deletes it by hand.

## M1. Connect agents from the app (Settings → Agents)

Why: someone who installs the DMG has no checkout, so `scripts/install.sh` can't connect their agents. The user agreed to the design on 2026-11-10.

Status: **core built** (2026-11-10, uncommitted; AgentKitTests 369, AgentSystemTests 162): AgentKit `Connect/`, AgentSystem `AgentConnector` + `ConnectCommand`, the CLI in `HoplyApp.init()`, `install.sh` without jq (output checked against the old jq code on scratch copies: Copilot file byte-identical, Claude settings same content). CLAUDE.md and README updated. Deviations: a hand-written sorted-key JSON writer instead of `JSONSerialization` (which prints `0.1` as `0.10000000000000001`); the CLI also reads the app's saved folders (env, then setting, then default); disconnect also strips an old port's env. Known gap: `ClaudeTranscriptIngester.defaultConfigDirectory` ignores `$CLAUDE_CONFIG_DIR`, the connector honours it, so with that variable set the ledger and the connector can point at different folders. **UI built** (2026-11-10, uncommitted): `Models/AgentConnections`, `Panel/AgentSettings` (first Settings card), `AgentNudgeCard` below "Waiting on you", install.sh hints replaced, snapshot variants. Its nudge dismissal survives relaunch (UserDefaults `HoplyAgentsNudgeDismissed`, reset by any status change); the user may prefer in-memory. **Left for the user:** click Connect / Update / Disconnect in the real app (never clicked against real files; the core has tests) and check that the bundle binary's `--connect` shows no Dock icon flash. Then M1 is done.

The design as agreed:

- **One implementation, in Swift.** Pure parts in AgentKit (`Connect/`): the event lists, the two Claude Code hook commands (generic: `curl -s -m 2 -o /dev/null …`, timeout 5; PermissionRequest: `curl -sf -m 590 -H 'X-Hoply-Approve: 1' …`, timeout 600), the OTel log env, the Copilot CLI hooks file, and a status per agent: connected / outdated (port or commands changed) / not connected. File I/O in AgentSystem (`AgentConnector`): back up `settings.json` first, refuse invalid JSON, write atomically, keep the user's own hooks and env, Copilot disconnect renames `hooks/hoply.json` instead of deleting it.
- **CLI mode** `Hoply --connect claude-code copilot-cli` / `--disconnect …`, handled before the UI starts (like `--snapshot`). `install.sh` calls it instead of its jq code, so jq is no longer needed and the script and app can't drift. It honours `CLAUDE_CONFIG_DIR`, `COPILOT_HOME`, `HOPLY_PORT`.
- **UI:** an Agents card at the top of Settings (status, Connect / Update / Disconnect, "restart running sessions"); a panel nudge when nothing is connected; the "Approve from Hoply" hint points there instead of at `install.sh`. A port change turns the status to Update.
- `JSONSerialization` loses key order, so `settings.json` is written with sorted keys; the backup keeps the original.
- CLAUDE.md: the "`~/.claude` and `~/.copilot` are read-only" rule gets this second exception.
- Tests: transforms with the user's own hooks and env present, connect → disconnect restores the file, status cases, CLI against temp dirs.

## M2. Sparkle auto-updates

- **First package dependency** (user approved, 2026-11-10): `https://github.com/sparkle-project/Sparkle` 2.x through SwiftPM, linked into the Hoply target only. CLAUDE.md's "no package dependencies" line changes.
- **Bundle:** copy `Sparkle.framework` from the resolved SPM artifact (`ditto`, keeps the version symlinks) into `Contents/Frameworks`; rpath `@executable_path/../Frameworks`; sign nested code inside out as Sparkle's docs describe (Installer.xpc, Downloader.xpc with its entitlements preserved, Autoupdate, Updater.app, the framework, then the app), never `--deep`. Check every path against the resolved artifact first. `swift run` must still find the framework.
- **Keys:** Sparkle's `generate_keys` (user runs it once; the private key lives in their login Keychain; export it with `-x` for the secret `SPARKLE_PRIVATE_KEY`; the public key goes to `SPARKLE_PUBLIC_KEY`).
- **Only release builds update:** `package.sh` writes `SUFeedURL` and `SUPublicEDKey` into the bundle's Info.plist; `install.sh` and `swift run` builds never self-update. The updater starts only in a bundled app with both keys present.
- **Appcast:** `package.sh` signs the DMG with `sign_update` and writes a one-item `appcast.xml` (`sparkle:version` = build number = commit count, short version, `minimumSystemVersion` 26.0, release-notes link). The workflow uploads it with the DMG; feed URL `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`, which needs public release assets (a private repo needs another public host).
- **App:** "Check for Updates…" in the status item menu and in Settings, an automatic-check switch. Hoply is an accessory app, so use Sparkle's gentle reminders: an update found in the background shows as a row in the panel footer instead of a window stealing focus.

## M3. First release to testers

- **Built, uncommitted:** `scripts/build-app.sh` (shared by `install.sh` and `package.sh`), `scripts/package.sh` (universal DMG; Developer ID + hardened runtime + notarize + staple when credentials are set), `.github/workflows/release.yml` (tag `v*` → test, package, publish a GitHub Release; manual run → artifact only). README → Releasing has the steps. A local ad-hoc run produced a universal DMG with the icon.
- **User:** Developer ID Application certificate exported as `.p12`; App Store Connect API key (`.p8`, Key ID, Issuer ID); the repo secrets `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `KEYCHAIN_PASSWORD`, `NOTARY_KEY_P8_BASE64`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` (plus Sparkle's two after M2); commit, push, `git tag v0.1.0`.
- **Unverified until the first CI run:** the `macos-26` runner label and its Xcode; signing and notarization on the runner; `spctl` on the stapled DMG.
- A private repo hides the release page from testers (send the DMG instead) and bills macOS minutes at a higher rate.
- **Mac App Store: not viable, decided 2026-11-10.** It requires the App Sandbox, which breaks reading `~/.claude` / `~/.copilot` without user-picked folders, writing agent hooks, scanning and signalling other processes (dev servers, orphans), reading Claude Code's Keychain item through `security`, and running git in the user's repos; it also forbids Sparkle. Only a reduced edition could be sandboxed; revisit only if the user asks for one.
- **More apps later:** once a second app exists, move signing, notarization and the appcast into a reusable workflow, and consider fastlane `match` for shared certificates. Not before (decided 2026-11-10: fastlane adds Ruby for no gain on a SwiftPM-only app).

## M4. Every mainstream model provider (user, 2026-11-10)

The user wants Hoply to cover all mainstream model providers, not only Claude Code, Copilot and local models. Nothing here is researched yet; every format must come from docs or captures, never memory.

- **Research first, one table:** source → how Hoply can capture it (hooks, OpenTelemetry, local logs or database, provider API) → session id, cwd, model, tokens, cost → verified or not. Candidates:
  - Agent CLIs and editors: OpenAI Codex CLI, Google Gemini CLI, Cursor, Windsurf, Cline / Roo Code, Aider, opencode, Amp, Kiro, JetBrains AI Assistant / Junie; Qwen Code and Copilot are already in.
  - Provider accounts (usage, spend, limits per API key or organisation): Anthropic API (Console / Admin API), OpenAI, Google Gemini / Vertex AI, xAI, Mistral, DeepSeek, OpenRouter, AWS Bedrock, Azure OpenAI. Which have a usage or cost endpoint, and which credential (admin key, org id) it needs; credentials live in the Keychain like model-server secrets.
  - Subscription limits like Claude's plan windows (ChatGPT plans for Codex, Gemini plans, Cursor): what is readable, and how.
- **Pricing:** prices for every provider's models from an authoritative source (provider pricing pages, or a maintained machine-readable list that is reviewed before use); keep "unpriced, never $0"; use native costs where a source reports them, as with Copilot's AIU.
- **Architecture:** `AgentSource` is a closed enum (`claudeCode`, `copilotCLI`, `copilotIDE`, `qwenCode`). Make a new source cheap to add: one descriptor per source (name, colour, badge, ledger authority, hook / telemetry mapping, resume command, connect support in M1's connector), with `UsageAuthority`, `TelemetryMapper.source(of:)` and `HookMapper` table-driven. Provider-account usage is a new ingest path next to transcripts, the Copilot store and OTel.
- **UI:** source and provider filters on the Dashboard pages, a card per provider account on Limits, per-provider spend on Spending, badges in the panel.
- **Order:** the research table, then one CLI end to end (pick the best-documented one from the table), then provider usage APIs, then the rest.

## Housekeeping

- The user commits the working tree; nothing is committed on their behalf.
- The leftover agent worktrees and their branches are gone (checked 2026-11-10: only `main` is left).
- Optional: rename `Sources/AgentKit/VLLM.swift` (now only the Prometheus parser) to `PrometheusParser.swift`.
- Out of scope: WidgetKit widgets (SwiftPM can't build the extension target).
- Left as is by decision (v2): the 2-minute per-session notification cooldown survives a withdraw; model-server counters are summed over label sets; squash-merged worktree branches count as unmerged and are kept; model servers leave out self-signed TLS trust, mDNS discovery, per-server poll intervals and pruning orphaned Keychain items.

## Facts worth keeping

**ZGX (checked 2026-11-09):** host `zgx-ff24`, 192.168.40.141. Model server `http://192.168.40.141:8888`, OpenAI API, no auth. Engine **tensorfold** (vLLM metric names under a `tensorfold:` prefix, no `model_name` label), model `Qwen3.8-Flash-Next`, 262k context. `generation_tokens_total` counts finished requests only; `generation_tokens_running` holds live streams. sparkDash on `:5555` (GPU and energy) is no longer used.

**Copilot CLI (checked 2026-11-09, `schema_version` 7):** `token_details_json` lists `{tokenType, tokenCount, costPerBatch, batchSize}`; **1 AIU = $0.01 at API list price**, so `total_nano_aiu / 1e11` is USD. `input_tokens` = input + cache read + cache write. Copilot's own SQLite removes `-wal`/`-shm` on a clean close, and macOS's SQLite then refuses `mode=ro`. Hooks (GitHub's CLI hooks reference, read 2026-11-10): `permissionRequest` runs before rule checks, session approvals and the user prompt; output `behavior` allow/deny, `message`, `interrupt`; empty output or `{}` falls through; `timeoutSec` defaults to 30 and timeouts fail open.

**Claude Code:** transcripts are deleted after about 30 days by default (`cleanupPeriodDays` keeps them longer), so Hoply's DB is the long-term history and never drops usage rows. Its `cost-state` totals include calls never written to the transcript, so ledger totals run a few percent below it. `claude --help` lists `-r, --resume [value]`. Hooks (code.claude.com/docs/en/hooks, read 2026-11-10): PermissionRequest gets `tool_name`, `tool_input`, `permission_suggestions`; allow is `hookSpecificOutput.decision.behavior: "allow"`; deny adds `message` and `interrupt`; exit code 2 is not honoured for it; command hooks time out after 600 s by default; the `permission_prompt` notification fires only when a prompt waited about 6 s unanswered; AskUserQuestion and ExitPlanMode need `updatedInput`, so a bare allow doesn't answer them.

**Distribution (2026-11-10):** Developer ID signing needs the hardened runtime and a secure timestamp for notarization; `notarytool` takes an App Store Connect API key (`--key`, `--key-id`, `--issuer`); staple the DMG. Hoply uses no Apple Events and no JIT, so it needs no entitlements. `swift build --arch arm64 --arch x86_64` works here (about 70 s) and lands in `.build/out/Products/Release`. `hdiutil create` prints a deprecation notice in favour of `diskutil image create from` but still works; `diskutil image` may be missing on macOS 26 runners.

**Pricing:** seed prices come from the `claude-api` skill's pricing reference, not from memory. Opus 4.5 and Sonnet 4.5 are unpriced (use "Price as" or `pricing.json`). Fast-mode cache prices are scaled by the fast/standard ratio (assumption).

**Unverified assumptions in the core:** hook payload shapes for the M5.5 hooks come from the public docs, not captures; whether `PermissionRequest` fires for `AskUserQuestion`; whether the limits API reports exactly 100 for a full window; `ask_user` as Copilot's question tool name.

**Toolchain:** Xcode 27.2 and Swift 6.4.2 on the user's Mac; the package targets macOS 26 with tools 6.2. `context7` needs `npx`, which isn't on PATH here.

**Verification tools:** `--snapshot` can't show glass or vibrancy, and this terminal has no Screen Recording permission, so anything about materials or the real menu bar needs the user's eyes.
