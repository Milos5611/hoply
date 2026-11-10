@testable import AgentKit
import XCTest

private struct FakeFileSystem: ProjectFileSystem {
    var directories: Set<String> = []
    var files: [String: String] = [:]
    var links: [String: String] = [:]

    func realPath(_ path: String) -> String? {
        for (link, target) in links where path == link || path.hasPrefix(link + "/") {
            return target + path.dropFirst(link.count)
        }
        return path
    }

    func isDirectory(_ path: String) -> Bool { directories.contains(path) }
    func isFile(_ path: String) -> Bool { files[path] != nil }
    func readText(_ path: String) -> String? { files[path] }
}

final class ProjectResolverTests: XCTestCase {
    private let resolver = ProjectResolver(home: "/Users/dev")

    func testRepoFolderHomeAndScratch() {
        let fs = FakeFileSystem(directories: ["/Users/dev/Project/fiba/.git", "/Users/dev/.git"])
        XCTAssertEqual(resolver.resolve(cwd: "/Users/dev/Project/fiba/src/api", fileSystem: fs),
                       ProjectResolution(root: "/Users/dev/Project/fiba", name: "fiba", kind: .repo))
        XCTAssertEqual(resolver.resolve(cwd: "/Users/dev/Project/notes/", fileSystem: fs),
                       ProjectResolution(root: "/Users/dev/Project/notes", name: "notes", kind: .folder),
                       "a dotfiles repo at ~/.git must not swallow folders below home")
        XCTAssertEqual(resolver.resolve(cwd: "/Users/dev", fileSystem: fs).kind, .home)
        let scratch = "/Users/dev/Library/Application Support/Claude/scratch-workspaces/7b0f/scratch-2026-10-05"
        XCTAssertEqual(resolver.resolve(cwd: scratch, fileSystem: fs),
                       ProjectResolution(root: "/Users/dev/Library/Application Support/Claude/scratch-workspaces",
                                         name: "Scratch", kind: .scratch))
        XCTAssertEqual(resolver.resolve(cwd: "/tmp/x", fileSystem: fs).kind, .folder)
    }

    func testLinkedWorktreeBelongsToTheMainRepo() {
        let fs = FakeFileSystem(
            directories: ["/Users/dev/Project/fiba/.git"],
            files: [
                "/Users/dev/Project/fiba-wt/feature/.git": "gitdir: /Users/dev/Project/fiba/.git/worktrees/feature\n",
                "/Users/dev/Project/fiba/.git/worktrees/feature/commondir": "../..\n",
            ])
        XCTAssertEqual(resolver.resolve(cwd: "/Users/dev/Project/fiba-wt/feature/web", fileSystem: fs),
                       ProjectResolution(root: "/Users/dev/Project/fiba", name: "fiba", kind: .repo,
                                         worktree: "/Users/dev/Project/fiba-wt/feature"))
    }

    func testRelativeGitdirAndSubmodules() {
        let fs = FakeFileSystem(
            directories: ["/Users/dev/Project/app/.git"],
            files: [
                "/Users/dev/Project/app/.claude/worktrees/fix/.git": "gitdir: ../../../.git/worktrees/fix",
                "/Users/dev/Project/app/.git/worktrees/fix/commondir": "../..",
                "/Users/dev/Project/app/vendor/lib/.git": "gitdir: ../../.git/modules/lib",
            ])
        XCTAssertEqual(resolver.resolve(cwd: "/Users/dev/Project/app/.claude/worktrees/fix", fileSystem: fs),
                       ProjectResolution(root: "/Users/dev/Project/app", name: "app", kind: .repo,
                                         worktree: "/Users/dev/Project/app/.claude/worktrees/fix"))
        XCTAssertEqual(resolver.resolve(cwd: "/Users/dev/Project/app/vendor/lib", fileSystem: fs),
                       ProjectResolution(root: "/Users/dev/Project/app/vendor/lib", name: "lib", kind: .repo),
                       "a submodule (no commondir) is its own project")
    }

    func testSymlinkedCwdResolvesToTheRealRepo() {
        let fs = FakeFileSystem(directories: ["/Volumes/Work/fiba/.git"], links: ["/Users/dev/fiba": "/Volumes/Work/fiba"])
        XCTAssertEqual(resolver.resolve(cwd: "/Users/dev/fiba/src", fileSystem: fs).root, "/Volumes/Work/fiba")
    }

    func testPathHelpers() {
        XCTAssertEqual(ProjectResolver.standardize("/a//b/./c/../d/"), "/a/b/d")
        XCTAssertEqual(ProjectResolver.parent("/a"), "/")
        XCTAssertEqual(ProjectResolver.lastComponent("/a/b"), "b")
    }
}

final class LedgerInputTests: XCTestCase {
    func testHookMapperCarriesTranscriptPath() {
        let json: [String: Any] = ["hook_event_name": "Stop", "session_id": "s1", "cwd": "/w",
                                   "transcript_path": "/Users/dev/.claude/projects/-w/s1.jsonl"]
        let events = HookMapper.events(source: .claudeCode, eventName: nil, json: json)
        XCTAssertEqual(events.first?.transcriptPath, "/Users/dev/.claude/projects/-w/s1.jsonl")
        let copilot = HookMapper.events(source: .copilotCLI, eventName: "agentStop", json: ["sessionId": "c1"])
        XCTAssertNil(copilot.first?.transcriptPath)
    }

    func testNewSettingsDecodeLeniently() {
        let defaults = AppSettings()
        XCTAssertEqual(defaults.localModelPatterns, ["qwen"])
        XCTAssertEqual(defaults.referenceModel, "claude-sonnet-5-5")
        XCTAssertEqual(defaults.claudeConfigDir, "")
        let json = #"{"vllmName":"ZGX","localModelPatterns":"qwen","referenceModel":"claude-opus-5-5","claudeConfigDir":"~/alt"}"#
        let settings = AppSettings.decode(Data(json.utf8))
        XCTAssertEqual(settings.legacyModelServer?.name, "ZGX")
        XCTAssertEqual(settings.localModelPatterns, ["qwen"], "a wrongly typed list falls back to the default")
        XCTAssertEqual(settings.referenceModel, "claude-opus-5-5")
        XCTAssertEqual(settings.claudeConfigDir, "~/alt")
        var changed = AppSettings()
        changed.localModelPatterns = ["qwen", "llama"]
        XCTAssertEqual(AppSettings.decode(changed.encoded()), changed)
    }

    func testTokenMergeKeepsTheLargerValues() {
        let early = TokenCounts(input: 2, output: 16, reasoning: 8, cacheRead: 100, cacheWrite5m: 0, cacheWrite1h: 50)
        let late = TokenCounts(input: 2, output: 616, reasoning: 508, cacheRead: 100, cacheWrite5m: 0, cacheWrite1h: 50)
        XCTAssertEqual(early.merged(with: late), late)
        XCTAssertEqual(late.merged(with: early), late)
        XCTAssertEqual(late.total, 2 + 616 + 100 + 50)
    }
}
