@testable import AgentKit
import Foundation
import XCTest

final class UsageAuthorityTests: XCTestCase {
    func testOneLedgerPerSource() {
        XCTAssertEqual(UsageAuthority.ledger(for: .claudeCode), .transcripts)
        XCTAssertEqual(UsageAuthority.ledger(for: .copilotCLI), .copilotStore)
        XCTAssertEqual(UsageAuthority.ledger(for: .copilotIDE), .telemetry)
        XCTAssertEqual(UsageAuthority.ledger(for: .qwenCode), .telemetry)
        XCTAssertEqual(AgentSource.allCases.filter(UsageAuthority.persistsTelemetry), [.copilotIDE, .qwenCode])
    }
}

final class TelemetryUsageTests: XCTestCase {
    private func qwen(_ attributes: [String: AttributeValue], resource: [String: AttributeValue] = [:],
                      nanos: UInt64? = 1_794_228_000_123_456_789) -> TelemetryRecord {
        var base: [String: AttributeValue] = ["session.id": .string("q1"), "prompt_id": .string("p7"),
                                              "model": .string("Qwen3.8-Flash-Next")]
        base.merge(attributes) { _, new in new }
        return TelemetryRecord(signal: .log, name: "qwen-code.api_response", attributes: base,
                               resource: ["service.name": .string("qwen-code")].merging(resource) { _, new in new },
                               time: nanos.map { Date(timeIntervalSince1970: Double($0) / 1e9) }, timeUnixNano: nanos)
    }

    func testQwenResponsesBecomeLedgerRows() throws {
        let records = try OTLPDecoder.decode(path: "/v1/logs", body: Fixture.data("qwen_logs.json"), encoding: .json)
        let usage = TelemetryUsage.records(from: records)
        XCTAssertEqual(usage.count, 1, "only api_response carries usage")
        let row = try XCTUnwrap(usage.first)
        XCTAssertEqual(row.dedupeKey, "qw:sess-qwen-1:p1:3588457252476097900")
        XCTAssertEqual(row.source, .qwenCode)
        XCTAssertEqual(row.sessionID, "sess-qwen-1")
        XCTAssertEqual(row.model, "qwen3-coder")
        XCTAssertEqual(row.tokens, TokenCounts(input: 800, output: 120))
        XCTAssertNil(row.cwd)
        XCTAssertNil(row.processID)
        let fromProtobuf = TelemetryUsage.records(from: try OTLPDecoder.decode(path: "/v1/logs",
                                                                              body: Fixture.data("qwen_logs.pb"),
                                                                              encoding: .protobuf))
        XCTAssertEqual(fromProtobuf, usage)
    }

    func testQwenCachedTokensAndThoughts() throws {
        let gemini = try XCTUnwrap(TelemetryUsage.record(qwen([
            "input_token_count": .int(1000), "cached_content_token_count": .int(600), "output_token_count": .int(50),
            "thoughts_token_count": .int(20), "total_token_count": .int(1070),
        ])))
        XCTAssertEqual(gemini.tokens, TokenCounts(input: 400, output: 70, reasoning: 20, cacheRead: 600),
                       "thoughts on top of the output are billed as output")
        let openAI = try XCTUnwrap(TelemetryUsage.record(qwen([
            "input_token_count": .int(1000), "cached_content_token_count": .int(600), "output_token_count": .int(50),
            "thoughts_token_count": .int(20), "total_token_count": .int(1050),
        ])))
        XCTAssertEqual(openAI.tokens, TokenCounts(input: 400, output: 50, reasoning: 20, cacheRead: 600),
                       "completions that already include reasoning are not counted twice")
    }

    func testCwdAndPidComeFromResourceAttributes() throws {
        let row = try XCTUnwrap(TelemetryUsage.record(qwen(["input_token_count": .int(10)], resource: [
            "hoply.cwd": .string("/Users/dev/Project/corestory"), "process.pid": .int(4242),
        ])))
        XCTAssertEqual(row.cwd, "/Users/dev/Project/corestory")
        XCTAssertEqual(row.processID, 4242)
        let blank = try XCTUnwrap(TelemetryUsage.record(qwen([:], resource: ["hoply.cwd": .string(""),
                                                                            "process.pid": .int(0)])))
        XCTAssertNil(blank.cwd)
        XCTAssertNil(blank.processID)
    }

    func testCopilotIDESpansAreKeyedByTraceAndSpan() throws {
        let json = TelemetryUsage.records(from: try OTLPDecoder.decode(path: "/v1/traces",
                                                                      body: Fixture.data("copilot_spans.json"),
                                                                      encoding: .json))
        let proto = TelemetryUsage.records(from: try OTLPDecoder.decode(path: "/v1/traces",
                                                                       body: Fixture.data("copilot_spans.pb"),
                                                                       encoding: .protobuf))
        XCTAssertEqual(json, proto)
        XCTAssertEqual(json.count, 1, "the tool span has no usage")
        let row = try XCTUnwrap(json.first)
        XCTAssertEqual(row.dedupeKey, "otel:3cabd6c553b33d8c33f2d6b9275ac68e:f73cc1dca94eaac6")
        XCTAssertEqual(row.source, .copilotIDE)
        XCTAssertEqual(row.sessionID, "conv-42")
        XCTAssertEqual(row.model, "gpt-5.1")
        XCTAssertEqual(row.tokens, TokenCounts(input: 1200, output: 340))
    }

    func testGenAICacheTokensComeOutOfTheInput() throws {
        let span = TelemetryRecord(signal: .span, name: "chat claude-sonnet-5", attributes: [
            "gen_ai.operation.name": .string("chat"), "gen_ai.conversation.id": .string("c1"),
            "gen_ai.request.model": .string("claude-sonnet-5"), "gen_ai.usage.input_tokens": .int(5000),
            "gen_ai.usage.cache_read.input_tokens": .int(4000), "gen_ai.usage.cache_creation.input_tokens": .int(900),
            "gen_ai.usage.output_tokens": .int(300), "gen_ai.usage.reasoning.output_tokens": .int(120),
        ], resource: ["service.name": .string("copilot-chat")], time: Date(timeIntervalSince1970: 1_794_228_000),
           traceID: "aa", spanID: "bb", timeUnixNano: 1_794_228_000_000_000_000)
        let row = try XCTUnwrap(TelemetryUsage.record(span))
        XCTAssertEqual(row.tokens, TokenCounts(input: 100, output: 300, reasoning: 120, cacheRead: 4000, cacheWrite5m: 900))
        XCTAssertEqual(row.dedupeKey, "otel:aa:bb")
    }

    func testOnlyTelemetryLedgerSourcesArePersisted() throws {
        let claude = try OTLPDecoder.decode(path: "/v1/logs", body: Fixture.data("claude_logs.pb"), encoding: .protobuf)
        XCTAssertTrue(TelemetryUsage.records(from: claude).isEmpty, "Claude Code's ledger is its transcripts")
        let cli = TelemetryRecord(signal: .span, name: "chat gpt-5.1", attributes: [
            "gen_ai.operation.name": .string("chat"), "gen_ai.usage.input_tokens": .int(10),
        ], resource: ["service.name": .string("github-copilot-cli")], time: Date(), traceID: "aa", spanID: "bb")
        XCTAssertNil(TelemetryUsage.record(cli), "Copilot CLI's ledger is its session store")
    }

    func testRecordsWithoutAStableIdentityAreSkipped() {
        XCTAssertNil(TelemetryUsage.record(qwen(["input_token_count": .int(10)], nanos: nil)))
        let request = TelemetryRecord(signal: .log, name: "qwen-code.api_request", attributes: ["session.id": .string("q1")],
                                      resource: ["service.name": .string("qwen-code")], time: Date(), timeUnixNano: 1)
        XCTAssertNil(TelemetryUsage.record(request))
    }

    func testLedgerBatchHasOneSessionUpdatePerSession() throws {
        let early = try XCTUnwrap(TelemetryUsage.record(qwen(["input_token_count": .int(10)], nanos: 1_794_228_000_000_000_000)))
        var late = try XCTUnwrap(TelemetryUsage.record(qwen(["input_token_count": .int(10)], nanos: 1_794_228_060_000_000_000)))
        late.cwd = "/Users/dev/Project/corestory"
        let batch = TelemetryUsage.ledgerBatch([late, early])
        XCTAssertEqual(batch.usage.count, 2)
        XCTAssertEqual(batch.sessions.count, 1)
        XCTAssertEqual(batch.sessions.first?.firstAt, early.timestamp)
        XCTAssertEqual(batch.sessions.first?.lastAt, late.timestamp)
        XCTAssertEqual(batch.sessions.first?.cwd, "/Users/dev/Project/corestory")
    }

    func testRouterReturnsUsageOnlyForTelemetryLedgers() throws {
        let router = HubRouter()
        func post(_ path: String, _ fixture: String) throws -> HubRouter.Outcome {
            router.handle(HTTPRequest(method: "POST", path: path, headers: ["content-type": "application/json"],
                                      body: try Fixture.data(fixture)))
        }
        let qwen = try post("/v1/logs", "qwen_logs.json")
        XCTAssertEqual(qwen.usage.map(\.dedupeKey), ["qw:sess-qwen-1:p1:3588457252476097900"])
        XCTAssertFalse(qwen.events.isEmpty, "live events are unchanged")
        XCTAssertEqual(try post("/v1/traces", "copilot_spans.json").usage.count, 1)
        XCTAssertTrue(try post("/v1/logs", "claude_logs.json").usage.isEmpty)
    }
}
