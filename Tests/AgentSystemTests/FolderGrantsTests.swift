import AgentKit
@testable import AgentSystem
import Foundation
import os
import XCTest

final class FolderGrantsTests: XCTestCase {
    private final class FakeBookmarks: FolderBookmarks, @unchecked Sendable {
        struct State {
            var stale: Set<String> = []
            var gone: Set<String> = []
            var refused: Set<String> = []
            var started: [String] = []
            var stopped: [String] = []
            var created: [(path: String, readOnly: Bool)] = []
        }

        let state = OSAllocatedUnfairLock(initialState: State())

        func create(for url: URL, readOnly: Bool) throws -> Data {
            state.withLock { $0.created.append((url.path, readOnly)) }
            return Data("\(readOnly ? "ro" : "rw"):\(url.path)".utf8)
        }

        func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
            let path = String(String(decoding: data, as: UTF8.self).dropFirst(3))
            let (gone, stale) = state.withLock { ($0.gone.contains(path), $0.stale.contains(path)) }
            if gone { throw CocoaError(.fileNoSuchFile) }
            return (URL(fileURLWithPath: path), stale)
        }

        func startAccessing(_ url: URL) -> Bool {
            state.withLock { state in
                guard !state.refused.contains(url.path) else { return false }
                state.started.append(url.path)
                return true
            }
        }

        func stopAccessing(_ url: URL) {
            state.withLock { $0.stopped.append(url.path) }
        }
    }

    private final class Defaults: @unchecked Sendable {
        let lock = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let loads = OSAllocatedUnfairLock(initialState: 0)
        var data: Data? { lock.withLock { $0 } }
    }

    private func grants(_ edition: Edition = .appStore, bookmarks: FakeBookmarks, defaults: Defaults) -> FolderGrants {
        FolderGrants(edition: edition, bookmarks: bookmarks,
                     load: { defaults.loads.withLock { $0 += 1 }; return defaults.lock.withLock { $0 } },
                     store: { data in defaults.lock.withLock { $0 = data } })
    }

    private func folders(_ temp: TempDirectory) throws -> (claude: String, codex: String, copilot: String) {
        for name in ["claude", "codex", "copilot"] { try temp.mkdir(name) }
        return (FolderGrants.canonical(temp.path("claude")), FolderGrants.canonical(temp.path("codex")),
                FolderGrants.canonical(temp.path("copilot")))
    }

    func testTheDirectEditionNeverReadsOrNeedsGrants() throws {
        let temp = try TempDirectory()
        let paths = try folders(temp)
        let defaults = Defaults()
        let grants = grants(.direct, bookmarks: FakeBookmarks(), defaults: defaults)
        grants.activate()
        XCTAssertEqual(grants.access(for: .claude, at: paths.claude), .notNeeded)
        XCTAssertEqual(defaults.loads.withLock { $0 }, 0)
    }

    func testAGrantIsRememberedAndOpenedAtTheNextLaunch() throws {
        let temp = try TempDirectory()
        let paths = try folders(temp)
        let bookmarks = FakeBookmarks()
        let defaults = Defaults()
        let first = grants(bookmarks: bookmarks, defaults: defaults)
        XCTAssertEqual(first.access(for: .claude, at: paths.claude), .missing)
        XCTAssertEqual(first.access(for: .claude, at: temp.path("nowhere")), .notFound)

        let claude = try first.grant(URL(fileURLWithPath: paths.claude), for: .claude)
        XCTAssertEqual(claude, FolderGrant(folder: .claude, path: paths.claude, readOnly: false))
        try first.grant(URL(fileURLWithPath: paths.copilot), for: .copilot)
        XCTAssertEqual(first.access(for: .claude, at: paths.claude), .granted(paths.claude))
        XCTAssertEqual(first.access(for: .copilot, at: paths.copilot), .granted(paths.copilot))
        XCTAssertEqual(first.access(for: .codex, at: paths.codex), .missing)
        XCTAssertEqual(bookmarks.state.withLock { $0.created.map(\.readOnly) }, [false, false],
                       "read-write: Connect writes each agent's hook config")
        let saved = try XCTUnwrap(defaults.data)
        XCTAssertEqual(Set(try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any]).keys),
                       ["claude", "copilot"])

        let next = grants(bookmarks: bookmarks, defaults: defaults)
        next.activate()
        XCTAssertEqual(next.grants.map(\.folder), [.claude, .copilot])
        XCTAssertEqual(next.access(for: .claude, at: paths.claude), .granted(paths.claude))
        XCTAssertEqual(bookmarks.state.withLock { $0.started.filter { $0 == paths.claude }.count }, 2)
    }

    func testStaleBookmarksAreRefreshedAndBrokenOnesAskAgain() throws {
        let temp = try TempDirectory()
        let paths = try folders(temp)
        let bookmarks = FakeBookmarks()
        let defaults = Defaults()
        let first = grants(bookmarks: bookmarks, defaults: defaults)
        try first.grant(URL(fileURLWithPath: paths.claude), for: .claude)
        try first.grant(URL(fileURLWithPath: paths.codex), for: .codex)
        bookmarks.state.withLock { state in
            state.stale = [paths.claude]
            state.gone = [paths.codex]
            state.created = []
        }

        let next = grants(bookmarks: bookmarks, defaults: defaults)
        XCTAssertEqual(next.access(for: .claude, at: paths.claude), .granted(paths.claude))
        XCTAssertEqual(bookmarks.state.withLock { $0.created.map(\.path) }, [paths.claude], "re-created once")
        guard case .broken = next.access(for: .codex, at: paths.codex) else { return XCTFail("codex is broken") }
        XCTAssertTrue(next.access(for: .codex, at: paths.codex).asksForGrant)

        bookmarks.state.withLock { $0.gone = [] }
        try next.grant(URL(fileURLWithPath: paths.codex), for: .codex)
        XCTAssertEqual(next.access(for: .codex, at: paths.codex), .granted(paths.codex), "picked again")
    }

    func testRefusedAccessAndRevoking() throws {
        let temp = try TempDirectory()
        let paths = try folders(temp)
        let bookmarks = FakeBookmarks()
        let defaults = Defaults()
        let first = grants(bookmarks: bookmarks, defaults: defaults)
        try first.grant(URL(fileURLWithPath: paths.claude), for: .claude)
        bookmarks.state.withLock { $0.refused = [paths.claude] }
        let refused = grants(bookmarks: bookmarks, defaults: defaults)
        guard case .broken = refused.access(for: .claude, at: paths.claude) else { return XCTFail("refused") }

        first.revoke(.claude)
        XCTAssertEqual(first.access(for: .claude, at: paths.claude), .missing)
        XCTAssertEqual(bookmarks.state.withLock { $0.stopped }, [paths.claude])
        XCTAssertNil(defaults.data)
    }

    func testAHomeGrantCoversAllThree() throws {
        let temp = try TempDirectory()
        let paths = try folders(temp)
        let grants = grants(bookmarks: FakeBookmarks(), defaults: Defaults())
        try grants.grant(temp.url, for: .claude)
        let root = FolderGrants.canonical(temp.url.path)
        XCTAssertEqual(grants.access(for: .claude, at: paths.claude), .granted(root))
        XCTAssertEqual(grants.access(for: .codex, at: paths.codex), .granted(root))
        XCTAssertEqual(grants.access(for: .copilot, at: paths.copilot), .granted(root))
    }

    func testAReadOnlyGrantFromAnEarlierBuildAsksAgain() throws {
        let temp = try TempDirectory()
        let paths = try folders(temp)
        let bookmarks = FakeBookmarks()
        let defaults = Defaults()
        let legacy = ["claude": FolderGrants.Saved(bookmark: try bookmarks.create(for: temp.url, readOnly: true),
                                                   path: FolderGrants.canonical(temp.url.path), readOnly: true)]
        defaults.lock.withLock { $0 = try? JSONEncoder().encode(legacy) }
        let grants = grants(bookmarks: bookmarks, defaults: defaults)
        let root = FolderGrants.canonical(temp.url.path)
        for (folder, path) in [(AgentFolder.claude, paths.claude), (.codex, paths.codex), (.copilot, paths.copilot)] {
            XCTAssertEqual(grants.access(for: folder, at: path), .readOnly(root), "\(folder)")
        }

        try grants.grant(URL(fileURLWithPath: paths.claude), for: .claude)
        XCTAssertEqual(grants.access(for: .claude, at: paths.claude), .granted(paths.claude), "allowed again")
        XCTAssertEqual(grants.access(for: .codex, at: paths.codex), .missing, "the home grant was Claude's")
    }

    func testAFolderConnectWillCreateComparesOnItsResolvedParent() throws {
        let temp = try TempDirectory()
        let root = FolderGrants.canonical(temp.url.path)
        XCTAssertEqual(FolderGrants.canonical(temp.path("not-yet/.codex")), root + "/not-yet/.codex")
        XCTAssertEqual(FolderGrants.canonical(temp.path("a/../b/")), root + "/b")
    }

    func testLedgerReadsOnlyGrantedFoldersInTheStoreEdition() throws {
        let temp = try TempDirectory()
        let paths = try folders(temp)
        var settings = AppSettings()
        settings.claudeConfigDir = temp.path("claude")
        settings.codexHome = temp.path("codex")
        settings.copilotHome = temp.path("copilot")
        let grants = grants(bookmarks: FakeBookmarks(), defaults: Defaults())
        XCTAssertEqual(LedgerConfiguration(settings: settings, edition: .appStore, grants: grants).folders, [])
        try grants.grant(URL(fileURLWithPath: paths.codex), for: .codex)
        XCTAssertEqual(LedgerConfiguration(settings: settings, edition: .appStore, grants: grants).folders, [.codex])
        let direct = LedgerConfiguration(settings: settings, edition: .direct, grants: grants)
        XCTAssertEqual(direct.folders, Set(AgentFolder.allCases))
        XCTAssertEqual(direct.claudeConfigDirectory, temp.path("claude"))
    }

    func testRealSecurityScopedBookmarkRoundTrip() throws {
        let temp = try TempDirectory()
        let paths = try folders(temp)
        let defaults = Defaults()
        let grants = FolderGrants(edition: .appStore, load: { defaults.lock.withLock { $0 } },
                                  store: { data in defaults.lock.withLock { $0 = data } })
        try grants.grant(URL(fileURLWithPath: paths.copilot), for: .copilot)
        let next = FolderGrants(edition: .appStore, load: { defaults.lock.withLock { $0 } }, store: { _ in })
        XCTAssertEqual(next.access(for: .copilot, at: paths.copilot), .granted(paths.copilot))
    }
}

final class LedgerFoldersTests: XCTestCase {
    private let sessionID = "33333333-3333-4333-8333-333333333333"

    private func transcript() -> String {
        #"{"parentUuid":null,"isSidechain":false,"message":{"model":"claude-opus-5-5","id":"m1","type":"message","role":"assistant","content":[],"usage":{"input_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":10}},"requestId":"req_m1","type":"assistant","timestamp":"2026-11-09T10:00:05.000Z","cwd":"/Users/dev/Project/demo","sessionId":"\#(sessionID)"}"# + "\n"
    }

    private func ledger(_ directory: TempDirectory, folders: Set<AgentFolder>) throws -> Ledger {
        try Ledger(configuration: LedgerConfiguration(databasePath: directory.path("hoply.sqlite"),
                                                      claudeConfigDirectory: directory.path("claude"),
                                                      copilotHome: directory.path("copilot"),
                                                      pricingOverridesURL: nil, watchForChanges: false,
                                                      codexHome: directory.path("codex"), folders: folders))
    }

    func testAFolderWithoutAGrantIsNeverRead() async throws {
        let directory = try TempDirectory()
        try directory.write("claude/projects/-Users-dev-Project-demo/\(sessionID).jsonl", transcript())
        let key = SessionKey(source: .claudeCode, id: sessionID)

        let ungranted = try ledger(directory, folders: [.codex, .copilot])
        await ungranted.ingest.start()
        await ungranted.ingest.tailTranscript(atPath: directory.path("claude/projects/-Users-dev-Project-demo/\(sessionID).jsonl"))
        let progress = await ungranted.ingest.progress
        XCTAssertEqual(progress.filesTotal, 0)
        let none = try await ungranted.reader.session(key)
        XCTAssertNil(none)
        await ungranted.ingest.reindex()
        await ungranted.ingest.stop()

        let granted = try ledger(directory, folders: Set(AgentFolder.allCases))
        await granted.ingest.start()
        let read = try await granted.reader.session(key)
        XCTAssertEqual(read?.totals.calls, 1)
    }
}

final class UserHomeTests: XCTestCase {
    func testTheRealHomeComesFromTheAccount() throws {
        let entry = try XCTUnwrap(getpwuid(getuid()))
        XCTAssertEqual(UserHome.path, String(cString: entry.pointee.pw_dir))
        XCTAssertEqual(UserHome.expandingTilde("~/.claude"), UserHome.path + "/.claude")
        XCTAssertEqual(UserHome.expandingTilde("/abs"), "/abs")
        XCTAssertEqual(UserHome.abbreviating(UserHome.path + "/.copilot/hooks/hoply.json"), "~/.copilot/hooks/hoply.json")
    }

    func testDefaultsUseTheRealHome() {
        let environment = ProcessInfo.processInfo.environment
        if environment["CLAUDE_CONFIG_DIR"] == nil {
            XCTAssertEqual(ClaudeTranscriptIngester.defaultConfigDirectory, UserHome.path + "/.claude")
        }
        if environment["CODEX_HOME"] == nil {
            XCTAssertEqual(CodexRolloutIngester.defaultHome, UserHome.path + "/.codex")
        }
        if environment["COPILOT_HOME"] == nil {
            XCTAssertEqual(CopilotStoreIngester.defaultHome, UserHome.path + "/.copilot")
        }
    }
}
