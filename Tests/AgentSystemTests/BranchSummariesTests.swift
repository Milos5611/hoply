import AgentKit
import AgentSystem
import Foundation
import XCTest

final class BranchSummariesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_200_000)
    private let allTime = DateInterval(start: .distantPast, end: .distantFuture)
    private let api = "/Users/dev/work/api"
    private let web = "/Users/dev/work/web"

    private func open(_ directory: TempDirectory) throws -> (Store, StoreReader) {
        let path = directory.path("hoply.sqlite")
        return (try Store(path: path, resolver: ProjectResolver(home: "/Users/dev")), try StoreReader(path: path))
    }

    private func call(_ key: String, _ session: String, _ source: AgentSource = .claudeCode, at seconds: TimeInterval = 0,
                      model: String = "claude-opus-5-5", output: Int = 100, cwd: String) -> UsageRecord {
        UsageRecord(dedupeKey: key, source: source, sessionID: session, timestamp: t0.addingTimeInterval(seconds),
                    model: model, tokens: TokenCounts(input: 10, output: output, cacheRead: 1000), cwd: cwd)
    }

    private func session(_ id: String, _ source: AgentSource = .claudeCode, branch: String?, cwd: String,
                         from: TimeInterval = 0, to: TimeInterval = 60, pr: String? = nil, added: Int? = nil,
                         removed: Int? = nil) -> SessionUpdate {
        SessionUpdate(key: SessionKey(source: source, id: id), firstAt: t0.addingTimeInterval(from),
                      lastAt: t0.addingTimeInterval(to), cwd: cwd, branch: branch, prURL: pr, linesAdded: added,
                      linesRemoved: removed)
    }

    private func projectID(_ store: Store, _ cwd: String) async throws -> Int64 {
        let found = try await store.projects(forCwds: [cwd])[cwd]
        return try XCTUnwrap(found).id
    }

    private func assertRowsSumToTheProject(_ reader: StoreReader, _ store: Store, cwd: String, range: DateInterval,
                                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let id = try await projectID(store, cwd)
        let project = try await reader.projects(in: range).first { $0.project?.id == id }
        let rows = try await reader.branches(in: range, project: .project(id))
        XCTAssertEqual(rows.reduce(LedgerTotals.zero) { $0 + $1.totals }, project?.totals ?? .zero, file: file, line: line)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.sessionCount }, project?.sessionCount ?? 0, file: file, line: line)
    }

    func testBranchesAreGroupedBySpendWithNoBranchLastAndSumToTheProject() async throws {
        let (store, reader) = try open(try TempDirectory())
        try await store.apply(LedgerBatch(
            usage: [call("a1", "s1", cwd: api), call("a2", "s1", at: 5, output: 400, cwd: api),
                    call("b1", "s2", at: 100, output: 900, cwd: api),
                    call("c1", "s3", at: 200, output: 50, cwd: api),
                    call("d1", "s4", at: 300, output: 5_000, cwd: api),
                    call("w1", "w", at: 400, cwd: web)],
            sessions: [session("s1", branch: "feature/a", cwd: api),
                       session("s2", branch: "feature/b", cwd: api, from: 100),
                       session("s3", branch: "feature/a", cwd: api, from: 200),
                       session("s4", branch: nil, cwd: api, from: 300),
                       session("w", branch: "feature/a", cwd: web, from: 400)]))

        let id = try await projectID(store, api)
        let rows = try await reader.branches(in: allTime, project: .project(id))
        XCTAssertEqual(rows.map(\.branch), ["feature/b", "feature/a", nil], "spend descending, the no-branch row last")
        XCTAssertEqual(rows.map(\.sessionCount), [1, 2, 1])
        XCTAssertEqual(rows.map(\.totals.calls), [1, 3, 1])
        XCTAssertEqual(rows[1].firstActive, t0)
        XCTAssertEqual(rows[1].lastActive, t0.addingTimeInterval(200))
        XCTAssertEqual(rows[1].sources, [.claudeCode])
        XCTAssertGreaterThan(rows[2].totals.apiEquivUSD, rows[0].totals.apiEquivUSD)
        try await assertRowsSumToTheProject(reader, store, cwd: api, range: allTime)
        try await assertRowsSumToTheProject(reader, store, cwd: web, range: allTime)

        let webID = try await projectID(store, web)
        let other = try await reader.branches(in: allTime, project: .project(webID))
        XCTAssertEqual(other.map(\.branch), ["feature/a"], "the same branch name in another project stays apart")
        XCTAssertEqual(other.first?.totals.calls, 1)
    }

    func testThreeAgentsOnOneBranchAreSummedAndListed() async throws {
        let (store, reader) = try open(try TempDirectory())
        let copilot = UsageRecord(dedupeKey: "cp:p1:1:x", source: .copilotCLI, sessionID: "p1",
                                  timestamp: t0.addingTimeInterval(20), model: "claude-opus-5",
                                  tokens: TokenCounts(input: 2, output: 50), nativeCost: 2, nativeUSD: 0.02,
                                  requestMultiplier: 15, turnIndex: 0, cwd: api)
        try await store.apply(LedgerBatch(
            usage: [call("cc1", "c1", at: 0, cwd: api), call("cx1", "x1", .codexCLI, at: 10, model: "gpt-5.5", cwd: api),
                    copilot],
            sessions: [session("c1", branch: "main", cwd: api),
                       session("x1", .codexCLI, branch: "main", cwd: api, from: 10),
                       session("p1", .copilotCLI, branch: "main", cwd: api, from: 20)]))

        let id = try await projectID(store, api)
        let rows = try await reader.branches(in: allTime, project: .project(id))
        XCTAssertEqual(rows.count, 1)
        let main = try XCTUnwrap(rows.first)
        XCTAssertEqual(main.branch, "main")
        XCTAssertEqual(main.sessionCount, 3)
        XCTAssertEqual(main.totals.calls, 3)
        XCTAssertEqual(main.totals.aiu, 2)
        XCTAssertEqual(main.sources, [.claudeCode, .copilotCLI, .codexCLI])
        try await assertRowsSumToTheProject(reader, store, cwd: api, range: allTime)
    }

    func testABranchWithOnlyAnUnpricedModelIsUnpricedNotZero() async throws {
        let (store, reader) = try open(try TempDirectory())
        try await store.apply(LedgerBatch(
            usage: [call("u1", "s1", model: "mystery-model-9", cwd: api), call("p1", "s2", at: 10, cwd: api)],
            sessions: [session("s1", branch: "experiment", cwd: api), session("s2", branch: "main", cwd: api, from: 10)]))

        let id = try await projectID(store, api)
        let rows = try await reader.branches(in: allTime, project: .project(id))
        let experiment = try XCTUnwrap(rows.first { $0.branch == "experiment" })
        XCTAssertTrue(experiment.totals.hasUnpriced)
        XCTAssertEqual(experiment.totals.apiEquivUSD, 0)
        XCTAssertEqual(experiment.totals.calls, 1)
        XCTAssertFalse(try XCTUnwrap(rows.first { $0.branch == "main" }).totals.hasUnpriced)
        try await assertRowsSumToTheProject(reader, store, cwd: api, range: allTime)
        let project = try await reader.projects(in: allTime).first { $0.project?.id == id }
        XCTAssertEqual(project?.totals.hasUnpriced, true)
    }

    func testOnlyUsageInsideTheRangeCountsAndAnEmptyBranchIsAbsent() async throws {
        let (store, reader) = try open(try TempDirectory())
        try await store.apply(LedgerBatch(
            usage: [call("e1", "s1", at: 0, cwd: api), call("e2", "s1", at: 7_200, output: 700, cwd: api),
                    call("l1", "s2", at: 7_300, cwd: api)],
            sessions: [session("s1", branch: "early", cwd: api, to: 7_200),
                       session("s2", branch: "late", cwd: api, from: 7_300, to: 7_360)]))

        let id = try await projectID(store, api)
        let range = DateInterval(start: t0.addingTimeInterval(-60), duration: 3_600)
        let rows = try await reader.branches(in: range, project: .project(id))
        XCTAssertEqual(rows.map(\.branch), ["early"])
        XCTAssertEqual(rows.first?.totals.calls, 1)
        XCTAssertEqual(rows.first?.lastActive, t0)
        try await assertRowsSumToTheProject(reader, store, cwd: api, range: range)
        let everything = try await reader.branches(in: allTime, project: .project(id))
        XCTAssertEqual(Set(everything.map(\.branch)), ["early", "late"])
        let none = try await reader.branches(in: DateInterval(start: t0.addingTimeInterval(86_400), duration: 60),
                                             project: .project(id))
        XCTAssertEqual(none, [])
    }

    func testPullRequestsAreDistinctNewestFirstAndOnTheirOwnBranch() async throws {
        let (store, reader) = try open(try TempDirectory())
        let first = "https://github.com/dev/api/pull/1"
        let second = "https://github.com/dev/api/pull/2"
        let elsewhere = "https://github.com/dev/api/pull/3"
        try await store.apply(LedgerBatch(
            usage: [call("1", "s1", at: 0, cwd: api), call("2", "s2", at: 100, cwd: api),
                    call("3", "s3", at: 200, cwd: api), call("4", "s4", at: 300, cwd: api)],
            sessions: [session("s1", branch: "feature", cwd: api, pr: first, added: 10, removed: 2),
                       session("s2", branch: "feature", cwd: api, from: 100, to: 160, pr: second, added: 5, removed: 1),
                       session("s3", branch: "feature", cwd: api, from: 200, to: 260, pr: first),
                       session("s4", branch: "other", cwd: api, from: 300, to: 360, pr: elsewhere)]))

        let id = try await projectID(store, api)
        let rows = try await reader.branches(in: allTime, project: .project(id))
        let feature = try XCTUnwrap(rows.first { $0.branch == "feature" })
        XCTAssertEqual(feature.prURLs, [first, second], "first is on the newest session, so it leads")
        XCTAssertEqual(feature.linesAdded, 15)
        XCTAssertEqual(feature.linesRemoved, 3)
        let other = try XCTUnwrap(rows.first { $0.branch == "other" })
        XCTAssertEqual(other.prURLs, [elsewhere])
        XCTAssertNil(other.linesAdded, "no session reports lines: unknown, never 0")
        XCTAssertNil(other.linesRemoved)
    }

    func testReassigningASessionMovesItsUsageToTheOtherProjectsBranches() async throws {
        let (store, reader) = try open(try TempDirectory())
        try await store.apply(LedgerBatch(
            usage: [call("1", "s1", cwd: api), call("2", "s2", at: 100, cwd: web), call("3", "s2", at: 110, cwd: web)],
            sessions: [session("s1", branch: "feature", cwd: api), session("s2", branch: "feature", cwd: web, from: 100)]))
        let apiID = try await projectID(store, api)
        let webID = try await projectID(store, web)
        let before = try await reader.branches(in: allTime, project: .project(apiID))
        XCTAssertEqual(before.map(\.totals.calls), [1])

        try await store.assign(session: SessionKey(source: .claudeCode, id: "s2"), toProject: apiID)

        let moved = try await reader.branches(in: allTime, project: .project(apiID))
        XCTAssertEqual(moved.map(\.branch), ["feature"])
        XCTAssertEqual(moved.first?.totals.calls, 3)
        XCTAssertEqual(moved.first?.sessionCount, 2)
        let left = try await reader.branches(in: allTime, project: .project(webID))
        XCTAssertEqual(left, [])
        try await assertRowsSumToTheProject(reader, store, cwd: api, range: allTime)
    }
}
