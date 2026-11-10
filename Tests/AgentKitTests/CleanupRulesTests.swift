import XCTest
@testable import AgentKit

final class CleanupRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let rules = CleanupRules()
    private let megabyte: Int64 = 1_048_576

    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func worktree(clean: Bool? = true, merged: Bool? = true, defaultBranch: String? = "main",
                          idleDays: Double? = 8) -> WorktreeFacts {
        WorktreeFacts(isClean: clean, branch: "feature/x", defaultBranch: defaultBranch, isMerged: merged,
                      lastActive: idleDays.map(daysAgo))
    }

    private func cache(megabytes: Int64 = 51, ignore: CacheFacts.IgnoreState = .ignored, idleDays: Double? = 15) -> CacheFacts {
        CacheFacts(bytes: megabytes * megabyte, ignoreState: ignore, projectLastActive: idleDays.map(daysAgo))
    }

    private func transcript(ageDays: Double = 91, offset: Int64? = 100, inode: UInt64? = 7) -> TranscriptFacts.File {
        TranscriptFacts.File(inode: 7, size: 100, modified: daysAgo(ageDays), ingestedInode: inode, ingestedOffset: offset)
    }

    func testMergedCleanIdleWorktreeIsEligible() {
        XCTAssertEqual(rules.keepReasons(for: worktree(), now: now), [])
    }

    func testEveryWorktreeKeepReason() {
        var facts = worktree()
        facts.isMain = true
        XCTAssertEqual(rules.keepReasons(for: facts, now: now), [.mainWorktree])
        facts = worktree()
        facts.isLocked = true
        XCTAssertEqual(rules.keepReasons(for: facts, now: now), [.locked])
        XCTAssertEqual(rules.keepReasons(for: worktree(clean: false), now: now), [.uncommittedChanges])
        XCTAssertEqual(rules.keepReasons(for: worktree(merged: false), now: now),
                       [.notMerged(branch: "feature/x", into: "main")])
        facts = worktree()
        facts.hasLiveSession = true
        facts.hasDevServer = true
        XCTAssertEqual(rules.keepReasons(for: facts, now: now), [.sessionRunning, .devServerRunning])
        XCTAssertEqual(rules.keepReasons(for: worktree(idleDays: 3.5), now: now),
                       [.recentlyActive(idleDays: 3, requiredDays: 7)])
        XCTAssertEqual(rules.keepReasons(for: worktree(idleDays: nil), now: now), [.activityUnknown])
    }

    func testUnknownGitStateIsNeverEligible() {
        XCTAssertEqual(rules.keepReasons(for: worktree(clean: nil), now: now), [.gitStateUnknown])
        XCTAssertEqual(rules.keepReasons(for: worktree(merged: nil), now: now), [.gitStateUnknown])
        XCTAssertEqual(rules.keepReasons(for: worktree(merged: nil, defaultBranch: nil), now: now), [.gitStateUnknown])
        XCTAssertEqual(rules.keepReasons(for: worktree(clean: false, merged: nil), now: now),
                       [.gitStateUnknown, .uncommittedChanges])
    }

    func testAnUntrackedWorktreeFolderIsOnlyEverListed() {
        var facts = worktree()
        facts.isTracked = false
        XCTAssertEqual(rules.keepReasons(for: facts, now: now), [.untrackedWorktree])
    }

    func testWorktreeIdleBoundaryIsExclusive() {
        XCTAssertEqual(rules.keepReasons(for: worktree(idleDays: 7), now: now),
                       [.recentlyActive(idleDays: 7, requiredDays: 7)])
        XCTAssertEqual(rules.keepReasons(for: worktree(idleDays: 7.001), now: now), [])
    }

    func testCacheRules() {
        XCTAssertEqual(rules.keepReasons(for: cache(), now: now), [])
        XCTAssertEqual(rules.keepReasons(for: cache(ignore: .notInRepository), now: now), [])
        XCTAssertEqual(rules.keepReasons(for: cache(ignore: .notIgnored), now: now), [.notIgnored])
        XCTAssertEqual(rules.keepReasons(for: cache(ignore: .unknown), now: now), [.gitStateUnknown])
        XCTAssertEqual(rules.keepReasons(for: cache(megabytes: 50), now: now),
                       [.tooSmall(bytes: 50 * megabyte, minimumBytes: 50 * megabyte)])
        XCTAssertEqual(rules.keepReasons(for: cache(idleDays: 14), now: now),
                       [.recentlyActive(idleDays: 14, requiredDays: 14)])
        XCTAssertEqual(rules.keepReasons(for: cache(idleDays: nil), now: now), [.activityUnknown])
        var facts = cache()
        facts.hasLiveSession = true
        facts.hasDevServer = true
        XCTAssertEqual(rules.keepReasons(for: facts, now: now), [.sessionRunning, .devServerRunning])
    }

    func testTranscriptRules() {
        XCTAssertEqual(rules.keepReasons(for: TranscriptFacts(files: [transcript(), transcript(ageDays: 200)]), now: now), [])
        XCTAssertEqual(rules.keepReasons(for: TranscriptFacts(files: [transcript(), transcript(ageDays: 12)]), now: now),
                       [.recentlyWritten(ageDays: 12, requiredDays: 90)])
        XCTAssertEqual(rules.keepReasons(for: TranscriptFacts(files: [transcript(ageDays: 90)]), now: now),
                       [.recentlyWritten(ageDays: 90, requiredDays: 90)])
        for partial in [transcript(offset: 99), transcript(offset: nil, inode: nil), transcript(inode: 8)] {
            XCTAssertEqual(rules.keepReasons(for: TranscriptFacts(files: [transcript(), partial]), now: now),
                           [.notFullyIngested])
        }
        XCTAssertEqual(rules.keepReasons(for: TranscriptFacts(files: []), now: now), [.missing])
    }

    func testThresholdsFollowSettings() {
        var settings = AppSettings()
        XCTAssertEqual(CleanupRules.Thresholds(settings: settings), CleanupRules.Thresholds())
        XCTAssertFalse(CleanupRules.Thresholds().includeNodeModules)
        settings.cleanupIncludesNodeModules = true
        XCTAssertTrue(CleanupRules.Thresholds(settings: settings).includeNodeModules)
    }

    func testBuildCacheCatalogue() {
        func match(_ name: String, nodeModules: Bool = false, siblings: Set<String> = []) -> String? {
            BuildCache.match(directoryName: name, includeNodeModules: nodeModules) { siblings.contains($0) }?.label
        }
        XCTAssertEqual(match(".next"), "Next.js build")
        XCTAssertEqual(match("DerivedData"), "Xcode DerivedData")
        XCTAssertNil(match("build"))
        XCTAssertNil(match("target"), "only next to a Cargo.toml")
        XCTAssertEqual(match("target", siblings: ["Cargo.toml"]), "Cargo target")
        XCTAssertNil(match("node_modules"))
        XCTAssertEqual(match("node_modules", nodeModules: true), "node_modules")
        XCTAssertFalse(BuildCache.isWalkable(directoryName: ".git"))
        XCTAssertFalse(BuildCache.isWalkable(directoryName: "node_modules"))
        XCTAssertTrue(BuildCache.isWalkable(directoryName: "packages"))
        XCTAssertEqual(Set(BuildCache.catalogue.map(\.directoryName)).count, BuildCache.catalogue.count)
    }

    func testPrivacyProtectedFolders() {
        let home = "/Users/dev"
        for path in ["/Users/dev/Documents", "/Users/dev/Documents/app", "/Users/dev/Desktop/x", "/Users/dev/Downloads/y/z",
                     "/Users/dev/Library/Mobile Documents/com~apple~CloudDocs/app"] {
            XCTAssertTrue(CleanupRules.isPrivacyProtected(path, home: home), path)
        }
        for path in ["/Users/dev", "/Users/dev/Project/app", "/Users/dev/DocumentsOld", "/Users/dev/Library/Caches",
                     "/Users/other/Documents/app"] {
            XCTAssertFalse(CleanupRules.isPrivacyProtected(path, home: home), path)
        }
    }

    func testTrashGuard() {
        let trashGuard = TrashGuard(home: "/Users/dev", projectRoots: ["/Users/dev/Project/app", "/Users/dev/Project"],
                                    worktrees: ["/Users/dev/worktrees/app-x"],
                                    transcriptsDirectory: "/Users/dev/.claude/projects")
        for path in ["/Users/dev/Project/app/.next", "/Users/dev/worktrees/app-x", "/Users/dev/worktrees/app-x/.build",
                     "/Users/dev/.claude/projects/-Users-dev/abc.jsonl", "/Users/dev/.claude/projects/-Users-dev/abc"] {
            XCTAssertTrue(trashGuard.allows(path), path)
        }
        for path in ["/", "", "/Users", "/Users/dev", "/Users/dev/", "/Users/dev/Project", "/Users/dev/Project/app",
                     "/Users/dev/Project/app/", "/Users/dev/other/.next", "/Users/dev/worktrees",
                     "/Users/dev/.claude/projects", "/Users/dev/.claude/projects/-Users-dev", "/Users/dev/.claude/settings.json",
                     "/Users/dev/Project/app/../../.ssh", "relative/.next"] {
            XCTAssertFalse(trashGuard.allows(path), path)
        }
    }

    func testExplanations() {
        let megabytes = 12 * megabyte
        let expected: [(CleanupKeepReason, String)] = [
            (.mainWorktree, "Main worktree"), (.locked, "Locked"), (.gitStateUnknown, "Could not read git state"),
            (.uncommittedChanges, "Has uncommitted changes"),
            (.notMerged(branch: "feature/x", into: "main"), "Branch feature/x is not merged into main"),
            (.notMerged(branch: nil, into: "main"), "Detached HEAD is not part of main"),
            (.untrackedWorktree, "Git no longer tracks this worktree; remove it yourself"),
            (.sessionRunning, "A session is running here"), (.devServerRunning, "A dev server is running here"),
            (.recentlyActive(idleDays: 3, requiredDays: 7), "Active 3 days ago; needs 7 idle days"),
            (.recentlyActive(idleDays: 0, requiredDays: 14), "Active today; needs 14 idle days"),
            (.recentlyWritten(ageDays: 1, requiredDays: 90), "Last written 1 day ago; needs 90 days"),
            (.tooSmall(bytes: megabytes, minimumBytes: 50 * megabyte), "Only 12 MB"),
            (.notIgnored, "Not ignored by git"), (.notFullyIngested, "Not fully ingested yet"),
            (.process(.identityChanged), "Another process now has this process id"),
            (.process(.includesAgent), "An agent session runs in its process tree"),
        ]
        for (reason, text) in expected { XCTAssertEqual(reason.explanation, text) }
    }
}
