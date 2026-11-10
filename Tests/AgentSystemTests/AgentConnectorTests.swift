import AgentKit
@testable import AgentSystem
import Foundation
import XCTest

final class AgentConnectorTests: XCTestCase {
    private let fixedNow: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_794_330_000) }

    private func connector(_ temp: TempDirectory, port: Int = 4318) -> AgentConnector {
        AgentConnector(claudeConfigDirectory: temp.path("claude"), copilotHome: temp.path("copilot"), port: port,
                       now: fixedNow)
    }

    private func files(in directory: String, prefix: String) -> [String] {
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

    private let userSettings = """
        {
          "alwaysThinkingEnabled": true,
          "cleanupPeriodDays": 30,
          "env": {"DOTNET_ROOT": "/opt/homebrew/opt/dotnet/libexec"},
          "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done", "timeout": 3}]}]},
          "statusLine": {"type": "command", "command": "~/bin/status", "padding": 0}
        }
        """

    func testStatusFollowsTheConfigFolder() throws {
        let temp = try TempDirectory()
        let connector = connector(temp)
        XCTAssertEqual(connector.status(of: .claudeCode), .notInstalled)
        XCTAssertEqual(connector.status(of: .copilotCLI), .notInstalled)
        XCTAssertFalse(connector.isInstalled(.claudeCode))
        try temp.mkdir("claude")
        try temp.mkdir("copilot")
        XCTAssertEqual(connector.statuses(), [.claudeCode: .notConnected, .copilotCLI: .notConnected])
        try connector.connect(.claudeCode)
        try connector.connect(.copilotCLI)
        XCTAssertEqual(connector.statuses(), [.claudeCode: .connected, .copilotCLI: .connected])
        XCTAssertEqual(self.connector(temp, port: 4319).statuses(), [.claudeCode: .outdated, .copilotCLI: .outdated])
    }

    func testConnectBacksUpThenWritesAndKeepsPermissions() throws {
        let temp = try TempDirectory()
        let path = try temp.write("claude/settings.json", userSettings)
        XCTAssertEqual(chmod(path, 0o600), 0)
        let connector = connector(temp)

        let outcome = try connector.connect(.claudeCode)
        XCTAssertTrue(outcome.changed)
        XCTAssertEqual(outcome.path, path)
        let backup = try XCTUnwrap(outcome.backupPath)
        XCTAssertEqual(backup, path + ".hoply-backup-" + stamp(fixedNow()))
        XCTAssertEqual(try String(contentsOfFile: backup, encoding: .utf8), userSettings)
        XCTAssertEqual(mode(path), 0o600)
        XCTAssertEqual(mode(backup), 0o600)
        XCTAssertEqual(connector.status(of: .claudeCode), .connected)
        XCTAssertEqual(files(in: temp.path("claude"), prefix: "."), [])

        let settings = try parsed(path)
        XCTAssertTrue(SettingsJSON.isBool(try XCTUnwrap(settings["alwaysThinkingEnabled"] as? NSNumber)))
        XCTAssertFalse(SettingsJSON.isBool(try XCTUnwrap(settings["cleanupPeriodDays"] as? NSNumber)))
        XCTAssertFalse(CFNumberIsFloatType(try XCTUnwrap(settings["cleanupPeriodDays"] as? NSNumber)))
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("\"alwaysThinkingEnabled\": true,\n"))
        XCTAssertTrue(text.contains("\"cleanupPeriodDays\": 30,\n"))
        XCTAssertTrue(text.contains("\"padding\": 0,\n"))
    }

    func testConnectTwiceWritesOnceAndDisconnectRestores() throws {
        let temp = try TempDirectory()
        let path = try temp.write("claude/settings.json", userSettings)
        let original = try parsed(path)
        let connector = connector(temp)

        XCTAssertTrue(try connector.connect(.claudeCode).changed)
        let written = try Data(contentsOf: URL(fileURLWithPath: path))
        let again = try connector.connect(.claudeCode)
        XCTAssertFalse(again.changed)
        XCTAssertNil(again.backupPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), written)
        XCTAssertEqual(files(in: temp.path("claude"), prefix: "settings.json.hoply-backup-").count, 1)

        let disconnected = try connector.disconnect(.claudeCode)
        XCTAssertTrue(disconnected.changed)
        XCTAssertNotNil(disconnected.backupPath)
        XCTAssertTrue(SettingsJSON.same(try parsed(path), original))
        XCTAssertEqual(connector.status(of: .claudeCode), .notConnected)
        XCTAssertFalse(try connector.disconnect(.claudeCode).changed)
        XCTAssertEqual(files(in: temp.path("claude"), prefix: "settings.json.hoply-backup-").count, 2)
    }

    func testMissingSettingsAreCreatedWithoutBackup() throws {
        let temp = try TempDirectory()
        let connector = connector(temp)
        XCTAssertFalse(try connector.disconnect(.claudeCode).changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path("claude")))

        let outcome = try connector.connect(.claudeCode)
        XCTAssertTrue(outcome.changed)
        XCTAssertNil(outcome.backupPath)
        XCTAssertEqual(mode(connector.claudeSettingsPath), 0o600)
        XCTAssertEqual(connector.status(of: .claudeCode), .connected)
        XCTAssertEqual(files(in: temp.path("claude"), prefix: "settings.json"), ["settings.json"])

        try connector.disconnect(.claudeCode)
        XCTAssertEqual(try String(contentsOfFile: connector.claudeSettingsPath, encoding: .utf8), "{}\n")
    }

    func testInvalidJSONIsRefusedUntouched() throws {
        let temp = try TempDirectory()
        let broken = "{\"hooks\": {\"Stop\": [}\n"
        let path = try temp.write("claude/settings.json", broken)
        let connector = connector(temp)
        guard case .unreadable(let message) = connector.status(of: .claudeCode) else {
            return XCTFail("expected unreadable")
        }
        XCTAssertTrue(message.contains("is not valid JSON"), message)

        for action in [connector.connect, connector.disconnect] {
            XCTAssertThrowsError(try action(.claudeCode)) { error in
                XCTAssertEqual((error as? AgentConnectorError)?.kind, .unreadable)
                XCTAssertTrue(error.localizedDescription.contains("fix it first"), error.localizedDescription)
            }
        }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), broken)
        XCTAssertEqual(files(in: temp.path("claude"), prefix: "settings.json"), ["settings.json"])

        try temp.write("claude/settings.json", #"{"hooks": []}"#)
        guard case .unreadable = connector.status(of: .claudeCode) else { return XCTFail("expected unreadable") }
        XCTAssertThrowsError(try connector.connect(.claudeCode))
    }

    func testSymlinkedSettingsStayALink() throws {
        let temp = try TempDirectory()
        let target = try temp.write("dotfiles/claude-settings.json", userSettings)
        XCTAssertEqual(chmod(target, 0o640), 0)
        try temp.mkdir("claude")
        let link = temp.path("claude/settings.json")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "../dotfiles/claude-settings.json")
        let connector = connector(temp)

        let outcome = try connector.connect(.claudeCode)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), "../dotfiles/claude-settings.json")
        XCTAssertEqual(hooksStatus(target), .connected)
        XCTAssertEqual(mode(target), 0o640)
        let backup = try XCTUnwrap(outcome.backupPath)
        XCTAssertTrue(backup.hasPrefix(link + ".hoply-backup-"))
        XCTAssertEqual(try String(contentsOfFile: backup, encoding: .utf8), userSettings)
        XCTAssertEqual(files(in: temp.path("dotfiles"), prefix: ""), ["claude-settings.json"])

        try connector.disconnect(.claudeCode)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link))
        XCTAssertEqual(hooksStatus(target), .notConnected)
    }

    func testBackupNamesNeverCollide() throws {
        let temp = try TempDirectory()
        try temp.write("claude/settings.json", userSettings)
        let connector = connector(temp)
        let first = try XCTUnwrap(try connector.connect(.claudeCode).backupPath)
        let second = try XCTUnwrap(try connector.disconnect(.claudeCode).backupPath)
        XCTAssertEqual(second, first + "-2")
        XCTAssertEqual(try String(contentsOfFile: first, encoding: .utf8), userSettings)
    }

    func testCopilotConnectWritesAndDisconnectRenames() throws {
        let temp = try TempDirectory()
        let connector = connector(temp)
        let outcome = try connector.connect(.copilotCLI)
        XCTAssertTrue(outcome.changed)
        let path = temp.path("copilot/hooks/hoply.json")
        XCTAssertEqual(outcome.path, path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), CopilotCLIHooks(port: 4318).fileContents)
        XCTAssertEqual(mode(path), 0o644)
        XCTAssertFalse(try connector.connect(.copilotCLI).changed)

        let updated = try self.connector(temp, port: 4319).connect(.copilotCLI)
        XCTAssertTrue(updated.changed)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), CopilotCLIHooks(port: 4319).fileContents)

        let removed = try connector.disconnect(.copilotCLI)
        XCTAssertTrue(removed.changed)
        XCTAssertEqual(removed.renamedPath, path + ".removed-" + stamp(fixedNow()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(removed.renamedPath))),
                       CopilotCLIHooks(port: 4319).fileContents)
        XCTAssertEqual(connector.status(of: .copilotCLI), .notConnected)
        XCTAssertFalse(try connector.disconnect(.copilotCLI).changed)

        try connector.connect(.copilotCLI)
        XCTAssertEqual(try connector.disconnect(.copilotCLI).renamedPath, path + ".removed-" + stamp(fixedNow()) + "-2")
        XCTAssertEqual(files(in: temp.path("copilot/hooks"), prefix: "").count, 2)
    }

    func testDirectoriesFromSettings() {
        let environment = ["CLAUDE_CONFIG_DIR": "/scratch/claude", "COPILOT_HOME": "~/scratch-copilot"]
        var settings = AppSettings()
        settings.port = 4400
        let defaults = AgentConnector(settings: settings, environment: environment)
        XCTAssertEqual(defaults.claudeConfigDirectory, "/scratch/claude")
        XCTAssertEqual(defaults.copilotHome, NSHomeDirectory() + "/scratch-copilot")
        XCTAssertEqual(defaults.port, 4400)
        XCTAssertEqual(defaults.claudeSettingsPath, "/scratch/claude/settings.json")
        XCTAssertEqual(defaults.copilotHooksPath, NSHomeDirectory() + "/scratch-copilot/hooks/hoply.json")

        settings.claudeConfigDir = " /work/claude/ "
        settings.copilotHome = "/work/copilot"
        let configured = AgentConnector(settings: settings, environment: environment)
        XCTAssertEqual(configured.claudeConfigDirectory, "/work/claude")
        XCTAssertEqual(configured.copilotHome, "/work/copilot")

        let bare = AgentConnector(settings: AppSettings(), environment: [:])
        XCTAssertEqual(bare.claudeConfigDirectory, FileManager.default.homeDirectoryForCurrentUser.path + "/.claude")
        XCTAssertEqual(bare.copilotHome, FileManager.default.homeDirectoryForCurrentUser.path + "/.copilot")
        XCTAssertEqual(AgentConnector.defaultClaudeConfigDirectory(environment: [:], home: "/h"), "/h/.claude")
        XCTAssertEqual(AgentConnector.defaultCopilotHome(environment: ["COPILOT_HOME": ""], home: "/h"), "/h/.copilot")
    }

    private func hooksStatus(_ path: String) -> ConnectionStatus? {
        (try? parsed(path)).map { ClaudeCodeHooks(port: 4318).status(of: $0) }
    }

    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date)
    }
}
