import AgentKit
import AgentSystem
import Darwin
import Foundation
import XCTest

final class TelemetryLedgerTests: XCTestCase {
    private let allTime = DateInterval(start: .distantPast, end: .distantFuture)

    private func makeLedger(_ directory: TempDirectory) throws -> Ledger {
        try Ledger(configuration: LedgerConfiguration(databasePath: directory.path("hoply.sqlite"),
                                                      claudeConfigDirectory: directory.path("claude"),
                                                      copilotHome: directory.path("copilot"),
                                                      pricingOverridesURL: nil, watchForChanges: false))
    }

    private func qwen(_ key: String, session: String = "q1", at time: Date = Date(), cwd: String? = nil,
                      pid: Int32? = nil, model: String = "Qwen3.8-Flash-Next") -> UsageRecord {
        UsageRecord(dedupeKey: key, source: .qwenCode, sessionID: session, timestamp: time, model: model,
                    tokens: TokenCounts(input: 1_000, output: 200, cacheRead: 4_000), cwd: cwd, processID: pid)
    }

    func testProcessCwdIsTheFallbackProject() async throws {
        let directory = try TempDirectory()
        let ledger = try makeLedger(directory)
        let ownCwd = try XCTUnwrap(ProcessDirectory.cwd(of: getpid()))
        XCTAssertEqual(LocalProjectFileSystem().realPath(ownCwd),
                       LocalProjectFileSystem().realPath(FileManager.default.currentDirectoryPath))

        await ledger.record([qwen("qw:q1:p1:1", pid: getpid())])
        let summary = try await ledger.reader.session(SessionKey(source: .qwenCode, id: "q1"))
        XCTAssertEqual(summary?.cwd, ownCwd)
        XCTAssertNotNil(summary?.project)
        XCTAssertEqual(summary?.totals.calls, 1)
        XCTAssertEqual(summary?.totals.costUSD, 0, "local model")
        XCTAssertGreaterThan(summary?.totals.apiEquivUSD ?? 0, 0, "priced at the reference model")

        // Later records of the session without a pid still land in its project.
        await ledger.record([qwen("qw:q1:p2:2")])
        let projects = try await ledger.reader.projects(in: allTime)
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.totals.calls, 2)
        XCTAssertNotNil(projects.first?.project)
    }

    func testProcessDirectoryOfAChildProcess() throws {
        let directory = try TempDirectory()
        func spawn(in cwd: URL) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            process.currentDirectoryURL = cwd
            try process.run()
            return process
        }
        let inTemp = try spawn(in: directory.url)
        let inRoot = try spawn(in: URL(fileURLWithPath: "/"))
        defer {
            inTemp.terminate()
            inRoot.terminate()
        }
        XCTAssertEqual(ProcessDirectory.cwd(of: inTemp.processIdentifier),
                       LocalProjectFileSystem().realPath(directory.url.path))
        XCTAssertNil(ProcessDirectory.cwd(of: inRoot.processIdentifier), "GUI apps run in /, which names no project")
        XCTAssertNil(ProcessDirectory.cwd(of: inTemp.processIdentifier, notStartedAfter: Date().addingTimeInterval(-3600)))
        XCTAssertNil(ProcessDirectory.cwd(of: 1), "launchd is not ours")
    }

    func testAPidStartedAfterTheRecordIsIgnored() async throws {
        let directory = try TempDirectory()
        let ledger = try makeLedger(directory)
        await ledger.record([qwen("qw:q1:p1:1", at: Date(timeIntervalSince1970: 1_000_000), pid: getpid())])
        let summary = try await ledger.reader.session(SessionKey(source: .qwenCode, id: "q1"))
        XCTAssertNil(summary?.cwd, "this process did not exist in 1970, so its pid was reused")
        XCTAssertNil(summary?.project)
    }

    func testNoCwdAndNoPidIsUnassigned() async throws {
        let directory = try TempDirectory()
        let ledger = try makeLedger(directory)
        await ledger.record([qwen("qw:q1:p1:1"), qwen("qw:q2:p1:1", session: "q2", cwd: directory.path("fiba"))])
        let projects = try await ledger.reader.projects(in: allTime)
        XCTAssertEqual(projects.count, 2)
        let unassigned = try XCTUnwrap(projects.first { $0.project == nil })
        XCTAssertEqual(unassigned.title, "Unassigned")
        XCTAssertEqual(unassigned.id, "")
        XCTAssertEqual(unassigned.filter, .unassigned)
        XCTAssertEqual(unassigned.totals.calls, 1)
        XCTAssertEqual(unassigned.bySource.keys.sorted { $0.rawValue < $1.rawValue }, [.qwenCode])
        let page = try await ledger.reader.sessions(in: allTime, project: .unassigned)
        XCTAssertEqual(page.sessions.map(\.key.id), ["q1"])
        let named = try XCTUnwrap(projects.first { $0.project != nil })
        XCTAssertEqual(named.project?.name, "fiba")
        let namedPage = try await ledger.reader.sessions(in: allTime, project: named.filter)
        XCTAssertEqual(namedPage.sessions.map(\.key.id), ["q2"])
    }

    func testResentBatchesNeverCountTwice() async throws {
        let directory = try TempDirectory()
        let ledger = try makeLedger(directory)
        let time = Date(timeIntervalSince1970: 1_794_228_000)
        let batch = [qwen("qw:q1:p1:1794228000000000000", at: time),
                     UsageRecord(dedupeKey: "otel:aa:bb", source: .copilotIDE, sessionID: "conv-1", timestamp: time,
                                 model: "gpt-9-preview", tokens: TokenCounts(input: 1200, output: 340))]
        await ledger.record(batch)
        await ledger.record(batch)
        let totals = try await ledger.reader.totalsBySource(in: allTime)
        XCTAssertEqual(totals[.qwenCode]?.calls, 1)
        XCTAssertEqual(totals[.copilotIDE]?.calls, 1)
        XCTAssertEqual(totals[.copilotIDE]?.hasUnpriced, true, "gpt-9-preview has no bundled price: unpriced, not $0")
    }

    func testSourcesWithAnotherLedgerAreDropped() async throws {
        let directory = try TempDirectory()
        let ledger = try makeLedger(directory)
        let time = Date(timeIntervalSince1970: 1_794_228_000)
        await ledger.record([
            UsageRecord(dedupeKey: "x1", source: .claudeCode, sessionID: "c", timestamp: time, model: "claude-opus-5",
                        tokens: TokenCounts(input: 1)),
            UsageRecord(dedupeKey: "x2", source: .copilotCLI, sessionID: "p", timestamp: time, model: "claude-opus-5",
                        tokens: TokenCounts(input: 1)),
        ])
        let totals = try await ledger.reader.totalsBySource(in: allTime)
        XCTAssertTrue(totals.isEmpty)
    }

    func testRecordedUsageReachesTheUpdatesStream() async throws {
        let directory = try TempDirectory()
        let ledger = try makeLedger(directory)
        let key = SessionKey(source: .qwenCode, id: "q1")
        let collector = Task { () -> Bool in
            for await update in ledger.ingest.updates where update.changedSessions.contains(key) { return true }
            return false
        }
        await ledger.record([qwen("qw:q1:p1:1", cwd: directory.path("fiba"))])
        let seen = await collector.value
        XCTAssertTrue(seen)
    }
}

final class ProjectQueriesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_200_000)

    /// fiba (repo) with a linked worktree fiba-feature and a subfolder, plus a plain folder.
    private func makeTree() throws -> (TempDirectory, root: String) {
        let directory = try TempDirectory()
        let root = try XCTUnwrap(LocalProjectFileSystem().realPath(directory.url.path))
        try directory.mkdir("fiba/.git/worktrees/feature")
        try directory.mkdir("fiba/src/api")
        try directory.write("fiba/.git/worktrees/feature/commondir", "../..\n")
        try directory.write("fiba-feature/.git", "gitdir: \(root)/fiba/.git/worktrees/feature\n")
        try directory.mkdir("plain")
        return (directory, root)
    }

    func testResolveProjectsPutsWorktreesAndSubfoldersInTheRepo() async throws {
        let (directory, root) = try makeTree()
        let ledger = try Ledger(configuration: LedgerConfiguration(databasePath: directory.path("hoply.sqlite"),
                                                                   claudeConfigDirectory: directory.path("claude"),
                                                                   copilotHome: directory.path("copilot"),
                                                                   pricingOverridesURL: nil, watchForChanges: false))
        let cwds = [directory.path("fiba"), directory.path("fiba-feature"), directory.path("fiba/src/api"),
                    directory.path("plain"), ""]
        let resolved = await ledger.resolveProjects(cwds)
        XCTAssertEqual(resolved.count, 4, "empty cwds are skipped")
        let fiba = try XCTUnwrap(resolved[directory.path("fiba")])
        XCTAssertEqual(fiba.root, root + "/fiba")
        XCTAssertEqual(fiba.kind, .repo)
        XCTAssertEqual(resolved[directory.path("fiba-feature")], fiba)
        XCTAssertEqual(resolved[directory.path("fiba/src/api")], fiba)
        XCTAssertEqual(resolved[directory.path("plain")]?.kind, .folder)
        XCTAssertNotEqual(resolved[directory.path("plain")]?.id, fiba.id)
        let again = await ledger.resolveProjects([directory.path("fiba-feature")])
        XCTAssertEqual(again[directory.path("fiba-feature")], fiba, "cached lookups agree")
    }

    func testProjectSummariesSeriesAndSessions() async throws {
        let (directory, root) = try makeTree()
        let path = directory.path("hoply.sqlite")
        let store = try Store(path: path, resolver: ProjectResolver(home: "/nonexistent-home"))
        let reader = try StoreReader(path: path)
        func claude(_ key: String, _ session: String, at seconds: TimeInterval, cwd: String?,
                    model: String = "claude-opus-5-5") -> UsageRecord {
            UsageRecord(dedupeKey: key, source: .claudeCode, sessionID: session, timestamp: t0.addingTimeInterval(seconds),
                        model: model, tokens: TokenCounts(input: 10, output: 100, cacheRead: 1000), cwd: cwd)
        }
        func session(_ id: String, _ source: AgentSource = .claudeCode, cwd: String?, branch: String?,
                     at seconds: TimeInterval) -> SessionUpdate {
            SessionUpdate(key: SessionKey(source: source, id: id), firstAt: t0.addingTimeInterval(seconds),
                          lastAt: t0.addingTimeInterval(seconds + 60), cwd: cwd, branch: branch)
        }
        let copilot = UsageRecord(dedupeKey: "cp:p1:1:x", source: .copilotCLI, sessionID: "p1",
                                  timestamp: t0.addingTimeInterval(300), model: "claude-opus-5",
                                  tokens: TokenCounts(input: 2, output: 50), nativeCost: 2, nativeUSD: 0.02,
                                  requestMultiplier: 15, turnIndex: 0, cwd: directory.path("fiba-feature"))
        try await store.apply(LedgerBatch(
            usage: [claude("cc:1", "main", at: 0, cwd: directory.path("fiba")),
                    claude("cc:2", "main", at: 10, cwd: directory.path("fiba"), model: "claude-haiku-5-5"),
                    claude("cc:3", "sub", at: 100, cwd: directory.path("fiba/src/api")),
                    claude("cc:4", "plain", at: 200, cwd: directory.path("plain")),
                    claude("cc:5", "nowhere", at: 400, cwd: nil),
                    copilot],
            sessions: [session("main", cwd: directory.path("fiba"), branch: "main", at: 0),
                       session("sub", cwd: directory.path("fiba/src/api"), branch: "main", at: 100),
                       session("plain", cwd: directory.path("plain"), branch: nil, at: 200),
                       session("nowhere", cwd: nil, branch: nil, at: 400),
                       session("p1", .copilotCLI, cwd: directory.path("fiba-feature"), branch: "feature", at: 300)]))

        let range = DateInterval(start: t0.addingTimeInterval(-60), duration: 3600)
        let projects = try await reader.projects(in: range, topModels: 2)
        XCTAssertEqual(projects.map(\.title), ["fiba", "Unassigned", "plain"], "equal spend: most recent first")
        let fiba = projects[0]
        XCTAssertEqual(fiba.root, root + "/fiba")
        XCTAssertEqual(fiba.kind, .repo)
        XCTAssertEqual(fiba.sessionCount, 3)
        XCTAssertEqual(fiba.totals.calls, 4)
        XCTAssertEqual(fiba.totals.aiu, 2)
        XCTAssertEqual(fiba.totals.premiumRequests, 15)
        XCTAssertEqual(fiba.bySource[.claudeCode]?.calls, 3)
        XCTAssertEqual(fiba.bySource[.copilotCLI]?.costUSD ?? 0, 0.02, accuracy: 1e-12)
        XCTAssertEqual(fiba.bySource.values.reduce(LedgerTotals.zero, +), fiba.totals)
        XCTAssertEqual(fiba.topModels.map(\.model), ["claude-opus-5", "claude-opus-5-5"], "two of three, largest first")
        XCTAssertEqual(fiba.branches, ["feature", "main"])
        XCTAssertEqual(fiba.worktrees, [root + "/fiba-feature"])
        XCTAssertEqual(fiba.lastActive, t0.addingTimeInterval(300))
        XCTAssertEqual(fiba.firstActive, t0)
        XCTAssertEqual(projects[2].firstActive, t0.addingTimeInterval(200))
        XCTAssertNil(projects[1].project)
        XCTAssertEqual(projects[1].totals.calls, 1)
        let everything = projects.reduce(LedgerTotals.zero) { $0 + $1.totals }
        let overview = try await reader.overview(now: t0)
        XCTAssertEqual(everything.calls, overview.allTime.calls)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let fibaID = try XCTUnwrap(fiba.project?.id)
        let fibaDaily = try await reader.dailySpend(days: 2, split: .source, project: .project(fibaID), now: t0,
                                                    calendar: calendar)
        XCTAssertEqual(fibaDaily.points.reduce(0) { $0 + $1.totals.calls }, 4)
        XCTAssertEqual(Set(fibaDaily.points.map(\.series)), ["claude-code", "copilot-cli"])
        let unassignedDaily = try await reader.dailySpend(days: 2, split: .model, project: .unassigned, now: t0,
                                                          calendar: calendar)
        XCTAssertEqual(unassignedDaily.points.map(\.totals.calls), [1])
        let fibaSessions = try await reader.sessions(in: range, project: .project(fibaID))
        XCTAssertEqual(Set(fibaSessions.sessions.map(\.key.id)), ["main", "sub", "p1"])
        let unassigned = try await reader.sessions(in: range, project: .unassigned)
        XCTAssertEqual(unassigned.sessions.map(\.key.id), ["nowhere"])

        let empty = try await reader.projects(in: DateInterval(start: t0.addingTimeInterval(86_400), duration: 60))
        XCTAssertTrue(empty.isEmpty)
    }
}
