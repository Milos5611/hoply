import AgentKit
import AgentSystem
import Foundation

extension PreviewData {
    static let updateVersion = "0.2.0"
    static let availableUpdate = PendingUpdate(version: updateVersion, stage: .available)
    static let readyUpdate = PendingUpdate(version: updateVersion, stage: .ready)

    static let connectionStatuses: [ConnectableAgent: ConnectionStatus] = [
        .claudeCode: .connected, .copilotCLI: .notInstalled, .codexCLI: .notConnected,
    ]

    static var connectionNotices: [ConnectableAgent: AgentConnections.Notice] {
        [.claudeCode: AgentConnections.Notice(
            text: "Restart running Claude Code sessions to load the hooks.",
            detail: "The previous file was backed up to ~/.claude/settings.json.hoply-backup-20261110142233.")]
    }

    static let connectionsToUpdate: [ConnectableAgent: ConnectionStatus] = [
        .claudeCode: .outdated, .copilotCLI: .notConnected, .codexCLI: .connected,
    ]

    static let connectionsUnreadable: [ConnectableAgent: ConnectionStatus] = [
        .claudeCode: .unreadable("~/.claude/settings.json is not valid JSON (Unexpected character '}' around line 14, column 3.); fix it first."),
        .copilotCLI: .connected, .codexCLI: .notInstalled,
    ]

    static var connectionFailure: [ConnectableAgent: AgentConnections.Notice] {
        [.copilotCLI: AgentConnections.Notice(text: "~/.copilot/hooks/hoply.json can't be written: Permission denied", isError: true)]
    }

    static let awayOneOutdated: [ConnectableAgent: ConnectionStatus] = [
        .claudeCode: .connected, .copilotCLI: .outdated, .codexCLI: .connected,
    ]

    static let awayTwoOutdated: [ConnectableAgent: ConnectionStatus] = [
        .claudeCode: .outdated, .copilotCLI: .outdated, .codexCLI: .connected,
    ]

    static let connectionsNone: [ConnectableAgent: ConnectionStatus] = [
        .claudeCode: .notConnected, .copilotCLI: .notConnected, .codexCLI: .notConnected,
    ]

    static func folder(_ name: String) -> String { "\(home)/\(name)" }

    static let storeFirstRunStatuses: [ConnectableAgent: ConnectionStatus] = [.copilotCLI: .notInstalled]

    static var storeFirstRunAccess: [AgentFolder: FolderAccess] {
        [.claude: .missing, .codex: .missing, .copilot: .notFound]
    }

    static let storeFirstRunProblems: [ConnectableAgent: AgentConnectorError.Kind] = [
        .claudeCode: .needsFolderAccess(.claude), .codexCLI: .needsFolderAccess(.codex),
    ]

    static var storeFolderAccess: [AgentFolder: FolderAccess] {
        [.claude: .granted(home), .codex: .granted(home), .copilot: .readOnly(folder(".copilot"))]
    }

    static var storeFolderNotices: [AgentFolder: AgentConnections.Notice] {
        [.claude: AgentConnections.Notice(text: "You allowed ~, which includes ~/.claude.")]
    }

    static var storeSetupStatuses: [ConnectableAgent: ConnectionStatus] {
        [.claudeCode: .unreadable("~/.claude/settings.json links to ~/dotfiles/claude/settings.json, outside the folders Hoply may change. Allow ~, which holds both, so Hoply can add its hooks.")]
    }

    static var storeSetupAccess: [AgentFolder: FolderAccess] {
        [.claude: .granted(folder(".claude")), .codex: .missing, .copilot: .readOnly(folder(".copilot"))]
    }

    static var storeSetupProblems: [ConnectableAgent: AgentConnectorError.Kind] {
        [.claudeCode: .linkOutsideGrant(.claude, target: folder("dotfiles/claude/settings.json"), allow: home),
         .codexCLI: .needsFolderAccess(.codex), .copilotCLI: .needsFolderAccess(.copilot)]
    }

    static var storeSetupNotices: [ConnectableAgent: AgentConnections.Notice] {
        [.codexCLI: AgentConnections.Notice(
            text: "You picked ~/Documents, but Codex CLI keeps its files in ~/.codex. Choose that folder, or set the folder you use under History.",
            isError: true)]
    }

    static let storeConnectedStatuses: [ConnectableAgent: ConnectionStatus] = [
        .claudeCode: .connected, .codexCLI: .connected, .copilotCLI: .connected,
    ]

    static var storeConnectedAccess: [AgentFolder: FolderAccess] {
        [.claude: .granted(home), .codex: .granted(home), .copilot: .granted(home)]
    }

    static var storeConnectedNotices: [ConnectableAgent: AgentConnections.Notice] {
        [.codexCLI: AgentConnections.Notice(
            text: "Run /hooks in Codex and trust Hoply's hooks, then restart running sessions.",
            detail: "The previous file was backed up to ~/.codex/hooks.json.hoply-backup-20261117101500."),
         .copilotCLI: AgentConnections.Notice(text: "Restart running Copilot CLI sessions to load the hooks.")]
    }
}
