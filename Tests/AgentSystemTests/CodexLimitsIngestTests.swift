import AgentKit
import AgentSystem
import Foundation
import XCTest

final class CodexLimitSamplesStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_200_400)
    private let allTime = DateInterval(start: .distantPast, end: .distantFuture)
    private let kind = LimitKind.codex(windowMinutes: 300)!

    private func open(_ directory: TempDirectory) throws -> (Store, StoreReader) {
        let path = directory.path("hoply.sqlite")
        return (try Store(path: path, resolver: ProjectResolver(home: "/Users/dev")), try StoreReader(path: path))
    }

    private func reading(_ utilization: Double, at seconds: TimeInterval, plan: String? = "plus") -> LimitSample {
        LimitSample(kind: kind, ts: t0.addingTimeInterval(seconds), utilization: utilization,
                    resetsAt: t0.addingTimeInterval(5 * 3600), plan: plan)
    }

    private var readings: [LimitSample] {
        stride(from: 0.0, to: 7200, by: 60).map { reading($0 < 3600 ? 40 : 41, at: $0) }
    }

    func testAnyArrivalOrderStoresAboutOneRowPerChangeOrQuarterHour() async throws {
        for (name, order) in [("in order", readings), ("newest first", Array(readings.reversed())),
                              ("shuffled", readings.shuffled())] {
            let (store, reader) = try open(try TempDirectory())
            for chunk in stride(from: 0, to: order.count, by: 7) {
                try await store.recordLimitSamples(Array(order[chunk..<min(chunk + 7, order.count)]))
            }
            let stored = try await reader.limitSamples(in: allTime)
            XCTAssertLessThanOrEqual(stored.count, 12, name)
            XCTAssertGreaterThanOrEqual(stored.count, 4, name)
            XCTAssertEqual(Set(stored.map(\.utilization)), [40, 41], name)
            XCTAssertTrue(stored.allSatisfy { $0.plan == "plus" }, name)
            for (earlier, later) in zip(stored, stored.dropFirst()) where earlier.isSameReading(as: later) {
                XCTAssertGreaterThanOrEqual(later.ts.timeIntervalSince(earlier.ts), Store.limitSampleInterval, name)
            }
            let newest = try XCTUnwrap(stored.last)
            XCTAssertGreaterThanOrEqual(newest.ts, t0.addingTimeInterval(7140 - Store.limitSampleInterval),
                                        "\(name): the newest row lags the newest reading by under 15 minutes")

            try await store.recordLimitSamples(order)
            try await store.recordLimitSamples(readings.reversed())
            let again = try await reader.limitSamples(in: allTime)
            XCTAssertEqual(again, stored, "\(name): ingesting again adds nothing")
        }
    }

    func testAChangedReadingAtTheSameInstantReplacesIt() async throws {
        let (store, reader) = try open(try TempDirectory())
        try await store.recordLimitSamples([reading(40, at: 0, plan: "free")])
        try await store.recordLimitSamples([reading(42, at: 0, plan: "plus")])
        let stored = try await reader.limitSamples(in: allTime)
        XCTAssertEqual(stored, [reading(42, at: 0, plan: "plus")])
    }

    func testCommitWritesTheBatchesReadingsAndReturnsWhatCameBefore() async throws {
        let (store, reader) = try open(try TempDirectory())
        let first = try await store.commit(LedgerBatch(limits: [reading(10, at: 0)]))
        XCTAssertEqual(first.previousLimits, [:])
        let second = try await store.commit(LedgerBatch(limits: [reading(20, at: 60)]))
        XCTAssertEqual(second.previousLimits[kind], reading(10, at: 0))
        let latest = try await reader.latestLimitSamples()
        XCTAssertEqual(latest[kind], reading(20, at: 60))
    }
}

final class CodexLimitsIngestTests: XCTestCase {
    private let root = "019c0000-0000-7000-8000-0000000000aa"
    private let subagent = "019c0000-0000-7000-8000-0000000000bb"
    private let other = "019c0000-0000-7000-8000-0000000000cc"
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func rollout(_ id: String) -> String {
        "codex/sessions/2026/11/12/rollout-2026-11-12T10-00-00-\(id).jsonl"
    }

    private func stamp(_ date: Date) -> String { formatter.string(from: date) }

    private func line(_ time: Date, _ type: String, _ payload: String) -> String {
        #"{"timestamp":"\#(stamp(time))","type":"\#(type)","payload":\#(payload)}"# + "\n"
    }

    private func meta(_ id: String, at time: Date) -> String {
        line(time, "session_meta", #"{"id":"\#(id)","session_id":"\#(id)","timestamp":"\#(stamp(time))","cwd":"/Users/dev/Project/demo","originator":"codex_cli_rs","cli_version":"0.167.1","source":"cli","model_provider":"openai"}"#)
            + line(time, "turn_context", #"{"cwd":"/Users/dev/Project/demo","model":"gpt-6.1-sol"}"#)
    }

    private func subagentMeta(at time: Date) -> String {
        line(time, "session_meta", #"{"id":"\#(subagent)","session_id":"\#(root)","timestamp":"\#(stamp(time))","cwd":"/Users/dev/Project/demo","originator":"codex_cli_rs","cli_version":"0.167.1","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\#(root)","depth":1,"agent_nickname":"Hume","agent_role":"explorer"}}},"agent_nickname":"Hume","agent_role":"explorer","model_provider":"openai"}"#)
            + line(time, "turn_context", #"{"cwd":"/Users/dev/Project/demo","model":"gpt-6-luna"}"#)
    }

    private func started(at time: Date) -> String {
        line(time, "event_msg", #"{"type":"task_started","turn_id":"t","model_context_window":258400}"#)
    }

    private func completed(at time: Date) -> String {
        line(time, "event_msg", #"{"type":"task_complete","turn_id":"t"}"#)
    }

    private func tokens(at time: Date, total input: Int, output: Int, fiveHour: Double, weekly: Double) -> String {
        line(time, "event_msg", #"{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(input + output)},"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":0},"model_context_window":258400},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":\#(fiveHour),"window_minutes":300,"resets_at":\#(Int(Date().timeIntervalSince1970) + 7200)},"secondary":{"used_percent":\#(weekly),"window_minutes":10080,"resets_at":\#(Int(Date().timeIntervalSince1970) + 400_000)},"credits":null,"individual_limit":null,"plan_type":"plus","rate_limit_reached_type":null}}"#)
    }

    private func index(_ id: String, _ name: String) -> String {
        #"{"id":"\#(id)","thread_name":"\#(name)","updated_at":"2026-11-12T10:00:00Z"}"# + "\n"
    }

    private func makeLedger(_ directory: TempDirectory, watch: Bool = false) throws -> Ledger {
        try Ledger(configuration: LedgerConfiguration(databasePath: directory.path("hoply.sqlite"),
                                                      claudeConfigDirectory: directory.path("claude"),
                                                      copilotHome: directory.path("copilot"),
                                                      pricingOverridesURL: nil, watchForChanges: watch,
                                                      codexHome: directory.path("codex")))
    }

    private var fiveHour: LimitKind { LimitKind.codex(windowMinutes: 300)! }
    private var weekly: LimitKind { LimitKind.codex(windowMinutes: 10_080)! }

    func testLimitsContextWindowAndSubagentNamesReachTheLedger() async throws {
        let directory = try TempDirectory()
        let then = Date().addingTimeInterval(-86_400)
        try directory.write(rollout(root), meta(root, at: then) + started(at: then.addingTimeInterval(1))
                            + tokens(at: then.addingTimeInterval(5), total: 220_000, output: 900, fiveHour: 12, weekly: 3)
                            + tokens(at: then.addingTimeInterval(9), total: 221_000, output: 1_000, fiveHour: 14, weekly: 3))
        try directory.write(rollout(subagent), subagentMeta(at: then.addingTimeInterval(2))
                            + started(at: then.addingTimeInterval(3))
                            + tokens(at: then.addingTimeInterval(7), total: 3_000, output: 40, fiveHour: 13, weekly: 3))
        let ledger = try makeLedger(directory)
        await ledger.ingest.start()

        let key = SessionKey(source: .codexCLI, id: root)
        let latest = try await ledger.latestLimitSamples()
        XCTAssertEqual(latest[fiveHour]?.utilization, 14)
        XCTAssertEqual(latest[fiveHour]?.plan, "plus")
        XCTAssertEqual(latest[weekly]?.utilization, 3)
        let current = try await ledger.currentLimitSamples(provider: .codex)
        XCTAssertEqual(Set(current.keys), [fiveHour, weekly])
        let none = try await ledger.currentLimitSamples(provider: .claude)
        XCTAssertTrue(none.isEmpty)
        let projections = try await ledger.limitProjections()
        XCTAssertNotNil(projections[fiveHour])

        let session = AgentSession.live(key, model: "gpt-6.1-sol")
        let windows = try await ledger.contextWindows(for: [session])
        XCTAssertEqual(windows[key]?.limit, 258_400)
        XCTAssertEqual(windows[key]?.used, 1_000 + 100, "the last main call's input and output")

        let subagents = try await ledger.subagents(of: key)
        XCTAssertEqual(subagents.map(\.agentID), [subagent])
        XCTAssertEqual(subagents.first?.agentType, "Hume")
        XCTAssertEqual(subagents.first?.description, "explorer")
    }

    func testAThirtyDayWindowProjectsFromItsWholeMonth() async throws {
        let directory = try TempDirectory()
        let ledger = try makeLedger(directory)
        let month = try XCTUnwrap(LimitKind.codex(windowMinutes: 43_200))
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        let resets = now.addingTimeInterval(10 * 86_400)
        try await ledger.store.recordLimitSamples([
            LimitSample(kind: month, ts: now.addingTimeInterval(-15 * 86_400), utilization: 20, resetsAt: resets, plan: "free"),
            LimitSample(kind: month, ts: now.addingTimeInterval(-3 * 3600), utilization: 50, resetsAt: resets, plan: "free"),
            LimitSample(kind: month, ts: now, utilization: 52, resetsAt: resets, plan: "free"),
        ])
        let projection = try await ledger.limitProjections(now: now)[month]
        XCTAssertEqual(projection?.windowSamples.count, 3, "the lookback covers the longest window present")
        XCTAssertEqual(projection?.windowStart, resets.addingTimeInterval(-30 * 86_400))
    }

    func testFreshReadingsAndLiveSubagentsReachTheUpdatesStream() async throws {
        let directory = try TempDirectory()
        let old = Date().addingTimeInterval(-3 * 3600)
        try directory.write(rollout(root), meta(root, at: old)
                            + tokens(at: old.addingTimeInterval(5), total: 1_000, output: 10, fiveHour: 70, weekly: 20))
        try directory.write(rollout(subagent), subagentMeta(at: old) + started(at: old.addingTimeInterval(1)))
        let ledger = try makeLedger(directory)
        let collector = Task { () -> [IngestUpdate] in
            var seen: [IngestUpdate] = []
            for await update in ledger.ingest.updates {
                seen.append(update)
                if update.limits.contains(where: { $0.utilization == 85 }) { break }
            }
            return seen
        }
        await ledger.ingest.start()

        let now = Date()
        try directory.append(rollout(subagent), completed(at: now.addingTimeInterval(-2)) + started(at: now.addingTimeInterval(-1)))
        await ledger.ingest.tailTranscript(atPath: directory.path(rollout(subagent)))
        try directory.append(rollout(root), tokens(at: now, total: 2_000, output: 20, fiveHour: 85, weekly: 21))
        await ledger.ingest.tailTranscript(atPath: directory.path(rollout(root)))
        let updates = await collector.value

        let limits = updates.flatMap(\.limits)
        XCTAssertEqual(limits.map(\.utilization), [85, 21], "the backfilled readings stay in the ledger only")
        let previous = try XCTUnwrap(updates.last { !$0.limits.isEmpty }?.previousLimits)
        XCTAssertEqual(previous[fiveHour]?.utilization, 70, "what was stored before this write")

        let activity = updates.flatMap(\.subagents)
        XCTAssertEqual(activity.map(\.ended), [true, false], "the backfilled start is not live news")
        XCTAssertTrue(activity.allSatisfy { $0.session == SessionKey(source: .codexCLI, id: self.root)
            && $0.agentID == self.subagent && $0.type == "Hume" })
    }

    func testSessionIndexNamesExistingSessionsOnly() async throws {
        let directory = try TempDirectory()
        let then = Date().addingTimeInterval(-86_400)
        try directory.write(rollout(root), meta(root, at: then)
                            + tokens(at: then.addingTimeInterval(5), total: 1_000, output: 10, fiveHour: 1, weekly: 1))
        try directory.write("codex/session_index.jsonl", index(root, "First name") + index(other, "No rollout yet"))
        var ledger = try makeLedger(directory)
        await ledger.ingest.start()

        let key = SessionKey(source: .codexCLI, id: root)
        var summary = try await ledger.reader.session(key)
        XCTAssertEqual(summary?.title, "First name")
        let ghost = try await ledger.reader.session(SessionKey(source: .codexCLI, id: other))
        XCTAssertNil(ghost, "the index never creates a session")

        try directory.append("codex/session_index.jsonl", index(root, "Renamed"))
        await ledger.ingest.rescan()
        summary = try await ledger.reader.session(key)
        XCTAssertEqual(summary?.title, "Renamed", "the newest entry wins")

        try directory.append("codex/session_index.jsonl", index(root, ""))
        await ledger.ingest.rescan()
        summary = try await ledger.reader.session(key)
        XCTAssertEqual(summary?.title, "Renamed", "an empty name leaves the title as it is")

        try directory.write(rollout(other), meta(other, at: then)
                            + tokens(at: then.addingTimeInterval(9), total: 500, output: 5, fiveHour: 1, weekly: 1))
        await ledger.ingest.rescan()
        let named = try await ledger.reader.session(SessionKey(source: .codexCLI, id: other))
        XCTAssertEqual(named?.title, "No rollout yet", "a session read after its name gets it")

        await ledger.ingest.stop()
        try directory.write("codex/session_index.jsonl", index(other, "Kept"))
        ledger = try makeLedger(directory)
        await ledger.ingest.start()
        let kept = try await ledger.reader.session(SessionKey(source: .codexCLI, id: other))
        XCTAssertEqual(kept?.title, "Kept")
        summary = try await ledger.reader.session(key)
        XCTAssertEqual(summary?.title, "Renamed")

        await ledger.ingest.reindex()
        let again = try await ledger.reader.session(SessionKey(source: .codexCLI, id: other))
        XCTAssertEqual(again?.title, "Kept")
    }

    func testAnIndexRenameReportsTheSession() async throws {
        let directory = try TempDirectory()
        let then = Date().addingTimeInterval(-86_400)
        try directory.write(rollout(root), meta(root, at: then)
                            + tokens(at: then.addingTimeInterval(5), total: 1_000, output: 10, fiveHour: 1, weekly: 1))
        try directory.write("codex/session_index.jsonl", index(root, "First name"))
        let ledger = try makeLedger(directory)
        await ledger.ingest.start()
        let key = SessionKey(source: .codexCLI, id: root)
        let reported = firstUpdateAfterBackfill(in: ledger.ingest.updates, touching: key)
        try directory.append("codex/session_index.jsonl", index(root, "Renamed"))
        await ledger.ingest.rescan()
        let update = await reported.value
        XCTAssertNotNil(update, "a rename touches no rollout, yet the app must re-read the title")
        let titles = try await ledger.reader.sessionTitles(for: [key])
        XCTAssertEqual(titles, [key: "Renamed"])
    }

    func testARewrittenIndexIsReadFromTheStart() async throws {
        let directory = try TempDirectory()
        let then = Date().addingTimeInterval(-86_400)
        for id in [root, other] {
            try directory.write(rollout(id), meta(id, at: then)
                                + tokens(at: then.addingTimeInterval(5), total: 1_000, output: 10, fiveHour: 1, weekly: 1))
        }
        try directory.write("codex/session_index.jsonl", index(root, "Alpha") + index(other, "Beta"))
        let ledger = try makeLedger(directory)
        await ledger.ingest.start()
        let replacement = directory.path("codex/session-index-tmp")
        try Data((index(other, "Beta two")).utf8).write(to: URL(fileURLWithPath: replacement))
        XCTAssertEqual(rename(replacement, directory.path("codex/session_index.jsonl")), 0)
        await ledger.ingest.rescan()
        let beta = try await ledger.reader.session(SessionKey(source: .codexCLI, id: other))
        XCTAssertEqual(beta?.title, "Beta two")
        let alpha = try await ledger.reader.session(SessionKey(source: .codexCLI, id: root))
        XCTAssertEqual(alpha?.title, "Alpha", "a removed name is never cleared from the ledger")
    }

    func testTheWatcherSeesTheIndexFile() async throws {
        let directory = try TempDirectory()
        let then = Date().addingTimeInterval(-86_400)
        try directory.write(rollout(root), meta(root, at: then)
                            + tokens(at: then.addingTimeInterval(5), total: 1_000, output: 10, fiveHour: 1, weekly: 1))
        try directory.write("codex/session_index.jsonl", index(other, "Someone else"))
        let ledger = try makeLedger(directory, watch: true)
        await ledger.ingest.start()
        try directory.append("codex/session_index.jsonl", index(root, "Watched"))
        let key = SessionKey(source: .codexCLI, id: root)
        var title: String?
        for _ in 0..<100 {
            title = try await ledger.reader.session(key)?.title
            if title != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        await ledger.ingest.stop()
        XCTAssertEqual(title, "Watched")
    }
}

private extension AgentSession {
    static func live(_ key: SessionKey, model: String?) -> AgentSession {
        var board = SessionBoard()
        board.apply(AgentEvent(key: key, kind: .sessionStarted, time: Date(), model: model, fromHook: true))
        return board.sessions[key]!
    }
}
