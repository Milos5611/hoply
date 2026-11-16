import AgentKit
import Foundation
import XCTest

final class ConnectHooksTests: XCTestCase {
    private let hooks = ClaudeCodeHooks(port: 4318)

    private func object(_ json: String) throws -> [String: Any] {
        try SettingsJSON.parse(Data(json.utf8))
    }

    private func assertSame(_ lhs: Any?, _ rhs: Any?, file: StaticString = #filePath, line: UInt = #line) {
        guard let lhs, let rhs else { return XCTFail("nil value", file: file, line: line) }
        XCTAssertTrue(SettingsJSON.same(lhs, rhs),
                      "\(String(decoding: SettingsJSON.encode(["v": lhs]), as: UTF8.self)) differs from "
                          + String(decoding: SettingsJSON.encode(["v": rhs]), as: UTF8.self), file: file, line: line)
    }

    private func ourCommands(_ settings: [String: Any], event: String) -> [String] {
        let groups = (settings["hooks"] as? [String: Any])?[event] as? [Any] ?? []
        return groups.flatMap { ($0 as? [String: Any])?["hooks"] as? [Any] ?? [] }
            .compactMap { ($0 as? [String: Any])?["command"] as? String }
            .filter { $0.contains("# hoply") }
    }

    func testCommandsMatchInstallScript() {
        XCTAssertEqual(hooks.hookCommand,
                       #"curl -s -m 2 -o /dev/null -H 'Expect:' -H 'Content-Type: application/json' -H "X-Hoply-Pid: $PPID" --data-binary @- http://127.0.0.1:4318/hooks/claude-code || true # hoply"#)
        XCTAssertEqual(hooks.approveCommand,
                       #"curl -sf -m 590 -H 'Expect:' -H 'Content-Type: application/json' -H 'X-Hoply-Approve: 1' -H "X-Hoply-Pid: $PPID" --data-binary @- http://127.0.0.1:4318/hooks/claude-code || true # hoply"#)
        XCTAssertEqual(hooks.replyCommand,
                       #"curl -sf -m 1790 -H 'Expect:' -H 'Content-Type: application/json' -H 'X-Hoply-Reply: 1' -H "X-Hoply-Pid: $PPID" --data-binary @- http://127.0.0.1:4318/hooks/claude-code || true # hoply"#)
        XCTAssertEqual(hooks.environment, [
            "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
            "OTEL_LOGS_EXPORTER": "otlp",
            "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL": "http/json",
            "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": "http://127.0.0.1:4318/v1/logs",
            "OTEL_LOGS_EXPORT_INTERVAL": "2000",
        ])
        XCTAssertEqual(ClaudeCodeHooks.events, ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                                                "PermissionRequest", "Notification", "Elicitation", "ElicitationResult",
                                                "SubagentStart", "SubagentStop", "Stop", "StopFailure", "SessionEnd"])
        assertSame(hooks.hook(for: "Stop"), ["type": "command", "command": hooks.replyCommand, "timeout": 1800,
                                             "statusMessage": "Waiting for your reply in Hoply"])
        assertSame(hooks.hook(for: "SubagentStop"), ["type": "command", "command": hooks.hookCommand, "timeout": 5])
        assertSame(hooks.hook(for: "StopFailure"), ["type": "command", "command": hooks.hookCommand, "timeout": 5])
        assertSame(hooks.hook(for: "PermissionRequest"),
                   ["type": "command", "command": hooks.approveCommand, "timeout": 600])
        XCTAssertEqual(CopilotCLIHooks(port: 4318).command(for: "sessionStart"),
                       #"curl -s -m 2 -o /dev/null -H 'Expect:' -H 'Content-Type: application/json' -H "X-Hoply-Pid: $PPID" --data-binary @- http://127.0.0.1:4318/hooks/copilot-cli/sessionStart || true"#)
        XCTAssertEqual(CopilotCLIHooks(port: 4318).command(for: "agentStop"),
                       #"curl -sf -m 1790 -H 'Expect:' -H 'Content-Type: application/json' -H 'X-Hoply-Reply: 1' -H "X-Hoply-Pid: $PPID" --data-binary @- http://127.0.0.1:4318/hooks/copilot-cli/agentStop || true"#)
        XCTAssertEqual(CopilotCLIHooks.events, ["sessionStart", "userPromptSubmitted", "preToolUse", "postToolUse",
                                                "permissionRequest", "notification", "agentStop", "sessionEnd",
                                                "errorOccurred"])
        let copilot = CopilotCLIHooks(port: 4318)
        assertSame(copilot.hook(for: "agentStop"),
                   ["type": "command", "bash": copilot.replyCommand, "timeoutSec": 1800])
        XCTAssertEqual(copilot.command(for: "agentStop"), copilot.replyCommand)
        for event in CopilotCLIHooks.events where event != "agentStop" {
            assertSame(copilot.hook(for: event), ["type": "command", "bash": copilot.command(for: event)])
            XCTAssertTrue(copilot.command(for: event).contains("curl -s -m 2 -o /dev/null "), event)
        }
        XCTAssertTrue(ClaudeCodeHooks(port: 5000).hookCommand.contains(" http://127.0.0.1:5000/hooks/claude-code "))
    }

    func testCopilotFileIsByteForByteWhatInstallScriptWrote() throws {
        XCTAssertEqual(String(decoding: CopilotCLIHooks(port: 4318).fileContents, as: UTF8.self),
                       try Fixture.text("install_sh_copilot_hooks.json"))
    }

    func testClaudeConnectMatchesInstallScript() throws {
        let input = try object(#"{"theme":"dark","env":{"MY_VAR":"x","OTEL_LOGS_EXPORT_INTERVAL":"5000"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done","timeout":3}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo pre"}]}]},"flag":true,"n":5}"#)
        let expected = try SettingsJSON.parse(Fixture.data("install_sh_claude_settings.json"))
        assertSame(try hooks.connect(input), expected)
        XCTAssertEqual(hooks.status(of: expected), .connected)
    }

    func testConnectKeepsUserHooksAndEnv() throws {
        let input = try object("""
            {"env": {"MY_VAR": "x"},
             "hooks": {
               "Stop": [{"hooks": [{"type": "command", "command": "say done", "timeout": 3}]}],
               "PreToolUse": [{"matcher": "Bash", "hooks": [
                 {"type": "command", "command": "echo pre"},
                 {"type": "command", "command": "curl old http://127.0.0.1:4318/hooks/claude-code || true # hoply"}]}],
               "PreCompact": [{"hooks": [{"type": "command", "command": "echo compact"}]}]
             }}
            """)
        let connected = try XCTUnwrap(try hooks.connect(input))
        XCTAssertEqual(hooks.status(of: connected), .connected)
        let all = try XCTUnwrap(connected["hooks"] as? [String: Any])
        assertSame(all["Stop"], [["hooks": [["type": "command", "command": "say done", "timeout": 3]]],
                                 ["hooks": [hooks.hook(for: "Stop")]]])
        assertSame(all["PreToolUse"], [["matcher": "Bash", "hooks": [["type": "command", "command": "echo pre"]]],
                                       ["hooks": [hooks.hook(for: "PreToolUse")]]])
        assertSame(all["PreCompact"], [["hooks": [["type": "command", "command": "echo compact"]]]])
        XCTAssertEqual((connected["env"] as? [String: Any])?["MY_VAR"] as? String, "x")
        for event in ClaudeCodeHooks.events {
            XCTAssertEqual(ourCommands(connected, event: event).count, 1, event)
        }

        let disconnected = try XCTUnwrap(hooks.disconnect(connected))
        XCTAssertEqual(hooks.status(of: disconnected), .notConnected)
        let remaining = try XCTUnwrap(disconnected["hooks"] as? [String: Any])
        XCTAssertEqual(Set(remaining.keys), ["Stop", "PreToolUse", "PreCompact"])
        assertSame(remaining["PreToolUse"], [["matcher": "Bash", "hooks": [["type": "command", "command": "echo pre"]]]])
        assertSame(disconnected["env"], ["MY_VAR": "x"])
    }

    func testConnectThenDisconnectRestoresTheOriginal() throws {
        let original = try object("""
            {"model": "opus", "alwaysThinkingEnabled": true, "cleanupPeriodDays": 30, "ratio": 0.25,
             "permissions": {"allow": ["Bash(git status)"], "deny": []},
             "env": {"DOTNET_ROOT": "/opt/homebrew/opt/dotnet/libexec"},
             "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done", "timeout": 3}]},
                                {"matcher": "", "hooks": []}],
                       "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo pre"}]}]},
             "statusLine": {"type": "command", "command": "~/bin/status", "padding": 0}}
            """)
        let connected = try XCTUnwrap(try hooks.connect(original))
        assertSame(hooks.disconnect(connected), original)

        let empty = try XCTUnwrap(try hooks.connect([:]))
        assertSame(hooks.disconnect(empty), [String: Any]())
    }

    func testEnvKeyWeAlsoSetIsOverwrittenAndThenRemovedLikeInstallScript() throws {
        let input = try object(#"{"env": {"OTEL_LOGS_EXPORT_INTERVAL": "5000", "OTEL_LOGS_EXPORTER": "console", "KEEP": "1"}}"#)
        let connected = try XCTUnwrap(try hooks.connect(input))
        XCTAssertEqual((connected["env"] as? [String: Any])?["OTEL_LOGS_EXPORT_INTERVAL"] as? String, "2000")
        XCTAssertEqual((connected["env"] as? [String: Any])?["OTEL_LOGS_EXPORTER"] as? String, "otlp")
        assertSame(hooks.disconnect(connected)?["env"], ["KEEP": "1"])

        let userValue = try object(#"{"env": {"OTEL_LOGS_EXPORT_INTERVAL": "5000"}}"#)
        XCTAssertNil(hooks.disconnect(userValue))
    }

    func testConnectIsANoOpWhenConnectedAndDisconnectWhenNothingIsOurs() throws {
        let connected = try XCTUnwrap(try hooks.connect([:]))
        XCTAssertNil(try hooks.connect(connected))
        let reordered = try object(#"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say"}]}]}}"#)
        let withUserHookAfterOurs = try XCTUnwrap(try hooks.connect(reordered))
        var hooksObject = try XCTUnwrap(withUserHookAfterOurs["hooks"] as? [String: Any])
        hooksObject["Stop"] = Array((hooksObject["Stop"] as? [Any] ?? []).reversed())
        var swapped = withUserHookAfterOurs
        swapped["hooks"] = hooksObject
        XCTAssertNil(try hooks.connect(swapped))

        XCTAssertNil(hooks.disconnect([:]))
        XCTAssertNil(hooks.disconnect(reordered))
    }

    func testStatus() throws {
        XCTAssertEqual(hooks.status(of: [:]), .notConnected)
        XCTAssertEqual(hooks.status(of: try object(#"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say"}]}]}, "env": {"CLAUDE_CODE_ENABLE_TELEMETRY": "1"}}"#)),
                       .notConnected)
        let connected = try XCTUnwrap(try hooks.connect([:]))
        XCTAssertEqual(hooks.status(of: connected), .connected)
        XCTAssertEqual(ClaudeCodeHooks(port: 4319).status(of: connected), .outdated)

        func edited(_ change: (inout [String: Any], inout [String: Any]) -> Void) -> [String: Any] {
            var settings = connected
            var hooksObject = settings["hooks"] as? [String: Any] ?? [:]
            var env = settings["env"] as? [String: Any] ?? [:]
            change(&hooksObject, &env)
            settings["hooks"] = hooksObject
            settings["env"] = env
            return settings
        }
        let generic: [String: Any] = ["type": "command", "command": hooks.hookCommand, "timeout": 5]
        let reply = hooks.hook(for: "Stop")
        let cases: [(String, [String: Any])] = [
            ("no approve command", edited { h, _ in h["PermissionRequest"] = [["hooks": [generic]]] }),
            ("no reply command", edited { h, _ in h["Stop"] = [["hooks": [generic]]] }),
            ("reply without status", edited { h, _ in
                h["Stop"] = [["hooks": [reply.filter { $0.key != "statusMessage" }]]]
            }),
            ("reply timeout", edited { h, _ in h["Stop"] = [["hooks": [reply.merging(["timeout": 600]) { $1 }]]] }),
            ("missing event", edited { h, _ in h["Elicitation"] = nil }),
            ("extra event", edited { h, _ in h["PreCompact"] = [["hooks": [generic]]] }),
            ("duplicate", edited { h, _ in h["PreToolUse"] = [["hooks": [generic]], ["hooks": [generic]]] }),
            ("timeout", edited { h, _ in h["PreToolUse"] = [["hooks": [generic.merging(["timeout": 10]) { $1 }]]] }),
            ("bool timeout", edited { h, _ in
                h["PreToolUse"] = [["hooks": [generic.merging(["timeout": true]) { $1 }]]]
            }),
            ("extra key", edited { h, _ in h["PreToolUse"] = [["hooks": [generic.merging(["async": true]) { $1 }]]] }),
            ("env value", edited { _, e in e["OTEL_LOGS_EXPORT_INTERVAL"] = "5000" }),
            ("env missing", edited { _, e in e["OTEL_LOGS_EXPORTER"] = nil }),
        ]
        for (name, settings) in cases {
            XCTAssertEqual(hooks.status(of: settings), .outdated, name)
            let repaired = try XCTUnwrap(try hooks.connect(settings), name)
            XCTAssertEqual(hooks.status(of: repaired), .connected, name)
        }
    }

    func testOldInstallReadsOutdatedAndUpgradesInPlace() throws {
        let oldCommand = "curl -s -m 2 -o /dev/null -H 'Expect:' -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:4318/hooks/claude-code || true # hoply"
        var oldHooks: [String: Any] = [:]
        for event in ["Notification", "PermissionRequest", "PostToolUse", "PreToolUse", "SessionEnd", "SessionStart",
                      "Stop", "UserPromptSubmit"] {
            oldHooks[event] = [["hooks": [["type": "command", "command": oldCommand, "timeout": 5]]]]
        }
        let old: [String: Any] = ["hooks": oldHooks, "env": hooks.environment.merging(["DOTNET_ROOT": "/x"]) { $1 }]
        XCTAssertEqual(hooks.status(of: old), .outdated)
        let upgraded = try XCTUnwrap(try hooks.connect(old))
        XCTAssertEqual(hooks.status(of: upgraded), .connected)
        XCTAssertEqual(ourCommands(upgraded, event: "PermissionRequest"), [hooks.approveCommand])
        XCTAssertEqual(ourCommands(upgraded, event: "Stop"), [hooks.replyCommand])
        XCTAssertEqual((upgraded["env"] as? [String: Any])?["DOTNET_ROOT"] as? String, "/x")
    }

    func testInstallWithoutTheReplyCommandReadsOutdatedAndUpgradesOnlyStop() throws {
        let original = try object(#"{"env": {"KEEP": "1"}, "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done", "timeout": 3}]}]}}"#)
        var previous = try XCTUnwrap(try hooks.connect(original))
        var hooksObject = try XCTUnwrap(previous["hooks"] as? [String: Any])
        hooksObject["Stop"] = [["hooks": [["type": "command", "command": "say done", "timeout": 3]]],
                               ["hooks": [["type": "command", "command": hooks.hookCommand, "timeout": 5]]]]
        previous["hooks"] = hooksObject
        XCTAssertEqual(hooks.status(of: previous), .outdated)

        let upgraded = try XCTUnwrap(try hooks.connect(previous))
        XCTAssertEqual(hooks.status(of: upgraded), .connected)
        let upgradedHooks = try XCTUnwrap(upgraded["hooks"] as? [String: Any])
        assertSame(upgradedHooks["Stop"], [["hooks": [["type": "command", "command": "say done", "timeout": 3]]],
                                           ["hooks": [hooks.hook(for: "Stop")]]])
        for event in ClaudeCodeHooks.events where event != "Stop" {
            assertSame(upgradedHooks[event], hooksObject[event])
        }
        assertSame(hooks.disconnect(upgraded), original)
    }

    func testDisconnectAfterAPortChangeRemovesTheOldEndpoint() throws {
        let connected = try XCTUnwrap(try hooks.connect(["env": ["KEEP": "1"]]))
        let disconnected = try XCTUnwrap(ClaudeCodeHooks(port: 4319).disconnect(connected))
        assertSame(disconnected, ["env": ["KEEP": "1"]])
    }

    func testWrongShapesAreRefused() throws {
        for json in [#"{"hooks": []}"#, #"{"hooks": {"Stop": {}}}"#, #"{"env": ["x"]}"#] {
            let settings = try object(json)
            guard case .unreadable = hooks.status(of: settings) else { return XCTFail(json) }
            XCTAssertThrowsError(try hooks.connect(settings), json)
        }
        XCTAssertEqual(hooks.status(of: try object(#"{"hooks": {"Custom": {}}, "env": null}"#)), .notConnected)
        XCTAssertNotNil(try hooks.connect(try object(#"{"hooks": null, "env": null}"#)))

        XCTAssertThrowsError(try SettingsJSON.parse(Data("[1]".utf8))) { error in
            XCTAssertEqual(error as? SettingsJSONError, .notAnObject)
        }
        XCTAssertThrowsError(try SettingsJSON.parse(Data(#"{"a": }"#.utf8))) { error in
            guard case .invalidJSON = error as? SettingsJSONError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(try SettingsJSON.parse(Data(" \n".utf8)).isEmpty)
    }
}

final class SettingsJSONTests: XCTestCase {
    func testRoundTripKeepsTypes() throws {
        let json = #"""
            {"bool": true, "off": false, "int": 30, "negative": -5, "big": 9007199254740993, "float": 0.1,
             "exp": 1.5e-7, "whole": 2.0, "null": null, "empty": {}, "list": [], "nested": {"a": [1, true, "x", null]},
             "text": "ü 🚀 \"quoted\" back\\slash http://x/y \n\t \u0001"}
            """#
        let parsed = try SettingsJSON.parse(Data(json.utf8))
        let encoded = SettingsJSON.encode(parsed)
        let reparsed = try SettingsJSON.parse(encoded)
        XCTAssertTrue(SettingsJSON.same(parsed, reparsed))
        XCTAssertEqual(encoded, SettingsJSON.encode(reparsed))
        XCTAssertTrue(SettingsJSON.isBool(try XCTUnwrap(reparsed["bool"] as? NSNumber)))
        XCTAssertTrue(SettingsJSON.isBool(try XCTUnwrap(reparsed["off"] as? NSNumber)))
        XCTAssertFalse(SettingsJSON.isBool(try XCTUnwrap(reparsed["int"] as? NSNumber)))
        XCTAssertFalse(CFNumberIsFloatType(try XCTUnwrap(reparsed["int"] as? NSNumber)))
        XCTAssertEqual((reparsed["big"] as? NSNumber)?.int64Value, 9_007_199_254_740_993)

        let text = String(decoding: encoded, as: UTF8.self)
        for line in [#"  "bool": true,"#, #"  "int": 30,"#, #"  "float": 0.1,"#, #"  "exp": 1.5e-07,"#,
                     #"  "whole": 2"#, #"  "empty": {},"#, #"  "list": [],"#, #"  "null": null,"#,
                     #"  "text": "ü 🚀 \"quoted\" back\\slash http://x/y \n\t \u0001","#] {
            XCTAssertTrue(text.contains(line + "\n"), line)
        }
        XCTAssertTrue(text.hasPrefix("{\n  \"big\": 9007199254740993,\n"))
        XCTAssertTrue(text.hasSuffix("\n}\n"))
    }

    func testEncodedFormat() {
        let object: [String: Any] = ["b": [1, ["c": false]], "a": "x"]
        XCTAssertEqual(String(decoding: SettingsJSON.encode(object), as: UTF8.self), """
            {
              "a": "x",
              "b": [
                1,
                {
                  "c": false
                }
              ]
            }

            """)
        XCTAssertEqual(String(decoding: SettingsJSON.encode([:]), as: UTF8.self), "{}\n")
    }

    func testSameTellsBoolsFromNumbers() throws {
        let parsed = try SettingsJSON.parse(Data(#"{"a": true, "b": 1}"#.utf8))
        XCTAssertFalse(SettingsJSON.same(parsed["a"] as Any, parsed["b"] as Any))
        XCTAssertTrue(SettingsJSON.same(parsed["a"] as Any, true))
        XCTAssertTrue(SettingsJSON.same(parsed["b"] as Any, 1))
        XCTAssertFalse(SettingsJSON.same(["a": 1], ["a": 1, "b": 2]))
        XCTAssertFalse(SettingsJSON.same([1, 2], [2, 1]))
    }
}

final class CopilotHooksFileTests: XCTestCase {
    func testStatus() throws {
        let hooks = CopilotCLIHooks(port: 4318)
        XCTAssertEqual(hooks.status(ofFile: nil), .notConnected)
        XCTAssertEqual(hooks.status(ofFile: hooks.fileContents), .connected)
        let reformatted = try JSONSerialization.data(withJSONObject: hooks.file, options: [.sortedKeys])
        XCTAssertEqual(hooks.status(ofFile: reformatted), .connected)
        XCTAssertEqual(CopilotCLIHooks(port: 4319).status(ofFile: hooks.fileContents), .outdated)
        XCTAssertEqual(hooks.status(ofFile: Data("{".utf8)), .outdated)

        let old = String(decoding: hooks.fileContents, as: UTF8.self)
            .replacingOccurrences(of: #" -H \"X-Hoply-Pid: $PPID\""#, with: "")
        XCTAssertNotEqual(old, String(decoding: hooks.fileContents, as: UTF8.self))
        XCTAssertEqual(hooks.status(ofFile: Data(old.utf8)), .outdated)

        var fewer = hooks.file
        var events = try XCTUnwrap(fewer["hooks"] as? [String: Any])
        events["errorOccurred"] = nil
        fewer["hooks"] = events
        XCTAssertEqual(hooks.status(ofFile: try JSONSerialization.data(withJSONObject: fewer)), .outdated)

        func agentStop(_ hook: [String: Any]) throws -> Data {
            var file = hooks.file
            var events = try XCTUnwrap(file["hooks"] as? [String: Any])
            events["agentStop"] = [hook]
            file["hooks"] = events
            return try JSONSerialization.data(withJSONObject: file)
        }
        let generic = hooks.command(for: "sessionStart").replacingOccurrences(of: "/sessionStart", with: "/agentStop")
        let reply = hooks.hook(for: "agentStop")
        let cases: [(String, [String: Any])] = [
            ("before Away mode", ["type": "command", "bash": generic]),
            ("no timeout", ["type": "command", "bash": hooks.replyCommand]),
            ("generic with timeout", ["type": "command", "bash": generic, "timeoutSec": 1800]),
            ("timeout", reply.merging(["timeoutSec": 30]) { $1 }),
            ("bool timeout", reply.merging(["timeoutSec": true]) { $1 }),
        ]
        for (name, hook) in cases {
            XCTAssertEqual(hooks.status(ofFile: try agentStop(hook)), .outdated, name)
        }
        XCTAssertEqual(hooks.status(ofFile: try agentStop(reply)), .connected)
    }

    func testFileContentsParseBackToTheFile() throws {
        for port in [4318, 5000] {
            let hooks = CopilotCLIHooks(port: port)
            let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: hooks.fileContents) as? [String: Any])
            XCTAssertTrue(SettingsJSON.same(parsed, hooks.file))
            let agentStop = try XCTUnwrap(((parsed["hooks"] as? [String: Any])?["agentStop"] as? [Any])?.first
                                          as? [String: Any])
            XCTAssertEqual(agentStop["timeoutSec"] as? Int, TurnReply.hookTimeout)
            XCTAssertEqual(agentStop["bash"] as? String, hooks.replyCommand)
            XCTAssertTrue(hooks.replyCommand.contains("http://127.0.0.1:\(port)/hooks/copilot-cli/agentStop "))
        }
        let before = try Fixture.text("install_sh_copilot_hooks.json")
            .replacingOccurrences(of: #"curl -sf -m 1790 -H 'Expect:' -H 'Content-Type: application/json' -H 'X-Hoply-Reply: 1' "#,
                                  with: #"curl -s -m 2 -o /dev/null -H 'Expect:' -H 'Content-Type: application/json' "#)
            .replacingOccurrences(of: "agentStop || true\",\n        \"timeoutSec\": 1800", with: "agentStop || true\"")
        XCTAssertFalse(before.contains("timeoutSec"))
        XCTAssertFalse(before.contains("X-Hoply-Reply"))
        XCTAssertEqual(CopilotCLIHooks(port: 4318).status(ofFile: Data(before.utf8)), .outdated,
                       "the file Hoply wrote before Away mode")
        XCTAssertFalse(CopilotCLIHooks.events.contains("subagentStop"))
    }

    func testConnectableAgents() {
        XCTAssertEqual(ConnectableAgent.allCases.map(\.rawValue), ["claude-code", "copilot-cli", "codex-cli"])
        XCTAssertEqual(ConnectableAgent(source: .codexCLI), .codexCLI)
        XCTAssertEqual(ConnectableAgent(source: .copilotCLI), .copilotCLI)
        XCTAssertNil(ConnectableAgent(source: .qwenCode))
        XCTAssertEqual(ConnectableAgent.claudeCode.displayName, "Claude Code")
    }
}
