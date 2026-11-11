import AgentKit
import Foundation

extension PreviewData {
    static let updateVersion = "0.2.0"

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

    static let connectionsNone: [ConnectableAgent: ConnectionStatus] = [
        .claudeCode: .notConnected, .copilotCLI: .notConnected, .codexCLI: .notConnected,
    ]
}
