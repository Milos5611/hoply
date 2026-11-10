import AgentKit
import AgentSystem
import Foundation
import Observation

@MainActor
@Observable
final class Palette {
    enum Icon: Equatable {
        case project(ProjectRef)
        case source(AgentSource)
        case symbol(String)
    }

    struct Command {
        var label: String
        var run: () -> Void
    }

    struct Entry {
        var item: PaletteItem
        var icon: Icon
        var status: SessionStatus?
        var failed = false
        var primary: Command
        var secondary: Command?
    }

    struct Row: Identifiable {
        var result: PaletteResult
        var entry: Entry

        var id: String { result.id }
    }

    static let frecencyKey = "HoplyPaletteFrecency"
    static let recentSessionLimit = 40
    static let recentProjectLimit = 30
    static let refreshInterval: Duration = .seconds(5)

    private(set) var query = ""
    private(set) var isOpen = false
    private(set) var recentSessions: [RecentSession] = []
    private(set) var recentProjects: [RecentProject] = []
    private(set) var frecency = Frecency()
    private var selectedID: String?
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored var dismiss: (() -> Void)?

    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?

    init(live: Bool = true) {
        isLive = live
        if live { frecency = Frecency.decode(UserDefaults.standard.data(forKey: Self.frecencyKey)) }
    }

    // MARK: - Open and close

    func open() {
        query = ""
        selectedID = nil
        isOpen = true
        guard isLive else { return }
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.loadRecents()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    func close() {
        isOpen = false
        refreshLoop?.cancel()
        refreshLoop = nil
    }

    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        selectedID = nil
    }

    private func loadRecents() async {
        guard let history = model?.history, let ledger = history.ledger else {
            recentSessions = []
            recentProjects = []
            return
        }
        let sessions = try? await ledger.recentSessions(limit: Self.recentSessionLimit)
        let projects = try? await ledger.recentProjects(limit: Self.recentProjectLimit)
        guard ledger.store === history.ledger?.store else { return }
        if let sessions, sessions != recentSessions { recentSessions = sessions }
        if let projects, projects != recentProjects { recentProjects = projects }
    }

    // MARK: - Results

    func rows(now: Date = Date()) -> [Row] {
        let entries = entries()
        let byID = Dictionary(entries.map { ($0.item.id, $0) }) { first, _ in first }
        return PaletteRanker(frecency: frecency).rank(entries.map(\.item), query: query, now: now).compactMap { result in
            byID[result.id].map { Row(result: result, entry: $0) }
        }
    }

    func selection(in rows: [Row]) -> Row? {
        rows.first { $0.id == selectedID } ?? rows.first
    }

    func move(by offset: Int) {
        let rows = rows()
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selectedID } ?? 0
        selectedID = rows[((current + offset) % rows.count + rows.count) % rows.count].id
    }

    func runSelection(secondary: Bool) {
        let rows = rows()
        guard let row = selection(in: rows) else { return }
        run(row, secondary: secondary)
    }

    func run(_ row: Row, secondary: Bool) {
        let command = secondary ? row.entry.secondary ?? row.entry.primary : row.entry.primary
        let now = Date()
        frecency.record(row.id, at: now)
        if isLive, let data = frecency.encoded() { UserDefaults.standard.set(data, forKey: Self.frecencyKey) }
        dismiss?()
        command.run()
    }

    // MARK: - Providers

    private func entries() -> [Entry] {
        guard let model else { return [] }
        let live = liveSessions(model)
        let liveKeys = Set(live.compactMap { PaletteItem.sessionKey(fromID: $0.item.id) })
        return live + recentSessions.filter { !liveKeys.contains($0.key) }.map { recent($0, model) }
            + recentProjects.map { project($0, model) } + model.devServers.servers.map { devServer($0, model) }
            + DashboardPage.allCases.map { page($0, model) } + actions(model)
    }

    private func liveSessions(_ model: AppModel) -> [Entry] {
        let grouping = model.grouping
        let hasHistory = model.history.isReady
        return model.sessions.filter { $0.state != .ended }.map { session in
            let status = grouping.status(of: session)
            let source = session.key.source
            let cwd = session.cwd.flatMap { $0.isEmpty ? nil : $0 }
            let projectTitle = model.projectTitle(for: session)
            let folder = cwd.map { folderCommand($0, model) }
            let details = Command(label: "Details") { [weak model] in model?.open(.session(session.key)) }
            let panel = Command(label: "Show") { [weak model] in model?.openPanel() }
            let item = PaletteItem(
                id: PaletteItem.sessionID(session.key), kind: .session,
                title: session.title ?? projectTitle ?? source.displayName,
                subtitle: [source.displayName, session.title == nil ? nil : projectTitle,
                           session.model.map(Format.model)].compactMap { $0 }.joined(separator: " · "),
                keywords: [status.label, cwd, session.key.id].compactMap { $0 },
                lastActive: session.lastEventAt,
                attention: status.needsAction ? .needsUser : status == .working ? .live : .none)
            return Entry(item: item, icon: .source(source), status: status,
                         failed: status == .yourTurn && session.failure != nil,
                         primary: hasHistory ? details : folder ?? panel,
                         secondary: hasHistory ? folder : nil)
        }
    }

    private func recent(_ session: RecentSession, _ model: AppModel) -> Entry {
        let source = session.key.source
        let title = session.title ?? session.project.map { "Session in \($0.title)" } ?? "\(source.displayName) session"
        let details = Command(label: "Details") { [weak model] in model?.open(.session(session.key)) }
        let canResume = ResumeScript.isSupported(source) && !session.cwd.isEmpty
        let resume = Command(label: "Resume") { [weak model] in
            if !ResumeLauncher.resume(source: source, sessionID: session.key.id, cwd: session.cwd) {
                model?.open(.session(session.key))
            }
        }
        let item = PaletteItem(
            id: PaletteItem.sessionID(session.key), kind: .session, title: title,
            subtitle: [source.displayName, session.title == nil ? nil : session.project?.title, session.branch,
                       Format.lastActive(session.lastAt)].compactMap { $0 }.joined(separator: " · "),
            keywords: [session.cwd, session.key.id].filter { !$0.isEmpty }, lastActive: session.lastAt)
        return Entry(item: item, icon: .source(source), primary: canResume ? resume : details,
                     secondary: canResume ? details : session.cwd.isEmpty ? nil : folderCommand(session.cwd, model))
    }

    private func project(_ recent: RecentProject, _ model: AppModel) -> Entry {
        let project = recent.project
        let sessions = recent.sessionCount == 1 ? "1 session" : "\(Format.count(recent.sessionCount)) sessions"
        let item = PaletteItem(id: PaletteItem.projectID(project.id), kind: .project, title: project.title,
                               subtitle: "\(Format.path(project.root)) · \(sessions)",
                               keywords: [project.name], lastActive: recent.lastActive)
        return Entry(item: item, icon: .project(project), primary: Command(label: "Open") { [weak model] in
            model?.history.openProject(project)
            model?.openDashboard()
        }, secondary: folderCommand(project.root, model))
    }

    private func devServer(_ server: DevServer, _ model: AppModel) -> Entry {
        let item = PaletteItem(
            id: PaletteItem.devServerID(server.id), kind: .devServer, title: server.shortName,
            subtitle: [server.projectName, "localhost:\(server.port)", server.memoryLabel].compactMap { $0 }
                .joined(separator: " · "),
            keywords: ["dev server", server.cwd])
        return Entry(item: item, icon: .symbol(DashboardPage.devServers.symbol),
                     primary: Command(label: "Open in Browser") { WorkspaceActions.openInBrowser(server.url) },
                     secondary: Command(label: "Show in Dev servers") { [weak model] in model?.openDashboard(.devServers) })
    }

    private func page(_ page: DashboardPage, _ model: AppModel) -> Entry {
        Entry(item: PaletteItem(id: PaletteItem.pageID(page.rawValue), kind: .page, title: page.title,
                                subtitle: "Dashboard", keywords: ["page"]),
              icon: .symbol(page.symbol),
              primary: Command(label: "Open") { [weak model] in model?.openDashboard(page) })
    }

    private func actions(_ model: AppModel) -> [Entry] {
        func action(_ name: String, _ title: String, _ subtitle: String, symbol: String, label: String = "Run",
                    keywords: [String] = [], run: @escaping (AppModel) -> Void) -> Entry {
            Entry(item: PaletteItem(id: PaletteItem.actionID(name), kind: .action, title: title, subtitle: subtitle,
                                    keywords: keywords),
                  icon: .symbol(symbol), primary: Command(label: label) { [weak model] in model.map(run) })
        }
        let hubURL = "http://127.0.0.1:\(model.settings.port)"
        let notifying = model.settings.notificationsEnabled
        var actions = [
            action("panel", "Open Panel", "Live sessions in the menu bar", symbol: "menubar.rectangle",
                   label: "Open") { $0.openPanel() },
            action("dashboard", "Open Dashboard", "Spending, projects, sessions and limits", symbol: "macwindow",
                   label: "Open") { $0.openDashboard() },
            action("settings", "Open Settings", "Listener, notifications, history and shortcuts", symbol: "gearshape",
                   label: "Open", keywords: ["preferences"]) { $0.openSettings() },
            action("notifications", notifying ? "Pause Notifications" : "Resume Notifications",
                   notifying ? "Stay silent until you resume them" : "Notify again when an agent needs you",
                   symbol: notifying ? "bell.slash" : "bell", keywords: ["mute", "bell"]) { $0.toggleNotifications() },
        ]
        if model.settings.claudeLimitsEnabled {
            actions.append(action("limits", "Refresh Claude Limits", "Fetch the plan usage now",
                                  symbol: "arrow.clockwise") { model in
                Task { await model.refreshClaudeLimits() }
            })
        }
        actions.append(action("cleanup", "Scan for Clean Up", "Find worktrees, caches and old transcripts to review",
                              symbol: DashboardPage.cleanUp.symbol, label: "Scan") { model in
            model.cleanup.refresh()
            model.openDashboard(.cleanUp)
        })
        if model.history.isReady, !model.history.progress.isBackfilling {
            actions.append(action("reindex", "Reindex History", "Re-read transcripts and the Copilot store; nothing is deleted",
                                  symbol: "arrow.triangle.2.circlepath") { $0.history.reindex() })
        }
        actions.append(action("hub-url", "Copy Hub URL", hubURL, symbol: "doc.on.doc", label: "Copy",
                              keywords: ["listener", "port"]) { _ in WorkspaceActions.copy(hubURL) })
        actions.append(action("quit", "Quit Hoply", "Stop the listener and exit", symbol: "power", label: "Quit") { $0.quit() })
        return actions
    }

    private func folderCommand(_ path: String, _ model: AppModel) -> Command {
        if let editor = model.defaultEditor {
            return Command(label: "Open in \(editor.name)") { [weak model] in model?.openInEditor(path, editor: editor) }
        }
        return Command(label: "Reveal in Finder") { WorkspaceActions.revealInFinder(path) }
    }
}

extension Palette {
    func show(query: String, sessions: [RecentSession], projects: [RecentProject]) {
        self.query = query
        selectedID = nil
        recentSessions = sessions
        recentProjects = projects
        isOpen = true
    }
}
