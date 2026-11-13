import AgentKit
import AgentSystem
import Foundation
import XCTest

final class StoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_200_000)
    private let cwd = "/Users/dev/Project/demo"
    private let resolver = ProjectResolver(home: "/Users/dev")

    private func open(_ directory: TempDirectory, pricing: PricingTable = .bundled()) throws -> (Store, StoreReader) {
        let path = directory.path("hoply.sqlite")
        let store = try Store(path: path, pricing: pricing, resolver: resolver)
        return (store, try StoreReader(path: path))
    }

    private func call(_ key: String, session: String = "s1", at seconds: TimeInterval = 0, model: String = "claude-opus-5-5",
                      output: Int = 100, sidechain: Bool = false, cwd: String? = nil) -> UsageRecord {
        UsageRecord(dedupeKey: key, source: .claudeCode, sessionID: session, timestamp: t0.addingTimeInterval(seconds),
                    model: model, isSidechain: sidechain, tokens: TokenCounts(input: 10, output: output, cacheRead: 1000,
                                                                               cacheWrite1h: 100),
                    speed: "standard", cwd: cwd ?? self.cwd)
    }

    private func session(_ id: String = "s1", from: TimeInterval = 0, to: TimeInterval = 60, prompts: Int = 0,
                         resets: Bool = false, title: String? = nil, rank: Int = 0, cwd: String? = nil,
                         authoritative: Bool = true) -> SessionUpdate {
        SessionUpdate(key: SessionKey(source: .claudeCode, id: id), firstAt: t0.addingTimeInterval(from),
                      lastAt: t0.addingTimeInterval(to), cwd: cwd ?? self.cwd, branch: "main",
                      placeIsAuthoritative: authoritative, title: title, titleRank: rank, prompts: prompts,
                      resetsTurns: resets)
    }

    private let key = SessionKey(source: .claudeCode, id: "s1")

    private func totals(_ reader: StoreReader, file: StaticString = #filePath, line: UInt = #line) async throws -> LedgerTotals {
        let found = try await reader.sessionTotals(for: [key])[key]
        return try XCTUnwrap(found, file: file, line: line)
    }

    func testApplyingTheSameBatchTwiceChangesNothing() async throws {
        let (store, reader) = try open(try TempDirectory())
        let batch = LedgerBatch(usage: [call("cc:a:1"), call("cc:b:2", at: 5), call("cc:c:3", at: 9, sidechain: true)],
                                sessions: [session(prompts: 2, resets: true)])
        try await store.apply(batch)
        let first = try await reader.sessionTotals(for: [key])[key]
        try await store.apply(batch)
        let second = try await reader.sessionTotals(for: [key])[key]
        XCTAssertEqual(first, second)
        XCTAssertEqual(second?.calls, 3)
        let summary = try await reader.session(key)
        XCTAssertEqual(summary?.turns, 2)
    }

    func testTurnsAddOnTailAndResetWhenTheFileIsReadFromTheStart() async throws {
        let (store, reader) = try open(try TempDirectory())
        let head = LedgerBatch(sessions: [session(prompts: 2, resets: true)])
        let tail = LedgerBatch(sessions: [session(prompts: 1, resets: false)])
        try await store.apply(head)
        try await store.apply(tail)
        var turns = try await reader.session(key)?.turns
        XCTAssertEqual(turns, 3)
        try await store.apply(head)
        try await store.apply(tail)
        turns = try await reader.session(key)?.turns
        XCTAssertEqual(turns, 3)
    }

    func testStreamedBlocksAcrossBatchesKeepTheLargestCountsAndReprice() async throws {
        let (store, reader) = try open(try TempDirectory())
        try await store.apply(LedgerBatch(usage: [call("cc:a:1", output: 16)], sessions: [session()]))
        let early = try await reader.sessionTotals(for: [key])[key]
        try await store.apply(LedgerBatch(usage: [call("cc:a:1", at: 2, output: 616)]))
        try await store.apply(LedgerBatch(usage: [call("cc:a:1", at: 1, output: 16)]))
        let late = try await totals(reader)
        XCTAssertEqual(late.calls, 1)
        XCTAssertEqual(late.tokens.output, 616)
        XCTAssertEqual(late.costUSD - (early?.costUSD ?? 0), 600 * 20 / 1e6, accuracy: 1e-12)
        XCTAssertEqual(late.apiEquivUSD, late.costUSD, accuracy: 1e-12)
    }

    func testCopiedCallsStayWithTheSessionThatStartedFirst() async throws {
        for originalFirst in [true, false] {
            let (store, reader) = try open(try TempDirectory())
            let original = LedgerBatch(usage: [call("cc:shared:1", session: "orig", at: 3600)],
                                       sessions: [session("orig", from: 0, to: 3600)])
            let continued = LedgerBatch(usage: [call("cc:shared:1", session: "cont", at: 3600),
                                                call("cc:own:2", session: "cont", at: 7200)],
                                        sessions: [session("cont", from: 3600, to: 7200)])
            for batch in originalFirst ? [original, continued] : [continued, original] {
                try await store.apply(batch)
            }
            let totals = try await reader.sessionTotals(for: [SessionKey(source: .claudeCode, id: "orig"),
                                                             SessionKey(source: .claudeCode, id: "cont")])
            XCTAssertEqual(totals[SessionKey(source: .claudeCode, id: "orig")]?.calls, 1, "original read first: \(originalFirst)")
            XCTAssertEqual(totals[SessionKey(source: .claudeCode, id: "cont")]?.calls, 1, "original read first: \(originalFirst)")
        }
    }

    func testRepricingWhenThePriceTableChanges() async throws {
        let directory = try TempDirectory()
        let (store, reader) = try open(directory)
        try await store.apply(LedgerBatch(usage: [call("cc:a:1"), call("cc:b:2", model: "Qwen3.8-Flash-Next")],
                                          sessions: [session()]))
        let before = try await totals(reader)
        var unchanged = try await store.setPricing(.bundled())
        XCTAssertEqual(unchanged, 0, "same revision, nothing to re-price")

        let overrides = PricingTable.Document(models: ["claude-opus-5-5": ModelPrice(input: 8, output: 40, cacheRead: 0.4)])
        let repriced = try await store.setPricing(.bundled(overrides: overrides, referenceModel: "claude-opus-5-5"))
        XCTAssertEqual(repriced, 2)
        let after = try await totals(reader)
        XCTAssertEqual(after.costUSD, before.costUSD * 2, accuracy: 1e-12, "the local row still costs $0")
        XCTAssertGreaterThan(after.apiEquivUSD, before.apiEquivUSD)

        // A reopened store with the old table re-prices back.
        let reopened = try Store(path: directory.path("hoply.sqlite"), pricing: .bundled(), resolver: resolver)
        unchanged = try await reopened.setPricing(.bundled())
        XCTAssertEqual(unchanged, 0, "opening the store already re-priced")
        let restored = try await totals(reader)
        XCTAssertEqual(restored, before)
    }

    func testUnpricedAndLocalCalls() async throws {
        let (store, reader) = try open(try TempDirectory())
        try await store.apply(LedgerBatch(usage: [call("cc:a:1"), call("cc:b:2", model: "claude-opus-4-5"),
                                                  call("cc:c:3", model: "Qwen3.8-Flash-Next")],
                                          sessions: [session()]))
        let totals = try await totals(reader)
        XCTAssertTrue(totals.hasUnpriced)
        XCTAssertEqual(totals.calls, 3)
        let opus = PricingTable.bundled().price(model: "claude-opus-5-5", tokens: call("x").tokens, speed: nil).costUSD ?? 0
        XCTAssertEqual(totals.costUSD, opus, accuracy: 1e-12, "unpriced counts as nothing, local as $0")
        XCTAssertGreaterThan(totals.apiEquivUSD, totals.costUSD, "local usage has an API-equivalent value")
    }

    func testTitleRanksAndSubagentPlaces() async throws {
        let (store, reader) = try open(try TempDirectory())
        try await store.apply(LedgerBatch(sessions: [session(title: "AI title", rank: 2)]))
        try await store.apply(LedgerBatch(sessions: [session(title: "agent name", rank: 1)]))
        var summary = try await reader.session(key)
        XCTAssertEqual(summary?.title, "AI title")
        try await store.apply(LedgerBatch(sessions: [session(title: "Custom", rank: 3)]))
        try await store.apply(LedgerBatch(sessions: [session(title: "Newer AI title", rank: 2)]))
        summary = try await reader.session(key)
        XCTAssertEqual(summary?.title, "Custom")

        try await store.apply(LedgerBatch(sessions: [session(cwd: "/Users/dev/elsewhere", authoritative: false)]))
        summary = try await reader.session(key)
        XCTAssertEqual(summary?.cwd, cwd, "subagent lines never replace the main thread's cwd")
    }

    func testSessionTitlesForLiveKeys() async throws {
        let (store, reader) = try open(try TempDirectory())
        let codex = SessionKey(source: .codexCLI, id: "s1")
        let copilot = SessionKey(source: .copilotCLI, id: "cp1")
        try await store.apply(LedgerBatch(sessions: [
            session(title: "AI title", rank: 2), session("untitled"), session("blank", title: ""),
            session("not-live", title: "Elsewhere", rank: 2),
            SessionUpdate(key: codex, cwd: cwd, title: "Codex thread", titleRank: 3),
            SessionUpdate(key: copilot, cwd: cwd, title: "Copilot summary", titleRank: 2),
        ]))
        let untitled = SessionKey(source: .claudeCode, id: "untitled")
        let blank = SessionKey(source: .claudeCode, id: "blank")
        let missing = SessionKey(source: .claudeCode, id: "missing")

        var titles = try await reader.sessionTitles(for: [key, untitled, blank, missing, codex, copilot])
        XCTAssertEqual(titles, [key: "AI title", codex: "Codex thread", copilot: "Copilot summary"],
                       "only non-empty titles of the asked keys, each under its own source")

        _ = try await store.applyTitles(["s1": "Renamed"], source: .codexCLI, rank: 3)
        try await store.apply(LedgerBatch(sessions: [session(title: "Custom", rank: 3)]))
        titles = try await reader.sessionTitles(for: [key, codex])
        XCTAssertEqual(titles, [key: "Custom", codex: "Renamed"])
        titles = try await reader.sessionTitles(for: [])
        XCTAssertEqual(titles, [:])
    }

    func testCursorsRoundTripAndReset() async throws {
        let (store, _) = try open(try TempDirectory())
        let cursor = IngestCursor(source: .claudeCode, path: "/x.jsonl",
                                  file: FileCursor(inode: UInt64.max - 3, size: 900, offset: 850, headHash: UInt64.max))
        try await store.apply(LedgerBatch(), cursor: cursor)
        var cursors = try await store.cursors(source: .claudeCode)
        XCTAssertEqual(cursors["/x.jsonl"], cursor.file)
        try await store.resetCursors(source: .claudeCode)
        cursors = try await store.cursors(source: .claudeCode)
        XCTAssertEqual(cursors["/x.jsonl"]?.offset, 0)
        XCTAssertEqual(cursors["/x.jsonl"]?.inode, cursor.file.inode)
        let copilot = try await store.cursors(source: .copilotCLI)
        XCTAssertTrue(copilot.isEmpty)
    }

    func testReadQueries() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.startOfDay(for: t0).addingTimeInterval(12 * 3600)
        let day: TimeInterval = 86_400
        let (store, reader) = try open(try TempDirectory())
        func at(_ offset: TimeInterval) -> TimeInterval { now.timeIntervalSince(t0) + offset }

        try await store.apply(LedgerBatch(
            usage: [call("cc:1", session: "today", at: at(-60)), call("cc:2", session: "today", at: at(-30), model: "claude-haiku-5-5"),
                    call("cc:3", session: "week", at: at(-3 * day)), call("cc:4", session: "old", at: at(-20 * day), cwd: "/Users/dev/other"),
                    call("cc:5", session: "old", at: at(-20 * day), model: "Qwen3.8-Flash-Next", cwd: "/Users/dev/other")],
            sessions: [session("today", from: at(-60), to: at(-30), title: "Today"),
                       session("week", from: at(-3 * day), to: at(-3 * day)),
                       session("old", from: at(-20 * day), to: at(-20 * day), cwd: "/Users/dev/other")]))

        let overview = try await reader.overview(now: now, calendar: calendar)
        XCTAssertEqual(overview.today.calls, 2)
        XCTAssertEqual(overview.last7Days.calls, 3)
        XCTAssertEqual(overview.last30Days.calls, 5)
        XCTAssertEqual(overview.allTime.calls, 5)

        let today = try await reader.todayBySource(now: now, calendar: calendar)
        XCTAssertEqual(today[.claudeCode]?.calls, 2)
        XCTAssertNil(today[.copilotCLI])

        let month = StoreReader.days(30, endingAt: now, calendar: calendar)
        let firstPage = try await reader.sessions(in: month, limit: 2)
        XCTAssertEqual(firstPage.totalCount, 3)
        XCTAssertEqual(firstPage.sessions.map(\.key.id), ["today", "week"])
        XCTAssertEqual(firstPage.sessions.first?.title, "Today")
        XCTAssertEqual(firstPage.sessions.first?.models.map(\.model), ["claude-opus-5-5", "claude-haiku-5-5"])
        XCTAssertEqual(firstPage.sessions.first?.project?.name, "demo")
        XCTAssertEqual(firstPage.sessions.first?.project?.kind, .folder)
        let secondPage = try await reader.sessions(in: month, limit: 2, offset: 2)
        XCTAssertEqual(secondPage.sessions.map(\.key.id), ["old"])
        let projectID = try XCTUnwrap(firstPage.sessions.first?.project?.id)
        let demoOnly = try await reader.sessions(in: month, project: .project(projectID))
        XCTAssertEqual(demoOnly.totalCount, 2)

        let byModel = try await reader.dailySpend(days: 7, split: .model, now: now, calendar: calendar)
        XCTAssertEqual(byModel.days.count, 7)
        XCTAssertEqual(byModel.days.last, calendar.startOfDay(for: now))
        XCTAssertEqual(Set(byModel.points.map(\.series)), ["claude-opus-5-5", "claude-haiku-5-5"])
        XCTAssertEqual(byModel.points.filter { $0.day == calendar.startOfDay(for: now) }.count, 2)
        let bySource = try await reader.dailySpend(days: 30, split: .source, now: now, calendar: calendar)
        XCTAssertEqual(bySource.points.reduce(0) { $0 + $1.totals.calls }, 5)
        XCTAssertEqual(Set(bySource.points.map(\.series)), ["claude-code"])

        let projects = try await reader.spendByProject(in: month)
        XCTAssertEqual(projects.map(\.label), ["demo", "other"])
        XCTAssertEqual(projects.first?.sessionCount, 2)
        let models = try await reader.spendByModel(in: month)
        XCTAssertEqual(models.first?.id, "claude-opus-5-5")
        XCTAssertEqual(models.first(where: { $0.id == "Qwen3.8-Flash-Next" })?.totals.costUSD, 0)
    }
}
