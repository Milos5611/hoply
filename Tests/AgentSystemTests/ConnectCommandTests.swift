import AgentKit
import AgentSystem
import Foundation
import XCTest

final class ConnectCommandTests: XCTestCase {
    private struct Run {
        var code: Int32
        var output: [String]
        var errors: [String]
    }

    private func run(_ arguments: [String], temp: TempDirectory, environment extra: [String: String] = [:],
                     settings: AppSettings = AppSettings()) -> Run {
        var environment = ["CLAUDE_CONFIG_DIR": temp.path("claude"), "COPILOT_HOME": temp.path("copilot"),
                           "CODEX_HOME": temp.path("codex")]
        environment.merge(extra) { $1 }
        var output: [String] = []
        var errors: [String] = []
        let code = ConnectCommand.run(arguments: arguments, environment: environment.filter { !$0.value.isEmpty },
                                      settings: settings, home: temp.path("home"),
                                      output: { output.append($0) }, errors: { errors.append($0) })
        return Run(code: code, output: output, errors: errors)
    }

    private func connector(_ temp: TempDirectory, port: Int = 4318) -> AgentConnector {
        AgentConnector(claudeConfigDirectory: temp.path("claude"), copilotHome: temp.path("copilot"), codexHome: temp.path("codex"), port: port)
    }

    func testRequestDetection() {
        XCTAssertTrue(ConnectCommand.isRequested(["--connect"]))
        XCTAssertTrue(ConnectCommand.isRequested(["--disconnect", "copilot-cli"]))
        XCTAssertFalse(ConnectCommand.isRequested([]))
        XCTAssertFalse(ConnectCommand.isRequested(["--snapshot", "build/snapshots"]))
    }

    func testUsageErrors() throws {
        let temp = try TempDirectory()
        for arguments in [["claude-code", "--connect"], ["--connect", "qwen-code"], ["--connect", "--disconnect"]] {
            let result = run(arguments, temp: temp)
            XCTAssertEqual(result.code, 2, "\(arguments)")
            XCTAssertTrue(result.output.isEmpty)
            XCTAssertTrue(result.errors.joined().contains(ConnectCommand.usage), "\(arguments)")
        }
        XCTAssertTrue(run(["--connect", "qwen-code"], temp: temp).errors.joined().contains("Unknown agent \"qwen-code\""))
        for port in ["abc", "0", "70000"] {
            let result = run(["--connect"], temp: temp, environment: ["HOPLY_PORT": port])
            XCTAssertEqual(result.code, 2, port)
            XCTAssertTrue(result.errors.joined().contains("HOPLY_PORT"), port)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path("claude")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path("copilot")))
    }

    func testNoNamesConnectsEveryAgentFound() throws {
        let temp = try TempDirectory()
        try temp.mkdir("claude")
        let result = run(["--connect"], temp: temp)
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.errors, [])
        XCTAssertEqual(result.output, [
            "Claude Code: connected to http://127.0.0.1:4318; restart running sessions (\(temp.path("claude/settings.json")))",
            "Copilot CLI: not found, skipped",
            "Codex CLI: not found, skipped",
        ])
        XCTAssertEqual(connector(temp).status(of: .claudeCode), .connected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path("copilot")))

        let again = run(["--connect"], temp: temp)
        XCTAssertEqual(again.output.first, "Claude Code: already connected (\(temp.path("claude/settings.json")))")

        let disconnect = run(["--disconnect"], temp: temp)
        XCTAssertEqual(disconnect.code, 0)
        XCTAssertEqual(disconnect.output.count, 3)
        XCTAssertTrue(disconnect.output[0].hasPrefix(
            "Claude Code: disconnected (\(temp.path("claude/settings.json")), backup: \(temp.path("claude/settings.json")).hoply-backup-"),
                      disconnect.output[0])
        XCTAssertEqual(disconnect.output[1], "Copilot CLI: not found, skipped")
        XCTAssertEqual(disconnect.output[2], "Codex CLI: not found, skipped")
        XCTAssertEqual(connector(temp).status(of: .claudeCode), .notConnected)
    }

    func testExplicitNamesConnectEvenWithoutTheFolder() throws {
        let temp = try TempDirectory()
        let result = run(["--connect", "copilot-cli", "copilot-cli"], temp: temp)
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.output, ["Copilot CLI: connected to http://127.0.0.1:4318 (\(temp.path("copilot/hooks/hoply.json")))"])
        XCTAssertEqual(connector(temp).status(of: .copilotCLI), .connected)
        XCTAssertEqual(connector(temp).status(of: .claudeCode), .notInstalled)

        let removed = run(["--disconnect", "copilot-cli", "claude-code"], temp: temp)
        XCTAssertEqual(removed.code, 0)
        XCTAssertEqual(removed.output.count, 2)
        XCTAssertTrue(removed.output[0].hasPrefix("Copilot CLI: disconnected (\(temp.path("copilot/hooks/hoply.json")), renamed to hoply.json.removed-"),
                      removed.output[0])
        XCTAssertEqual(removed.output[1], "Claude Code: not connected, nothing to change (\(temp.path("claude/settings.json")))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path("claude")))
    }

    func testPortComesFromTheEnvironmentThenTheSavedSettings() throws {
        let temp = try TempDirectory()
        var settings = AppSettings()
        settings.port = 4400
        XCTAssertEqual(run(["--connect", "copilot-cli"], temp: temp, settings: settings).code, 0)
        XCTAssertEqual(connector(temp, port: 4400).status(of: .copilotCLI), .connected)

        let result = run(["--connect", "copilot-cli"], temp: temp, environment: ["HOPLY_PORT": "4500"], settings: settings)
        XCTAssertEqual(result.output.first?.contains("connected to http://127.0.0.1:4500"), true)
        XCTAssertEqual(connector(temp, port: 4500).status(of: .copilotCLI), .connected)
    }

    func testFoldersComeFromTheEnvironmentThenSettingsThenHome() throws {
        let temp = try TempDirectory()
        var settings = AppSettings()
        settings.claudeConfigDir = temp.path("saved-claude")
        XCTAssertEqual(run(["--connect", "claude-code"], temp: temp, settings: settings).code, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path("saved-claude")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path("claude/settings.json")))

        XCTAssertEqual(run(["--connect", "claude-code"], temp: temp, environment: ["CLAUDE_CONFIG_DIR": ""],
                           settings: settings).code, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path("saved-claude/settings.json")))

        let homeRun = run(["--connect", "claude-code", "copilot-cli"], temp: temp,
                          environment: ["CLAUDE_CONFIG_DIR": "", "COPILOT_HOME": ""])
        XCTAssertEqual(homeRun.code, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path("home/.claude/settings.json")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path("home/.copilot/hooks/hoply.json")))
    }

    func testAFailureReportsOnStderrAndContinues() throws {
        let temp = try TempDirectory()
        try temp.write("claude/settings.json", "{ not json")
        try temp.mkdir("copilot")
        let result = run(["--connect"], temp: temp)
        XCTAssertEqual(result.code, 1)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(result.errors[0].hasPrefix("Claude Code: "), result.errors[0])
        XCTAssertTrue(result.errors[0].contains("is not valid JSON"), result.errors[0])
        XCTAssertEqual(result.output, [result.output[0], "Codex CLI: not found, skipped"])
        XCTAssertTrue(result.output[0].hasPrefix("Copilot CLI: connected"))
        XCTAssertEqual(try String(contentsOfFile: temp.path("claude/settings.json"), encoding: .utf8), "{ not json")
    }
}
