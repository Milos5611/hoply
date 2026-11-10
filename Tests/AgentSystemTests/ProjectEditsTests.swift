import AgentKit
import AgentSystem
import Foundation
import XCTest

final class ProjectEditsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_200_000)
    private let allTime = DateInterval(start: .distantPast, end: .distantFuture)
    private let resolver = ProjectResolver(home: "/Users/dev")

    private func open(_ directory: TempDirectory) throws -> (Store, StoreReader) {
        let path = directory.path("hoply.sqlite")
        return (try Store(path: path, resolver: resolver), try StoreReader(path: path))
    }

    private func batch(_ id: String, cwd: String?, calls: Int = 1, source: AgentSource = .claudeCode,
                       at seconds: TimeInterval = 0, tag: String = "") -> LedgerBatch {
        let usage = (0..<calls).map { index in
            UsageRecord(dedupeKey: "k:\(id):\(tag)\(index)", source: source, sessionID: id,
                        timestamp: t0.addingTimeInterval(seconds + Double(index)), model: "claude-opus-5-5",
                        tokens: TokenCounts(input: 10, output: 100), cwd: cwd)
        }
        return LedgerBatch(usage: usage, sessions: [
            SessionUpdate(key: SessionKey(source: source, id: id), firstAt: t0.addingTimeInterval(seconds),
                          lastAt: t0.addingTimeInterval(seconds + 60), cwd: cwd, placeIsAuthoritative: cwd != nil),
        ])
    }

    private func callsByProject(_ reader: StoreReader) async throws -> [String: Int] {
        var result: [String: Int] = [:]
        for summary in try await reader.projects(in: allTime) {
            result[summary.project?.root ?? "unassigned"] = summary.totals.calls
        }
        return result
    }

    private func projectID(_ store: Store, _ cwd: String) async throws -> Int64 {
        let found = try await store.projects(forCwds: [cwd])[cwd]
        return try XCTUnwrap(found).id
    }

    private func sessionProject(_ reader: StoreReader, _ id: String, source: AgentSource = .claudeCode) async throws -> String? {
        try await reader.session(SessionKey(source: source, id: id))?.project?.root
    }

    func testAssigningAFolderMovesItsSessionsAndUndoPutsThemBack() async throws {
        let directory = try TempDirectory()
        var (store, reader) = try open(directory)
        try await store.apply(batch("s1", cwd: "/Users/dev/work/a", calls: 2))
        try await store.apply(batch("s2", cwd: "/Users/dev/work/a/sub", calls: 3))
        try await store.apply(batch("s3", cwd: "/Users/dev/main"))
        try await store.apply(batch("s4", cwd: "/Users/dev/work/ab"))
        let before = try await callsByProject(reader)
        XCTAssertEqual(before, ["/Users/dev/work/a": 2, "/Users/dev/work/a/sub": 3, "/Users/dev/main": 1,
                                "/Users/dev/work/ab": 1])
        let overall = try await reader.overview().allTime
        let main = try await projectID(store, "/Users/dev/main")

        let moved = try await store.assign(path: "/Users/dev/work/a/", toProject: main)
        XCTAssertEqual(moved, [SessionKey(source: .claudeCode, id: "s1"), SessionKey(source: .claudeCode, id: "s2")])
        let assigned = try await callsByProject(reader)
        XCTAssertEqual(assigned, ["/Users/dev/main": 6, "/Users/dev/work/ab": 1])
        let overallAfter = try await reader.overview().allTime
        XCTAssertEqual(overallAfter, overall, "nothing is added or lost")
        let s2 = try await sessionProject(reader, "s2")
        XCTAssertEqual(s2, "/Users/dev/main")
        let listed = try await reader.pathAssignments()
        XCTAssertEqual(listed.map(\.path), ["/Users/dev/work/a"])
        XCTAssertEqual(listed.first?.project.id, main)

        try await store.apply(batch("s5", cwd: "/Users/dev/work/a/new"))
        let resolved = try await store.projects(forCwds: ["/Users/dev/work/a/other", "/Users/dev/work/ab"])
        XCTAssertEqual(resolved["/Users/dev/work/a/other"]?.id, main)
        XCTAssertNotEqual(resolved["/Users/dev/work/ab"]?.id, main)

        // Relaunch, then Reindex: the transcripts are read again from the start.
        (store, reader) = try open(directory)
        try await store.resetCursors(source: .claudeCode)
        try await store.apply(batch("s1", cwd: "/Users/dev/work/a", calls: 2))
        try await store.apply(batch("s6", cwd: "/Users/dev/work/a/sub"))
        let reindexed = try await callsByProject(reader)
        XCTAssertEqual(reindexed, ["/Users/dev/main": 8, "/Users/dev/work/ab": 1])

        let back = try await store.unassign(path: "/Users/dev/work/a")
        XCTAssertEqual(back.count, 4)
        let undone = try await callsByProject(reader)
        XCTAssertEqual(undone, ["/Users/dev/work/a": 2, "/Users/dev/work/a/sub": 4, "/Users/dev/work/a/new": 1,
                                "/Users/dev/main": 1, "/Users/dev/work/ab": 1])
        let none = try await reader.pathAssignments()
        XCTAssertEqual(none, [])
    }

    func testARepositoryInsideAnAssignedFolderAndADeeperAssignmentKeepTheirProjects() async throws {
        let directory = try TempDirectory()
        let root = try XCTUnwrap(LocalProjectFileSystem().realPath(directory.url.path))
        try directory.mkdir("work/api/.git")
        try directory.mkdir("work/api/src")
        try directory.mkdir("work/notes/deep")
        try directory.mkdir("work/client/app")
        try directory.mkdir("main")
        try directory.mkdir("other")
        let (store, reader) = try open(directory)
        for (id, folder) in [("repo", "work/api/src"), ("notes", "work/notes/deep"), ("client", "work/client/app"),
                             ("main", "main"), ("other", "other")] {
            try await store.apply(batch(id, cwd: directory.path(folder)))
        }
        let main = try await projectID(store, directory.path("main"))
        let other = try await projectID(store, directory.path("other"))
        try await store.assign(path: directory.path("work"), toProject: main)
        try await store.assign(path: directory.path("work/client"), toProject: other)

        let calls = try await callsByProject(reader)
        XCTAssertEqual(calls, [root + "/main": 2, root + "/other": 2, root + "/work/api": 1])
        let viaSymlinkFreePath = try await store.projects(forCwds: [root + "/work/client/app/x"])
        XCTAssertEqual(viaSymlinkFreePath.values.first?.id, other)

        try await store.unassign(path: directory.path("work/client"))
        let client = try await sessionProject(reader, "client")
        XCTAssertEqual(client, root + "/main", "the wider assignment takes over")
    }

    func testInvalidEditsAreRefused() async throws {
        let (store, _) = try open(try TempDirectory())
        try await store.apply(batch("s1", cwd: "/Users/dev/main"))
        let main = try await projectID(store, "/Users/dev/main")
        for bad in ["", "/", "relative"] {
            do {
                try await store.assign(path: bad, toProject: main)
                XCTFail("accepted \(bad)")
            } catch let error as ProjectEditError {
                XCTAssertEqual(error, .invalidPath(bad))
            }
        }
        await XCTAssertThrowsEdit(.unknownProject(999)) { try await store.assign(path: "/Users/dev/x", toProject: 999) }
        await XCTAssertThrowsEdit(.sameProject) { try await store.mergeProject(main, into: main) }
        await XCTAssertThrowsEdit(.unknownProject(999)) { try await store.mergeProject(999, into: main) }
        await XCTAssertThrowsEdit(.notMerged) { try await store.unmergeProject(main) }
        await XCTAssertThrowsEdit(.unknownSession) {
            try await store.assign(session: SessionKey(source: .qwenCode, id: "nope"), toProject: main)
        }
        let still = try await store.projects(forCwds: ["/Users/dev/x"])
        XCTAssertNotEqual(still["/Users/dev/x"]?.id, main, "a refused edit leaves no rule behind")
    }

    private func XCTAssertThrowsEdit(_ expected: ProjectEditError, file: StaticString = #filePath, line: UInt = #line,
                                     _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("no error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ProjectEditError, expected, file: file, line: line)
        }
    }

    func testMergingMovesEverythingAndUndoRestoresIt() async throws {
        let directory = try TempDirectory()
        var (store, reader) = try open(directory)
        try await store.apply(batch("a1", cwd: "/Users/dev/a", calls: 2))
        try await store.apply(batch("a2", cwd: "/Users/dev/a", calls: 1))
        try await store.apply(batch("b1", cwd: "/Users/dev/b", calls: 4))
        try await store.apply(batch("c1", cwd: "/Users/dev/c", calls: 1))
        let a = try await projectID(store, "/Users/dev/a")
        let b = try await projectID(store, "/Users/dev/b")
        let c = try await projectID(store, "/Users/dev/c")
        let overall = try await reader.overview().allTime

        let moved = try await store.mergeProject(a, into: b)
        XCTAssertEqual(moved.map(\.id).sorted(), ["a1", "a2"])
        let merged = try await callsByProject(reader)
        XCTAssertEqual(merged, ["/Users/dev/b": 7, "/Users/dev/c": 1])
        let overallAfter = try await reader.overview().allTime
        XCTAssertEqual(overallAfter, overall)
        let list = try await reader.projectList()
        XCTAssertEqual(Set(list.map(\.id)), [b, c], "the merged project leaves the listings")
        let pairs = try await reader.mergedProjects()
        XCTAssertEqual(pairs.map { [$0.project.id, $0.into.id] }, [[a, b]])
        let recent = try await reader.recentProjects(limit: 10)
        XCTAssertFalse(recent.contains { $0.project.id == a })
        let a1 = try await sessionProject(reader, "a1")
        XCTAssertEqual(a1, "/Users/dev/b")
        await XCTAssertThrowsEdit(.sameProject) { try await store.mergeProject(b, into: a) }

        (store, reader) = try open(directory)
        try await store.apply(batch("a3", cwd: "/Users/dev/a"))
        let resolved = try await projectID(store, "/Users/dev/a")
        XCTAssertEqual(resolved, b, "later work in the merged folder lands in the target, also after a relaunch")

        // A chain: b into c takes a's rows along; undoing it leaves a merged into b.
        try await store.mergeProject(b, into: c)
        let chained = try await callsByProject(reader)
        XCTAssertEqual(chained, ["/Users/dev/c": 9])
        try await store.unmergeProject(b)
        let unchained = try await callsByProject(reader)
        XCTAssertEqual(unchained, ["/Users/dev/b": 8, "/Users/dev/c": 1])

        let back = try await store.unmergeProject(a)
        XCTAssertEqual(back.map(\.id).sorted(), ["a1", "a2", "a3"])
        let undone = try await callsByProject(reader)
        XCTAssertEqual(undone, ["/Users/dev/a": 4, "/Users/dev/b": 4, "/Users/dev/c": 1])
        let nothing = try await reader.mergedProjects()
        XCTAssertEqual(nothing, [])
        let final = try await reader.overview().allTime
        XCTAssertEqual(final.calls, overall.calls + 1)
    }

    func testAnUnassignedTelemetrySessionStaysWhereTheUserPutIt() async throws {
        let directory = try TempDirectory()
        var (store, reader) = try open(directory)
        let key = SessionKey(source: .copilotIDE, id: "ide-1")
        try await store.apply(batch("ide-1", cwd: nil, calls: 2, source: .copilotIDE))
        try await store.apply(batch("s1", cwd: "/Users/dev/main"))
        let main = try await projectID(store, "/Users/dev/main")
        let before = try await callsByProject(reader)
        XCTAssertEqual(before, ["unassigned": 2, "/Users/dev/main": 1])

        try await store.assign(session: key, toProject: main)
        let assigned = try await callsByProject(reader)
        XCTAssertEqual(assigned, ["/Users/dev/main": 3])
        let pins = try await reader.sessionAssignments()
        XCTAssertEqual(pins.map(\.key), [key])

        (store, reader) = try open(directory)
        try await store.apply(batch("ide-1", cwd: nil, source: .copilotIDE, at: 100, tag: "later"))
        try await store.apply(batch("ide-1", cwd: "/Users/dev/elsewhere", source: .copilotIDE, at: 200, tag: "placed"))
        let later = try await callsByProject(reader)
        XCTAssertEqual(later, ["/Users/dev/main": 5], "later records follow the session, with or without a folder")
        let project = try await sessionProject(reader, "ide-1", source: .copilotIDE)
        XCTAssertEqual(project, "/Users/dev/main")

        try await store.unassign(session: key)
        let undone = try await callsByProject(reader)
        XCTAssertEqual(undone, ["/Users/dev/elsewhere": 4, "/Users/dev/main": 1],
                       "back to automatic: the folder the session has reported since")
        let noPins = try await reader.sessionAssignments()
        XCTAssertEqual(noPins, [])
        let again = try await store.unassign(session: key)
        XCTAssertEqual(again, [])
    }

    func testClonesOfOneRepositoryAreSuggestedOnceAndStayDismissed() async throws {
        let directory = try TempDirectory()
        func repo(_ name: String, url: String?) throws {
            try directory.mkdir("\(name)/.git")
            if let url { try directory.write("\(name)/.git/config", "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = \(url)\n") }
        }
        try repo("fiba", url: "git@github.com:acme/fiba.git")
        try repo("fiba-second", url: "https://github.com/Acme/fiba")
        try repo("other", url: "git@github.com:acme/other.git")
        try repo("local", url: nil)
        var (store, reader) = try open(directory)
        for name in ["fiba", "fiba-second", "other", "local"] {
            try await store.apply(batch(name, cwd: directory.path(name)))
        }
        let suggestions = try await store.mergeSuggestions()
        XCTAssertEqual(suggestions.count, 1)
        let suggestion = try XCTUnwrap(suggestions.first)
        XCTAssertEqual(suggestion.remote, "github.com/acme/fiba")
        XCTAssertEqual(Set(suggestion.projects.map(\.name)), ["fiba", "fiba-second"])
        let untouched = try await callsByProject(reader)
        XCTAssertEqual(untouched.count, 4, "a suggestion merges nothing")

        try await store.dismissSuggestion(suggestion.id)
        try await store.dismissSuggestion(suggestion.id)
        (store, reader) = try open(directory)
        let dismissed = try await store.mergeSuggestions()
        XCTAssertEqual(dismissed, [])
        try await store.restoreSuggestions()
        let restored = try await store.mergeSuggestions()
        XCTAssertEqual(restored.map(\.id), [suggestion.id])

        try await store.mergeProject(suggestion.projects[0].id, into: suggestion.projects[1].id)
        let afterMerge = try await store.mergeSuggestions()
        XCTAssertEqual(afterMerge, [], "a merged clone is no longer suggested")
    }

    func testQwenTurnsCountEachPromptOnce() async throws {
        let directory = try TempDirectory()
        let ledger = try Ledger(configuration: LedgerConfiguration(databasePath: directory.path("hoply.sqlite"),
                                                                   claudeConfigDirectory: directory.path("claude"),
                                                                   copilotHome: directory.path("copilot"),
                                                                   pricingOverridesURL: nil, watchForChanges: false))
        let key = SessionKey(source: .qwenCode, id: "q1")
        func prompt(_ id: String, at seconds: TimeInterval, cwd: String? = nil) -> PromptRecord {
            PromptRecord(dedupeKey: "qwp:q1:\(id):\(Int(seconds))", source: .qwenCode, sessionID: "q1",
                         timestamp: t0.addingTimeInterval(seconds), cwd: cwd)
        }
        let response = UsageRecord(dedupeKey: "qw:q1:p1:5", source: .qwenCode, sessionID: "q1",
                                   timestamp: t0.addingTimeInterval(5), model: "qwen3-coder",
                                   tokens: TokenCounts(input: 100, output: 20))
        let first = [prompt("p1", at: 0, cwd: "/Users/dev/main"), prompt("p2", at: 60)]
        await ledger.record([response], prompts: first)
        await ledger.record([response], prompts: first)
        var summary = try await ledger.reader.session(key)
        XCTAssertEqual(summary?.turns, 2, "a re-sent batch counts nothing twice")
        XCTAssertEqual(summary?.totals.calls, 1)
        XCTAssertEqual(summary?.cwd, "/Users/dev/main")
        XCTAssertEqual(summary?.firstAt, t0)
        XCTAssertEqual(summary?.lastAt, t0.addingTimeInterval(60))

        await ledger.record([], prompts: [prompt("p2", at: 60), prompt("p3", at: 120)])
        await ledger.record([], prompts: [PromptRecord(dedupeKey: "x", source: .claudeCode, sessionID: "c1", timestamp: t0)])
        summary = try await ledger.reader.session(key)
        XCTAssertEqual(summary?.turns, 3)
        XCTAssertEqual(summary?.totals.calls, 1, "prompts are not model calls")
        let claude = try await ledger.reader.session(SessionKey(source: .claudeCode, id: "c1"))
        XCTAssertNil(claude, "only telemetry-ledger sources count turns this way")
    }
}
