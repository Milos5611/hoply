import AgentKit
import AgentSystem
import Foundation
import XCTest

final class CleanupScannerTests: XCTestCase {
    func testProposesOnlyTheMergedCleanIdleWorktree() async throws {
        let fixture = try CleanupFixture()
        let repository = fixture.repository
        let done = try repository.addWorktree("app-done", branch: "done")
        let dirty = try repository.addWorktree("app-dirty", branch: "dirty")
        try repository.write("notes.txt", "work in progress\n", in: dirty)
        let ahead = try repository.addWorktree("app-ahead", branch: "ahead")
        try repository.write("b.txt", "two\n", in: ahead)
        try repository.commit("second", in: ahead)
        let locked = try repository.addWorktree("app-locked", branch: "locked")
        try repository.git("worktree", "lock", locked)

        let scan = await fixture.scan()
        XCTAssertEqual(scan.candidates.filter { $0.kind == .worktree }.compactMap(\.path).sorted(),
                       [ahead, dirty, done, locked].sorted(), "the main worktree is never a candidate")
        let proposal = try XCTUnwrap(scan.candidate(done))
        XCTAssertEqual(proposal.keepReasons, [])
        XCTAssertEqual(proposal.branch, "done")
        XCTAssertEqual(proposal.project, fixture.project)
        XCTAssertGreaterThan(proposal.bytes, 0)
        XCTAssertEqual(scan.candidate(dirty)?.keepReasons, [.uncommittedChanges])
        XCTAssertEqual(scan.candidate(ahead)?.keepReasons, [.notMerged(branch: "ahead", into: "main")])
        XCTAssertEqual(scan.candidate(locked)?.keepReasons, [.locked])
        XCTAssertEqual(scan.eligible.map(\.path), [done])
        XCTAssertEqual(scan.reclaimableBytes, proposal.bytes)
    }

    func testActivityKeepsAWorktree() async throws {
        let fixture = try CleanupFixture()
        let done = try fixture.repository.addWorktree("app-done", branch: "done")

        let fresh = await fixture.scan(now: Date())
        XCTAssertEqual(fresh.candidate(done)?.keepReasons, [.recentlyActive(idleDays: 0, requiredDays: 7)])

        let busy = CleanupActivity(sessionDirectories: [done + "/src"], devServerDirectories: [done])
        let watched = await fixture.scan(activity: busy)
        XCTAssertEqual(watched.candidate(done)?.keepReasons, [.sessionRunning, .devServerRunning])

        let recent = fixture.inventory(worktrees: [done]).projects[0]
        var inventory = fixture.inventory()
        inventory.projects[0].worktrees = recent.worktrees.map {
            CleanupInventory.Worktree(path: $0.path, lastActive: fixture.now.addingTimeInterval(-2 * 86_400))
        }
        let used = await fixture.scan(inventory)
        XCTAssertEqual(used.candidate(done)?.keepReasons, [.recentlyActive(idleDays: 2, requiredDays: 7)])
    }

    func testAFolderGitNoLongerTracksIsListedButKept() async throws {
        let fixture = try CleanupFixture()
        let stale = (fixture.repository.root as NSString).deletingLastPathComponent + "/app-stale"
        try fixture.repository.write("left.txt", "left behind\n", in: stale)

        let scan = await fixture.scan(fixture.inventory(worktrees: [stale]))
        let candidate = try XCTUnwrap(scan.candidate(stale))
        XCTAssertEqual(candidate.kind, .worktree)
        XCTAssertEqual(candidate.keepReasons, [.untrackedWorktree])
        XCTAssertGreaterThan(candidate.bytes, 0)
    }

    func testBuildCacheRules() async throws {
        let fixture = try CleanupFixture()
        let next = try fixture.writeCache("apps/web/.next")
        let small = try fixture.writeCache(".turbo", bytes: 16)
        let unignored = try fixture.writeCache(".build")
        try fixture.writeCache("node_modules/pkg")
        try fixture.writeCache("a/b/c/.next")

        let scan = await fixture.scan()
        XCTAssertEqual(scan.candidates.compactMap(\.path).sorted(), [unignored, small, next].sorted(),
                       "node_modules is opt-in and the walk stops at depth 3")
        XCTAssertEqual(scan.candidate(next)?.keepReasons, [])
        XCTAssertEqual(scan.candidate(next)?.title, "Next.js build")
        XCTAssertEqual(scan.candidate(unignored)?.keepReasons, [.notIgnored])
        guard case .tooSmall? = scan.candidate(small)?.keepReasons.first else { return XCTFail("small cache offered") }

        let active = await fixture.scan(activity: CleanupActivity(devServerDirectories: [fixture.repository.root]))
        XCTAssertEqual(active.candidate(next)?.keepReasons, [.devServerRunning])
        let recent = await fixture.scan(fixture.inventory(lastActive: fixture.now.addingTimeInterval(-86_400)))
        XCTAssertEqual(recent.candidate(next)?.keepReasons, [.recentlyActive(idleDays: 1, requiredDays: 14)])
    }

    func testNodeModulesOnlyWhenOptedIn() async throws {
        let fixture = try CleanupFixture(includeNodeModules: true)
        let modules = try fixture.writeCache("node_modules/pkg")
        let scan = await fixture.scan()
        XCTAssertEqual(scan.eligible.map(\.path), [(modules as NSString).deletingLastPathComponent])
    }

    func testTranscriptsNeedAgeAndACompleteIngest() async throws {
        let fixture = try CleanupFixture()
        let main = try fixture.writeTranscript("-p/s1.jsonl")
        let subagent = try fixture.writeTranscript("-p/s1/subagents/agent-a.jsonl")
        let partial = try fixture.writeTranscript("-p/s2.jsonl", "{}\n{}\n")
        let unread = try fixture.writeTranscript("-p/s3.jsonl")
        _ = try fixture.writeTranscript("-p/memory/MEMORY.md")
        var cursors = fixture.ingested([main, subagent])
        cursors.merge(fixture.ingested([partial], short: 3)) { $1 }

        let scan = await fixture.scan(fixture.inventory(cursors: cursors))
        XCTAssertEqual(scan.candidates.compactMap(\.path).sorted(), [main, partial, unread])
        XCTAssertEqual(scan.candidate(main)?.keepReasons, [])
        XCTAssertEqual(scan.candidate(partial)?.keepReasons, [.notFullyIngested])
        XCTAssertEqual(scan.candidate(unread)?.keepReasons, [.notFullyIngested])
        XCTAssertEqual(fixture.scanner.trashPaths(for: try XCTUnwrap(scan.candidate(main))),
                       [main, String(main.dropLast(".jsonl".count))])

        let young = await fixture.scan(fixture.inventory(cursors: cursors), now: Date().addingTimeInterval(86_400))
        XCTAssertEqual(young.candidate(main)?.keepReasons, [.recentlyWritten(ageDays: 1, requiredDays: 90)])
    }

    func testAnUnattendedScanSkipsPrivacyProtectedFolders() async throws {
        let fixture = try CleanupFixture()
        let home = CleanupFiles().canonical(fixture.repository.container.url.path)
        let root = home + "/Documents/site"
        let cache = try fixture.writeCache(".next", in: root)
        let project = CleanupInventory.Project(ref: ProjectRef(id: 2, root: root, name: "site", kind: .folder),
                                               lastActive: Date())
        let inventory = CleanupInventory(projects: [project], transcriptsDirectory: fixture.transcripts)

        let unattended = await fixture.scan(inventory)
        XCTAssertEqual(unattended.candidates, [])
        var options = fixture.options
        options.includesProtectedFolders = true
        let asked = await fixture.scanner.scan(inventory: inventory, activity: CleanupActivity(), options: options,
                                               now: fixture.now)
        XCTAssertEqual(asked.eligible.map(\.path), [cache])
    }
}
