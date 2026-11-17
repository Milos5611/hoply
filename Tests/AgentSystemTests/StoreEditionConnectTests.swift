import AgentKit
@testable import AgentSystem
import Foundation
import os
import XCTest

final class StoreEditionConnectTests: XCTestCase {
    private let fixedNow: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_794_330_000) }

    private let userSettings = """
        {
          "alwaysThinkingEnabled": true,
          "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done", "timeout": 3}]}]}
        }
        """

    private func grants() -> FolderGrants {
        let saved = OSAllocatedUnfairLock<Data?>(initialState: nil)
        return FolderGrants(edition: .appStore, load: { saved.withLock { $0 } },
                            store: { data in saved.withLock { $0 = data } })
    }

    private func connector(_ temp: TempDirectory, edition: Edition = .appStore, grants: FolderGrants? = nil,
                           port: Int = 4318) -> AgentConnector {
        AgentConnector(claudeConfigDirectory: temp.path("claude"), copilotHome: temp.path("copilot"),
                       codexHome: temp.path("codex"), port: port, edition: edition, grants: grants ?? self.grants(),
                       now: fixedNow)
    }

    private func kind(_ error: Error) -> AgentConnectorError.Kind? {
        (error as? AgentConnectorError)?.kind
    }

    private func files(in directory: String, prefix: String = "") -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter { $0.hasPrefix(prefix) }.sorted()
    }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        XCTAssertEqual(stat(path, &info), 0)
        return info.st_mode & 0o777
    }

    private func parsed(_ path: String) throws -> [String: Any] {
        try SettingsJSON.parse(try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: fixedNow())
    }

    func testConnectWritesInsideAReadWriteGrantLikeTheDirectEdition() throws {
        let temp = try TempDirectory()
        let settings = try temp.write("claude/settings.json", userSettings)
        XCTAssertEqual(chmod(settings, 0o600), 0)
        let codex = try temp.write("codex/hooks.json", """
            {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done", "timeout": 3}]}]}}
            """)
        try temp.mkdir("copilot")
        let originalSettings = try parsed(settings)
        let originalCodex = try parsed(codex)
        let grants = grants()
        for folder in AgentFolder.allCases {
            try grants.grant(URL(fileURLWithPath: temp.path(folder.rawValue)), for: folder)
        }
        let connector = connector(temp, grants: grants)
        for agent in ConnectableAgent.allCases {
            XCTAssertNil(connector.accessProblem(for: agent), "\(agent)")
        }

        let claude = try connector.connect(.claudeCode)
        XCTAssertEqual(claude.backupPath, settings + ".hoply-backup-" + stamp())
        XCTAssertEqual(try String(contentsOfFile: try XCTUnwrap(claude.backupPath), encoding: .utf8), userSettings)
        XCTAssertEqual(mode(settings), 0o600)
        XCTAssertNotNil(try connector.connect(.codexCLI).backupPath)
        let stop = try XCTUnwrap((try parsed(codex)["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2)
        XCTAssertEqual(((stop.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String), "say done",
                       "Codex trusts hooks by position, so the user's group stays first")
        try connector.connect(.copilotCLI)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: connector.copilotHooksPath)),
                       CopilotCLIHooks(port: 4318).fileContents)
        XCTAssertEqual(connector.statuses(), [.claudeCode: .connected, .codexCLI: .connected, .copilotCLI: .connected])
        XCTAssertFalse(try connector.connect(.claudeCode).changed, "no change, no write")
        for directory in ["claude", "codex", "copilot/hooks"] {
            XCTAssertEqual(files(in: temp.path(directory), prefix: "."), [], "no temporary file left in \(directory)")
        }

        XCTAssertTrue(try connector.disconnect(.claudeCode).changed)
        XCTAssertTrue(try connector.disconnect(.codexCLI).changed)
        let removed = try connector.disconnect(.copilotCLI)
        XCTAssertEqual(removed.renamedPath, connector.copilotHooksPath + ".removed-" + stamp())
        XCTAssertTrue(SettingsJSON.same(try parsed(settings), originalSettings))
        XCTAssertTrue(SettingsJSON.same(try parsed(codex), originalCodex))
        XCTAssertEqual(connector.statuses(),
                       [.claudeCode: .notConnected, .codexCLI: .notConnected, .copilotCLI: .notConnected])
    }

    func testOneHomeGrantConnectsAllThree() throws {
        let temp = try TempDirectory()
        for name in ["claude", "codex", "copilot"] { try temp.mkdir(name) }
        let grants = grants()
        try grants.grant(temp.url, for: .claude)
        let connector = connector(temp, grants: grants)
        for agent in ConnectableAgent.allCases {
            XCTAssertTrue(try connector.connect(agent).changed, "\(agent)")
        }
        XCTAssertEqual(connector.statuses(), [.claudeCode: .connected, .codexCLI: .connected, .copilotCLI: .connected])
    }

    func testWithoutAGrantConnectAsksForTheAgentsFolder() throws {
        let temp = try TempDirectory()
        let settings = try temp.write("claude/settings.json", #"{"theme": "dark"}"#)
        for name in ["codex", "copilot", "elsewhere"] { try temp.mkdir(name) }
        let grants = grants()
        try grants.grant(URL(fileURLWithPath: temp.path("elsewhere")), for: .claude)
        let connector = connector(temp, grants: grants)
        for agent in ConnectableAgent.allCases {
            XCTAssertEqual(connector.accessProblem(for: agent)?.kind, .needsFolderAccess(agent.folder))
            XCTAssertThrowsError(try connector.connect(agent)) { error in
                XCTAssertEqual(kind(error), .needsFolderAccess(agent.folder))
            }
            XCTAssertThrowsError(try connector.disconnect(agent)) { error in
                XCTAssertEqual(kind(error), .needsFolderAccess(agent.folder))
            }
        }
        let message = try XCTUnwrap(connector.accessProblem(for: .claudeCode)?.message)
        XCTAssertTrue(message.hasPrefix("Allow " + FolderGrants.canonical(temp.path("claude"))), message)
        XCTAssertEqual(try String(contentsOfFile: settings, encoding: .utf8), #"{"theme": "dark"}"#)
        XCTAssertEqual(files(in: temp.path("claude")), ["settings.json"])
        XCTAssertEqual(files(in: temp.path("codex")), [])
        XCTAssertEqual(files(in: temp.path("copilot")), [])

        try grants.grant(URL(fileURLWithPath: temp.path("codex")), for: .codex)
        XCTAssertTrue(try connector.connect(.codexCLI).changed)
        XCTAssertEqual(connector.accessProblem(for: .claudeCode)?.kind, .needsFolderAccess(.claude))

        let direct = self.connector(temp, edition: .direct, grants: self.grants())
        XCTAssertNil(direct.accessProblem(for: .claudeCode), "the direct edition needs no grant")
        XCTAssertTrue(try direct.connect(.claudeCode).changed)
    }

    func testAReadOnlyGrantFromAnEarlierBuildIsRefusedUntilAllowedAgain() throws {
        let temp = try TempDirectory()
        let settings = try temp.write("claude/settings.json", #"{"theme": "dark"}"#)
        let claude = URL(fileURLWithPath: temp.path("claude"))
        let canonical = FolderGrants.canonical(claude.path)
        let saved = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let legacy = ["claude": FolderGrants.Saved(
            bookmark: try SecurityScopedBookmarks().create(for: claude, readOnly: true), path: canonical, readOnly: true)]
        saved.withLock { $0 = try? JSONEncoder().encode(legacy) }
        let grants = FolderGrants(edition: .appStore, load: { saved.withLock { $0 } },
                                  store: { data in saved.withLock { $0 = data } })
        XCTAssertEqual(grants.access(for: .claude, at: claude.path), .readOnly(canonical))

        let connector = connector(temp, grants: grants)
        XCTAssertThrowsError(try connector.connect(.claudeCode)) { error in
            XCTAssertEqual(kind(error), .needsFolderAccess(.claude))
            XCTAssertTrue(error.localizedDescription.contains("Allow it again"), error.localizedDescription)
        }
        XCTAssertEqual(try String(contentsOfFile: settings, encoding: .utf8), #"{"theme": "dark"}"#)
        XCTAssertEqual(files(in: claude.path), ["settings.json"])

        try grants.grant(claude, for: .claude)
        XCTAssertEqual(grants.access(for: .claude, at: claude.path), .granted(canonical))
        XCTAssertTrue(try connector.connect(.claudeCode).changed)
        XCTAssertEqual(connector.status(of: .claudeCode), .connected)
    }

    func testASettingsFileLinkedOutsideTheGrantIsReported() throws {
        let temp = try TempDirectory()
        let target = try temp.write("dotfiles/claude-settings.json", userSettings)
        try temp.mkdir("claude")
        let link = temp.path("claude/settings.json")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "../dotfiles/claude-settings.json")
        let grants = grants()
        try grants.grant(URL(fileURLWithPath: temp.path("claude")), for: .claude)
        let connector = connector(temp, grants: grants)
        let root = FolderGrants.canonical(temp.url.path)
        let expected = AgentConnectorError.Kind.linkOutsideGrant(.claude, target: root + "/dotfiles/claude-settings.json",
                                                                 allow: root)

        XCTAssertEqual(connector.accessProblem(for: .claudeCode)?.kind, expected)
        XCTAssertThrowsError(try connector.connect(.claudeCode)) { error in XCTAssertEqual(kind(error), expected) }
        XCTAssertThrowsError(try connector.disconnect(.claudeCode)) { error in XCTAssertEqual(kind(error), expected) }
        guard case .unreadable(let message) = connector.status(of: .claudeCode) else {
            return XCTFail("a link the sandbox won't follow reads as unreadable, with the folder to allow")
        }
        XCTAssertTrue(message.contains("links to") && message.contains("Allow \(root),"), message)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), userSettings)
        XCTAssertEqual(files(in: temp.path("claude")), ["settings.json"])
        XCTAssertEqual(files(in: temp.path("dotfiles")), ["claude-settings.json"])

        try grants.grant(URL(fileURLWithPath: root), for: .claude)
        XCTAssertNil(connector.accessProblem(for: .claudeCode))
        XCTAssertNotNil(try connector.connect(.claudeCode).backupPath)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), "../dotfiles/claude-settings.json")
        XCTAssertEqual(connector.status(of: .claudeCode), .connected)
    }

    func testCopilotHooksLinkedOutsideTheGrant() throws {
        let temp = try TempDirectory()
        try temp.mkdir("copilot")
        try temp.mkdir("dotfiles/copilot-hooks")
        try FileManager.default.createSymbolicLink(atPath: temp.path("copilot/hooks"),
                                                   withDestinationPath: "../dotfiles/copilot-hooks")
        let grants = grants()
        try grants.grant(URL(fileURLWithPath: temp.path("copilot")), for: .copilot)
        let root = FolderGrants.canonical(temp.url.path)
        XCTAssertThrowsError(try connector(temp, grants: grants).connect(.copilotCLI)) { error in
            XCTAssertEqual(kind(error), .linkOutsideGrant(.copilot, target: root + "/dotfiles/copilot-hooks/hoply.json",
                                                          allow: root), "a linked hooks folder counts too")
        }
        XCTAssertEqual(files(in: temp.path("dotfiles/copilot-hooks")), [])

        let linked = try TempDirectory()
        let outside = try linked.write("dotfiles/hoply.json",
                                       String(decoding: CopilotCLIHooks(port: 4318).fileContents, as: UTF8.self))
        try linked.mkdir("copilot/hooks")
        try FileManager.default.createSymbolicLink(atPath: linked.path("copilot/hooks/hoply.json"),
                                                   withDestinationPath: "../../dotfiles/hoply.json")
        let linkedGrants = self.grants()
        try linkedGrants.grant(URL(fileURLWithPath: linked.path("copilot")), for: .copilot)
        let connector = connector(linked, grants: linkedGrants)
        XCTAssertThrowsError(try connector.connect(.copilotCLI)) { error in
            guard case .linkOutsideGrant(.copilot, _, _)? = kind(error) else { return XCTFail("\(error)") }
        }
        let removed = try connector.disconnect(.copilotCLI)
        XCTAssertTrue(try XCTUnwrap(removed.renamedPath).hasPrefix(linked.path("copilot/hooks/hoply.json.removed-")),
                      "disconnect renames only the link, inside the grant")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside))
    }

    func testInvalidJSONIsRefusedUntouchedInsideAGrant() throws {
        let temp = try TempDirectory()
        let broken = "{\"hooks\": {\"Stop\": [}\n"
        let path = try temp.write("claude/settings.json", broken)
        let grants = grants()
        try grants.grant(URL(fileURLWithPath: temp.path("claude")), for: .claude)
        XCTAssertThrowsError(try connector(temp, grants: grants).connect(.claudeCode)) { error in
            XCTAssertEqual(kind(error), .unreadable)
        }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), broken)
        XCTAssertEqual(files(in: temp.path("claude")), ["settings.json"])
    }

    func testFilesTheUserAddedReadAsConnected() throws {
        let temp = try TempDirectory()
        let connector = connector(temp)
        try temp.write("copilot/hooks/hoply.json", String(decoding: CopilotCLIHooks(port: 4318).fileContents, as: UTF8.self))
        try temp.write("codex/hooks.json", String(decoding: CodexHooks(port: 4318).fileContents, as: UTF8.self))
        XCTAssertEqual(connector.status(of: .copilotCLI), .connected)
        XCTAssertEqual(connector.status(of: .codexCLI), .connected)
        XCTAssertEqual(connector.copilotHooksDirectory, temp.path("copilot") + "/hooks")
    }

    private func installPlugin(_ temp: TempDirectory, port: Int = 4318) throws {
        let install = temp.path("claude/plugins/cache/hoply/hoply/1.0.0")
        try temp.write("claude/plugins/installed_plugins.json", String(decoding: SettingsJSON.encode(
            ["version": 2, "plugins": ["hoply@hoply": [["scope": "user", "installPath": install]]]]), as: UTF8.self))
        for (path, data) in ClaudeCodePlugin(port: port).files {
            try temp.write("claude/plugins/cache/hoply/hoply/1.0.0/\(path)", String(decoding: data, as: UTF8.self))
        }
    }

    func testClaudeCodeReadsAsConnectedThroughThePlugin() throws {
        let temp = try TempDirectory()
        let connector = connector(temp)
        try temp.write("claude/settings.json", #"{"enabledPlugins": {"hoply@hoply": true}}"#)
        XCTAssertEqual(connector.status(of: .claudeCode), .notConnected, "enabled but not installed")

        try temp.write("claude/plugins/installed_plugins.json", String(decoding: SettingsJSON.encode(
            ["version": 2, "plugins": ["hoply@hoply": [["scope": "user",
                                                       "installPath": temp.path("claude/plugins/cache/hoply/hoply/1.0.0")]]]]),
            as: UTF8.self))
        XCTAssertEqual(connector.status(of: .claudeCode), .notConnected, "no hooks file in the install")
        try installPlugin(temp)
        XCTAssertEqual(connector.status(of: .claudeCode), .connected)
        XCTAssertEqual(self.connector(temp, port: 4319).status(of: .claudeCode), .outdated)
        XCTAssertEqual(self.connector(temp, edition: .direct).status(of: .claudeCode), .notConnected,
                       "the direct edition reads only its own settings.json hooks")

        try temp.write("claude/settings.json", #"{"enabledPlugins": {"hoply@hoply": false}}"#)
        XCTAssertEqual(connector.status(of: .claudeCode), .notConnected)
    }

    func testTheWrittenHooksDecideTheStatusBeforeThePlugin() throws {
        let temp = try TempDirectory()
        try installPlugin(temp)
        let enabled: [String: Any] = ["enabledPlugins": ["hoply@hoply": true]]
        let old = try XCTUnwrap(ClaudeCodeHooks(port: 4319).connect(enabled))
        try temp.write("claude/settings.json", String(decoding: SettingsJSON.encode(old), as: UTF8.self))
        XCTAssertEqual(connector(temp).status(of: .claudeCode), .outdated, "outdated hooks ask for Update")

        let current = try XCTUnwrap(ClaudeCodeHooks(port: 4318).connect(enabled))
        try temp.write("claude/settings.json", String(decoding: SettingsJSON.encode(current), as: UTF8.self))
        XCTAssertEqual(connector(temp).status(of: .claudeCode), .connected)
        XCTAssertTrue(ClaudeCodePlugin.isInstalledTwice(inSettings: current))
    }

    func testHooksTheDirectEditionWroteStillCount() throws {
        let temp = try TempDirectory()
        try temp.mkdir("claude")
        try self.connector(temp, edition: .direct).connect(.claudeCode)
        XCTAssertEqual(connector(temp).status(of: .claudeCode), .connected)
    }

    func testTheCommandLineRefusesInTheStoreEdition() throws {
        let temp = try TempDirectory()
        try temp.mkdir("claude")
        var errors: [String] = []
        let code = ConnectCommand.run(arguments: ["--connect"],
                                      environment: ["CLAUDE_CONFIG_DIR": temp.path("claude")],
                                      settings: AppSettings(), home: temp.path("home"), edition: .appStore,
                                      output: { _ in XCTFail("no output") }, errors: { errors.append($0) })
        XCTAssertEqual(code, 1)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first?.contains("from its window") == true, errors.first ?? "")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path("claude")), [])
    }
}
