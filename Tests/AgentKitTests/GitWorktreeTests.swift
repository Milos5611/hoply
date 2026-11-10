import AgentKit
import XCTest

final class GitWorktreeTests: XCTestCase {
    private func porcelain(_ records: [[String]]) -> Data {
        Data(records.map { $0.map { $0 + "\0" }.joined() + "\0" }.joined().utf8)
    }

    func testParsesEveryAttribute() {
        let output = porcelain([
            ["worktree /r/app", "HEAD 1111111111111111111111111111111111111111", "branch refs/heads/main"],
            ["worktree /r/app worktrees/feature x", "HEAD 2222222222222222222222222222222222222222",
             "branch refs/heads/feature/x", "locked agent is working"],
            ["worktree /r/detached", "HEAD 3333333333333333333333333333333333333333", "detached", "locked"],
            ["worktree /r/gone", "HEAD 4444444444444444444444444444444444444444", "branch refs/heads/old",
             "prunable gitdir file points to non-existent location"],
        ])
        XCTAssertEqual(GitWorktree.parse(porcelainZ: output), [
            GitWorktree(path: "/r/app", head: "1111111111111111111111111111111111111111", branch: "main"),
            GitWorktree(path: "/r/app worktrees/feature x", head: "2222222222222222222222222222222222222222",
                        branch: "feature/x", isLocked: true),
            GitWorktree(path: "/r/detached", head: "3333333333333333333333333333333333333333", isDetached: true,
                        isLocked: true),
            GitWorktree(path: "/r/gone", head: "4444444444444444444444444444444444444444", branch: "old",
                        isPrunable: true),
        ])
    }

    func testBareRepositoryAndMissingSeparators() {
        let bare = porcelain([["worktree /r/app.git", "bare"], ["worktree /r/app-x", "HEAD abc", "branch refs/heads/x"]])
        XCTAssertEqual(GitWorktree.parse(porcelainZ: bare), [
            GitWorktree(path: "/r/app.git", isBare: true),
            GitWorktree(path: "/r/app-x", head: "abc", branch: "x"),
        ])
        let unterminated = Data("worktree /r/a\0HEAD abc\0worktree /r/b\0detached".utf8)
        XCTAssertEqual(GitWorktree.parse(porcelainZ: unterminated).map(\.path), ["/r/a", "/r/b"])
        XCTAssertEqual(GitWorktree.parse(porcelainZ: Data()), [])
        XCTAssertEqual(GitWorktree.parse(porcelainZ: Data("HEAD abc\0\0".utf8)), [], "attributes without a worktree")
    }
}
