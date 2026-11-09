import AgentKit
import AgentSystem
import Foundation
import XCTest

final class IngestCoordinatorTests: XCTestCase {
    private let sessionID = "22222222-2222-4222-8222-222222222222"
    private var key: SessionKey { SessionKey(source: .claudeCode, id: sessionID) }
    private var mainFile: String { "claude/projects/-Users-dev-Project-demo/\(sessionID).jsonl" }
    private var subagentFile: String { "claude/projects/-Users-dev-Project-demo/\(sessionID)/subagents/agent-a1.jsonl" }

    private func prompt(_ id: String, at time: String) -> String {
        #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"x"},"uuid":"\#(id)","timestamp":"\#(time)","origin":{"kind":"human"},"cwd":"/Users/dev/Project/demo","sessionId":"\#(sessionID)","gitBranch":"main"}"# + "\n"
    }

    private func assistant(_ message: String, output: Int, at time: String, sidechain: Bool = false) -> String {
        let agent = sidechain ? #","agentId":"a1""# : ""
        return #"{"parentUuid":null,"isSidechain":\#(sidechain)\#(agent),"message":{"model":"claude-opus-5-5","id":"\#(message)","type":"message","role":"assistant","content":[],"usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":\#(output),"cache_creation":{"ephemeral_1h_input_tokens":100,"ephemeral_5m_input_tokens":0},"speed":"standard"}},"requestId":"req_\#(message)","type":"assistant","timestamp":"\#(time)","cwd":"/Users/dev/Project/demo","sessionId":"\#(sessionID)","gitBranch":"main"}"# + "\n"
    }

    private func makeLedger(_ directory: TempDirectory, watch: Bool = false) throws -> Ledger {
        try Ledger(configuration: LedgerConfiguration(databasePath: directory.path("hoply.sqlite"),
                                                      claudeConfigDirectory: directory.path("claude"),
                                                      copilotHome: directory.path("copilot"),
                                                      pricingOverridesURL: nil, watchForChanges: watch))
    }

    private func seed(_ directory: TempDirectory) throws {
        try directory.write(mainFile, #"{"type":"ai-title","aiTitle":"Demo","sessionId":"\#(sessionID)"}"# + "\n"
                            + prompt("u1", at: "2026-11-09T10:00:00.000Z")
                            + assistant("m1", output: 10, at: "2026-11-09T10:00:05.000Z")
                            + assistant("m1", output: 400, at: "2026-11-09T10:00:06.000Z"))
        try directory.write(subagentFile, assistant("m2", output: 50, at: "2026-11-09T10:00:07.000Z", sidechain: true))
        try directory.write("claude/projects/-Users-dev-Project-demo/\(sessionID)/tool-results/x.txt", "not a transcript\n")
    }

    func testBackfillTailAndReindex() async throws {
        let directory = try TempDirectory()
        try seed(directory)
        let ledger = try makeLedger(directory)
        await ledger.ingest.start()

        let progress = await ledger.ingest.progress
        XCTAssertEqual(progress.filesTotal, 2)
        XCTAssertEqual(progress.filesDone, 2)
        XCTAssertEqual(progress.bytesDone, progress.bytesTotal)
        XCTAssertFalse(progress.isBackfilling)
        XCTAssertNil(progress.lastError)

        var summary = try await ledger.reader.session(key)
        XCTAssertEqual(summary?.totals.calls, 2)
        XCTAssertEqual(summary?.totals.tokens.output, 450)
        XCTAssertEqual(summary?.turns, 1)
        XCTAssertEqual(summary?.title, "Demo")
        XCTAssertEqual(summary?.transcriptPath?.hasSuffix(mainFile), true)
        let backfilled = summary?.totals

        await ledger.ingest.reindex()
        summary = try await ledger.reader.session(key)
        XCTAssertEqual(summary?.totals, backfilled, "ingesting twice gives the same totals")
        XCTAssertEqual(summary?.turns, 1)

        try directory.append(mainFile, prompt("u2", at: "2026-11-09T10:05:00.000Z")
                             + assistant("m3", output: 70, at: "2026-11-09T10:05:04.000Z"))
        await ledger.ingest.tailTranscript(atPath: directory.path(mainFile))
        summary = try await ledger.reader.session(key)
        XCTAssertEqual(summary?.totals.calls, 3)
        XCTAssertEqual(summary?.turns, 2)

        await ledger.ingest.rescan()
        let afterRescan = try await ledger.reader.session(key)
        XCTAssertEqual(afterRescan?.totals, summary?.totals, "an unchanged tree reads nothing")
    }

    func testUpdatesReportChangedSessions() async throws {
        let directory = try TempDirectory()
        try seed(directory)
        let ledger = try makeLedger(directory)
        let collector = Task { () -> [IngestUpdate] in
            var seen: [IngestUpdate] = []
            for await update in ledger.ingest.updates {
                seen.append(update)
                if !update.progress.isBackfilling, update.progress.filesDone == 2 { break }
            }
            return seen
        }
        await ledger.ingest.start()
        let updates = await collector.value
        XCTAssertTrue(updates.first?.progress.isBackfilling ?? false)
        XCTAssertTrue(updates.contains { $0.changedSessions.contains(key) })
        XCTAssertEqual(updates.last?.progress.fraction, 1)
    }

    func testFileSystemEventsTriggerATail() async throws {
        let directory = try TempDirectory()
        try seed(directory)
        let ledger = try makeLedger(directory, watch: true)
        await ledger.ingest.start()
        try directory.append(mainFile, assistant("m9", output: 5, at: "2026-11-09T10:09:00.000Z"))
        var calls = 0
        for _ in 0..<100 {
            calls = try await ledger.reader.session(key)?.totals.calls ?? 0
            if calls == 3 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(calls, 3)
        await ledger.ingest.stop()
    }

    private struct LedgerState: Equatable {
        var bySource: [AgentSource: LedgerTotals]
        var sessions: [SessionKey: LedgerTotals]
        var turns: [SessionKey: Int]
        var cursors: [String: FileCursor]
    }

    private func state(_ store: Store, _ reader: StoreReader) async throws -> LedgerState {
        let all = DateInterval(start: .distantPast, end: .distantFuture)
        let page = try await reader.sessions(in: all, limit: 1_000)
        return LedgerState(bySource: try await reader.totalsBySource(in: all),
                           sessions: Dictionary(uniqueKeysWithValues: page.sessions.map { ($0.key, $0.totals) }),
                           turns: Dictionary(uniqueKeysWithValues: page.sessions.map { ($0.key, $0.turns) }),
                           cursors: try await store.cursors(source: .claudeCode))
    }

    /// 16 sessions of 8 turns × 10 calls (about 60 KB each), read in 4 KB batches.
    private func seedMany(_ directory: TempDirectory) throws -> Int {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let base = Date(timeIntervalSince1970: 1_793_000_000)
        for file in 0..<16 {
            let session = String(format: "33333333-3333-4333-8333-%012d", file)
            var text = ""
            for turn in 0..<8 {
                let start = base.addingTimeInterval(Double(file * 3_600 + turn * 120))
                text += #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"x"},"uuid":"u\#(file)-\#(turn)","timestamp":"\#(formatter.string(from: start))","origin":{"kind":"human"},"cwd":"/Users/dev/Project/demo","sessionId":"\#(session)","gitBranch":"main"}"# + "\n"
                for call in 0..<10 {
                    let message = "m\(file)-\(turn)-\(call)"
                    text += #"{"parentUuid":null,"isSidechain":false,"message":{"model":"claude-opus-5-5","id":"\#(message)","type":"message","role":"assistant","content":[],"usage":{"input_tokens":\#(call + 1),"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":\#(10 * turn + call),"cache_creation":{"ephemeral_1h_input_tokens":100,"ephemeral_5m_input_tokens":0},"speed":"standard"}},"requestId":"req_\#(message)","type":"assistant","timestamp":"\#(formatter.string(from: start.addingTimeInterval(Double(call + 1))))","cwd":"/Users/dev/Project/demo","sessionId":"\#(session)","gitBranch":"main"}"# + "\n"
                }
            }
            try directory.write("claude/projects/-Users-dev-Project-demo/\(session).jsonl", text)
        }
        return 16
    }

    func testStopCancelsBackfillAndAFreshStartResumes() async throws {
        let directory = try TempDirectory()
        let files = try seedMany(directory)
        let claude = ClaudeTranscriptIngester(configDirectory: directory.path("claude"))
        func coordinator(_ store: Store) -> IngestCoordinator {
            IngestCoordinator(store: store, claude: claude, watch: false, chunkBytes: 4_096)
        }

        let referenceStore = try Store(path: directory.path("reference.sqlite"))
        await coordinator(referenceStore).start()
        let expected = try await state(referenceStore, StoreReader(path: directory.path("reference.sqlite")))
        XCTAssertEqual(expected.sessions.count, files)
        XCTAssertEqual(expected.bySource[.claudeCode]?.calls, files * 80)

        let store = try Store(path: directory.path("hoply.sqlite"))
        let reader = try StoreReader(path: directory.path("hoply.sqlite"))
        let first = coordinator(store)
        let run = Task { await first.start() }
        while await first.progress.bytesDone == 0 { await Task.yield() }
        await first.stop()
        let atStop = try await state(store, reader)
        await run.value
        await first.rescan()
        await first.tailTranscript(atPath: atStop.cursors.keys.first ?? "")
        await first.reindex()
        try await Task.sleep(for: .milliseconds(200))
        let afterStop = try await state(store, reader)
        XCTAssertEqual(afterStop, atStop, "nothing is written once stop() returns")

        let stopped = await first.progress
        XCTAssertFalse(stopped.isBackfilling)
        XCTAssertLessThan(stopped.filesDone, files, "stopped mid-way")
        XCTAssertLessThan(atStop.bySource[.claudeCode]?.calls ?? 0, files * 80)
        XCTAssertTrue(atStop.cursors.contains { path, cursor in cursor.offset < FileTailer.status(of: path)?.size ?? 0 },
                      "a file was left half-read")

        let second = coordinator(store)
        await second.start()
        let resumed = await second.progress
        XCTAssertEqual(resumed.filesDone, resumed.filesTotal)
        XCTAssertEqual(resumed.bytesDone, resumed.bytesTotal)
        XCTAssertNil(resumed.lastError)
        let final = try await state(store, reader)
        XCTAssertEqual(final.bySource, expected.bySource)
        XCTAssertEqual(final.sessions, expected.sessions)
        XCTAssertEqual(final.turns, expected.turns)
        XCTAssertEqual(final.cursors.count, files)
        for (path, cursor) in final.cursors {
            XCTAssertEqual(cursor.offset, FileTailer.status(of: path)?.size, "\(path) read to the end")
        }
    }

    func testTranscriptPathShapes() throws {
        let directory = try TempDirectory()
        try directory.mkdir("claude/projects")
        let ingester = ClaudeTranscriptIngester(configDirectory: directory.path("claude"))
        let projects = ingester.projectsDirectory
        XCTAssertTrue(ingester.isTranscript("\(projects)/-a/\(sessionID).jsonl"))
        XCTAssertTrue(ingester.isTranscript("\(projects)/-a/\(sessionID)/subagents/agent-x.jsonl"))
        XCTAssertFalse(ingester.isTranscript("\(projects)/-a/\(sessionID)/tool-results/x.jsonl"))
        XCTAssertFalse(ingester.isTranscript("\(projects)/-a/\(sessionID).json"))
        XCTAssertFalse(ingester.isTranscript("/elsewhere/-a/\(sessionID).jsonl"))
        XCTAssertTrue(ingester.discover().isEmpty)
    }
}
