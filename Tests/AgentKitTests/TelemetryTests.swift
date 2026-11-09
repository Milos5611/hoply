@testable import AgentKit
import XCTest

final class OTLPDecoderTests: XCTestCase {
    func testClaudeLogsDecodeIdenticallyFromJSONAndProtobuf() throws {
        let json = try OTLPDecoder.decode(path: "/v1/logs", body: Fixture.data("claude_logs.json"), encoding: .json)
        let proto = try OTLPDecoder.decode(path: "/v1/logs", body: Fixture.data("claude_logs.pb"), encoding: .protobuf)
        XCTAssertEqual(json, proto)
        XCTAssertEqual(json.map(\.name), ["user_prompt", "api_request", "tool_result"])

        let request = json[1]
        XCTAssertEqual(request.signal, .log)
        XCTAssertEqual(request.resource["service.name"], .string("claude-code"))
        XCTAssertEqual(request["input_tokens"], .int(1500))
        XCTAssertEqual(request["cost_usd"], .double(0.0425))
        XCTAssertEqual(request["model"], .string("claude-opus-5"))
        XCTAssertNotNil(request.time)
    }

    func testQwenLogs() throws {
        let records = try OTLPDecoder.decode(path: "/v1/logs", body: Fixture.data("qwen_logs.pb"), encoding: .protobuf)
        XCTAssertEqual(records.map(\.name), ["qwen-code.api_request", "qwen-code.api_response"])
        XCTAssertEqual(records[1]["input_token_count"]?.int, 800)
        let json = try OTLPDecoder.decode(path: "/v1/logs", body: Fixture.data("qwen_logs.json"), encoding: .json)
        XCTAssertEqual(json, records)
    }

    func testCopilotSpansDecodeIdenticallyFromJSONAndProtobuf() throws {
        let json = try OTLPDecoder.decode(path: "/v1/traces", body: Fixture.data("copilot_spans.json"), encoding: .json)
        let proto = try OTLPDecoder.decode(path: "/v1/traces", body: Fixture.data("copilot_spans.pb"), encoding: .protobuf)
        XCTAssertEqual(json, proto)
        XCTAssertEqual(json.map(\.name), ["chat gpt-5.1", "execute_tool read_file"])
        XCTAssertEqual(json[0]["gen_ai.usage.output_tokens"], .int(340))
        XCTAssertEqual(json[0].signal, .span)
    }

    func testMalformedProtobufThrows() {
        // Field 1, length-delimited, claims 127 bytes that are not there.
        XCTAssertThrowsError(try OTLPDecoder.decode(path: "/v1/logs", body: Data([0x0A, 0x7F, 0x01]), encoding: .protobuf))
    }

    func testUnknownSignalThrows() {
        XCTAssertThrowsError(try OTLPDecoder.decode(path: "/v1/profiles", body: Data([0x0A]), encoding: .protobuf)) { error in
            XCTAssertEqual(error as? OTLPError, .unknownSignal)
        }
    }

    func testProtoReaderVarintAndFixed64() throws {
        let bytes: [UInt8] = [0xAC, 0x02, 0x01, 0, 0, 0, 0, 0, 0, 0]
        var reader = ProtoReader(bytes)
        XCTAssertEqual(try reader.readVarint(), 300)
        XCTAssertEqual(try reader.readFixed64(), 1)
        XCTAssertTrue(reader.isAtEnd)
    }
}

final class TelemetryMapperTests: XCTestCase {
    func testClaudeEvents() throws {
        let records = try OTLPDecoder.decode(path: "/v1/logs", body: Fixture.data("claude_logs.pb"), encoding: .protobuf)
        let events = TelemetryMapper.events(from: records)
        XCTAssertEqual(events.map(\.key), Array(repeating: SessionKey(source: .claudeCode, id: "sess-claude-1"), count: 3))
        XCTAssertEqual(events.map(\.kind), [
            .promptSubmitted("<REDACTED>"),
            .usage(.init(inputTokens: 1500, outputTokens: 250, cacheTokens: 9000, costUSD: 0.0425)),
            .toolFinished("Bash"),
        ])
        XCTAssertTrue(events.allSatisfy { !$0.fromHook })
        XCTAssertEqual(events[1].model, "claude-opus-5")
    }

    func testQwenEvents() throws {
        let records = try OTLPDecoder.decode(path: "/v1/logs", body: Fixture.data("qwen_logs.json"), encoding: .json)
        let events = TelemetryMapper.events(from: records)
        XCTAssertEqual(events.map(\.key.source), [.qwenCode, .qwenCode])
        XCTAssertEqual(events.map(\.key.id), ["sess-qwen-1", "sess-qwen-1"])
        XCTAssertEqual(events.map(\.kind), [.activity, .usage(.init(inputTokens: 800, outputTokens: 120))])
        XCTAssertEqual(events[1].model, "qwen3-coder")
    }

    func testCopilotGenAISpans() throws {
        let records = try OTLPDecoder.decode(path: "/v1/traces", body: Fixture.data("copilot_spans.pb"), encoding: .protobuf)
        let events = TelemetryMapper.events(from: records)
        XCTAssertEqual(events.map(\.key), Array(repeating: SessionKey(source: .copilotIDE, id: "conv-42"), count: 2))
        XCTAssertEqual(events.map(\.kind), [
            .usage(.init(inputTokens: 1200, outputTokens: 340)),
            .toolFinished("read_file"),
        ])
        XCTAssertEqual(events[0].model, "gpt-5.1")
    }

    func testSourceDetection() {
        func record(service: String, name: String = "x") -> TelemetryRecord {
            TelemetryRecord(signal: .log, name: name, attributes: [:],
                            resource: ["service.name": .string(service)], time: nil)
        }
        XCTAssertEqual(TelemetryMapper.source(of: record(service: "claude-code")), .claudeCode)
        XCTAssertEqual(TelemetryMapper.source(of: record(service: "qwen-code")), .qwenCode)
        XCTAssertEqual(TelemetryMapper.source(of: record(service: "github-copilot-cli")), .copilotCLI)
        XCTAssertEqual(TelemetryMapper.source(of: record(service: "copilot-chat")), .copilotIDE)
        XCTAssertNil(TelemetryMapper.source(of: record(service: "my-dotnet-api")))
    }
}

final class HookMapperTests: XCTestCase {
    func testClaudeCodeHooks() throws {
        let payloads = try Fixture.hookPayloads("claude_hooks.json")
        func kinds(_ name: String) throws -> [AgentEvent.Kind] {
            let json = try XCTUnwrap(payloads[name])
            return HookMapper.events(source: .claudeCode, eventName: nil, json: json).map(\.kind)
        }
        XCTAssertEqual(try kinds("SessionStart"), [.sessionStarted])
        XCTAssertEqual(try kinds("UserPromptSubmit"), [.promptSubmitted("Fix the flaky login test\nand explain why it failed")])
        XCTAssertEqual(try kinds("PreToolUse"), [.toolStarted("Bash")])
        XCTAssertEqual(try kinds("PermissionNotification"), [.needsPermission("Claude needs your permission to use Bash")])
        XCTAssertEqual(try kinds("PostToolUse"), [.toolFinished("Bash")])
        XCTAssertEqual(try kinds("Stop"), [.turnFinished("The test raced the token refresh. I added an await.")])
        XCTAssertEqual(try kinds("IdleNotification"), [.waitingForInput("Claude is waiting for your input")])
        XCTAssertEqual(try kinds("SessionEnd"), [.sessionEnded("prompt_input_exit")])

        let start = HookMapper.events(source: .claudeCode, eventName: nil, json: try XCTUnwrap(payloads["SessionStart"]))
        XCTAssertEqual(start.first?.key, SessionKey(source: .claudeCode, id: "abc123"))
        XCTAssertEqual(start.first?.cwd, "/Users/milos/Project/fiba")
        XCTAssertEqual(start.first?.model, "claude-opus-5")
        XCTAssertEqual(start.first?.fromHook, true)
    }

    func testCopilotCLIHooksWithEventNameInPath() throws {
        let payloads = try Fixture.hookPayloads("copilot_cli_hooks.json")
        func kinds(_ name: String) throws -> [AgentEvent.Kind] {
            let json = try XCTUnwrap(payloads[name])
            return HookMapper.events(source: .copilotCLI, eventName: name, json: json).map(\.kind)
        }
        XCTAssertEqual(try kinds("sessionStart"), [.sessionStarted, .promptSubmitted("Add pagination to the orders endpoint")])
        XCTAssertEqual(try kinds("userPromptSubmitted"), [.promptSubmitted("Also add tests")])
        XCTAssertEqual(try kinds("preToolUse"), [.toolStarted("bash")])
        XCTAssertEqual(try kinds("postToolUse"), [.toolFinished("bash")])
        XCTAssertEqual(try kinds("agentStop"), [.turnFinished(nil)])
        XCTAssertEqual(try kinds("sessionEnd"), [.sessionEnded("user_exit")])
    }

    func testNotificationClassification() {
        XCTAssertEqual(HookMapper.notification(["notification_type": "permission_prompt"]), .needsPermission(nil))
        XCTAssertEqual(HookMapper.notification(["notificationType": "agent_idle", "message": "Idle"]), .waitingForInput("Idle"))
        XCTAssertEqual(HookMapper.notification(["notification_type": "agent_completed"]), .turnFinished(nil))
        XCTAssertNil(HookMapper.notification(["notification_type": "auth_success"]))
    }

    func testEventNameNormalization() {
        XCTAssertEqual(HookMapper.normalize("UserPromptSubmit"), "userpromptsubmit")
        XCTAssertEqual(HookMapper.normalize("user_prompt_submitted"), "userpromptsubmitted")
    }
}
