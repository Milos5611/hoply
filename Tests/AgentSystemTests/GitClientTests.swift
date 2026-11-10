import AgentKit
import AgentSystem
import Foundation
import XCTest

final class GitClientTests: XCTestCase {
    private func git(_ arguments: [String], in directory: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                             "-c", "init.defaultBranch=main"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    private func repository() throws -> TempDirectory {
        let directory = try TempDirectory()
        try git(["init", "-q"], in: directory.url.path)
        try directory.write("a.txt", "one\ntwo\nthree\n")
        try directory.write("src/b.txt", "keep\n")
        try directory.write(".gitignore", "ignored/\n")
        try git(["add", "."], in: directory.url.path)
        try git(["commit", "-q", "-m", "first"], in: directory.url.path)
        return directory
    }

    func testCleanRepository() throws {
        let directory = try repository()
        XCTAssertEqual(GitClient().diffStat(worktree: directory.url.path), GitDiffStat())
    }

    func testChangesAgainstHeadAndUntrackedFiles() throws {
        let directory = try repository()
        try directory.write("a.txt", "one\n2\nthree\nfour\nfive\n")
        try directory.write("src/b.txt", "")
        try directory.write("staged.txt", "s1\ns2\n")
        try git(["add", "staged.txt"], in: directory.url.path)
        try directory.write("new.txt", "untracked\n")
        try directory.write("src/deep/other new.txt", "untracked\n")
        try directory.write("ignored/build.o", "x\n")

        let expected = GitDiffStat(filesChanged: 3, added: 5, removed: 2, untracked: 2)
        XCTAssertEqual(GitClient().diffStat(worktree: directory.url.path), expected)
        XCTAssertEqual(GitClient().diffStat(worktree: directory.path("src")), expected,
                       "a subfolder reports its whole worktree")
    }

    func testNeverWritesToTheRepository() throws {
        let directory = try repository()
        try directory.write("a.txt", "changed\n")
        func snapshot() throws -> [String: Date] {
            var result: [String: Date] = [:]
            let root = directory.url.appendingPathComponent(".git")
            for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) ?? .init() {
                result[url.path] = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            }
            return result
        }
        let before = try snapshot()
        XCTAssertNotNil(GitClient().diffStat(worktree: directory.url.path))
        XCTAssertEqual(try snapshot(), before, "no index refresh, no lock files")
    }

    func testRepositoryWithoutCommitsCountsUntracked() throws {
        let directory = try TempDirectory()
        try git(["init", "-q"], in: directory.url.path)
        try directory.write("a.txt", "one\n")
        XCTAssertEqual(GitClient().diffStat(worktree: directory.url.path), GitDiffStat(untracked: 1))
    }

    func testNotARepositoryOrMissingGit() throws {
        let directory = try TempDirectory()
        try directory.write("a.txt", "one\n")
        XCTAssertNil(GitClient().diffStat(worktree: directory.url.path))
        XCTAssertNil(GitClient().diffStat(worktree: directory.path("missing")))
        let repo = try repository()
        XCTAssertNil(GitClient(gitPath: directory.path("no-git")).diffStat(worktree: repo.url.path))
    }

    func testTimeout() throws {
        let directory = try repository()
        let slow = try directory.write("slow-git", "#!/bin/sh\nsleep 5\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow)
        let started = Date()
        XCTAssertNil(GitClient(gitPath: slow, timeout: 0.3).diffStat(worktree: directory.url.path))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testCacheRefreshesOnDemand() async throws {
        let directory = try repository()
        let path = directory.url.path
        let cache = GitStatCache()
        let none = await cache.cached(path)
        XCTAssertNil(none)
        let clean = await cache.stat(for: path)
        XCTAssertEqual(clean, GitDiffStat())

        try directory.write("new.txt", "x\n")
        let stale = await cache.stat(for: path)
        XCTAssertEqual(stale, GitDiffStat(), "served from the cache until refreshed")
        let fresh = await cache.refresh(path)
        XCTAssertEqual(fresh, GitDiffStat(untracked: 1))
        let cached = await cache.cached(path)
        XCTAssertEqual(cached, fresh)

        let plain = try TempDirectory()
        let missing = await cache.refresh(plain.url.path)
        XCTAssertNil(missing)
        let all = await cache.all()
        XCTAssertEqual(all, [path: GitDiffStat(untracked: 1)])
    }
}
