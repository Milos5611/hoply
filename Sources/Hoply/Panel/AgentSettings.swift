import AgentKit
import AgentSystem
import SwiftUI

struct AgentSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let connections = model.connections
        let connector = connections.connector
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("Agents")
                ForEach(ConnectableAgent.allCases) { agent in
                    AgentConnectionRow(agent: agent, status: connections.status(of: agent),
                                       path: connector.configPath(for: agent),
                                       directory: connector.configDirectory(for: agent),
                                       notice: connections.notices[agent], running: connections.running)
                }
                Hint("Copilot CLI also covers Copilot's agent in JetBrains. Qwen Code is set up by hand: see the README.")
            }
        }
    }
}

struct AgentConnectionRow: View {
    @Environment(AppModel.self) private var model
    let agent: ConnectableAgent
    let status: ConnectionStatus?
    let path: String
    let directory: String
    let notice: AgentConnections.Notice?
    let running: ConnectableAgent?

    var body: some View {
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
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(status == .notInstalled ? directory : path)
                }
                Spacer(minLength: 8)
                action
            }
            if case .unreadable(let reason) = status {
                message(reason, symbol: "exclamationmark.triangle.fill", color: .red, isError: true)
            }
            if let notice {
                message(notice.text, symbol: notice.isError ? "exclamationmark.triangle.fill" : "arrow.clockwise",
                        color: notice.isError ? .red : .orange, isError: notice.isError)
                    .help(notice.detail ?? notice.text)
            }
        }
    }

    private var subtitle: String {
        guard status == .notInstalled else { return Format.path(path) }
        return "No \(Format.path(directory)) folder. Install \(agent.displayName) first."
    }

    @ViewBuilder private var action: some View {
        if running == agent {
            ProgressView()
                .controlSize(.small)
        } else {
            switch status {
            case .notConnected:
                Button("Connect") { model.connections.connect(agent) }
                    .buttonStyle(.borderedProminent)
                    .disabled(running != nil)
                    .help(connectHelp)
            case .outdated:
                Button("Update") { model.connections.connect(agent) }
                    .buttonStyle(.borderedProminent)
                    .disabled(running != nil)
                    .help("Rewrite Hoply's hooks for port \(model.settings.port); your own hooks and settings stay")
            case .connected:
                Button("Disconnect") { model.connections.disconnect(agent) }
                    .buttonStyle(.bordered)
                    .disabled(running != nil)
                    .help(disconnectHelp)
            case .notInstalled, .unreadable, nil:
                EmptyView()
            }
        }
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
