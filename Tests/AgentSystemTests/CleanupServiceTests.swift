import AgentKit
import AgentSystem
import Foundation
import XCTest

final class CleanupServiceTests: XCTestCase {
    private func service(_ fixture: CleanupFixture) throws -> (CleanupService, FolderTrash) {
        let trash = try FolderTrash(in: fixture.repository.container)
        return (CleanupService(trash: trash, scanner: fixture.scanner, terminator: ProcessTerminator(grace: 3)), trash)
    }

    private func run(_ service: CleanupService, _ selection: [CleanupCandidate], _ fixture: CleanupFixture,
                     inventory: CleanupInventory? = nil) async -> CleanupReport {
        await service.run(selection, inventory: inventory ?? fixture.inventory(), activity: CleanupActivity(),
                          options: fixture.options, now: fixture.now)
    }

    func testTrashesAWorktreePrunesItAndLogsTheRun() async throws {
        let fixture = try CleanupFixture()
        let done = try fixture.repository.addWorktree("app-done", branch: "done")
        let cache = try fixture.writeCache(".next", in: done)
        let (service, trash) = try service(fixture)
        let scan = await service.scan(inventory: fixture.inventory(), activity: CleanupActivity(),
                                      options: fixture.options, now: fixture.now)
        XCTAssertEqual(scan.eligible.compactMap(\.path).sorted(), [done, cache].sorted())

        let report = await run(service, scan.eligible, fixture)
        XCTAssertEqual(report.removed.count, 2, "the cache left with its worktree")
        XCTAssertEqual(report.bytesFreed, scan.candidate(done)?.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: done))
        XCTAssertEqual(trash.names, ["app-done"])
        XCTAssertEqual(GitClient().worktrees(repository: fixture.repository.root)?.map(\.path), [fixture.repository.root])

        let database = fixture.repository.container.path("hoply.sqlite")
        let store = try Store(path: database)
        try await store.logCleanup(report.logEntries)
        let log = try await StoreReader(path: database).cleanupLog()
        XCTAssertEqual(log.map(\.path), [done])
        XCTAssertEqual(log.first?.kind, .worktree)
        XCTAssertEqual(log.first?.bytes, report.bytesFreed)
        XCTAssertEqual(log.first?.detail, "done")
        XCTAssertEqual(try XCTUnwrap(log.first).timestamp.timeIntervalSince1970, fixture.now.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    func testAnItemThatChangedSinceTheScanIsSkippedWithItsReason() async throws {
        let fixture = try CleanupFixture()
        let done = try fixture.repository.addWorktree("app-done", branch: "done")
        let gone = try fixture.writeCache(".next")
        let (service, trash) = try service(fixture)
        let scan = await fixture.scan()
        try fixture.repository.write("late.txt", "written after the scan\n", in: done)
        try fixture.repository.moveAside(gone)

        let report = await run(service, scan.eligible, fixture)
        XCTAssertEqual(report.removed, [])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: report.items.map { ($0.candidate.path, $0.outcome) }),
                       [done: .skipped([.uncommittedChanges]), gone: .skipped([.missing])])
        XCTAssertTrue(FileManager.default.fileExists(atPath: done + "/late.txt"))
        XCTAssertEqual(trash.names, [])
        XCTAssertEqual(report.logEntries, [])
    }

    func testATranscriptLeavesWithItsSessionFolder() async throws {
        let fixture = try CleanupFixture()
        let main = try fixture.writeTranscript("-p/s1.jsonl")
        let subagent = try fixture.writeTranscript("-p/s1/subagents/agent-a.jsonl")
        let kept = try fixture.writeTranscript("-p/s2.jsonl")
        let inventory = fixture.inventory(cursors: fixture.ingested([main, subagent]))
        let (service, trash) = try service(fixture)
        let scan = await fixture.scan(inventory)

        let report = await run(service, scan.candidates, fixture, inventory: inventory)
        XCTAssertEqual(report.removed.map(\.candidate.path), [main])
        XCTAssertEqual(report.skipped.map(\.candidate.path), [kept])
        XCTAssertEqual(trash.names, ["s1", "s1.jsonl"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept))
    }

    func testWithoutALedgerNothingIsTrashed() async throws {
        let fixture = try CleanupFixture()
        let cache = try fixture.writeCache(".next")
        let (service, trash) = try service(fixture)
        let scan = await fixture.scan()

        let report = await service.run(scan.eligible, inventory: nil, activity: CleanupActivity(),
                                       options: fixture.options, now: fixture.now)
        XCTAssertEqual(report.items.map(\.outcome), [.skipped([.historyOff])])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache))
        XCTAssertEqual(trash.names, [])
    }

    func testTerminatesAnOrphanAndLogsIt() async throws {
        let fixture = try CleanupFixture()
        let child = try SpawnedProcess("/bin/sleep", ["60"])
        defer { child.cleanUp() }
        let identity = try XCTUnwrap(ProcessScanner.identity(of: child.pid))
        let orphan = OrphanProcess(identity: identity, name: "sleep", cwd: "/tmp", agent: .claudeCode, members: [identity])
        let (service, _) = try service(fixture)

        let report = await service.run([CleanupCandidate(orphan: orphan)], inventory: nil, activity: CleanupActivity(),
                                       options: fixture.options, now: fixture.now)
        XCTAssertEqual(report.items.map(\.outcome), [.terminated])
        XCTAssertNotNil(child.waitForExit())
        XCTAssertEqual(report.logEntries.map(\.kind), [.orphanProcess])
        XCTAssertEqual(report.logEntries.first?.detail, "sleep · pid \(child.pid) · terminated")
        XCTAssertEqual(report.bytesFreed, 0)

        let again = await service.run([CleanupCandidate(orphan: orphan)], inventory: nil, activity: CleanupActivity(),
                                      options: fixture.options, now: fixture.now)
        XCTAssertEqual(again.items.map(\.outcome), [.skipped([.process(.processGone)])])
    }

    func testAnOrphanWhosePidWasReusedIsLeftAlone() async throws {
        let fixture = try CleanupFixture()
        let child = try SpawnedProcess("/bin/sleep", ["60"])
        defer { child.cleanUp() }
        var stale = try XCTUnwrap(ProcessScanner.identity(of: child.pid))
        stale.startedAt = stale.startedAt.addingTimeInterval(-60)
        let orphan = OrphanProcess(identity: stale, name: "sleep", agent: .claudeCode, members: [stale])
        let (service, _) = try service(fixture)

        let report = await service.run([CleanupCandidate(orphan: orphan)], inventory: nil, activity: CleanupActivity(),
                                       options: fixture.options, now: fixture.now)
        XCTAssertEqual(report.items.map(\.outcome), [.skipped([.process(.identityChanged)])])
        XCTAssertTrue(child.isRunning)
    }
}
