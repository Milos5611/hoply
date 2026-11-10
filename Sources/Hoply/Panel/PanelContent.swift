import AgentKit
import SwiftUI

struct PanelContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            PanelSections()
                .padding(.top, 2)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .scrollIndicators(.automatic)
    }
}

struct PanelSections: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let grouping = model.grouping
        VStack(spacing: 10) {
                StatStrip(oldestWait: grouping.waiting.filter { grouping.status(of: $0).needsAction }
                    .map(\.stateSince).min())
                if !grouping.waiting.isEmpty {
                    WaitingCard(grouping: grouping)
                }
                if let nudge = model.connections.nudge {
                    AgentNudgeCard(nudge: nudge)
                }
                ForEach(grouping.projects) { group in
                    ProjectCard(group: group, grouping: grouping)
                }
                if model.sessions.isEmpty {
                    EmptySessionsCard()
                }
                let unplaced = model.devServers.unplacedServers(groups: grouping.projects, sessions: model.sessions)
                if !unplaced.isEmpty {
                    DevServersCard(servers: unplaced)
                }
                WidgetStrip()
        }
    }
}

struct StatStrip: View {
    @Environment(AppModel.self) private var model
    let oldestWait: Date?

    var body: some View {
        HStack(spacing: 10) {
            StatTile(label: "Agents", value: "\(model.activeCount)",
                     tag: model.workingCount > 0 ? "Live" : nil, tagColor: .green,
                     prominent: model.workingCount > 0 && model.attentionCount == 0) {
                MiniBars(values: model.activity.values, highlightLast: 3, tint: .orange)
            }
            StatTile(label: "Need you", value: "\(model.attentionCount)",
                     valueColor: model.attentionCount > 0 ? .orange : .primary,
                     tag: oldestWait.map { Format.age(since: $0) }, tagColor: .orange,
                     prominent: model.attentionCount > 0) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(model.attentionCount > 0 ? Color.orange : Color.primary.opacity(0.18))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            LocalModelStatTile()
        }
    }
}

struct LocalModelStatTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let servers = model.settings.modelServers.filter(\.isActive)
        let monitor = model.modelServers
        let online = servers.compactMap { monitor.state(of: $0.id)?.online }
        let figure = Self.figure(online)
        let tag = tag(servers)
        StatTile(label: servers.count == 1 ? servers[0].displayName : servers.count > 1 ? "Models" : "Local model",
                 value: figure.value, unit: figure.unit, tag: tag.text, tagColor: tag.color) {
            MiniBars(values: monitor.combinedThroughput, highlightLast: 1, tint: .blue)
        }
    }

    private static func figure(_ online: [ModelServerStatus]) -> ModelServerText.Figure {
        let rated = online.filter { $0.capabilities.contains(.generationRate) }
        if !rated.isEmpty {
            let rates = rated.compactMap(\.generationTokensPerSecond)
            return ModelServerText.Figure(value: rates.isEmpty ? "–" : "\(Format.whole(rates.reduce(0, +)))", unit: "tok/s")
        }
        if online.contains(where: { $0.capabilities.contains(.loadedModels) }) {
            return ModelServerText.Figure(value: "\(online.reduce(0) { $0 + $1.snapshot.loadedModels.count })", unit: "loaded")
        }
        if online.count == 1, let only = ModelServerText.figure(online[0]) { return only }
        return ModelServerText.Figure(value: "–", unit: "tok/s")
    }

    private func tag(_ servers: [ModelServer]) -> (text: String, color: Color) {
        guard !servers.isEmpty else { return ("Off", .secondary) }
        let health = servers.map(model.modelServers.health)
        if servers.count == 1 { return (health[0] == .connecting ? "…" : health[0].label, health[0].color) }
        let live = health.count { $0 == .live }
        let color: Color = live == servers.count ? .green : health.contains(.offline) && live == 0 ? .red : .orange
        return ("\(live)/\(servers.count) live", color)
    }
}

struct WaitingCard: View {
    @Environment(AppModel.self) private var model
    let grouping: SessionGrouping

    var body: some View {
        let sessions = grouping.waiting
        let acting = sessions.count { grouping.status(of: $0).needsAction }
        Card(tint: .orange) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(.orange)
                    Text("Waiting on you")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    CountChip(value: acting, label: acting == 1 ? "session" : "sessions", tint: .orange)
                }
                ForEach(sessions) { session in
                    SessionRow(session: session, status: grouping.status(of: session),
                               place: model.projectTitle(for: session).map(SessionPlace.project))
                }
            }
        }
    }
}

struct ProjectCard: View {
    @Environment(AppModel.self) private var model
    let group: ProjectGroup
    let grouping: SessionGrouping

    var body: some View {
        let muted = group.path.map(model.isMuted) ?? false
        let servers = model.devServers.headerServers(inGroup: group.id, sessions: model.sessions)
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    icon
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.name)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if muted {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .help("Notifications from this project are muted")
                    }
                    if group.isWorking {
                        Circle()
                            .fill(.green)
                            .frame(width: 7, height: 7)
                            .help("An agent is working here")
                    }
                }
                if !servers.isEmpty {
                    DevServerStrip(servers: servers)
                }
                ForEach(group.sessions) { session in
                    SessionRow(session: session, status: grouping.status(of: session),
                               place: SessionPlace(cwd: session.cwd, root: group.path))
                }
                if let path = group.path {
                    HStack(spacing: 8) {
                        if let editor = model.defaultEditor {
                            Button { model.openInEditor(path) } label: {
                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                            }
                            .tooltip(model.editors.count > 1 ? "Open in \(editor.name) · right-click for other editors"
                                                             : "Open in \(editor.name)")
                            .contextMenu {
                                ForEach(model.editors) { other in
                                    Button("Open in \(other.name)") { model.openInEditor(path, editor: other) }
                                }
                            }
                        }
                        Button { WorkspaceActions.openInTerminal(path) } label: { Image(systemName: "apple.terminal") }
                            .tooltip("Open Terminal in this folder")
                        Button { WorkspaceActions.revealInFinder(path) } label: { Image(systemName: "folder") }
                            .tooltip("Show in Finder")
                        Button { WorkspaceActions.copy(path) } label: { Image(systemName: "doc.on.doc") }
                            .tooltip("Copy the folder's path")
                        Button { model.toggleMute(path) } label: { Image(systemName: muted ? "bell.slash" : "bell") }
                            .tooltip(muted ? "Unmute this project's notifications" : "Mute this project's notifications")
                    }
                    .buttonStyle(.tile)
                }
            }
        }
    }

    private var icon: some View {
        ProjectIcon(kind: group.project?.kind, title: group.name, key: group.project?.root ?? group.path,
                    hasFolder: group.path != nil, size: 34)
    }

    private var subtitle: String {
        let count = group.sessions.count
        let agents = count == 1 ? "1 agent" : "\(count) agents"
        guard let path = group.path else { return agents }
        return "\(Format.path(path)) · \(agents)"
    }
}

struct EmptySessionsCard: View {
    var body: some View {
        Card {
            HStack(spacing: 10) {
                IconTile(symbol: "sparkles", tint: .secondary, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No agent sessions yet")
                        .font(.system(size: 13, weight: .medium))
                    Text("Start Claude Code, Copilot or Qwen Code once they're connected in Settings → Agents. Sessions appear here as they report in.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct AgentNudgeCard: View {
    @Environment(AppModel.self) private var model
    let nudge: AgentConnections.Nudge

    var body: some View {
        Card(tint: .blue) {
            HStack(spacing: 10) {
                IconTile(symbol: isUpdate ? "arrow.triangle.2.circlepath" : "link", tint: isUpdate ? .orange : .blue,
                         size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isUpdate ? "Agent hooks need an update" : "Connect your agents")
                        .font(.system(size: 13, weight: .semibold))
                    Text(reason)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(isUpdate ? "Update…" : "Connect…") { model.showingSettings = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Open Settings → Agents")
                Button { model.connections.dismissNudge() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .tooltip("Hide until an agent's connection changes")
            }
        }
    }

    private var isUpdate: Bool {
        if case .update = nudge { return true }
        return false
    }

    private var reason: String {
        switch nudge {
        case .connect(let agents):
            return "Without Hoply's hooks, \(Self.names(agents)) sessions don't show up here."
        case .update(let agents):
            return "\(Self.names(agents)) \(agents.count == 1 ? "still reports" : "still report") to an old port or with older hooks."
        }
    }

    private static func names(_ agents: [ConnectableAgent]) -> String {
        agents.map(\.displayName).joined(separator: " and ")
    }
}

struct DevServersCard: View {
    @Environment(AppModel.self) private var model
    let servers: [DevServer]

    var body: some View {
        let groups = DevServerGroup.groups(of: servers)
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.secondary)
                    Text("Dev servers")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { model.openDashboard(.devServers) } label: {
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Show all dev servers in the Dashboard")
                }
                ForEach(groups) { group in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(group.name)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 104, alignment: .leading)
                            .help(Format.path(group.path))
                        DevServerStrip(servers: group.servers)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

struct WidgetStrip: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ClaudeLimitsWidget()
            LocalModelWidget()
            TodayWidget()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
