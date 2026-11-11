@testable import AgentKit
import Foundation
import XCTest

final class CodexHooksTests: XCTestCase {
    private let hooks = CodexHooks(port: 4318)

    private func object(_ json: String) throws -> [String: Any] {
        try SettingsJSON.parse(Data(json.utf8))
    }

    private func commands(_ file: [String: Any], event: String) -> [String] {
        let groups = (file["hooks"] as? [String: Any])?[event] as? [Any] ?? []
        return groups.flatMap { ($0 as? [String: Any])?["hooks"] as? [Any] ?? [] }
            .compactMap { ($0 as? [String: Any])?["command"] as? String }
    }

    func testCommandsObserveOnly() {
        XCTAssertEqual(hooks.hookCommand,
                       "curl -s -m 2 -o /dev/null -H 'Expect:' -H 'Content-Type: application/json' -H \"X-Hoply-Pid: $PPID\" "
                           + "--data-binary @- http://127.0.0.1:4318/hooks/codex-cli || true # hoply")
        XCTAssertFalse(hooks.hookCommand.contains(PermissionApproval.header), "Codex hooks run before its prompt")
        XCTAssertEqual(hooks.hook(for: "PermissionRequest")["command"] as? String, hooks.hookCommand)
        XCTAssertEqual(hooks.hook(for: "Stop")["timeout"] as? Int, 5)
        XCTAssertEqual(hooks.hook(for: "SessionEnd")["timeout"] as? Int, 3)
    }

    func testConnectAppendsAfterTheUsersHooksAndDisconnectRestores() throws {
        let original = try object("""
            {"description": "mine",
             "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done", "timeout": 3}]}],
                       "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo pre"}]}],
                       "PreCompact": [{"hooks": [{"type": "command", "command": "echo compact"}]}]}}
            """)
        XCTAssertEqual(hooks.status(of: original), .notConnected)
        let connected = try XCTUnwrap(try hooks.connect(original))
        XCTAssertEqual(hooks.status(of: connected), .connected)
        XCTAssertEqual(commands(connected, event: "Stop"), ["say done", hooks.hookCommand])
        XCTAssertEqual(commands(connected, event: "PreToolUse"), ["echo pre", hooks.hookCommand])
        XCTAssertEqual(commands(connected, event: "PreCompact"), ["echo compact"])
        for event in CodexHooks.events {
            XCTAssertEqual(commands(connected, event: event).last, hooks.hookCommand, event)
        }
        XCTAssertNil(try hooks.connect(connected), "connected: nothing to write")
        XCTAssertTrue(SettingsJSON.same(try XCTUnwrap(hooks.disconnect(connected)), original))
        XCTAssertNil(hooks.disconnect(original))
        XCTAssertTrue(SettingsJSON.same(try XCTUnwrap(hooks.disconnect(try XCTUnwrap(try hooks.connect([:])))),
                                        [String: Any]()))
    }

    func testStatusAndShape() throws {
        let connected = try XCTUnwrap(try hooks.connect([:]))
        XCTAssertEqual(CodexHooks(port: 4319).status(of: connected), .outdated)
        let moved = try XCTUnwrap(try CodexHooks(port: 4319).connect(connected))
        XCTAssertEqual(commands(moved, event: "Stop"), [CodexHooks(port: 4319).hookCommand])

        var fewer = connected
        var events = try XCTUnwrap(fewer["hooks"] as? [String: Any])
        events["SessionEnd"] = nil
        fewer["hooks"] = events
        XCTAssertEqual(hooks.status(of: fewer), .outdated)

        XCTAssertEqual(hooks.status(of: try object(#"{"hooks": []}"#)), .unreadable("\"hooks\" is not an object"))
        XCTAssertThrowsError(try hooks.connect(try object(#"{"hooks": {"Stop": {}}}"#)))
    }
}

final class CodexRoutingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_300_000)

    private func post(_ path: String, _ payload: [String: Any], headers: [String: String] = [:]) throws -> HubRouter.Outcome {
        let body = try JSONSerialization.data(withJSONObject: payload)
        return HubRouter().handle(HTTPRequest(method: "POST", path: path,
                                              headers: ["content-type": "application/json"].merging(headers) { $1 },
                                              body: body), now: now)
    }

    func testCodexHooksMapLikeClaudeCodesAndAreNeverHeld() throws {
        let base: [String: Any] = ["session_id": "019c0000-0000-7000-8000-000000000001", "cwd": "/Users/dev/project",
                                   "model": "gpt-6.1-sol", "permission_mode": "default",
                                   "transcript_path": "/Users/dev/.codex/sessions/2026/11/10/rollout-x.jsonl"]
        let start = try post("/hooks/codex-cli", base.merging(["hook_event_name": "SessionStart", "source": "startup"]) { $1 })
        XCTAssertEqual(start.events.map(\.kind), [.sessionStarted])
        XCTAssertEqual(start.events.first?.key, SessionKey(source: .codexCLI, id: "019c0000-0000-7000-8000-000000000001"))
        XCTAssertEqual(start.events.first?.transcriptPath, "/Users/dev/.codex/sessions/2026/11/10/rollout-x.jsonl")

        let permission = try post("/hooks/codex-cli", base.merging(["hook_event_name": "PermissionRequest",
                                                                    "turn_id": "t1", "tool_name": "Bash",
                                                                    "tool_input": ["command": "ls"]]) { $1 },
                                  headers: [PermissionApproval.header: "1"])
        XCTAssertEqual(permission.events.map(\.kind), [.needsPermission("Allow Bash?")])
        XCTAssertNil(permission.approval)

        let stop = try post("/hooks/codex-cli", base.merging(["hook_event_name": "Stop", "turn_id": "t1",
                                                              "last_assistant_message": "done",
                                                              "stop_hook_active": false]) { $1 })
        XCTAssertEqual(stop.events.map(\.kind), [.turnFinished("done")])
    }

    func testCursorRunningClaudeHooksIsIgnored() throws {
        let outcome = try post("/hooks/claude-code", ["hook_event_name": "Stop", "session_id": "c1",
                                                      "cursor_version": "2.4.1"])
        XCTAssertEqual(outcome.events, [])
        XCTAssertEqual(String(decoding: outcome.response.body, as: UTF8.self), "{}")
    }
}

final class CodexTelemetryTests: XCTestCase {
    private func record(_ name: String, _ attributes: [String: AttributeValue],
                        service: String = "codex_cli_rs") -> TelemetryRecord {
        TelemetryRecord(signal: .log, name: name,
                        attributes: ["conversation.id": .string("019c-conv"), "model": .string("gpt-6.1-sol")]
                            .merging(attributes) { $1 },
                        resource: ["service.name": .string(service)], time: Date(timeIntervalSince1970: 1_794_300_000))
    }

    func testCodexLogsAreLiveOnly() {
        let completed = record("codex.sse_event", ["event.kind": .string("response.completed"),
                                                   "input_token_count": .int(13_630), "cached_token_count": .int(10_496),
                                                   "output_token_count": .int(131), "reasoning_token_count": .int(25)])
        XCTAssertEqual(TelemetryMapper.source(of: completed), .codexCLI)
        XCTAssertEqual(TelemetryMapper.source(of: record("codex.user_prompt", [:], service: "codex_exec")), .codexCLI)
        let events = TelemetryMapper.events(from: [completed,
                                                   record("codex.sse_event", ["event.kind": .string("response.output_text.delta")]),
                                                   record("codex.tool_result", ["tool_name": .string("shell")]),
                                                   record("codex.user_prompt", [:])])
        XCTAssertEqual(events.map(\.kind), [.usage(.init(inputTokens: 3_134, outputTokens: 131, cacheTokens: 10_496)),
                                            .activity, .toolFinished("shell"), .promptSubmitted(nil)])
        XCTAssertEqual(events.first?.key, SessionKey(source: .codexCLI, id: "019c-conv"))
        XCTAssertEqual(events.first?.model, "gpt-6.1-sol")
        XCTAssertEqual(TelemetryUsage.records(from: [completed]), [], "rollouts are Codex's ledger, never its OTel")
        XCTAssertEqual(UsageAuthority.ledger(for: .codexCLI), .codexRollouts)
    }

    func testResumeCommand() throws {
        let script = try XCTUnwrap(ResumeScript.script(source: .codexCLI, sessionID: "019c0000-0000-7000-8000-000000000001",
                                                       cwd: "/Users/dev/project"))
        XCTAssertTrue(script.contains("exec 'codex' 'resume' '019c0000-0000-7000-8000-000000000001'"), script)
    }
}
