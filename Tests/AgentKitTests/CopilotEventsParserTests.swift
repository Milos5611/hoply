@testable import AgentKit
import Foundation
import XCTest

final class CopilotEventsParserTests: XCTestCase {
    static let session = "5e551011-0000-4000-8000-000000000001"
    static let path = "/Users/dev/.copilot/session-state/\(session)/events.jsonl"

    func lines(_ fixture: String) throws -> [Data] {
        JSONLines.complete(in: try Fixture.data(fixture)).lines
    }

    func workspace() throws -> CopilotWorkspace {
        CopilotWorkspace(yaml: try Fixture.text("copilot_workspace.yaml"))
    }

    func parse(_ lines: [Data], path: String = path, workspace: CopilotWorkspace? = nil)
        -> (LedgerBatch, CopilotEventsState) {
        var state = CopilotEventsState(path: path)
        let batch = CopilotEventsParser.batch(lines: lines, state: &state, workspace: workspace)
        return (batch, state)
    }

    func sum(_ usage: [UsageRecord]) -> TokenCounts {
        usage.reduce(TokenCounts()) { $0 + $1.tokens }
    }

    // The Store's rule: a turn's premium requests are the highest multiplier among its calls, booked once.
    func premiumRequests(_ usage: [UsageRecord]) -> Double {
        Dictionary(grouping: usage, by: \.turnIndex).values
            .reduce(0) { $0 + ($1.compactMap(\.requestMultiplier).max() ?? 0) }
    }

    func checkpoint(_ fixture: String) throws -> [String: Any] {
        let last = try lines(fixture).compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .last { $0["type"] as? String == "session.usage_checkpoint" }
        return try XCTUnwrap(last?["data"] as? [String: Any])
    }

    func line(_ type: String, _ data: String, at time: String = "2026-11-11T19:13:10.000Z", agentID: String? = nil,
              id: String = UUID().uuidString.lowercased()) -> Data {
        let agent = agentID.map { #","agentId":"\#($0)""# } ?? ""
        return Data(#"{"type":"\#(type)","data":\#(data)\#(agent),"id":"\#(id)","timestamp":"\#(time)","parentId":null}"#.utf8)
    }

    func usage(model: String = "claude-opus-5", input: Int = 1_000, cacheRead: Int = 900, output: Int = 50,
               cost: Double = 1, callID: String? = "call-1") -> String {
        let call = callID.map { #","apiCallId":"\#($0)""# } ?? ""
        return #"{"usage":{"model":"\#(model)","inputTokens":\#(input),"outputTokens":\#(output),"cacheReadTokens":\#(cacheRead),"cacheWriteTokens":0,"reasoningTokens":0,"cost":\#(cost)\#(call)}}"#
    }

    func testUsageMatchesCopilotsOwnCheckpoint() throws {
        let (batch, state) = parse(try lines("copilot_events.jsonl"), workspace: try workspace())
        XCTAssertEqual(batch.usage.count, 5)
        XCTAssertEqual(batch.origin, CopilotEventsParser.keyPrefix)
        XCTAssertEqual(sum(batch.usage), TokenCounts(input: 15, output: 1_372, reasoning: 735, cacheRead: 109_357,
                                                     cacheWrite5m: 81_044))
        XCTAssertEqual(batch.usage.map(\.model), ["gpt-6-luna", "gpt-6-luna", "gpt-6-luna", "gpt-6-astra", "gpt-6-astra"])
        XCTAssertEqual(batch.usage.map(\.turnIndex), [0, 0, 0, 1, 2], "a turn is a user message, not an assistant turn")
        XCTAssertEqual(batch.usage[0].tokens, TokenCounts(input: 3, output: 446, reasoning: 344, cacheRead: 0,
                                                          cacheWrite5m: 30_538))
        XCTAssertEqual(batch.usage[0].timestamp, Timestamps.parse("2026-11-11T19:13:17.259Z"))
        XCTAssertTrue(batch.usage.allSatisfy {
            $0.source == .copilotCLI && $0.sessionID == Self.session && !$0.isSidechain
                && $0.cwd == "/Users/dev/Project/demo" && $0.gitBranch == "main"
        })
        XCTAssertEqual(Set(batch.usage.map(\.dedupeKey)).count, 5)
        XCTAssertTrue(batch.usage.allSatisfy { $0.dedupeKey.hasPrefix("cpe:") && $0.dedupeKey.count == 20 },
                      "the ~500 character call id is hashed")

        let point = try checkpoint("copilot_events.jsonl")
        let nano = try XCTUnwrap(point["totalNanoAiu"] as? NSNumber).doubleValue
        XCTAssertEqual(batch.usage.compactMap(\.nativeUSD).reduce(0, +), nano / 1e11, accuracy: 1e-12)
        XCTAssertEqual(batch.usage.compactMap(\.nativeCost).reduce(0, +), nano / 1e9, accuracy: 1e-9)
        XCTAssertEqual(premiumRequests(batch.usage), try XCTUnwrap(point["totalPremiumRequests"] as? NSNumber).doubleValue)
        XCTAssertEqual(premiumRequests(batch.usage), 3)

        let session = try XCTUnwrap(batch.sessions.first)
        XCTAssertEqual(batch.sessions.count, 1)
        XCTAssertEqual(session.key, SessionKey(source: .copilotCLI, id: Self.session))
        XCTAssertEqual(session.cwd, "/Users/dev/Project/demo")
        XCTAssertEqual(session.branch, "main")
        XCTAssertTrue(session.placeIsAuthoritative)
        XCTAssertEqual(session.title, "Review demo setup")
        XCTAssertEqual(session.titleRank, CopilotUsageMapper.titleRank)
        XCTAssertEqual(session.prompts, 3)
        XCTAssertTrue(session.resetsTurns)
        XCTAssertNil(session.transcriptPath)
        XCTAssertEqual(session.firstAt, Timestamps.parse("2026-11-11T19:13:06.885Z"))
        XCTAssertEqual(session.lastAt, Timestamps.parse("2026-11-11T20:21:00.364Z"), "the shutdown line")

        XCTAssertEqual(state.model, "gpt-6-astra", "auto at start, then the calls' model, then the switch")
        XCTAssertEqual(state.turns, 3)
    }

    func testModelWithoutAICreditsIsUnpriced() throws {
        let path = "/Users/dev/.copilot/session-state/5e551011-0000-4000-8000-000000000002/events.jsonl"
        let (batch, state) = parse(try lines("copilot_events_kimi.jsonl"), path: path)
        XCTAssertEqual(batch.usage.count, 2)
        XCTAssertEqual(batch.usage.map(\.model), ["kimi-k3", "kimi-k3"])
        XCTAssertTrue(batch.usage.allSatisfy { $0.nativeUSD == nil && $0.nativeCost == nil })
        XCTAssertEqual(batch.usage[1].tokens, TokenCounts(input: 2_245, output: 892, reasoning: 610, cacheRead: 20_713),
                       "input tokens include cache reads")
        XCTAssertEqual(premiumRequests(batch.usage), 1, "two calls in one turn")
        XCTAssertEqual(premiumRequests(batch.usage),
                       try XCTUnwrap(checkpoint("copilot_events_kimi.jsonl")["totalPremiumRequests"] as? NSNumber).doubleValue)
        XCTAssertEqual(state.model, "kimi-k3")
        XCTAssertNil(batch.sessions.first?.title, "no workspace.yaml")
        XCTAssertEqual(batch.sessions.first?.cwd, "/Users/dev/Project/demo", "from session.start")
        XCTAssertEqual(ModelName.display("kimi-k3"), "Kimi K3")

        let priced = PricingTable.bundled().price(model: "kimi-k3", tokens: batch.usage[0].tokens, speed: nil)
        XCTAssertNil(priced.costUSD, "an unknown model stays unpriced, never $0")
    }

    func testStartAndModelChangesSetTheLiveModel() {
        var state = CopilotEventsState(path: Self.path)
        var batch = CopilotEventsParser.batch(lines: [
            line("session.start", #"{"sessionId":"\#(Self.session)","selectedModel":"kimi-k3","context":{"cwd":"/w","branch":"dev"}}"#),
        ], state: &state)
        XCTAssertEqual(state.model, "kimi-k3")
        XCTAssertEqual(state.cwd, "/w")
        XCTAssertTrue(batch.usage.isEmpty)
        XCTAssertTrue(batch.sessions.isEmpty, "no ledger session before the first call")

        batch = CopilotEventsParser.batch(lines: [
            line("session.model_change", #"{"previousModel":"kimi-k3","newModel":"claude-opus-5"}"#),
            line("session.model_change", #"{"previousModel":"claude-opus-5","newModel":"auto"}"#),
        ], state: &state)
        XCTAssertEqual(state.model, "claude-opus-5", "auto names no model")

        batch = CopilotEventsParser.batch(lines: [
            line("user.message", #"{"content":"x","interactionId":"i1"}"#),
            line("session.usage_record", usage(model: "gpt-6-luna")),
        ], state: &state)
        XCTAssertEqual(state.model, "gpt-6-luna", "auto resolves at the call")
        XCTAssertEqual(batch.sessions.first?.branch, "dev")
    }

    func testTextIsNeverKept() {
        let secret = "SECRET-TEXT-7f3a"
        var state = CopilotEventsState(path: Self.path)
        let batch = CopilotEventsParser.batch(lines: [
            line("session.start", #"{"selectedModel":"kimi-k3","context":{"cwd":"/w"}}"#),
            line("user.message", #"{"content":"\#(secret)","transformedContent":"\#(secret)","interactionId":"i1"}"#),
            line("hook.start", #"{"hookType":"userPromptSubmitted","input":{"prompt":"\#(secret)"}}"#),
            line("assistant.message", #"{"content":"\#(secret)","model":"kimi-k3","apiCallId":"call-1"}"#),
            line("tool.execution_complete", #"{"result":{"content":"\#(secret)"}}"#),
            line("session.usage_record", usage(model: "kimi-k3")),
        ], state: &state, workspace: CopilotWorkspace(cwd: "/w", name: "Title"))
        XCTAssertEqual(batch.usage.count, 1)
        XCTAssertFalse(String(describing: batch).contains(secret))
        XCTAssertFalse(String(describing: state).contains(secret))
    }

    func testPartialLastLineAndTailsMatchOneRead() throws {
        let fixture = try Fixture.data("copilot_events.jsonl")
        let record = try XCTUnwrap(JSONLines.complete(in: fixture).lines.last {
            $0.starts(with: Data(#"{"type":"session.usage_record""#.utf8))
        })
        let data = fixture + record.prefix(record.count / 2)
        let all = JSONLines.complete(in: data).lines
        XCTAssertEqual(all.count, 126, "a partial last line, still being written, is not read")
        let (whole, wholeState) = parse(all)
        XCTAssertEqual(whole.usage.count, 5)
        for split in [1, 40, 80, all.count - 1] {
            var state = CopilotEventsState(path: Self.path)
            let first = CopilotEventsParser.batch(lines: all[..<split], state: &state)
            let second = CopilotEventsParser.batch(lines: all[split...], state: &state)
            XCTAssertEqual(first.usage + second.usage, whole.usage, "split at \(split)")
            XCTAssertEqual(second.sessions.first?.prompts, whole.sessions.first?.prompts)
            XCTAssertEqual(state, wholeState)
        }

        var state = CopilotEventsState(path: Self.path)
        let cut = String(decoding: try XCTUnwrap(all.first { $0.starts(with: Data(#"{"type":"session.usage_record""#.utf8)) }),
                         as: UTF8.self).dropLast(40)
        XCTAssertTrue(CopilotEventsParser.batch(lines: [Data(cut.utf8)], state: &state).usage.isEmpty)
    }

    func testSubagentCallsAreSidechainsInTheParentsTurn() {
        let agent = "a9e00000-0000-4000-8000-000000000001"
        let (batch, state) = parse([
            line("user.message", #"{"content":"x","interactionId":"i1"}"#),
            line("session.usage_record", usage(model: "claude-opus-5", cost: 15, callID: "main-1")),
            line("user.message", #"{"content":"x"}"#, agentID: agent),
            line("session.usage_record", usage(model: "claude-haiku-4.5", cost: 0.33, callID: "sub-1"), agentID: agent),
        ])
        XCTAssertEqual(batch.usage.map(\.isSidechain), [false, true])
        XCTAssertEqual(batch.usage[1].agentID, agent)
        XCTAssertEqual(batch.usage.map(\.turnIndex), [0, 0])
        XCTAssertEqual(premiumRequests(batch.usage), 15)
        XCTAssertEqual(state.turns, 1, "a subagent's task message is not a prompt")
        XCTAssertEqual(state.model, "claude-opus-5", "the live model is the main agent's")
    }

    func testDedupeKeyFallsBackToTheLineID() {
        let (batch, _) = parse([
            line("session.usage_record", usage(callID: nil), id: "line-1"),
            line("session.usage_record", usage(callID: nil), id: ""),
        ])
        XCTAssertEqual(batch.usage.map(\.dedupeKey), ["cpe:\(Self.session):line-1"], "no stable identity, no row")
    }

    func testTypeNeedNotComeFirst() {
        let late = Data(#"{"data":{"usage":{"model":"kimi-k3","inputTokens":10,"outputTokens":2,"cacheReadTokens":0,"cacheWriteTokens":0,"cost":1,"apiCallId":"c"}},"id":"l","timestamp":"2026-11-11T19:13:10.000Z","type":"session.usage_record"}"#.utf8)
        let (batch, _) = parse([late])
        XCTAssertEqual(batch.usage.first?.tokens, TokenCounts(input: 10, output: 2))
    }

    func testWorkspaceYAML() throws {
        let workspace = try workspace()
        XCTAssertEqual(workspace.id, Self.session)
        XCTAssertEqual(workspace.cwd, "/Users/dev/Project/demo")
        XCTAssertEqual(workspace.gitRoot, "/Users/dev/Project/demo")
        XCTAssertEqual(workspace.branch, "main")
        XCTAssertEqual(workspace.clientName, "copilot-intellij")
        XCTAssertEqual(workspace.name, "Review demo setup")
        XCTAssertEqual(workspace.createdAt, "2026-11-11T19:13:06.885Z")

        let quoted = CopilotWorkspace(yaml: """
            name: "Fix: the \\"login\\" bug"
            branch: 'it''s'
            cwd: |
              /not/a/value
            client_name:
            """)
        XCTAssertEqual(quoted.name, #"Fix: the "login" bug"#)
        XCTAssertEqual(quoted.branch, "it's")
        XCTAssertNil(quoted.cwd)
        XCTAssertNil(quoted.clientName)
    }
}
