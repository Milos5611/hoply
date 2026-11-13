import AgentKit
import Foundation
import XCTest

/// Rows shaped like Copilot CLI's `session-store.db` (schema_version 7), with usage numbers from real events.
final class CopilotUsageMapperTests: XCTestCase {
    private let session = CopilotSession(id: "s1", cwd: "/Users/dev/Project/corestory", branch: "main",
                                         summary: "Build Event Reports Page", createdAt: "2026-09-17T11:18:17.432Z",
                                         updatedAt: "2026-09-17 17:39:52", turns: 2)

    private let miniDetails = #"[{"batchSize":1000000,"costPerBatch":67500000000,"tokenCount":264,"tokenType":"input"},{"batchSize":1000000,"costPerBatch":6750000000,"tokenCount":27136,"tokenType":"cache_read"},{"batchSize":1000000,"costPerBatch":0,"tokenCount":0,"tokenType":"cache_write"},{"batchSize":1000000,"costPerBatch":405000000000,"tokenCount":80,"tokenType":"output"}]"#

    private func miniEvent() -> CopilotUsageEvent {
        CopilotUsageEvent(id: 279, sessionID: "s1", turnIndex: 3, agentID: nil, model: "gpt-5.4-mini",
                          inputTokens: 27_400, outputTokens: 80, cacheReadTokens: 27_136, cacheWriteTokens: 0,
                          reasoningTokens: 0, totalNanoAIU: 233_388_000, requestMultiplier: 0.33,
                          tokenDetailsJSON: miniDetails, createdAt: "2026-09-17T17:45:32.462Z")
    }

    func testTokenDetailsGiveTheUncachedInputAndAIUGiveTheCost() throws {
        let record = try XCTUnwrap(CopilotUsageMapper.usage(miniEvent(), session: session))
        XCTAssertEqual(record.dedupeKey, "cp:s1:279:2026-09-17T17:45:32.462Z")
        XCTAssertEqual(record.source, .copilotCLI)
        XCTAssertEqual(record.sessionID, "s1")
        XCTAssertEqual(record.timestamp, Timestamps.parse("2026-09-17T17:45:32.462Z"))
        XCTAssertEqual(record.tokens, TokenCounts(input: 264, output: 80, cacheRead: 27_136))
        XCTAssertEqual(try XCTUnwrap(record.nativeCost), 0.233388, accuracy: 1e-12, "AIU = nano ÷ 1e9")
        XCTAssertEqual(try XCTUnwrap(record.nativeUSD), 0.00233388, accuracy: 1e-12, "1 AIU = $0.01")
        XCTAssertEqual(record.requestMultiplier, 0.33)
        XCTAssertEqual(record.turnIndex, 3)
        XCTAssertEqual(record.cwd, "/Users/dev/Project/corestory")
        XCTAssertEqual(record.gitBranch, "main")
        XCTAssertFalse(record.isSidechain)
    }

    func testWithoutDetailsCacheReadsAndWritesAreTakenOutOfTheInput() throws {
        // Real Opus 5 row: input_tokens 31468 = 2 uncached + 31418 cache read + 48 cache write.
        let event = CopilotUsageEvent(id: 1, sessionID: "s1", turnIndex: 0, agentID: "task-1", model: "claude-opus-5",
                                      inputTokens: 31_468, outputTokens: 167, cacheReadTokens: 31_418,
                                      cacheWriteTokens: 48, reasoningTokens: 51, totalNanoAIU: 2_019_400_000,
                                      requestMultiplier: 15, createdAt: "2026-09-11T08:51:30.185Z")
        let record = try XCTUnwrap(CopilotUsageMapper.usage(event, session: session))
        XCTAssertEqual(record.tokens, TokenCounts(input: 2, output: 167, reasoning: 51, cacheRead: 31_418,
                                                  cacheWrite5m: 48))
        XCTAssertTrue(record.isSidechain, "subagent calls carry an agent id")
        XCTAssertEqual(record.agentID, "task-1")
        let listPrice = PricingTable.bundled().price(model: "claude-opus-5", tokens: record.tokens, speed: nil)
        XCTAssertEqual(try XCTUnwrap(record.nativeUSD), try XCTUnwrap(listPrice.costUSD), accuracy: 1e-12,
                       "Copilot's own figure equals the API list price")
    }

    func testDottedClaudeIdsMatchTheBundledPrices() throws {
        // Real Haiku 4.5 row through Copilot: 369785000 nano-AIU.
        let event = CopilotUsageEvent(id: 100, sessionID: "s1", turnIndex: 3, model: "claude-haiku-4.5",
                                      inputTokens: 18_443, outputTokens: 221, cacheReadTokens: 17_791,
                                      cacheWriteTokens: 647, totalNanoAIU: 369_785_000, requestMultiplier: 0.33,
                                      createdAt: "2026-09-11T09:20:00.000Z")
        let record = try XCTUnwrap(CopilotUsageMapper.usage(event, session: session))
        let table = PricingTable.bundled()
        XCTAssertEqual(table.match("claude-haiku-4.5")?.id, "claude-haiku-4-5")
        let price = try XCTUnwrap(table.price(model: record.model, tokens: record.tokens, speed: nil).costUSD)
        XCTAssertEqual(price, try XCTUnwrap(record.nativeUSD), accuracy: 1e-12)
    }

    func testMissingAIULeavesPricingToTheTable() throws {
        var event = miniEvent()
        event.totalNanoAIU = nil
        event.tokenDetailsJSON = "not json"
        let record = try XCTUnwrap(CopilotUsageMapper.usage(event, session: nil))
        XCTAssertNil(record.nativeCost)
        XCTAssertNil(record.nativeUSD)
        XCTAssertEqual(record.tokens.input, 264, "falls back to input - cache read - cache write")
        XCTAssertNil(record.cwd)
    }

    func testBothTimestampFormatsParseAsUTC() {
        XCTAssertEqual(CopilotUsageMapper.date("2026-09-17 17:45:32"), CopilotUsageMapper.date("2026-09-17T17:45:32Z"))
        XCTAssertEqual(CopilotUsageMapper.date("2026-09-17 17:45:32")?.timeIntervalSince1970, 1_789_667_132)
        XCTAssertEqual(CopilotUsageMapper.date("2026-09-17T17:45:32.462Z")?.timeIntervalSince1970 ?? 0,
                       1_789_667_132.462, accuracy: 1e-6)
        XCTAssertNil(CopilotUsageMapper.date(""))
        XCTAssertNil(CopilotUsageMapper.date(nil))

        var event = miniEvent()
        event.createdAt = nil
        XCTAssertEqual(CopilotUsageMapper.usage(event, session: session)?.timestamp,
                       CopilotUsageMapper.date(session.createdAt), "falls back to the session's start")
        XCTAssertNil(CopilotUsageMapper.usage(event, session: nil), "a row needs some time")
    }

    func testSessionUpdate() throws {
        let usage = try XCTUnwrap(CopilotUsageMapper.usage(miniEvent(), session: session))
        let update = CopilotUsageMapper.sessionUpdate(session, usage: [usage])
        XCTAssertEqual(update.key, SessionKey(source: .copilotCLI, id: "s1"))
        XCTAssertEqual(update.firstAt, CopilotUsageMapper.date("2026-09-17T11:18:17.432Z"))
        XCTAssertEqual(update.lastAt, usage.timestamp, "the last call is later than updated_at")
        XCTAssertEqual(update.cwd, "/Users/dev/Project/corestory")
        XCTAssertEqual(update.branch, "main")
        XCTAssertTrue(update.placeIsAuthoritative)
        XCTAssertEqual(update.title, "Build Event Reports Page")
        XCTAssertEqual(update.titleRank, CopilotUsageMapper.titleRank)
        XCTAssertEqual(update.prompts, 2)
        XCTAssertTrue(update.resetsTurns, "the turn count is Copilot's own, so it replaces")

        XCTAssertNil(CopilotUsageMapper.title(""))
        XCTAssertNil(CopilotUsageMapper.title("   "))
        XCTAssertNil(CopilotUsageMapper.title("<current_datetime>2026</current_datetime>"))
        XCTAssertEqual(CopilotUsageMapper.title("Fix login\nmore detail"), "Fix login")
        let untitled = CopilotUsageMapper.sessionUpdate(CopilotSession(id: "s2", summary: ""))
        XCTAssertNil(untitled.title)
        XCTAssertEqual(untitled.titleRank, 0)
        XCTAssertFalse(untitled.placeIsAuthoritative)
    }

    func testBatchGroupsSessionsAndKeepsOrphanEvents() {
        var orphan = miniEvent()
        orphan.id = 280
        orphan.sessionID = "gone"
        let batch = CopilotUsageMapper.batch(events: [miniEvent(), orphan], sessions: ["s1": session])
        XCTAssertEqual(batch.usage.map(\.dedupeKey), ["cp:s1:279:2026-09-17T17:45:32.462Z",
                                                      "cp:gone:280:2026-09-17T17:45:32.462Z"])
        XCTAssertEqual(batch.sessions.map(\.key.id), ["gone", "s1"])
        XCTAssertEqual(batch.sessions.first?.firstAt, CopilotUsageMapper.date("2026-09-17T17:45:32.462Z"))
    }
}
