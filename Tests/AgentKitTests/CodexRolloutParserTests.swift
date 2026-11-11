@testable import AgentKit
import Foundation
import XCTest

final class CodexRolloutParserTests: XCTestCase {
    static let execPath = "/x/sessions/2026/07/20/rollout-2026-07-20T17-42-22-019c0000-0000-7000-8000-000000000001.jsonl"

    func lines(_ fixture: String) throws -> [Data] {
        JSONLines.complete(in: try Fixture.data(fixture)).lines
    }

    func parse(_ lines: [Data], path: String = execPath) -> (LedgerBatch, CodexRolloutState) {
        var state = CodexRolloutState(path: path)
        let batch = CodexRolloutParser.batch(lines: lines, state: &state, transcriptPath: path, startsAtFileStart: true)
        return (batch, state)
    }

    func sum(_ usage: [UsageRecord]) -> TokenCounts {
        usage.reduce(TokenCounts()) { $0 + $1.tokens }
    }

    func testExecRollout() throws {
        let (batch, state) = parse(try lines("codex_rollout_exec.jsonl"))
        XCTAssertEqual(batch.usage.count, 7)
        XCTAssertEqual(sum(batch.usage), TokenCounts(input: 11_931, output: 1_821, reasoning: 999, cacheRead: 107_264))
        XCTAssertEqual(Set(batch.usage.map(\.model)), ["gpt-5.6-terra"])
        XCTAssertEqual(batch.usage[0].tokens, TokenCounts(input: 3_134, output: 131, reasoning: 25, cacheRead: 10_496))
        XCTAssertEqual(batch.usage[0].timestamp, Timestamps.parse("2026-07-20T15:42:28.577Z"))
        XCTAssertTrue(batch.usage.allSatisfy { $0.source == .codexCLI && !$0.isSidechain && $0.agentID == nil })
        XCTAssertEqual(Set(batch.usage.map(\.dedupeKey)).count, 7)

        let session = try XCTUnwrap(batch.sessions.first)
        XCTAssertEqual(batch.sessions.count, 1)
        XCTAssertEqual(session.key, SessionKey(source: .codexCLI, id: "019c0000-0000-7000-8000-000000000001"))
        XCTAssertEqual(session.cwd, "/Users/dev/project")
        XCTAssertTrue(session.placeIsAuthoritative)
        XCTAssertEqual(session.prompts, 1)
        XCTAssertTrue(session.resetsTurns)
        XCTAssertEqual(session.transcriptPath, Self.execPath)
        XCTAssertEqual(session.firstAt, Timestamps.parse("2026-07-20T15:42:22.253Z"))
        XCTAssertEqual(session.lastAt, Timestamps.parse("2026-07-20T15:43:05.611Z"))
        XCTAssertEqual(state.total?.total, 121_016)
    }

    func testOlderRolloutSkipsRepeatedTotalsAndCountsUserMessages() throws {
        let all = try lines("codex_rollout_cli.jsonl")
        let counts = all.filter { String(decoding: $0, as: UTF8.self).contains(#""type":"token_count""#) }.count
        let (batch, _) = parse(all)
        XCTAssertEqual(counts, 56)
        XCTAssertEqual(batch.usage.count, 28)
        XCTAssertEqual(sum(batch.usage), TokenCounts(input: 102_335, output: 8_048, reasoning: 1_792, cacheRead: 922_112))
        XCTAssertEqual(Set(batch.usage.map(\.model)), ["gpt-5.2-codex"])
        XCTAssertEqual(batch.sessions.first?.branch, "main")
        XCTAssertEqual(batch.sessions.first?.prompts, 3)
    }

    func testTailAcrossChunksMatchesOneRead() throws {
        let all = try lines("codex_rollout_exec.jsonl")
        let (whole, _) = parse(all)
        for split in [1, 5, 20, all.count - 1] {
            var state = CodexRolloutState(path: Self.execPath)
            let first = CodexRolloutParser.batch(lines: all[..<split], state: &state, transcriptPath: Self.execPath,
                                                 startsAtFileStart: true)
            let second = CodexRolloutParser.batch(lines: all[split...], state: &state, transcriptPath: Self.execPath,
                                                  startsAtFileStart: false)
            XCTAssertEqual(first.usage + second.usage, whole.usage, "split at \(split)")
            XCTAssertEqual(second.sessions.first?.resetsTurns, false)
            XCTAssertEqual(second.sessions.first?.key, whole.sessions.first?.key)
        }
    }

    func testDroppedTotalStartsANewBase() {
        let lines = [
            Self.meta(id: "019c0000-0000-7000-8000-00000000000a"),
            Self.context(model: "gpt-6.1-sol"),
            Self.tokens(input: 1_000, cached: 400, output: 50, total: 1_050, at: "2026-11-10T10:00:01Z"),
            Self.tokens(input: 0, cached: 0, output: 0, total: 258_400, at: "2026-11-10T10:00:02Z"),
            Self.tokens(input: 2_000, cached: 0, output: 30, total: 260_430, at: "2026-11-10T10:00:03Z"),
            Self.nullInfo(at: "2026-11-10T10:00:04Z"),
        ]
        let (batch, _) = parse(lines.map { Data($0.utf8) })
        XCTAssertEqual(batch.usage.map(\.tokens), [TokenCounts(input: 600, output: 50, cacheRead: 400),
                                                    TokenCounts(input: 2_000, output: 30)])
        XCTAssertEqual(batch.usage.map(\.model), ["gpt-6.1-sol", "gpt-6.1-sol"])
    }

    func testForkCopiesLandOnTheParentsKeys() {
        let parentID = "019c0000-0000-7000-8000-00000000000b"
        let forkID = "019c0000-0000-7000-8000-00000000000c"
        let parentLines = [Self.meta(id: parentID), Self.context(model: "gpt-6.1-sol"),
                           Self.tokens(input: 500, cached: 0, output: 10, total: 510, at: "2026-11-10T10:00:01Z")]
        let forkLines = [Self.meta(id: forkID), Self.meta(id: parentID), Self.context(model: "gpt-6.1-sol"),
                         Self.tokens(input: 500, cached: 0, output: 10, total: 510, at: "2026-11-10T11:00:00Z"),
                         Self.tokens(input: 900, cached: 300, output: 20, total: 920, at: "2026-11-10T11:00:05Z")]
        let (parent, _) = parse(parentLines.map { Data($0.utf8) })
        let (fork, state) = parse(forkLines.map { Data($0.utf8) },
                                  path: "/x/sessions/2026/11/10/rollout-2026-11-10T12-00-00-\(forkID).jsonl")
        XCTAssertEqual(state.sessionID, forkID)
        XCTAssertEqual(fork.usage.first?.dedupeKey, parent.usage.first?.dedupeKey)
        XCTAssertEqual(fork.usage.count, 2)
        XCTAssertEqual(fork.usage[1].tokens, TokenCounts(input: 100, output: 10, cacheRead: 300))
        XCTAssertTrue(fork.usage.allSatisfy { $0.sessionID == forkID })
    }

    func testSubagentThreadBooksOnTheRootSession() {
        let root = "019c0000-0000-7000-8000-0000000000aa"
        let thread = "019c0000-0000-7000-8000-0000000000bb"
        let meta = #"{"timestamp":"2026-11-10T10:00:00.000Z","type":"session_meta","payload":{"id":"\#(thread)","session_id":"\#(root)","cwd":"/Users/dev/project","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\#(root)","depth":1}}}}}"#
        let lines = [meta, Self.context(model: "gpt-6-luna"),
                     #"{"timestamp":"2026-11-10T10:00:01.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
                     Self.tokens(input: 100, cached: 0, output: 5, total: 105, at: "2026-11-10T10:00:02Z")]
        let (batch, _) = parse(lines.map { Data($0.utf8) })
        let record = batch.usage.first
        XCTAssertEqual(record?.sessionID, root)
        XCTAssertEqual(record?.agentID, thread)
        XCTAssertEqual(record?.isSidechain, true)
        let session = batch.sessions.first
        XCTAssertEqual(session?.key.id, root)
        XCTAssertEqual(session?.prompts, 0)
        XCTAssertEqual(session?.resetsTurns, false)
        XCTAssertNil(session?.transcriptPath)
        XCTAssertEqual(session?.placeIsAuthoritative, false)
    }

    func testThreadIDFromPath() {
        XCTAssertEqual(CodexRolloutState.threadID(fromPath: Self.execPath), "019c0000-0000-7000-8000-000000000001")
        XCTAssertEqual(CodexRolloutState.threadID(
            fromPath: "/x/rollout-2026-11-10T12-00-00-019C0000-0000-7000-8000-00000000000C_019c0000-0000-7000-8000-0000000000ff.jsonl"),
                       "019c0000-0000-7000-8000-00000000000c")
        XCTAssertNil(CodexRolloutState.threadID(fromPath: "/x/history.jsonl"))
    }

    func testBulkyLinesAreSkippedBeforeDecoding() throws {
        let item = try XCTUnwrap(try lines("codex_rollout_exec.jsonl").first {
            String(decoding: $0, as: UTF8.self).contains(#""type":"response_item""#)
        })
        XCTAssertEqual(CodexRolloutParser.leadingType(item), "response_item")
    }

    static func meta(id: String) -> String {
        #"{"timestamp":"2026-11-10T10:00:00.000Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/Users/dev/project","source":"cli"}}"#
    }

    static func context(model: String) -> String {
        #"{"timestamp":"2026-11-10T10:00:00.500Z","type":"turn_context","payload":{"cwd":"/Users/dev/project","model":"\#(model)"}}"#
    }

    static func tokens(input: Int, cached: Int, output: Int, total: Int, at time: String) -> String {
        #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(total)},"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":0},"model_context_window":258400},"rate_limits":null}}"#
    }

    static func nullInfo(at time: String) -> String {
        #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}"#
    }
}
