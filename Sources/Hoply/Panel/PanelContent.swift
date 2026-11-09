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
                StatStrip(oldestWait: grouping.oldestWaitSince)
                if !grouping.waiting.isEmpty {
                    WaitingCard(sessions: grouping.waiting)
                }
                ForEach(grouping.projects) { group in
                    ProjectCard(group: group)
                }
                if model.sessions.isEmpty {
                    EmptySessionsCard()
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
                     prominent: model.workingCount > 0) {
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
            StatTile(label: localModelName, value: model.vllm?.generationTokensPerSecond.map { "\(Int($0.rounded()))" } ?? "–",
                     unit: "tok/s", tag: localModelTag.text, tagColor: localModelTag.color,
                     prominent: model.vllmOnline) {
                MiniBars(values: model.throughput.values, highlightLast: 1, tint: .blue)
            }
        }
    }

    private var localModelName: String {
        model.settings.vllmName.isEmpty ? "Local model" : model.settings.vllmName
    }

    private var localModelTag: (text: String, color: Color) {
        if model.settings.vllmBaseURL.isEmpty { return ("Off", .secondary) }
        return model.vllmOnline ? ("Live", .green) : ("Offline", .red)
    }
}

struct WaitingCard: View {
    @Environment(AppModel.self) private var model
    let sessions: [AgentSession]

    var body: some View {
        Card(prominent: true, tint: .orange) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(.orange)
                    Text("Waiting on you")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    CountChip(value: sessions.count, label: sessions.count == 1 ? "session" : "sessions", tint: .orange)
                }
                ForEach(sessions) { session in
                    SessionRow(session: session, place: model.projectTitle(for: session).map(SessionPlace.project))
                }
            }
        }
    }
}

struct ProjectCard: View {
    @Environment(AppModel.self) private var model
    let group: ProjectGroup

    var body: some View {
        let muted = group.path.map(model.isMuted) ?? false
        Card(prominent: group.isWorking) {
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
                ForEach(group.sessions) { session in
                    SessionRow(session: session, place: SessionPlace(cwd: session.cwd, root: group.path))
                }
                if let path = group.path {
                    HStack(spacing: 8) {
                        Button { WorkspaceActions.openInTerminal(path) } label: { Image(systemName: "apple.terminal") }
                            .help("Open in Terminal")
                        Button { WorkspaceActions.revealInFinder(path) } label: { Image(systemName: "folder") }
                            .help("Reveal in Finder")
                        Button { WorkspaceActions.copy(path) } label: { Image(systemName: "doc.on.doc") }
                            .help("Copy path")
                        Button { model.toggleMute(path) } label: { Image(systemName: muted ? "bell.slash" : "bell") }
                            .help(muted ? "Unmute notifications" : "Mute notifications")
                    }
                    .buttonStyle(.tile)
                }
            }
        }
    }

    /// A resolved project shows its kind; an unresolved cwd (History off or not resolved yet) a plain folder.
    @ViewBuilder
    private var icon: some View {
        if let project = group.project {
            IconTile(projectKind: project.kind, size: 34)
        } else {
            IconTile(symbol: group.path == nil ? "questionmark.folder" : "folder.fill", tint: .blue, size: 34)
        }
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
                    Text("Start Claude Code, Copilot or Qwen Code after running scripts/install.sh. Sessions appear here as they report in.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
