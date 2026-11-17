import AgentKit
import Foundation
import XCTest

final class EditionTests: XCTestCase {
    func testTheTestBuildIsTheDirectEdition() {
        XCTAssertEqual(Edition.current, .direct)
    }

    func testWhatEachEditionMayDo() {
        XCTAssertEqual(Edition.direct.agentConfigWrites, .always)
        XCTAssertFalse(Edition.direct.needsFolderGrants)
        XCTAssertTrue(Edition.direct.opensTerminal)
        XCTAssertTrue(Edition.direct.offersPhoneLaunch)

        XCTAssertEqual(Edition.appStore.agentConfigWrites, .withinReadWriteGrant)
        XCTAssertTrue(Edition.appStore.needsFolderGrants)
        XCTAssertFalse(Edition.appStore.opensTerminal)
        XCTAssertFalse(Edition.appStore.offersPhoneLaunch, "starting a session from the iPhone needs Terminal")
    }

    func testTheStoreEditionWritesAgentConfigOnlyInsideAReadWriteGrant() {
        let claude = FolderGrant(folder: .claude, path: "/Users/x/.claude", readOnly: false)
        let readOnlyHome = FolderGrant(folder: .codex, path: "/Users/x", readOnly: true)
        let home = FolderGrant(folder: .copilot, path: "/Users/x", readOnly: false)

        XCTAssertTrue(Edition.direct.writesAgentConfig(at: "/Users/x/.claude", grants: []))
        XCTAssertTrue(Edition.direct.writesAgentConfig(at: "/anywhere", grants: [readOnlyHome]))

        let store = Edition.appStore
        XCTAssertFalse(store.writesAgentConfig(at: "/Users/x/.claude", grants: []))
        XCTAssertTrue(store.writesAgentConfig(at: "/Users/x/.claude", grants: [claude]))
        XCTAssertTrue(store.writesAgentConfig(at: "/Users/x/.claude/hooks", grants: [claude]))
        XCTAssertFalse(store.writesAgentConfig(at: "/Users/x/.claude-work", grants: [claude]))
        XCTAssertFalse(store.writesAgentConfig(at: "/Users/x/.codex", grants: [claude]))
        XCTAssertFalse(store.writesAgentConfig(at: "/Users/x/.codex", grants: [readOnlyHome]),
                       "a read-only grant from an earlier build never allows a write")
        for path in ["/Users/x/.claude", "/Users/x/.codex", "/Users/x/.copilot/hooks"] {
            XCTAssertTrue(store.writesAgentConfig(at: path, grants: [readOnlyHome, home]), path)
        }
    }

    func testTildeFollowsTheGivenHomeNotTheProcessHome() {
        let home = "/Users/x"
        XCTAssertEqual(HomePath.expandingTilde("~", home: home), "/Users/x")
        XCTAssertEqual(HomePath.expandingTilde("~/.claude", home: home), "/Users/x/.claude")
        XCTAssertEqual(HomePath.expandingTilde("~/.claude", home: "/Users/x/"), "/Users/x/.claude")
        XCTAssertEqual(HomePath.expandingTilde("/work/~/x", home: home), "/work/~/x")
        XCTAssertEqual(HomePath.expandingTilde("~other/x", home: home), "~other/x")
        XCTAssertEqual(HomePath.expandingTilde("relative", home: home), "relative")

        XCTAssertEqual(HomePath.abbreviating("/Users/x", home: home), "~")
        XCTAssertEqual(HomePath.abbreviating("/Users/x/.codex/hooks.json", home: home), "~/.codex/hooks.json")
        XCTAssertEqual(HomePath.abbreviating("/Users/xy/.codex", home: home), "/Users/xy/.codex")
        XCTAssertEqual(HomePath.abbreviating("/etc", home: "/"), "/etc")
    }
}

final class AgentFolderTests: XCTestCase {
    private let home = "/Users/x"

    func testSettingWinsOverEnvironmentOverHome() {
        var settings = AppSettings()
        XCTAssertEqual(AgentFolder.claude.path(settings: settings, environment: [:], home: home), "/Users/x/.claude")
        XCTAssertEqual(AgentFolder.codex.path(settings: settings, environment: [:], home: home), "/Users/x/.codex")
        XCTAssertEqual(AgentFolder.copilot.path(settings: settings, environment: ["COPILOT_HOME": " "], home: home),
                       "/Users/x/.copilot")
        let environment = ["CLAUDE_CONFIG_DIR": "~/work-claude", "CODEX_HOME": "/scratch/codex", "COPILOT_HOME": ""]
        XCTAssertEqual(AgentFolder.claude.path(settings: settings, environment: environment, home: home),
                       "/Users/x/work-claude")
        XCTAssertEqual(AgentFolder.codex.path(settings: settings, environment: environment, home: home), "/scratch/codex")
        settings.claudeConfigDir = " ~/saved-claude "
        settings.copilotHome = "/saved/copilot"
        XCTAssertEqual(AgentFolder.claude.path(settings: settings, environment: environment, home: home),
                       "/Users/x/saved-claude")
        XCTAssertEqual(AgentFolder.copilot.path(settings: settings, environment: environment, home: home),
                       "/saved/copilot")
    }

    func testEachFolderBelongsToOneAgent() {
        XCTAssertEqual(AgentFolder.allCases.map(\.agent), [.claudeCode, .codexCLI, .copilotCLI])
        XCTAssertEqual(AgentFolder.allCases.map(\.environmentKey), ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "COPILOT_HOME"])
    }

    private func access(_ folder: AgentFolder, _ path: String, exists: Bool = true, edition: Edition = .appStore,
                        _ grants: [FolderGrant], failures: [AgentFolder: String] = [:]) -> FolderAccess {
        FolderGrantRules.access(for: folder, at: path, exists: exists, edition: edition, grants: grants,
                                failures: failures)
    }

    func testTheDirectEditionNeedsNoGrants() {
        XCTAssertEqual(access(.claude, "/Users/x/.claude", edition: .direct, []), .notNeeded)
        XCTAssertEqual(access(.copilot, "/Users/x/.copilot", exists: false, edition: .direct, []), .notNeeded)
        XCTAssertTrue(FolderAccess.notNeeded.allowsReading)
    }

    func testAGrantCoversItsFolderAndEverythingBelow() {
        let claude = FolderGrant(folder: .claude, path: "/Users/x/.claude/", readOnly: false)
        XCTAssertEqual(claude.path, "/Users/x/.claude")
        XCTAssertEqual(access(.claude, "/Users/x/.claude", [claude]), .granted("/Users/x/.claude"))
        XCTAssertEqual(access(.codex, "/Users/x/.codex", [claude]), .missing)
        XCTAssertEqual(access(.codex, "/Users/x/.codex", exists: false, [claude]), .notFound,
                       "no picker for an agent that isn't installed")

        let home = FolderGrant(folder: .claude, path: "/Users/x", readOnly: false)
        for folder in AgentFolder.allCases {
            XCTAssertEqual(access(folder, "/Users/x/" + folder.defaultName, [home]), .granted("/Users/x"),
                           "one home grant covers all three")
        }
        let codexHome = FolderGrant(folder: .codex, path: "/Users/x", readOnly: false)
        XCTAssertEqual(access(.claude, "/Users/x/.claude", [codexHome, claude]), .granted("/Users/x/.claude"),
                       "the folder's own grant is named first")
    }

    func testAReadOnlyGrantFromAnEarlierBuildAsksAgain() {
        let readOnlyHome = FolderGrant(folder: .claude, path: "/Users/x", readOnly: true)
        for folder in AgentFolder.allCases {
            let state = access(folder, "/Users/x/" + folder.defaultName, [readOnlyHome])
            XCTAssertEqual(state, .readOnly("/Users/x"), "\(folder)")
            XCTAssertTrue(state.asksForGrant)
            XCTAssertFalse(state.allowsReading)
        }
        let copilot = FolderGrant(folder: .copilot, path: "/Users/x/.copilot", readOnly: false)
        XCTAssertEqual(access(.copilot, "/Users/x/.copilot", [readOnlyHome, copilot]), .granted("/Users/x/.copilot"))
        let ownReadOnly = FolderGrant(folder: .codex, path: "/Users/x/.codex", readOnly: true)
        let readWriteHome = FolderGrant(folder: .claude, path: "/Users/x", readOnly: false)
        XCTAssertEqual(access(.codex, "/Users/x/.codex", [ownReadOnly, readWriteHome]), .granted("/Users/x"),
                       "a read-write grant on a parent wins over the folder's own read-only one")
    }

    func testAStaleOrMovedGrantAsksAgain() {
        let elsewhere = FolderGrant(folder: .claude, path: "/Users/x/old-claude", readOnly: true)
        XCTAssertEqual(access(.claude, "/Users/x/.claude", [elsewhere]), .elsewhere("/Users/x/old-claude"))
        XCTAssertEqual(access(.claude, "/Users/x/.claude", [], failures: [.claude: "gone"]), .broken("gone"))
        XCTAssertEqual(access(.claude, "/Users/x/.claude", [FolderGrant(folder: .codex, path: "/Users/x", readOnly: false)],
                              failures: [.claude: "gone"]),
                       .granted("/Users/x"), "another folder's grant still covers it")
        for state in [FolderAccess.missing, .elsewhere("/a"), .readOnly("/a"), .broken("x")] {
            XCTAssertTrue(state.asksForGrant, "\(state)")
            XCTAssertFalse(state.allowsReading, "\(state)")
        }
        for state in [FolderAccess.notNeeded, .granted("/a"), .notFound] {
            XCTAssertFalse(state.asksForGrant, "\(state)")
        }
    }

    func testReadableFoldersAndPicks() {
        XCTAssertEqual(FolderGrantRules.readable([.claude: .granted("/a"), .codex: .missing, .copilot: .readOnly("/a")]),
                       [.claude])
        XCTAssertEqual(FolderGrantRules.pick("/Users/x/.claude/", expected: "/Users/x/.claude"), .expected)
        XCTAssertEqual(FolderGrantRules.pick("/Users/x", expected: "/Users/x/.claude"), .covering)
        XCTAssertEqual(FolderGrantRules.pick("/Users/x/.claude-work", expected: "/Users/x/.claude"), .other)
    }

    func testTheFolderHoldingBothPaths() {
        XCTAssertEqual(FolderGrantRules.covering("/Users/x/.claude", "/Users/x/dotfiles/claude"), "/Users/x")
        XCTAssertEqual(FolderGrantRules.covering("/Users/x/.claude/", "/Users/x/.claude/hooks"), "/Users/x/.claude")
        XCTAssertEqual(FolderGrantRules.covering("/Users/xy/.claude", "/Users/x/dotfiles"), "/Users")
        XCTAssertEqual(FolderGrantRules.covering("/Users/x/.claude", "/Volumes/dotfiles"), "/")
    }

    func testGrantsRoundTrip() throws {
        let grant = FolderGrant(folder: .copilot, path: "/Users/x/.copilot", readOnly: false)
        XCTAssertEqual(try JSONDecoder().decode(FolderGrant.self, from: JSONEncoder().encode(grant)), grant)
    }
}

final class ManualConnectTests: XCTestCase {
    private func json(_ data: Data?) throws -> [String: Any] {
        try SettingsJSON.parse(try XCTUnwrap(data))
    }

    func testPluginIsHoplysHooksInPluginForm() throws {
        let plugin = ClaudeCodePlugin(port: 4318)
        XCTAssertEqual(Set(plugin.files.keys), [".claude-plugin/plugin.json", ".claude-plugin/marketplace.json",
                                                "hooks/hooks.json"])
        let manifest = try json(plugin.files[ClaudeCodePlugin.manifestPath])
        XCTAssertEqual(manifest["name"] as? String, "hoply")
        XCTAssertEqual(manifest["version"] as? String, "1.0.0")
        let marketplace = try json(plugin.files[ClaudeCodePlugin.marketplacePath])
        XCTAssertEqual(marketplace["name"] as? String, "hoply")
        let listed = try XCTUnwrap((marketplace["plugins"] as? [[String: Any]])?.first)
        XCTAssertEqual(listed["name"] as? String, "hoply")
        XCTAssertEqual(listed["source"] as? String, "./")

        let hooks = try XCTUnwrap(try json(plugin.files[ClaudeCodePlugin.hooksPath])["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(ClaudeCodeHooks.events))
        let claude = ClaudeCodeHooks(port: 4318)
        for event in ClaudeCodeHooks.events {
            let groups = try XCTUnwrap(hooks[event] as? [[String: Any]], event)
            XCTAssertEqual(groups.count, 1, event)
            let entries = try XCTUnwrap(groups.first?["hooks"] as? [Any], event)
            XCTAssertTrue(SettingsJSON.same(entries, [claude.hook(for: event)]), event)
        }
        XCTAssertEqual(ClaudeCodePlugin.installCommands(folder: "/Users/x/hoply-plugin"),
                       ["/plugin marketplace add /Users/x/hoply-plugin", "/plugin install hoply@hoply"])
    }

    func testPluginAlwaysAsksToHoldWithTheLongTimeouts() throws {
        let hooks = try XCTUnwrap(ClaudeCodePlugin(port: 4400).hooksFile["hooks"] as? [String: Any])
        func hook(_ event: String) throws -> [String: Any] {
            let groups = try XCTUnwrap(hooks[event] as? [[String: Any]])
            return try XCTUnwrap((groups.first?["hooks"] as? [[String: Any]])?.first)
        }
        let approve = try hook("PermissionRequest")
        XCTAssertTrue((approve["command"] as? String)?.contains("'X-Hoply-Approve: 1'") == true)
        XCTAssertTrue((approve["command"] as? String)?.contains("-m 590 ") == true)
        XCTAssertEqual(approve["timeout"] as? Int, ClaudeCodeHooks.approvalTimeout)
        let reply = try hook("Stop")
        XCTAssertTrue((reply["command"] as? String)?.contains("'X-Hoply-Reply: 1'") == true)
        XCTAssertTrue((reply["command"] as? String)?.contains("-m \(TurnReply.curlTimeout) ") == true)
        XCTAssertEqual(reply["timeout"] as? Int, TurnReply.hookTimeout)
        XCTAssertTrue((try hook("SessionStart")["command"] as? String)?.contains("http://127.0.0.1:4400/hooks/claude-code")
                      == true)
    }

    func testPluginOffersTelemetryAsAPasteableSnippet() throws {
        let snippet = try SettingsJSON.parse(Data(ClaudeCodePlugin(port: 4318).environmentSnippet.utf8))
        let env = try XCTUnwrap(snippet["env"] as? [String: String])
        XCTAssertEqual(env, ClaudeCodeHooks.environment(port: 4318))
    }

    func testPluginStatusFromSettingsAndItsInstall() throws {
        let settings: [String: Any] = ["enabledPlugins": ["hoply@hoply": true, "hoplyish@x": true,
                                                          "hoply@disabled": false, "other@hoply": true]]
        XCTAssertEqual(ClaudeCodePlugin.enabledKeys(inSettings: settings), ["hoply@hoply"])
        XCTAssertEqual(ClaudeCodePlugin.enabledKeys(inSettings: ["enabledPlugins": ["hoply@hoply": 1]]), [],
                       "only a real true counts")
        XCTAssertEqual(ClaudeCodePlugin.enabledKeys(inSettings: [:]), [])

        let installed: [String: Any] = ["version": 2, "plugins": ["hoply@hoply": [
            ["scope": "local", "projectPath": "/Users/x/p", "installPath": "/Users/x/.claude/plugins/cache/local"],
            ["scope": "user", "installPath": "/Users/x/.claude/plugins/cache/hoply/hoply/1.0.0"],
        ]]]
        XCTAssertEqual(ClaudeCodePlugin.installPath(forKeys: ["hoply@hoply"], installedPlugins: installed),
                       "/Users/x/.claude/plugins/cache/hoply/hoply/1.0.0")
        XCTAssertNil(ClaudeCodePlugin.installPath(forKeys: ["hoply@other"], installedPlugins: installed))

        let plugin = ClaudeCodePlugin(port: 4318)
        XCTAssertEqual(plugin.status(installedHooks: plugin.hooksFile), .connected)
        XCTAssertEqual(ClaudeCodePlugin(port: 4319).status(installedHooks: plugin.hooksFile), .outdated)
        XCTAssertEqual(plugin.status(installedHooks: nil), .notConnected)
    }

    func testCodexSnippetIsAHooksFileCodexReadsAsConnected() throws {
        let hooks = CodexHooks(port: 4318)
        let file = try SettingsJSON.parse(hooks.fileContents)
        XCTAssertEqual(hooks.status(of: file), .connected)
        XCTAssertEqual(CodexHooks(port: 4319).status(of: file), .outdated)
        XCTAssertEqual(String(decoding: hooks.fileContents, as: UTF8.self),
                       String(decoding: SettingsJSON.encode(try XCTUnwrap(hooks.connect([:]))), as: UTF8.self))
    }

    func testCopilotFileForTheSavePanel() {
        let hooks = CopilotCLIHooks(port: 4318)
        XCTAssertEqual(CopilotCLIHooks.fileName, "hoply.json")
        XCTAssertEqual(hooks.status(ofFile: hooks.fileContents), .connected)
    }
}

final class ResumeCommandTests: XCTestCase {
    private let id = "0b6f6c1e-8a57-4f0e-9d0c-2f6a4a1f3b77"

    func testEachAgentsResumeCommand() {
        XCTAssertEqual(ResumeScript.commandLine(source: .claudeCode, sessionID: id, cwd: "/Users/dev/Project/api"),
                       "cd /Users/dev/Project/api && claude --resume \(id)")
        XCTAssertEqual(ResumeScript.commandLine(source: .copilotCLI, sessionID: id, cwd: "/Users/dev/api"),
                       "cd /Users/dev/api && copilot --resume=\(id)")
        XCTAssertEqual(ResumeScript.commandLine(source: .codexCLI, sessionID: id, cwd: nil), "codex resume \(id)")
        XCTAssertEqual(ResumeScript.commandLine(source: .qwenCode, sessionID: id, cwd: "/tmp"),
                       "cd /tmp && qwen --resume \(id)")
        XCTAssertNil(ResumeScript.commandLine(source: .copilotIDE, sessionID: id, cwd: "/tmp"))
    }

    func testFoldersAreQuotedForTheShell() {
        XCTAssertEqual(ResumeScript.commandLine(source: .claudeCode, sessionID: "s1", cwd: "/Users/dev/My Project"),
                       "cd '/Users/dev/My Project' && claude --resume s1")
        XCTAssertEqual(ResumeScript.commandLine(source: .claudeCode, sessionID: "s1", cwd: "/Users/dev/it's $HOME"),
                       #"cd '/Users/dev/it'\''s $HOME' && claude --resume s1"#)
        XCTAssertEqual(ResumeScript.commandLine(source: .claudeCode, sessionID: "s1", cwd: "/Users/dev/~x"),
                       "cd '/Users/dev/~x' && claude --resume s1")
        XCTAssertEqual(ResumeScript.shellWord(""), "''")
        XCTAssertEqual(ResumeScript.shellWord("ünïcode"), "'ünïcode'")
    }

    func testUnsafeInputGivesNoCommand() {
        XCTAssertNil(ResumeScript.commandLine(source: .claudeCode, sessionID: "; rm -rf ~", cwd: "/tmp"))
        XCTAssertNil(ResumeScript.commandLine(source: .claudeCode, sessionID: id, cwd: "relative/path"))
        XCTAssertNil(ResumeScript.commandLine(source: .claudeCode, sessionID: id, cwd: "/tmp/a\nb"))
    }
}

final class EditionLaunchTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let api = ProjectRef(id: 1, root: "/Users/dev/Project/api", name: "api", kind: .repo)

    private var catalog: LaunchCatalog {
        LaunchCatalog.build(projects: [api], sessions: [], available: Set(AgentSource.allCases))
    }

    func testTheStoreEditionNeverPublishesALaunchBlock() {
        let block = catalog.remote(last: nil)
        let direct = RemoteSnapshot.build(device: "m", away: false, sessions: [], today: nil, launch: block,
                                          edition: .direct, now: t0)
        XCTAssertEqual(direct.launch, block)
        let store = RemoteSnapshot.build(device: "m", away: false, sessions: [], today: nil, launch: block,
                                         edition: .appStore, now: t0)
        XCTAssertNil(store.launch)
    }

    func testTheStoreEditionRefusesLaunchesFromThePhone() {
        let answer = RemoteAnswer.launch("claude-code", projectID: LaunchCatalog.projectID(root: api.root),
                                         prompt: "Fix the flaky test", device: "mac-1", at: t0)
        let direct = RemoteAnswers.resolve([answer], approvals: [], replies: [], device: "mac-1", launch: catalog,
                                           edition: .direct, now: t0.addingTimeInterval(5))
        guard case .start? = direct.launches.first else { return XCTFail("the direct edition starts it") }
        let store = RemoteAnswers.resolve([answer], approvals: [], replies: [], device: "mac-1", launch: catalog,
                                          edition: .appStore, now: t0.addingTimeInterval(5))
        XCTAssertEqual(store.acknowledged, [answer.id])
        guard case .refuse(let result)? = store.launches.first else { return XCTFail("refused") }
        XCTAssertEqual(result.reason, .disabled)
    }
}

final class StoreConnectTests: XCTestCase {
    func testEachAgentMapsToItsOwnFolder() {
        for agent in ConnectableAgent.allCases {
            XCTAssertEqual(agent.folder.agent, agent)
        }
        XCTAssertEqual(Set(ConnectableAgent.allCases.map(\.folder)), Set(AgentFolder.allCases))
    }

    func testHooksInSettingsAndTheEnabledPluginAreInstalledTwice() throws {
        let withHooks = try XCTUnwrap(ClaudeCodeHooks(port: 4318).connect([:]))
        var both = withHooks
        both["enabledPlugins"] = ["hoply@hoply": true]
        XCTAssertTrue(ClaudeCodePlugin.isInstalledTwice(inSettings: both))
        both["enabledPlugins"] = ["hoply@my-marketplace": true, "other@hoply": false]
        XCTAssertTrue(ClaudeCodePlugin.isInstalledTwice(inSettings: both), "any marketplace's hoply plugin counts")

        XCTAssertFalse(ClaudeCodePlugin.isInstalledTwice(inSettings: withHooks))
        XCTAssertFalse(ClaudeCodePlugin.isInstalledTwice(inSettings: ["enabledPlugins": ["hoply@hoply": true]]))
        var disabled = withHooks
        disabled["enabledPlugins"] = ["hoply@hoply": false, "other@hoply": true]
        XCTAssertFalse(ClaudeCodePlugin.isInstalledTwice(inSettings: disabled))
        var userHooks = try SettingsJSON.parse(Data(#"""
            {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]},
             "enabledPlugins": {"hoply@hoply": true}}
            """#.utf8))
        XCTAssertFalse(ClaudeCodePlugin.isInstalledTwice(inSettings: userHooks), "only Hoply's own hooks count")
        userHooks["enabledPlugins"] = nil
        XCTAssertFalse(ClaudeCodePlugin.isInstalledTwice(inSettings: userHooks))
    }
}
