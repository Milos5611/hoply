import AgentKit
import AgentSystem
import Foundation
import XCTest

/// `ProjectResolver` against a real filesystem: a temp repo with a linked worktree laid out the way git does it.
final class ProjectRegistryTests: XCTestCase {
    private func makeRepo() throws -> (TempDirectory, repo: String, worktree: String) {
        let directory = try TempDirectory()
        let fs = LocalProjectFileSystem()
        let root = try XCTUnwrap(fs.realPath(directory.url.path))
        try directory.mkdir("corestory/.git/worktrees/feature")
        try directory.mkdir("corestory/src/api")
        try directory.write("corestory/.git/worktrees/feature/commondir", "../..\n")
        try directory.write("corestory-feature/.git", "gitdir: \(root)/corestory/.git/worktrees/feature\n")
        try directory.mkdir("corestory-feature/web")
        try directory.mkdir("plain/sub")
        try FileManager.default.createSymbolicLink(atPath: directory.path("link"), withDestinationPath: directory.path("corestory"))
        return (directory, root + "/corestory", root + "/corestory-feature")
    }

    func testResolverOnARealRepoAndWorktree() throws {
        let (directory, repo, worktree) = try makeRepo()
        let fs = LocalProjectFileSystem()
        let resolver = ProjectResolver(home: "/nonexistent-home")
        XCTAssertEqual(resolver.resolve(cwd: directory.path("corestory/src/api"), fileSystem: fs),
                       ProjectResolution(root: repo, name: "corestory", kind: .repo))
        XCTAssertEqual(resolver.resolve(cwd: directory.path("corestory-feature/web"), fileSystem: fs),
                       ProjectResolution(root: repo, name: "corestory", kind: .repo, worktree: worktree))
        XCTAssertEqual(resolver.resolve(cwd: directory.path("link/src"), fileSystem: fs).root, repo)
        XCTAssertEqual(resolver.resolve(cwd: directory.path("plain/sub"), fileSystem: fs).kind, .folder)
        XCTAssertTrue(fs.isDirectory(repo + "/.git"))
        XCTAssertTrue(fs.isFile(worktree + "/.git"))
        XCTAssertFalse(fs.isFile(repo + "/.git"))
    }

    func testStoreGroupsWorktreeSessionsUnderTheMainRepo() async throws {
        let (directory, repo, worktree) = try makeRepo()
        let path = directory.path("hoply.sqlite")
        let store = try Store(path: path, resolver: ProjectResolver(home: "/nonexistent-home"))
        let reader = try StoreReader(path: path)
        let t0 = Date(timeIntervalSince1970: 1_794_200_000)
        func update(_ id: String, _ cwd: String) -> SessionUpdate {
            SessionUpdate(key: SessionKey(source: .claudeCode, id: id), firstAt: t0, lastAt: t0, cwd: cwd)
        }
        try await store.apply(LedgerBatch(sessions: [update("main", directory.path("corestory/src")),
                                                     update("wt", directory.path("corestory-feature/web"))]))
        let page = try await reader.sessions(in: DateInterval(start: t0.addingTimeInterval(-1), duration: 10))
        XCTAssertEqual(page.totalCount, 2)
        XCTAssertEqual(Set(page.sessions.compactMap(\.project?.root)), [repo])
        XCTAssertEqual(page.sessions.first { $0.key.id == "wt" }?.worktree, worktree)
        XCTAssertNil(page.sessions.first { $0.key.id == "main" }?.worktree)
    }
}
