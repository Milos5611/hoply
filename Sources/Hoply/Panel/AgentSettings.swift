import AgentKit
import AgentSystem
import SwiftUI

struct AgentSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.edition) private var edition

    var body: some View {
        let connections = model.connections
        let connector = connections.connector
        let connectable = connections.connectable
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle("Agents")
                    Spacer(minLength: 8)
                    if connectable.count > 1 {
                        let asks = connectable.contains { connections.problems[$0] != nil || connections.status(of: $0) == nil }
                        Button(asks ? "Connect All…" : "Connect All") { model.connectAll() }
                            .buttonStyle(.bordered)
                            .disabled(connections.isBusy)
                            .help(asks ? "Asks macOS once for your home folder, then connects \(AgentText.list(connectable))"
                                       : "Connect \(AgentText.list(connectable)); your own hooks and settings stay")
                    }
                }
                ForEach(ConnectableAgent.allCases) { agent in
                    AgentConnectionRow(agent: agent, path: connector.configPath(for: agent),
                                       directory: connector.configDirectory(for: agent))
                }
                if edition.needsFolderGrants {
                    Hint("Connect asks macOS once for access to the agent's folder; Connect All asks once for your home folder.")
                }
                Hint("Copilot CLI also covers Copilot's agent in JetBrains. Qwen Code is set up by hand: see the README.")
            }
        }
    }
}

struct AgentConnectionRow: View {
    @Environment(AppModel.self) private var model
    let agent: ConnectableAgent
    let path: String
    let directory: String

    var body: some View {
        let connections = model.connections
        let status = connections.status(of: agent)
        let access = connections.access(of: agent)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                SourceBadge(source: agent.source, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(agent.displayName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if let status {
                            ConnectionPill(status: status)
                        } else if let access, access.asksForGrant {
                            FolderAccessPill(access: access)
                        }
                    }
                    Text(subtitle(status))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(status == .notInstalled ? directory : path)
                }
                Spacer(minLength: 8)
                action(status: status, access: access)
            }
            if agent == .claudeCode, connections.claudeHooksTwice {
                message("Hoply's hooks are in \(Format.path(path)) and in Hoply's Claude Code plugin, so every event arrives twice. Remove the plugin with /plugin in Claude Code.",
                        symbol: "exclamationmark.triangle.fill", color: .orange, isError: false)
            }
            if case .unreadable(let reason) = status {
                message(reason, symbol: "exclamationmark.triangle.fill", color: .red, isError: true)
            }
            if let notice = connections.notices[agent] {
                message(notice.text, symbol: notice.isError ? "exclamationmark.triangle.fill" : "arrow.clockwise",
                        color: notice.isError ? .red : .orange, isError: notice.isError)
                    .help(notice.detail ?? notice.text)
            }
        }
    }

    private func subtitle(_ status: ConnectionStatus?) -> String {
        guard status == .notInstalled else { return Format.path(path) }
        return "No \(Format.path(directory)) folder. Install \(agent.displayName) first."
    }

    @ViewBuilder private func action(status: ConnectionStatus?, access: FolderAccess?) -> some View {
        let connections = model.connections
        let asks = connections.problems[agent] != nil
        if connections.running == agent {
            ProgressView()
                .controlSize(.small)
        } else {
            switch status {
            case .notConnected:
                Button(asks ? "Connect…" : "Connect") { model.connect(agent) }
                    .buttonStyle(.borderedProminent)
                    .disabled(connections.isBusy)
                    .help(asks ? askHelp : connectHelp)
            case .outdated:
                Button(asks ? "Update…" : "Update") { model.connect(agent) }
                    .buttonStyle(.borderedProminent)
                    .disabled(connections.isBusy)
                    .help("Rewrite Hoply's hooks for port \(model.settings.port); your own hooks and settings stay")
            case .connected:
                Button("Disconnect") { model.disconnect(agent) }
                    .buttonStyle(.bordered)
                    .disabled(connections.isBusy)
                    .help(disconnectHelp)
            case .unreadable where asks:
                Button("Allow Access…") { model.connect(agent) }
                    .buttonStyle(.borderedProminent)
                    .disabled(connections.isBusy)
                    .help("Asks macOS for the folder that holds both files, then connects \(agent.displayName)")
            case nil where access?.asksForGrant == true:
                Button("Connect…") { model.connect(agent) }
                    .buttonStyle(.borderedProminent)
                    .disabled(connections.isBusy)
                    .help(askHelp)
            case .notInstalled, .unreadable, nil:
                EmptyView()
            }
        }
    }

    private var askHelp: String {
        "Asks macOS for access to \(Format.path(directory)), then adds Hoply's hooks to \(Format.path(path))"
    }

    private var connectHelp: String {
        switch agent {
        case .claudeCode: return "Add Hoply's hooks to \(Format.path(path)), backing it up first; your own hooks and settings stay"
        case .copilotCLI: return "Write Hoply's hooks to \(Format.path(path))"
        case .codexCLI:
            return "Add Hoply's hooks to \(Format.path(path)), backing it up first; then trust them with /hooks in Codex"
        }
    }

    private var disconnectHelp: String {
        switch agent {
        case .claudeCode: return "Remove only Hoply's hooks from \(Format.path(path)), backing it up first"
        case .copilotCLI: return "Rename \(Format.path(path)) so Copilot CLI stops loading it"
        case .codexCLI: return "Remove only Hoply's hooks from \(Format.path(path)), backing it up first"
        }
    }

    private func message(_ text: String, symbol: String, color: Color, isError: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(isError ? color : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 38)
    }
}

enum AgentText {
    static func list(_ agents: [ConnectableAgent]) -> String {
        list(agents.map(\.displayName))
    }

    static func list(_ names: [String]) -> String {
        guard names.count > 2 else { return names.joined(separator: " and ") }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}

struct ConnectionPill: View {
    let status: ConnectionStatus

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
            .fixedSize()
    }

    private var label: String {
        switch status {
        case .connected: return "Connected"
        case .outdated: return "Update needed"
        case .notConnected: return "Not connected"
        case .notInstalled: return "Not found"
        case .unreadable: return "Can't read"
        }
    }

    private var color: Color {
        switch status {
        case .connected: return .green
        case .outdated: return .orange
        case .notConnected, .notInstalled: return .secondary
        case .unreadable: return .red
        }
    }
}
