@testable import AgentKit
import XCTest

final class ClaudeTranscriptParserTests: XCTestCase {
    private let session = "11111111-1111-4111-8111-111111111111"

    private func batch() throws -> (ClaudeTranscriptBatch, lines: Int, consumed: Int, size: Int) {
        let data = try Fixture.data("claude_transcript.jsonl")
        let split = JSONLines.complete(in: data)
        return (ClaudeTranscriptParser.batch(from: split.lines), split.lines.count, split.consumed, data.count)
    }

    func testPartialLastLineIsLeftForTheNextRead() throws {
        let (_, lines, consumed, size) = try batch()
        XCTAssertEqual(lines, 26)
        XCTAssertLessThan(consumed, size)
        let rest = try Fixture.data("claude_transcript.jsonl").dropFirst(consumed)
        XCTAssertNil(rest.firstIndex(of: UInt8(ascii: "\n")))
        XCTAssertNil(ClaudeTranscriptParser.item(from: Data(rest)))
    }

    func testRepeatedContentBlocksMergeIntoOneCall() throws {
        let (batch, _, _, _) = try batch()
        let call = try XCTUnwrap(batch.usage.first { $0.dedupeKey == "cc:msg_A1:req_A1" })
        XCTAssertEqual(call.tokens, TokenCounts(input: 2, output: 616, reasoning: 508, cacheRead: 38775,
                                                cacheWrite5m: 0, cacheWrite1h: 19911))
        XCTAssertEqual(call.timestamp, Timestamps.parse("2026-11-09T14:00:05.000Z"))
        XCTAssertEqual(call.model, "claude-opus-5-5")
        XCTAssertEqual(call.speed, "standard")
        XCTAssertEqual(call.cwd, "/Users/dev/Project/demo")
        XCTAssertFalse(call.isSidechain)
        XCTAssertEqual(batch.usage.filter { $0.dedupeKey == "cc:msg_A1:req_A1" }.count, 1)
    }

    func testSidechainSyntheticAndLocalModelRows() throws {
        let (batch, _, _, _) = try batch()
        XCTAssertEqual(batch.usage.map(\.dedupeKey),
                       ["cc:msg_A1:req_A1", "cc:msg_B1:req_B1", "cc:msg_98857eaddd4a8931eba5a64ad60100e0:", "cc:msg_A2:req_A2"])

        let subagent = batch.usage[1]
        XCTAssertTrue(subagent.isSidechain)
        XCTAssertEqual(subagent.agentID, "a1b2c3")
        XCTAssertEqual(subagent.tokens.cacheWrite5m, 4990)
        XCTAssertEqual(subagent.tokens.cacheWrite1h, 0)

        let qwen = batch.usage[2]
        XCTAssertEqual(qwen.model, "Qwen3.8-Flash-Next")
        XCTAssertEqual(qwen.tokens.output, 30)
        XCTAssertEqual(qwen.tokens.cacheRead, 6957)

        XCTAssertFalse(batch.usage.contains { $0.model == "<synthetic>" })
    }

    func testSessionFactsTitlePromptsAndCostState() throws {
        let (batch, _, _, _) = try batch()
        let facts = try XCTUnwrap(batch.sessions[session])
        XCTAssertEqual(facts.title, "Login test fix", "a custom title outranks later AI titles")
        XCTAssertEqual(facts.titleKind, .custom)
        XCTAssertEqual(facts.prompts, 2, "typed prompts only: not tool results, meta, task notifications, subagents or commands")
        XCTAssertEqual(facts.prURL, "https://github.com/dev/demo/pull/42")
        XCTAssertEqual(facts.gitBranch, "feature/login")
        XCTAssertEqual(facts.cwd, "/Users/dev/Project/demo")
        XCTAssertEqual(facts.firstAt, Timestamps.parse("2026-11-09T14:00:00.000Z"))
        XCTAssertEqual(facts.lastAt, Timestamps.parse("2026-11-09T14:04:00.000Z"))

        let cost = try XCTUnwrap(facts.costState)
        XCTAssertEqual(cost.totalCostUSD, 0.248821, accuracy: 1e-9)
        XCTAssertEqual(cost.linesAdded, 12)
        XCTAssertEqual(cost.linesRemoved, 3)
        let opus = try XCTUnwrap(cost.models["claude-opus-5-5"])
        XCTAssertEqual(opus.tokens.cacheWrite5m + opus.tokens.cacheWrite1h, 22041)
        XCTAssertFalse(opus.cacheSplitKnown)
    }

    func testBulkyLinesAreSkippedBeforeDecoding() {
        XCTAssertEqual(ClaudeTranscriptParser.leadingType(Data(#"{"type":"api-request-blob","x":1}"#.utf8)), "api-request-blob")
        XCTAssertTrue(ClaudeTranscriptParser.isSkipped("api-request-blob"))
        XCTAssertTrue(ClaudeTranscriptParser.isSkipped("file-history-delta"))
        XCTAssertTrue(ClaudeTranscriptParser.isSkipped("last-prompt"))
        XCTAssertFalse(ClaudeTranscriptParser.isSkipped("cost-state"))
        XCTAssertFalse(ClaudeTranscriptParser.isSkipped("assistant"), "a reordered assistant line must still be decoded")
        XCTAssertNil(ClaudeTranscriptParser.leadingType(Data(#"{"parentUuid":null}"#.utf8)))
        XCTAssertNil(ClaudeTranscriptParser.item(from: Data(#"{"type":"api-request-blob","sessionId":"s","message":"#.utf8)))
    }

    func testAssistantLineWithTypeFirstStillCounts() {
        let line = #"{"type":"assistant","sessionId":"s","timestamp":"2026-11-09T14:00:00Z","requestId":"r","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        guard case .usage(let record)? = ClaudeTranscriptParser.item(from: Data(line.utf8)) else {
            return XCTFail("expected a usage item")
        }
        XCTAssertEqual(record.dedupeKey, "cc:m:r")
        XCTAssertEqual(record.tokens.output, 2)
    }

    func testCacheWritesWithoutSplitCountAsFiveMinutes() {
        let line = #"{"parentUuid":null,"type":"assistant","sessionId":"s","timestamp":"2026-11-09T14:00:00Z","requestId":"r","message":{"id":"m","model":"claude-opus-4-6","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":900,"cache_read_input_tokens":0}}}"#
        guard case .usage(let record)? = ClaudeTranscriptParser.item(from: Data(line.utf8)) else {
            return XCTFail("expected a usage item")
        }
        XCTAssertEqual(record.tokens.cacheWrite5m, 900)
        XCTAssertEqual(record.tokens.cacheWrite1h, 0)
    }

    func testMalformedAndWronglyTypedLinesAreLenient() {
        XCTAssertNil(ClaudeTranscriptParser.item(from: Data(#"{"parentUuid":"broken","#.utf8)))
        XCTAssertNil(ClaudeTranscriptParser.item(from: Data("not json".utf8)))
        let wrongTypes = #"{"parentUuid":null,"isSidechain":"no","agentId":7,"type":"assistant","sessionId":"s","timestamp":"2026-11-09T14:00:00Z","requestId":"r","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":"many","output_tokens":5}}}"#
        guard case .usage(let record)? = ClaudeTranscriptParser.item(from: Data(wrongTypes.utf8)) else {
            return XCTFail("a wrongly typed field must not drop the line")
        }
        XCTAssertEqual(record.tokens.input, 0)
        XCTAssertEqual(record.tokens.output, 5)
        XCTAssertFalse(record.isSidechain)
        XCTAssertNil(record.agentID)
    }

    func testLedgerBatchForMainAndSubagentFiles() throws {
        let (batch, _, _, _) = try batch()
        let mainPath = "/Users/dev/.claude/projects/-Users-dev-Project-demo/\(session).jsonl"
        let main = batch.ledgerBatch(transcriptPath: mainPath, startsAtFileStart: true)
        let update = try XCTUnwrap(main.sessions.first)
        XCTAssertEqual(update.key, SessionKey(source: .claudeCode, id: session))
        XCTAssertEqual(update.transcriptPath, mainPath)
        XCTAssertTrue(update.resetsTurns)
        XCTAssertTrue(update.placeIsAuthoritative)
        XCTAssertEqual(update.titleRank, ClaudeTitleKind.custom.rawValue)
        XCTAssertEqual(update.nativeCostUSD ?? 0, 0.248821, accuracy: 1e-9)
        XCTAssertEqual(main.usage.count, 4)

        let subagentPath = "/Users/dev/.claude/projects/-Users-dev-Project-demo/\(session)/subagents/agent-a1b2c3.jsonl"
        let subagent = batch.ledgerBatch(transcriptPath: subagentPath, startsAtFileStart: true).sessions.first
        XCTAssertNil(subagent?.transcriptPath)
        XCTAssertEqual(subagent?.resetsTurns, false, "a subagent file must never reset the parent's turn count")
        XCTAssertEqual(subagent?.placeIsAuthoritative, false)

        let tail = batch.ledgerBatch(transcriptPath: mainPath, startsAtFileStart: false).sessions.first
        XCTAssertEqual(tail?.resetsTurns, false)
    }
}

final class TimestampsTests: XCTestCase {
    func testFastPathMatchesFoundation() throws {
        let reference = ISO8601DateFormatter()
        reference.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for text in ["2026-11-09T14:41:50.835Z", "2026-02-28T23:59:59.999Z", "2024-02-29T00:00:00.000Z",
                     "1999-12-31T23:59:59.500+02:00", "2026-11-09T14:41:50.835-0530"] {
            let fast = try XCTUnwrap(Timestamps.epochSeconds(text), text)
            let expected = try XCTUnwrap(reference.date(from: text), text).timeIntervalSince1970
            XCTAssertEqual(fast, expected, accuracy: 0.0005, text)
        }
        XCTAssertEqual(Timestamps.parse("2026-11-13T08:00:00Z")?.timeIntervalSince1970, 1_794_556_800)
    }

    func testLongFractionsAndOtherShapes() {
        XCTAssertEqual(Timestamps.parse("2026-11-09T15:40:00.123456+00:00")?.timeIntervalSince1970 ?? 0,
                       1_794_238_800.123456, accuracy: 1e-5)
        XCTAssertEqual(Timestamps.date(NSNumber(value: 1_794_643_200)), Date(timeIntervalSince1970: 1_794_643_200))
        XCTAssertEqual(Timestamps.date(NSNumber(value: 1_794_643_200_000)), Date(timeIntervalSince1970: 1_794_643_200))
        XCTAssertNil(Timestamps.parse("yesterday"))
        XCTAssertNil(Timestamps.parse("2026-13-09T14:41:50Z"))
        XCTAssertNil(Timestamps.date(nil))
    }

    func testAdvisorIterationsAreTheirOwnRowsUnderTheirModel() throws {
        func line(output: Int) -> Data {
            Data(#"{"parentUuid":null,"isSidechain":false,"message":{"model":"claude-sonnet-5","id":"msg_1","type":"message","role":"assistant","content":[],"usage":{"input_tokens":10,"cache_read_input_tokens":1000,"output_tokens":\#(output),"speed":"standard","iterations":[{"type":"message","input_tokens":10,"cache_read_input_tokens":1000,"output_tokens":40},{"type":"advisor_message","model":"claude-opus-5-5","input_tokens":800,"cache_read_input_tokens":200,"cache_creation_input_tokens":50,"output_tokens":300},{"type":"message","input_tokens":10,"output_tokens":60},{"type":"advisor_message","input_tokens":5,"output_tokens":5}]}},"requestId":"req_1","type":"assistant","timestamp":"2026-11-09T10:00:05.000Z","cwd":"/Users/dev/Project/demo","sessionId":"s1","gitBranch":"main"}"#.utf8)
        }
        let batch = ClaudeTranscriptParser.batch(from: [line(output: 40), line(output: 100)])
        XCTAssertEqual(batch.usage.map(\.dedupeKey), ["cc:msg_1:req_1", "cc:msg_1:req_1:advisor:1"])
        XCTAssertEqual(batch.usage[0].model, "claude-sonnet-5")
        XCTAssertEqual(batch.usage[0].tokens, TokenCounts(input: 10, output: 100, cacheRead: 1000))
        XCTAssertEqual(batch.usage[1].model, "claude-opus-5-5")
        XCTAssertEqual(batch.usage[1].tokens, TokenCounts(input: 800, output: 300, cacheRead: 200, cacheWrite5m: 50))
        XCTAssertEqual(batch.usage[1].sessionID, "s1")
        guard case .usage(let first)? = ClaudeTranscriptParser.item(from: line(output: 40)) else { return XCTFail() }
        XCTAssertEqual(first.dedupeKey, "cc:msg_1:req_1")
    }
}
