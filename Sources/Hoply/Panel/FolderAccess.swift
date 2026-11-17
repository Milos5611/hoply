import AgentKit
import SwiftUI

struct FolderAccessCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let connections = model.connections
        let connector = connections.connector
        let agents = connections.connectable
        let asking = connections.needingAccess.filter(agents.contains)
        Card(tint: .blue) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    IconTile(symbol: agents.isEmpty ? "folder.badge.questionmark" : "link", tint: .blue, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agents.isEmpty ? "No coding agents on this Mac yet" : "Connect your agents")
                            .font(.system(size: 13, weight: .semibold))
                        Text(agents.isEmpty ? FolderAccessText.noneInstalled
                                            : FolderAccessText.connectAll(agents, directories: asking.map(connector.configDirectory(for:))))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button { connections.dismissFolderCard() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .tooltip("Hide; Settings → Agents connects them too")
                }
                if !agents.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(agents) { agent in
                            SourceBadge(source: agent.source, size: 22)
                        }
                        Spacer(minLength: 8)
                        if connections.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button(agents.count > 1 ? "Connect All…" : "Connect…") {
                                model.connectAll(agents, showingResult: true)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .help("Asks macOS once for your home folder, then connects \(AgentText.list(agents))")
                        }
                    }
                    .padding(.leading, 44)
                }
            }
        }
    }
}

struct FolderAccessSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("Folder access")
                Hint(FolderAccessText.why)
                FolderAccessRows(showsRemove: true)
                Hint(FolderAccessText.settingsHint(shared: !FolderAccessText.sharing(model.connections.access).isEmpty))
            }
        }
    }
}

struct FolderAccessRows: View {
    @Environment(AppModel.self) private var model
    var showsRemove = false

    var body: some View {
        let connections = model.connections
        let connector = connections.connector
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AgentFolder.allCases) { folder in
                FolderAccessRow(folder: folder, access: connections.access[folder],
                                expected: connector.configDirectory(for: folder.agent),
                                notice: connections.folderNotices[folder], showsRemove: showsRemove)
            }
        }
    }
}

struct FolderAccessRow: View {
    @Environment(AppModel.self) private var model
    let folder: AgentFolder
    let access: FolderAccess?
    let expected: String
    let notice: AgentConnections.Notice?
    var showsRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                SourceBadge(source: folder.agent.source, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(folder.displayName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if let access {
                            FolderAccessPill(access: access)
                        }
                    }
                    Text(FolderAccessText.detail(folder, access: access, expected: expected))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                action
            }
            if let notice {
                NoticeLine(notice: notice)
            }
        }
    }

    @ViewBuilder private var action: some View {
        let connections = model.connections
        if let access, access.asksForGrant {
            Button(FolderAccessText.buttonTitle(access)) { model.grantFolderAccess(folder) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(connections.isBusy)
                .help("Opens a window where you pick \(Format.path(expected)). Hoply reads it, and adds its hooks there only when you connect \(folder.displayName).")
        } else if showsRemove, case .granted(let granted) = access {
            Button("Remove") { model.revokeFolderAccess(folder) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(connections.isBusy)
                .help(FolderAccessText.removeHelp(folder, expected: expected, granted: granted,
                                                  sharing: FolderAccessText.sharing(connections.access)[granted] ?? []))
        }
    }
}

struct FolderAccessPill: View {
    let access: FolderAccess

    var body: some View {
        if let label {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .foregroundStyle(color)
                .background(Capsule().fill(color.opacity(0.15)))
                .fixedSize()
        }
    }

    private var label: String? {
        switch access {
        case .notNeeded: nil
        case .granted: "Allowed"
        case .missing: "Needs access"
        case .notFound: "Not installed"
        case .elsewhere: "Other folder"
        case .readOnly: "Read-only"
        case .broken: "Access lost"
        }
    }

    private var color: Color {
        switch access {
        case .granted: .green
        case .missing, .elsewhere, .readOnly: .orange
        case .broken: .red
        case .notFound, .notNeeded: .secondary
        }
    }
}

struct NoticeLine: View {
    let notice: AgentConnections.Notice
    var indent: CGFloat = 38

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(notice.isError ? Color.orange : Color.green)
            Text(notice.text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, indent)
        .help(notice.detail ?? notice.text)
    }
}

enum FolderAccessText {
    static let why = "Hoply runs in the Mac App Store sandbox, so it sees Claude Code's, Codex's and Copilot's folders only once you allow them. It reads them for your sessions, token usage and costs, and adds its hooks there when you connect an agent."

    static let noneInstalled = "Hoply shows sessions, token usage and costs from Claude Code, Codex and Copilot. None of them is installed on this Mac yet; once one is, connect it in Settings → Agents."

    static func connectAll(_ agents: [ConnectableAgent], directories: [String]) -> String {
        let button = agents.count > 1 ? "Connect All" : "Connect"
        let whose = agents.count > 1 ? "your agents'" : "\(agents[0].displayName)'s"
        guard !directories.isEmpty else { return "\(button) adds Hoply's hooks so \(whose) sessions show up here." }
        return "Click \(button) and allow your home folder when macOS asks. Hoply then reads \(whose) usage and adds its hooks to \(paths(directories))."
    }

    static func homeMessage(_ directories: [String]) -> String {
        "Allow your home folder so Hoply can read your agents' usage and add its hooks to \(paths(directories)). Hoply changes nothing else."
    }

    static func reason(_ folder: AgentFolder) -> String {
        switch folder {
        case .claude: "your sessions, token usage and costs from its transcripts"
        case .codex: "your sessions, token usage and plan limits from its session files"
        case .copilot: "your sessions, token usage and premium requests from its session store"
        }
    }

    static func panelMessage(_ folder: AgentFolder, expected: String) -> String {
        "Allow \(Format.path(expected)) so Hoply can show \(reason(folder)) and add its hooks for \(folder.displayName)."
    }

    static func buttonTitle(_ access: FolderAccess) -> String {
        switch access {
        case .elsewhere, .broken: "Choose Again…"
        case .readOnly: "Allow Again…"
        default: "Allow Access…"
        }
    }

    static func detail(_ folder: AgentFolder, access: FolderAccess?, expected: String) -> String {
        let path = Format.path(expected)
        switch access {
        case nil, .notNeeded: return path
        case .granted(let granted):
            return granted == expected ? "Reading \(path)" : "Reading \(path) through \(Format.path(granted))"
        case .missing: return "Allow \(path) for \(reason(folder))"
        case .notFound: return "No \(path) folder on this Mac"
        case .elsewhere(let granted): return "Allowed \(Format.path(granted)), but \(folder.displayName) uses \(path)"
        case .readOnly(let granted):
            let through = granted == expected ? "" : " through \(Format.path(granted))"
            return "Read-only\(through) from an earlier version. Allow again to read it and add hooks."
        case .broken(let reason): return "\(reason). Allow \(path) again."
        }
    }

    static func settingsHint(shared: Bool) -> String {
        let base = "Each folder stays allowed after a restart. A folder you moved is set under History."
        return shared ? base + " Removing a folder several agents share removes it for all of them." : base
    }

    static func sharing(_ access: [AgentFolder: FolderAccess]) -> [String: [AgentFolder]] {
        var byPath: [String: [AgentFolder]] = [:]
        for folder in AgentFolder.allCases {
            if case .granted(let path)? = access[folder] { byPath[path, default: []].append(folder) }
        }
        return byPath.filter { $0.value.count > 1 }
    }

    static func removeHelp(_ folder: AgentFolder, expected: String, granted: String, sharing: [AgentFolder]) -> String {
        let others = sharing.filter { $0 != folder }.map(\.displayName)
        guard !others.isEmpty else { return "Stop reading \(Format.path(expected)). History already read stays." }
        return "Stop reading \(Format.path(expected)). \(AgentText.list(others)) \(others.count == 1 ? "uses" : "use") the same folder, \(Format.path(granted)), so \(others.count == 1 ? "it stops" : "they stop") too. History already read stays."
    }

    static func removedNotice(_ removed: [String], others: [AgentFolder]) -> AgentConnections.Notice? {
        guard !others.isEmpty, !removed.isEmpty else { return nil }
        let names = AgentText.list(others.map(\.displayName))
        return AgentConnections.Notice(
            text: "Removed \(paths(removed)). Hoply stopped reading \(names) too, which used the same folder.")
    }

    static func pick(_ picked: String, expected: String) -> FolderPick {
        let resolved = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path }
        return FolderGrantRules.pick(resolved(picked), expected: resolved(expected))
    }

    static func coveringPick(_ picked: String, expected: String) -> AgentConnections.Notice {
        AgentConnections.Notice(text: "You allowed \(Format.path(picked)), which includes \(Format.path(expected)).")
    }

    static func wrongPick(_ folder: AgentFolder, picked: String, expected: String) -> AgentConnections.Notice {
        AgentConnections.Notice(
            text: "You picked \(Format.path(picked)), but \(folder.displayName) keeps its files in \(Format.path(expected)). Choose that folder, or set the folder you use under History.",
            isError: true)
    }

    static func wrongLinkPick(picked: String, path: String, target: String, allow: String) -> AgentConnections.Notice {
        AgentConnections.Notice(
            text: "You picked \(Format.path(picked)), but \(Format.path(path)) links to \(Format.path(target)), so Hoply needs \(Format.path(allow)), which holds both.",
            isError: true)
    }

    static func outsidePick(_ agent: ConnectableAgent, picked: String, directory: String) -> AgentConnections.Notice {
        AgentConnections.Notice(
            text: "\(Format.path(picked)) doesn't include \(Format.path(directory)), so \(agent.displayName) isn't connected yet.",
            isError: true)
    }

    static func grantFailed(_ picked: String, _ error: Error) -> AgentConnections.Notice {
        AgentConnections.Notice(
            text: "macOS didn't give Hoply access to \(Format.path(picked)): \(error.localizedDescription)", isError: true)
    }

    private static func paths(_ paths: [String]) -> String {
        AgentText.list(paths.map(Format.path))
    }
}
