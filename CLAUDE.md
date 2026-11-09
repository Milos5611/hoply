# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

AgentBar is a macOS 14+ menu bar app (SwiftPM, Swift 5.10, no package dependencies). It contains its own HTTP listener on `127.0.0.1:4318`, which receives hook calls and OTLP exports from AI coding agents (Claude Code, Copilot CLI, Copilot in JetBrains, Qwen Code). It also polls a vLLM server's Prometheus `/metrics` and Claude's plan-usage endpoint.

## Roadmap

The v2 plan is in `.claude/memory/v2-plan.md`: decisions, schema, ingestion rules and milestones M0–M8. Read it before working on v2 features, stay inside the milestone at hand, and update its status line as milestones land.

## Commands

```bash
swift build
swift test                                                    # all tests (AgentKit only)
swift test --filter SessionBoardTests                         # one test class
swift test --filter SessionBoardTests/testClaudeLifecycle     # one test
swift run AgentBar                                            # run unbundled; icon appears in the menu bar
scripts/simulate.sh                                           # with the app running: post fake hook/OTLP traffic (DELAY=0 for no pauses)
scripts/make-app.sh [--install]                               # release build, ad-hoc signed build/AgentBar.app; --install copies to ~/Applications and launches
curl -s http://127.0.0.1:4318/health
```

Notifications and "Launch at login" only work in the bundled `.app` (`AppModel.isBundledApp`), not under `swift run`.

## Architecture

Two targets:

- **`AgentKit`**: platform-neutral core: HTTP parsing, routing, OTLP decoding, event mapping, the session state machine, Prometheus/vLLM, Claude limits. It has no UI and is the only target with tests. `HubServer` is wrapped in `#if canImport(Network)`.
- **`AgentBar`**: the SwiftUI `MenuBarExtra` app. `AppModel` (`@MainActor`) owns everything; `Views.swift` holds all UI.

### Request → panel data flow

1. `HubServer`: an `NWListener` restricted to the loopback interface; it also rejects non-loopback peers. It buffers bytes until `HTTPRequestParser` (Content-Length and chunked, handles `Expect: 100-continue`) returns a complete request. Each connection serves one request, then closes.
2. `HubRouter.handle` is pure: request in, `Outcome` (response + `[AgentEvent]` + optional note) out.
   - `POST /v1/logs|traces` → `OTLPDecoder` (JSON or protobuf, sniffed when Content-Type is missing) → flat `[TelemetryRecord]` → `TelemetryMapper` → events. `/v1/metrics` is accepted and ignored. Compressed bodies get 415; gRPC is not supported.
   - `POST /hooks/<source>[/<event>]` → `HookMapper`. Claude Code sends `hook_event_name` in the body. Copilot CLI payloads have no event name, so its setup script puts the event in the URL path. The path name wins.
3. `HubServer` callbacks (`onEvents`, `onStatus`, `onNote`) fire on a private dispatch queue. `AppModel` hops to the main actor and feeds events to `SessionBoard`.
4. `SessionBoard` (a pure value type) applies each `AgentEvent` to an `AgentSession` keyed by `(AgentSource, sessionID)` and returns a `StateChange`. `AppModel.shouldNotify` decides on macOS notifications from that change.

`AgentEvent` is the normalization boundary. Every source, whether hook or telemetry, maps into its `Kind` cases. `SessionBoard` never sees raw payloads.

### SessionBoard rules (easy to break)

- Once any hook event arrives for a session (`fromHook`), `hasLiveState` is set. From then on, telemetry only adds token/cost usage and never changes state, because OTLP arrives in delayed batches.
- Telemetry-only sessions (JetBrains Copilot, Qwen) can only be `working`/`idle`. They fall back to `idle` after `idleAfter` (45 s) of silence in `tick()`.
- An `ended` session ignores everything except a new `sessionStarted`. Ended sessions are dropped after 10 min, and any session is dropped after 4 h of silence.
- `AppModel` runs three loops: `tick` every 5 s, vLLM poll every 5 s, Claude limits every 180 s.

### Source detection

`TelemetryMapper.source(of:)` picks the `AgentSource` from `service.name` and the record name. Session IDs come from a list of candidate attribute keys (`sessionKeys`). To add a source, update `AgentSource`, `TelemetryMapper` and/or `HookMapper`, and add a `scripts/setup-*.sh`.

### Other pieces

- `Package.swift` embeds `Sources/AgentBar/Info.plist` into the executable through linker `-sectcreate`, so `swift run` gets the same App Transport Security exceptions (plain HTTP to private-range IPs for vLLM) as the bundle. `make-app.sh` also copies it into the `.app`.
- `ClaudeLimitsClient` reads Claude Code's OAuth token from the Keychain item "Claude Code-credentials" by shelling out to `/usr/bin/security`. It then calls the undocumented `api.anthropic.com/api/oauth/usage`.
- Settings (`AppSettings`) are stored as JSON in `UserDefaults` under the key `AgentBarSettings`.

## Tests and fixtures

`Tests/AgentKitTests/Fixtures/` holds real payloads captured from the official OpenTelemetry JS exporters. Several come as `.json` + `.pb` pairs, and tests assert both decode identically. Load fixtures with the `Fixture` helper in `Support.swift`. Hook fixtures are a JSON dictionary of named payloads (`Fixture.hookPayloads`).

## Setup scripts

`scripts/setup-{claude-code,copilot-cli,qwen-code}.sh` edit the user's agent configs with `jq`. Each script backs up the file first, supports `--uninstall`, and honors `AGENTBAR_PORT`. Hook commands carry a `# agentbar` marker, so re-runs and uninstall strip only AgentBar's own entries. The Claude script skips telemetry when the user already exports OTel elsewhere, unless `--force` is passed. If you change routes or the hook event list, keep these scripts and `simulate.sh` in sync.

## Working in this repo

- **Subagents:** use `swift-core-dev` for AgentKit, the v2 `AgentSystem` target, `scripts/` and tests. Use `macos-ui-dev` for the `AgentBar` app target (panel, Dashboard, palette, components). When you delegate, name the v2 milestone and tell the subagent to read `.claude/memory/v2-plan.md`.
- **Skills:** project skills go in `.claude/skills/<name>/SKILL.md`. There are none yet; add one only when the knowledge is reusable and not already in this file.
- **Never commit or push on the user's behalf.** Leave changes in the working tree and report them; the user reviews and commits. Creating a new branch is the most git writing allowed.
- **Memory:** `.claude/memory/` is Claude Code's auto-memory directory, set through `autoMemoryDirectory` in the gitignored `.claude/settings.local.json`. `MEMORY.md` is the index: one line per memory, one fact per file, frontmatter as in the existing files. Memory is versioned with the repo.
- **Copilot mirror:** Copilot reads the same configuration through these paths:
  - `.github/copilot-instructions.md` is a symlink to this file. The Edit tool refuses symlinks, so edit `CLAUDE.md` itself.
  - `.github/agents/*.md` are real copies, not symlinks. Edit agent bodies in both `.claude/agents/` and `.github/agents/`.
  - Each new skill also gets a symlink `.github/skills/<name>` pointing to `../../.claude/skills/<name>`.
- **`.mcp.json`:** `context7` provides current library docs. Swift 6.2, macOS 26 SwiftUI, Liquid Glass and Swift Charts are newer than training data, so check `context7` before guessing an API.
