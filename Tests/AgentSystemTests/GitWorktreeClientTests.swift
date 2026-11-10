import AgentKit
import AgentSystem
import Foundation
import XCTest

final class GitWorktreeClientTests: XCTestCase {
    private let client = GitClient()

    func testListsMainLinkedLockedAndDetachedWorktrees() throws {
        let repository = try TestRepository()
        let feature = try repository.addWorktree("app-feature", branch: "feature/x")
        let locked = try repository.addWorktree("app-locked", branch: "locked")
        try repository.git("worktree", "lock", locked)
        let detached = try repository.addWorktree("app-detached")

        let worktrees = try XCTUnwrap(client.worktrees(repository: repository.root))
        XCTAssertEqual(worktrees.first?.path, repository.root)
        XCTAssertEqual(Set(worktrees.map(\.path)), [repository.root, feature, locked, detached])
        let byPath = Dictionary(uniqueKeysWithValues: worktrees.map { ($0.path, $0) })
        XCTAssertEqual([repository.root, feature, locked, detached].map { byPath[$0]?.branch },
                       ["main", "feature/x", "locked", nil])
        XCTAssertEqual(worktrees.filter(\.isLocked).map(\.path), [locked])
        XCTAssertEqual(worktrees.filter(\.isDetached).map(\.path), [detached])
        XCTAssertTrue(worktrees.allSatisfy { $0.head?.count == 40 })
        XCTAssertEqual(client.worktrees(repository: feature)?.map(\.path), worktrees.map(\.path),
                       "asked from a linked worktree, the main one still comes first")
        XCTAssertEqual(client.gitDirectory(worktree: feature), repository.root + "/.git/worktrees/app-feature")
        XCTAssertNil(client.worktrees(repository: repository.container.url.path), "not a repository")
    }

    func testCleanAndDirtyWorktrees() throws {
        let repository = try TestRepository()
        let feature = try repository.addWorktree("app-feature", branch: "feature/x")
        XCTAssertEqual(client.isClean(worktree: feature), true)
        try repository.write(".next/build.js", "ignored\n", in: feature)
        XCTAssertEqual(client.isClean(worktree: feature), true, "ignored files are not work")
        try repository.write("new.txt", "untracked\n", in: feature)
        XCTAssertEqual(client.isClean(worktree: feature), false)
        XCTAssertEqual(client.isClean(worktree: repository.root), true, "each worktree has its own state")
        try repository.write("a.txt", "changed\n")
        XCTAssertEqual(client.isClean(worktree: repository.root), false)
        XCTAssertNil(client.isClean(worktree: repository.container.url.path))
        XCTAssertNil(GitClient(gitPath: repository.container.path("no-git")).isClean(worktree: feature))
    }

    func testDefaultBranchDetection() throws {
        let main = try TestRepository()
        XCTAssertEqual(client.defaultBranch(repository: main.root), "main")
        XCTAssertEqual(client.defaultBranch(repository: try TestRepository(defaultBranch: "master").root), "master")
        XCTAssertNil(client.defaultBranch(repository: try TestRepository(defaultBranch: "develop").root))

        try main.git("update-ref", "refs/remotes/origin/trunk", "HEAD")
        try main.git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk")
        XCTAssertEqual(client.defaultBranch(repository: main.root), "trunk", "origin/HEAD wins over a local main")
    }

    func testMergedIntoTheDefaultBranch() throws {
        let repository = try TestRepository()
        let feature = try repository.addWorktree("app-feature", branch: "feature/x")
        XCTAssertEqual(client.isMerged("refs/heads/feature/x", into: "main", repository: repository.root), true,
                       "a branch without commits of its own")
        try repository.write("b.txt", "work\n", in: feature)
        try repository.commit("work", in: feature)
        let head = try XCTUnwrap(client.worktrees(repository: repository.root)?.first { $0.path == feature }?.head)
        XCTAssertEqual(client.isMerged(head, into: "main", repository: repository.root), false)

        try repository.git("update-ref", "refs/remotes/origin/main", head)
        XCTAssertEqual(client.isMerged(head, into: "main", repository: repository.root), true,
                       "pushed and merged on origin, local main not pulled yet")
        try repository.git("update-ref", "-d", "refs/remotes/origin/main")
        XCTAssertEqual(client.isMerged(head, into: "main", repository: repository.root), false)

        try repository.git("merge", "-q", "--no-ff", "-m", "merge", "feature/x")
        XCTAssertEqual(client.isMerged(head, into: "main", repository: repository.root), true)
        XCTAssertNil(client.isMerged(head, into: "missing", repository: repository.root))
        XCTAssertNil(client.isMerged("0000000000000000000000000000000000000000", into: "main", repository: repository.root))
    }

    func testIgnoredNeverCoversTrackedFiles() throws {
        let repository = try TestRepository()
        try repository.write(".next/build.js", "x\n")
        try repository.write(".astro/cache.json", "x\n")
        XCTAssertEqual(client.isIgnored(repository.root + "/.next", repository: repository.root), true)
        XCTAssertEqual(client.isIgnored(repository.root + "/.astro", repository: repository.root), false)

        try repository.write(".turbo/kept.json", "x\n")
        try repository.git("add", "-f", ".turbo/kept.json")
        try repository.commit("track a file inside an ignored folder")
        XCTAssertEqual(client.isIgnored(repository.root + "/.turbo", repository: repository.root), false)
        XCTAssertNil(client.isIgnored(repository.container.path("x"), repository: repository.container.url.path))
    }

    func testPruneForgetsAWorktreeWhoseFolderIsGone() throws {
        let repository = try TestRepository()
        let feature = try repository.addWorktree("app-feature", branch: "feature/x")
        try repository.moveAside(feature)
        XCTAssertEqual(client.worktrees(repository: repository.root)?.map(\.isPrunable), [false, true])
        XCTAssertTrue(client.pruneWorktrees(repository: repository.root))
        XCTAssertEqual(client.worktrees(repository: repository.root)?.map(\.path), [repository.root])
        XCTAssertEqual(client.isMerged("refs/heads/feature/x", into: "main", repository: repository.root), true,
                       "the branch is still there")
    }

    func testReadCallsNeverWriteToTheRepository() throws {
        let repository = try TestRepository()
        let feature = try repository.addWorktree("app-feature", branch: "feature/x")
        try repository.write("a.txt", "changed\n", in: feature)
        try repository.write(".next/build.js", "x\n", in: feature)
        func snapshot() throws -> [String: Date] {
            var result: [String: Date] = [:]
            let root = URL(fileURLWithPath: repository.root + "/.git")
            for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) ?? .init() {
                result[url.path] = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            }
            return result
        }
        let before = try snapshot()
        XCTAssertNotNil(client.worktrees(repository: repository.root))
        XCTAssertEqual(client.isClean(worktree: feature), false)
        XCTAssertEqual(client.defaultBranch(repository: repository.root), "main")
        XCTAssertEqual(client.isMerged("refs/heads/feature/x", into: "main", repository: repository.root), true)
        XCTAssertEqual(client.isIgnored(feature + "/.next", repository: feature), true)
        XCTAssertNotNil(client.gitDirectory(worktree: feature))
        XCTAssertEqual(try snapshot(), before)
    }
}
