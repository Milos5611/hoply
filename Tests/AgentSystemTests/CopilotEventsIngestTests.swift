import AgentKit
import AgentSystem
import Foundation
import XCTest

final class CopilotEventsIngestTests: XCTestCase {
    private let sessionID = "5e551011-0000-4000-8000-000000000001"
    private var key: SessionKey { SessionKey(source: .copilotCLI, id: sessionID) }
    private let allTime = DateInterval(start: .distantPast, end: .distantFuture)

    private func events(_ id: String) -> String { "copilot/session-state/\(id)/events.jsonl" }

    private func line(_ type: String, _ data: String, at time: String) -> String {
        #"{"type":"\#(type)","data":\#(data),"id":"\#(UUID().uuidString.lowercased())","timestamp":"\#(time)","parentId":null}"#
            + "\n"
    }

    private func start(_ id: String, model: String = "claude-opus-5", cwd: String) -> String {
        line("session.start", #"{"sessionId":"\#(id)","selectedModel":"\#(model)","context":{"cwd":"\#(cwd)","branch":"main"}}"#,
             at: "2026-11-11T19:00:00.000Z")
    }

    private func prompt(at time: String) -> String {
        line("user.message", #"{"content":"x","interactionId":"\#(UUID().uuidString.lowercased())"}"#, at: time)
    }

    // Opus 5 prices in AIU per 1M: 500 input, 50 cache read, 2500 output.
    private func call(_ id: String, input: Int, cacheRead: Int, output: Int, cost: Double = 15, at time: String) -> String {
        let nano = (input - cacheRead) * 500_000 + cacheRead * 50_000 + output * 2_500_000
        return line("session.usage_record", #"{"usage":{"model":"claude-opus-5","inputTokens":\#(input),"outputTokens":\#(output),"cacheReadTokens":\#(cacheRead),"cacheWriteTokens":0,"reasoningTokens":0,"cost":\#(cost),"apiCallId":"\#(id)","copilotUsage":{"tokenDetails":[],"totalNanoAiu":\#(nano)}}}"#,
                    at: time)
    }

    private func workspace(_ id: String, cwd: String, name: String) -> String {
        "id: \(id)\ncwd: \(cwd)\nbranch: main\nclient_name: copilot-intellij\nname: \(name)\nuser_named: false\n"
            + "created_at: 2026-11-11T19:00:00.000Z\nupdated_at: 2026-11-11T19:00:01.000Z\n"
    }

    private func makeLedger(_ directory: TempDirectory) throws -> Ledger {
        try directory.mkdir("copilot")
        return try Ledger(configuration: LedgerConfiguration(databasePath: directory.path("hoply.sqlite"),
                                                             claudeConfigDirectory: directory.path("claude"),
                                                             copilotHome: directory.path("copilot"),
                                                             pricingOverridesURL: nil, watchForChanges: false))
    }

    func testBackfillTailRelaunchAndReindex() async throws {
        let directory = try TempDirectory()
        let cwd = directory.path("demo")
        try directory.write("copilot/session-state/\(sessionID)/workspace.yaml",
                            workspace(sessionID, cwd: cwd, name: "Review demo setup"))
        try directory.write(events(sessionID), start(sessionID, cwd: cwd)
                            + prompt(at: "2026-11-11T19:00:05.000Z")
                            + call("c1", input: 1_000, cacheRead: 900, output: 50, at: "2026-11-11T19:00:09.000Z")
                            + call("c2", input: 1_200, cacheRead: 1_000, output: 60, at: "2026-11-11T19:00:15.000Z"))
        try directory.write("copilot/session-state/.session-operation-locks/events.jsonl",
                            call("stray", input: 9, cacheRead: 0, output: 9, at: "2026-11-11T19:00:00.000Z"))

        var ledger = try makeLedger(directory)
        await ledger.ingest.start()
        var summary = try await ledger.reader.session(key)
        XCTAssertEqual(summary?.totals.calls, 2)
        XCTAssertEqual(summary?.totals.tokens, TokenCounts(input: 300, output: 110, cacheRead: 1_900))
        XCTAssertEqual(summary?.totals.premiumRequests ?? 0, 15, accuracy: 1e-9, "two calls, one turn")
        XCTAssertEqual(summary?.totals.costUSD ?? 0, (300 * 500.0 + 1_900 * 50 + 110 * 2_500) / 1e6 / 100, accuracy: 1e-12)
        XCTAssertEqual(summary?.totals.hasUnpriced, false)
        XCTAssertEqual(summary?.title, "Review demo setup")
        XCTAssertEqual(summary?.turns, 1)
        XCTAssertEqual(summary?.cwd, cwd)
        var totals = try await ledger.reader.totalsBySource(in: allTime)[.copilotCLI]
        XCTAssertEqual(totals?.calls, 2, "a folder without a session id is not a session")
        var progress = await ledger.ingest.progress
        XCTAssertNil(progress.lastError)

        try directory.append(events(sessionID), prompt(at: "2026-11-11T19:01:00.000Z")
                             + call("c3", input: 1_500, cacheRead: 1_200, output: 70, at: "2026-11-11T19:01:05.000Z"))
        await ledger.pollCopilot(sessions: [sessionID])
        summary = try await ledger.reader.session(key)
        XCTAssertEqual(summary?.totals.calls, 3)
        XCTAssertEqual(summary?.totals.premiumRequests ?? 0, 30, accuracy: 1e-9)
        XCTAssertEqual(summary?.turns, 2)

        // A relaunch tails from the saved cursor: the turn count comes from the lines before it.
        await ledger.ingest.stop()
        ledger = try makeLedger(directory)
        await ledger.ingest.start()
        try directory.append(events(sessionID), prompt(at: "2026-11-11T19:02:00.000Z")
                             + call("c4", input: 1_600, cacheRead: 1_500, output: 20, at: "2026-11-11T19:02:05.000Z"))
        await ledger.ingest.tailTranscript(atPath: directory.path(events(sessionID)))
        summary = try await ledger.reader.session(key)
        XCTAssertEqual(summary?.totals.calls, 4)
        XCTAssertEqual(summary?.totals.premiumRequests ?? 0, 45, accuracy: 1e-9, "the new call is a new turn")
        XCTAssertEqual(summary?.turns, 3)
        let settled = summary?.totals

        await ledger.ingest.reindex()
        await ledger.ingest.rescan()
        summary = try await ledger.reader.session(key)
        XCTAssertEqual(summary?.totals, settled, "re-reading upserts the same rows")
        XCTAssertEqual(summary?.turns, 3)
        totals = try await ledger.reader.totalsBySource(in: allTime)[.copilotCLI]
        XCTAssertEqual(totals?.calls, 4)
        progress = await ledger.ingest.progress
        XCTAssertNil(progress.lastError)
    }

    func testStoreRowsKeepTheirSession() async throws {
        let directory = try TempDirectory()
        let cwd = directory.path("demo")
        let copilot = try CopilotDatabase(home: directory.path("copilot"))
        try copilot.session(sessionID, cwd: cwd, summary: "From the store")
        try copilot.turn(sessionID, 0)
        try copilot.event(sessionID, turn: 0, multiplier: 1, at: "2026-11-11T19:00:09.000Z")
        try copilot.event(sessionID, turn: 0, multiplier: 1, output: 50, at: "2026-11-11T19:00:15.000Z")
        let ledger = try makeLedger(directory)
        await ledger.ingest.start()
        let stored = try await ledger.reader.session(key)
        XCTAssertEqual(stored?.totals.calls, 2)

        let other = "5e551011-0000-4000-8000-000000000002"
        try directory.write("copilot/session-state/\(sessionID)/workspace.yaml",
                            workspace(sessionID, cwd: cwd, name: "From events"))
        try directory.write(events(sessionID), start(sessionID, cwd: cwd) + prompt(at: "2026-11-11T19:00:05.000Z")
                            + call("c1", input: 1_000, cacheRead: 900, output: 50, at: "2026-11-11T19:00:09.000Z")
                            + call("c2", input: 1_200, cacheRead: 1_000, output: 60, at: "2026-11-11T19:00:15.000Z")
                            + call("c3", input: 1_300, cacheRead: 1_100, output: 60, at: "2026-11-11T19:00:20.000Z"))
        try directory.write(events(other), start(other, cwd: cwd) + prompt(at: "2026-11-11T19:10:00.000Z")
                            + call("o1", input: 500, cacheRead: 0, output: 10, at: "2026-11-11T19:10:05.000Z"))
        await ledger.ingest.rescan()

        let summary = try await ledger.reader.session(key)
        XCTAssertEqual(summary?.totals, stored?.totals, "the store wrote this session first")
        XCTAssertEqual(summary?.title, "From the store")
        let newer = try await ledger.reader.session(SessionKey(source: .copilotCLI, id: other))
        XCTAssertEqual(newer?.totals.calls, 1, "the rule is per session")
        let totals = try await ledger.reader.totalsBySource(in: allTime)[.copilotCLI]
        XCTAssertEqual(totals?.calls, 3)
    }

    func testEventsRowsKeepTheirSession() async throws {
        let directory = try TempDirectory()
        let cwd = directory.path("demo")
        try directory.write("copilot/session-state/\(sessionID)/workspace.yaml",
                            workspace(sessionID, cwd: cwd, name: "From events"))
        try directory.write(events(sessionID), start(sessionID, cwd: cwd) + prompt(at: "2026-11-11T19:00:05.000Z")
                            + call("c1", input: 1_000, cacheRead: 900, output: 50, at: "2026-11-11T19:00:09.000Z")
                            + call("c2", input: 1_200, cacheRead: 1_000, output: 60, at: "2026-11-11T19:00:15.000Z"))
        let ledger = try makeLedger(directory)
        await ledger.ingest.start()
        let first = try await ledger.reader.session(key)
        XCTAssertEqual(first?.totals.calls, 2)
        var progress = await ledger.ingest.progress
        XCTAssertEqual(progress.copilot, .notFound)

        // The runtime may write the store when it closes the session.
        let copilot = try CopilotDatabase(home: directory.path("copilot"))
        try copilot.session(sessionID, cwd: cwd, summary: "From the store")
        try copilot.turn(sessionID, 0)
        try copilot.event(sessionID, turn: 0, multiplier: 15, at: "2026-11-11T19:00:09.000Z")
        try copilot.event(sessionID, turn: 0, multiplier: 15, output: 60, at: "2026-11-11T19:00:15.000Z")
        try copilot.session("older", cwd: cwd, summary: "Only in the store")
        try copilot.event("older", turn: 0, multiplier: 1, at: "2026-09-17T11:00:05.000Z")
        await ledger.pollCopilot()
        progress = await ledger.ingest.progress
        XCTAssertEqual(progress.copilot, .ready(schemaVersion: 7))

        let summary = try await ledger.reader.session(key)
        XCTAssertEqual(summary?.totals, first?.totals, "events.jsonl wrote this session first")
        XCTAssertEqual(summary?.title, "From events")
        let older = try await ledger.reader.session(SessionKey(source: .copilotCLI, id: "older"))
        XCTAssertEqual(older?.totals.calls, 1)

        await ledger.ingest.reindex()
        let again = try await ledger.reader.session(key)
        XCTAssertEqual(again?.totals, first?.totals, "a reindex keeps the first authority")
    }

    func testLiveModelReachesTheUpdatesStream() async throws {
        let directory = try TempDirectory()
        let ledger = try makeLedger(directory)
        await ledger.ingest.start()
        let key = key
        let collector = Task { () -> [String] in
            var models: [String] = []
            for await update in ledger.ingest.updates {
                if let model = update.models[key] { models.append(model) }
                if models.count == 2 { break }
            }
            return models
        }
        try directory.write(events(sessionID), start(sessionID, model: "kimi-k3", cwd: directory.path("demo")))
        await ledger.pollCopilot(sessions: [sessionID, "../escape", "unknown"])
        try directory.append(events(sessionID),
                             line("session.model_change", #"{"previousModel":"kimi-k3","newModel":"claude-opus-5"}"#,
                                  at: "2026-11-11T19:00:30.000Z"))
        await ledger.ingest.tailTranscript(atPath: directory.path(events(sessionID)))
        let models = await collector.value
        XCTAssertEqual(models, ["kimi-k3", "claude-opus-5"])
        let summary = try await ledger.reader.session(key)
        XCTAssertNil(summary, "no ledger session before the first call")
    }

    func testEventsPathShapes() throws {
        let directory = try TempDirectory()
        try directory.mkdir("copilot/session-state/\(sessionID)")
        try directory.mkdir("copilot/session-state/empty")
        try directory.write("copilot/session-state/\(sessionID)/events.jsonl", "")
        try directory.write("copilot/session-state/.session-operation-locks/events.jsonl", "")
        let ingester = CopilotEventsIngester(home: directory.path("copilot"))
        let state = ingester.sessionStateDirectory
        XCTAssertTrue(ingester.isEventsFile(state + "/\(sessionID)/events.jsonl"))
        XCTAssertFalse(ingester.isEventsFile(state + "/\(sessionID)/workspace.yaml"))
        XCTAssertFalse(ingester.isEventsFile(state + "/\(sessionID)/files/events.jsonl"))
        XCTAssertFalse(ingester.isEventsFile(state + "/.session-operation-locks/events.jsonl"))
        XCTAssertFalse(ingester.isEventsFile("/elsewhere/session-state/\(sessionID)/events.jsonl"))
        XCTAssertEqual(ingester.eventsPath(sessionID: sessionID), state + "/\(sessionID)/events.jsonl")
        XCTAssertNil(ingester.eventsPath(sessionID: ".."))
        XCTAssertNil(ingester.eventsPath(sessionID: "a/b"))
        XCTAssertEqual(ingester.discover().map(\.path), [state + "/\(sessionID)/events.jsonl"])
    }
}
