import AgentKit
import AgentSystem
import AppKit
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppModel {
    private(set) var sessions: [AgentSession] = []
    private(set) var serverStatus: HubServer.Status = .stopped
    private(set) var claudeLimits: ClaudeLimits?
    private(set) var claudeLimitsFetchedAt: Date?
    private(set) var claudeLimitsError: String?
    private(set) var lastNote: String?
    private(set) var settings: AppSettings
    private(set) var launchAtLogin = false
    private(set) var activity = RollingSeries(bucketLength: 30, capacity: 20, now: Date())
    private(set) var projectsByCwd: [String: ProjectRef] = [:]
    private(set) var gitStats: [String: GitDiffStat] = [:]
    private(set) var editors: [Editor] = []
    private(set) var defaultEditorID = ""
    private(set) var approvals: [ApprovalRequest] = []
    var showingSettings = false
    let history = History()
    let modelServers: ModelServers
    let devServers: DevServers
    let cleanup: Cleanup
    let palette: Palette
    let hotKey: HotKey
    let projectEdits: ProjectEdits
    let connections: AgentConnections
    let updates: Updates
    @ObservationIgnored var paletteToggler: (() -> Void)?
    @ObservationIgnored var dashboardOpener: ((DashboardPage?) -> Void)?
    @ObservationIgnored var panelOpener: (() -> Void)?
    @ObservationIgnored var settingsOpener: (() -> Void)?

    @ObservationIgnored private var board = SessionBoard()
    @ObservationIgnored private let server = HubServer()
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var policy = NotificationPolicy()
    @ObservationIgnored private let limitsClient = ClaudeLimitsClient()
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var resolvingCwds: Set<String> = []
    @ObservationIgnored private var unresolvedCwds: Set<String> = []
    @ObservationIgnored private var projectsEpoch = 0
    @ObservationIgnored private var panelOnScreen = false
    @ObservationIgnored private var dashboardOnScreen = false
    @ObservationIgnored private var isFetchingLimits = false
    @ObservationIgnored private var limitsEpoch = 0
    @ObservationIgnored private let gitCache = GitStatCache()
    @ObservationIgnored private var gitWatch: [SessionKey: GitWatch] = [:]
    @ObservationIgnored private let isLive: Bool

    private struct GitWatch: Equatable {
        var cwd: String
        var settled: Bool
    }

    var attentionCount: Int {
        let grouping = grouping
        return grouping.waiting.count { grouping.status(of: $0).needsAction }
    }
    var workingCount: Int { sessions.filter { $0.state == .working }.count }
    var activeCount: Int { sessions.filter { $0.state != .ended }.count }
    var grouping: SessionGrouping {
        SessionGrouping(sessions: sessions, projects: history.unavailableReason == nil ? projectsByCwd : [:],
                        limits: limitSamples, localModelPatterns: settings.localModelPatterns, now: Date())
    }
    var limitSamples: [LimitSample] {
        let codex = Array(history.codexLimits.values)
        guard let claudeLimits, let claudeLimitsFetchedAt else { return codex }
        return claudeLimits.samples(at: claudeLimitsFetchedAt) + codex
    }
    var defaultEditor: Editor? {
        editors.first { $0.id == defaultEditorID } ?? editors.first
    }
    var isBundledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    init(live: Bool = true) {
        isLive = live
        modelServers = ModelServers(history: history, live: live)
        devServers = DevServers(live: live)
        cleanup = Cleanup(history: history, live: live)
        palette = Palette(live: live)
        hotKey = HotKey(live: live)
        projectEdits = ProjectEdits(history: history)
        connections = AgentConnections(live: live)
        updates = Updates(live: live)
        guard live else {
            settings = AppSettings()
            palette.model = self
            modelServers.settings = { [weak self] in self?.settings ?? AppSettings() }
            connections.settings = { [weak self] in self?.settings ?? AppSettings() }
            return
        }
        settings = AppSettings.load()
        palette.model = self
        hotKey.onPress = { [weak self] in self?.togglePalette() }
        hotKey.update(enabled: settings.paletteEnabled, combo: settings.paletteHotKey)
        policy.preferences = NotificationPreferences(settings: settings)
        history.setPlan(settings)
        notifier.onOpen = { [weak self] target in self?.open(target) }
        notifier.onDecision = { [weak self] id, decision in self?.decide(id, decision) }
        notifier.activate()

        server.onEvents = { [weak self] events in
            Task { @MainActor in self?.ingest(events) }
        }
        server.onUsage = { [weak self] usage in
            Task { @MainActor in self?.history.record(usage) }
        }
        server.onPrompts = { [weak self] prompts in
            Task { @MainActor in self?.history.record([], prompts: prompts) }
        }
        server.onStatus = { [weak self] status in
            Task { @MainActor in self?.serverStatus = status }
        }
        server.onNote = { [weak self] note in
            Task { @MainActor in self?.lastNote = note }
        }
        // One task, approval first: the permission notification its events post must find it.
        server.onApproval = { [weak self] approval, events in
            Task { @MainActor in
                self?.approvals.append(approval)
                self?.ingest(events)
            }
        }
        server.onApprovalClosed = { [weak self] id in
            Task { @MainActor in self?.approvals.removeAll { $0.id == id } }
        }
        server.setHoldsApprovals(settings.approveFromHoply)
        server.start(port: UInt16(clamping: settings.port))
        history.onLoaded = { [weak self] _ in self?.projectEdits.reload() }
        history.onLiveModels = { [weak self] in self?.applyLiveModels() }
        history.onLiveTitles = { [weak self] in self?.applyLiveTitles() }
        history.onLimits = { [weak self] samples, previous in self?.codexLimitsRead(samples, previous: previous) }
        history.onCodexLimits = { [weak self] in self?.checkLimitedSessions(now: Date()) }
        history.onSubagents = { [weak self] activity in self?.applySubagents(activity) }
        projectEdits.onEdited = { [weak self] in self?.projectsEdited() }
        history.open(LedgerConfiguration(settings: settings))
        ResumeLauncher.prune()
        modelServers.settings = { [weak self] in self?.settings ?? AppSettings() }
        connections.settings = { [weak self] in self?.settings ?? AppSettings() }
        connections.refresh()
        modelServers.onChecked = { [weak self] server, availability, now in
            guard let self else { return }
            perform(policy.modelServerChecked(server, availability, now: now))
        }

        if settings.notificationsEnabled { notifier.requestAuthorization() }
        refreshLaunchAtLogin()
        defaultEditorID = UserDefaults.standard.string(forKey: Editor.defaultsKey) ?? ""
        refreshEditors()

        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(5))
            }
        })
        modelServers.start()
        devServers.context = { [weak self] in self?.devServerContext }
        devServers.onSnapshot = { [weak self] snapshot in self?.cleanup.observe(snapshot) }
        devServers.start()
        cleanup.context = { [weak self] in self?.cleanupContext }
        cleanup.start()
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshClaudeLimits()
                try? await Task.sleep(for: .seconds(180))
            }
        })
    }

    // MARK: - Sessions

    func ingest(_ events: [AgentEvent]) {
        let now = Date()
        var changes: [StateChange] = []
        for event in events {
            activity.add(at: event.time)
            guard let change = board.apply(event) else { continue }
            changes.append(change)
            perform(policy.sessionChanged(change, project: project(of: change.session), now: now))
        }
        history.recordStateChanges(changes)
        releaseApprovals(PermissionApproval.answered(approvals, by: events))
        history.tail(Set(events.compactMap(\.transcriptPath)))
        let copilotSessions = Set(events.filter { $0.key.source == .copilotCLI && $0.fromHook }.map(\.key.id))
        if !copilotSessions.isEmpty {
            history.pollCopilot(sessions: copilotSessions)
        }
        publishSessions()
    }

    private func applyLiveModels() {
        if board.noteModels(history.liveModels) { publishSessions() }
    }

    private func applyLiveTitles() {
        if board.noteTitles(history.liveTitles) { publishSessions() }
    }

    private func applySubagents(_ activity: [SubagentActivity]) {
        if board.noteSubagents(activity) { publishSessions() }
    }

    private func publishSessions() {
        board.noteModels(history.liveModels)
        board.noteTitles(history.liveTitles)
        sessions = board.ordered
        history.track(sessions)
        resolveProjects()
        watchGit()
    }

    private func watchGit() {
        guard isLive else { return }
        var watch: [SessionKey: GitWatch] = [:]
        var stale: Set<String> = []
        for session in sessions {
            guard let cwd = session.cwd, !cwd.isEmpty else { continue }
            let entry = GitWatch(cwd: cwd, settled: session.turnEnded || session.state == .idle)
            watch[session.key] = entry
            let known = gitWatch[session.key]
            if known?.cwd != cwd || (entry.settled && known?.settled == false) { stale.insert(cwd) }
        }
        let kept = Set(watch.values.map(\.cwd))
        let dropped = Set(gitWatch.values.map(\.cwd)).subtracting(kept)
        gitWatch = watch
        for cwd in dropped { gitStats[cwd] = nil }
        guard !stale.isEmpty || !dropped.isEmpty else { return }
        let cache = gitCache
        Task {
            for cwd in dropped { await cache.forget(cwd) }
            for cwd in stale {
                let stat = await cache.refresh(cwd)
                if gitWatch.values.contains(where: { $0.cwd == cwd }) { gitStats[cwd] = stat }
            }
        }
    }

    func diffStat(for session: AgentSession) -> GitDiffStat? {
        session.cwd.flatMap { gitStats[$0] }
    }

    func contextWindow(for key: SessionKey) -> ContextWindow? {
        history.contextWindows[key]
    }

    func subagentCount(for session: AgentSession) -> Int {
        max(session.subagents.count, history.subagentCounts[session.key] ?? 0)
    }

    private func resolveProjects(replacing: Bool = false) {
        guard history.isReady else { return }
        var cwds = Set(sessions.compactMap(\.cwd).filter { !$0.isEmpty })
        if !replacing {
            cwds = cwds.subtracting(projectsByCwd.keys).subtracting(resolvingCwds).subtracting(unresolvedCwds)
        }
        guard !cwds.isEmpty else {
            if replacing { projectsByCwd = [:] }
            return
        }
        resolvingCwds.formUnion(cwds)
        let epoch = projectsEpoch
        Task {
            let found = await history.resolveProjects(Array(cwds))
            guard epoch == projectsEpoch else { return }
            resolvingCwds.subtract(cwds)
            guard let found else { return }
            unresolvedCwds.formUnion(cwds.subtracting(found.keys))
            if replacing {
                projectsByCwd = found
            } else if !found.isEmpty {
                projectsByCwd.merge(found) { _, new in new }
            }
        }
    }

    // The old grouping stays up until the new one is resolved, so the panel regroups without a per-folder flash.
    private func projectsEdited() {
        projectsEpoch += 1
        resolvingCwds = []
        unresolvedCwds = []
        resolveProjects(replacing: true)
    }

    func projectTitle(for session: AgentSession) -> String? {
        session.cwd.flatMap { projectsByCwd[$0]?.title } ?? session.project
    }

    func ledgerTotals(for key: SessionKey) -> LedgerTotals? {
        history.sessionTotals[key]
    }

    func openDashboard(_ page: DashboardPage? = nil) {
        dashboardOpener?(page)
    }

    func openSettings() {
        settingsOpener?()
    }

    func openPanel() {
        panelOpener?()
    }

    func togglePalette() {
        guard settings.paletteEnabled else { return }
        paletteToggler?()
    }

    func setPaletteEnabled(_ enabled: Bool) {
        var updated = settings
        updated.paletteEnabled = enabled
        apply(updated)
    }

    func setPaletteHotKey(_ combo: HotKeyCombo) {
        guard combo.isValid else { return }
        var updated = settings
        updated.paletteHotKey = combo
        apply(updated)
    }

    private func tick() {
        let now = Date()
        let sweep = board.sweep(now: now)
        for change in sweep.changes {
            perform(policy.sessionChanged(change, project: project(of: change.session), now: now))
        }
        history.recordStateChanges(sweep.changes)
        for session in sweep.dropped {
            perform(policy.sessionDismissed(session.key))
        }
        let dropped = Set(sweep.dropped.map(\.key))
        releaseApprovals(approvals.filter { dropped.contains($0.key) }.map(\.id))
        history.closeStateSpans(for: sweep.dropped.map(\.key))
        activity.advance(to: now)
        modelServers.advance(to: now)
        publishSessions()
        checkLimitedSessions(now: now)
        perform(updates.tick(now: now, notify: settings.notificationsEnabled && !policy.isQuiet(at: now)))
    }

    private func checkLimitedSessions(now: Date) {
        perform(policy.limitedSessionsChecked(sessions, limits: limitSamples,
                                              localModelPatterns: settings.localModelPatterns, now: now))
    }

    func dismiss(_ key: SessionKey) {
        releaseApprovals(approvals.filter { $0.key == key }.map(\.id))
        board.dismiss(key)
        perform(policy.sessionDismissed(key))
        history.closeStateSpans(for: [key])
        publishSessions()
    }

    // MARK: - Notifications

    private func project(of session: AgentSession) -> ProjectRef? {
        session.cwd.flatMap { projectsByCwd[$0] }
    }

    private func perform(_ actions: NotificationActions) {
        guard !actions.isEmpty else { return }
        notifier.withdraw(actions.withdraw)
        for request in actions.post {
            let approval = request.kind == .permission ? request.session.flatMap { approvals(for: $0).last } : nil
            notifier.post(request, approval: approval)
        }
    }

    // MARK: - Approvals

    func approvals(for key: SessionKey) -> [ApprovalRequest] {
        approvals.filter { $0.key == key }
    }

    func decide(_ id: String, _ decision: ApprovalDecision) {
        guard approvals.contains(where: { $0.id == id }) else { return }
        approvals.removeAll { $0.id == id }
        server.resolve(id, decision)
    }

    private func releaseApprovals(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        approvals.removeAll { ids.contains($0.id) }
        server.release(ids)
    }

    func open(_ target: NotificationTarget) {
        switch target {
        case .session(let key):
            history.openSession(key)
            openDashboard()
        case .limits:
            openDashboard(.limits)
        case .localModel:
            openDashboard(.localModel)
        case .update:
            if updates.pending == nil { openPanel() } else { updates.update() }
        }
    }

    var quietHoursNote: String? {
        guard settings.notificationsEnabled, policy.isQuiet(at: Date()) else { return nil }
        return "Quiet hours until \(Format.timeOfDay(minutes: settings.quietHoursEnd))"
    }

    func isMuted(_ root: String) -> Bool {
        settings.mutedProjectRoots.contains(root)
    }

    func toggleMute(_ root: String) {
        var updated = settings
        if let index = updated.mutedProjectRoots.firstIndex(of: root) {
            updated.mutedProjectRoots.remove(at: index)
        } else {
            updated.mutedProjectRoots.append(root)
        }
        apply(updated)
    }

    // MARK: - Dev servers

    private var devServerContext: DevServers.Context {
        let history = history
        let live = sessions.filter { $0.state != .ended }.map { session in
            DevServerClassifier.Session(key: session.key, cwd: session.cwd.flatMap { $0.isEmpty ? nil : $0 },
                                        reportedPID: session.reportedPID, reportedAt: session.pidReportedAt)
        }
        let resolve: DevServerMonitor.ProjectLookup = { cwds in await history.resolveProjects(cwds) ?? [:] }
        return DevServers.Context(hubPort: settings.port, sessions: live,
                                  resolveProjects: history.isReady ? resolve : nil)
    }

    // MARK: - Clean up

    private var cleanupContext: Cleanup.Context {
        let live = sessions.filter { $0.state != .ended }.compactMap(\.cwd).filter { !$0.isEmpty }
        return Cleanup.Context(activity: CleanupActivity(sessionDirectories: live,
                                                         devServerDirectories: devServers.servers.map(\.cwd)),
                               thresholds: CleanupRules.Thresholds(settings: settings))
    }

    func setCleanupIncludesNodeModules(_ included: Bool) {
        var updated = settings
        updated.cleanupIncludesNodeModules = included
        apply(updated)
        cleanup.refresh()
    }

    func session(_ key: SessionKey?) -> AgentSession? {
        key.flatMap { key in sessions.first { $0.key == key } }
    }

    // MARK: - Model servers

    func setPanelOnScreen(_ visible: Bool) {
        panelOnScreen = visible
        watchChanged(cameOnScreen: visible)
        if visible { connections.refresh() }
    }

    func setDashboardOnScreen(_ visible: Bool) {
        dashboardOnScreen = visible
        watchChanged(cameOnScreen: visible)
    }

    private func watchChanged(cameOnScreen: Bool) {
        devServers.setWatched(panelOnScreen || dashboardOnScreen)
        modelServers.setWatched(panelOnScreen || dashboardOnScreen)
        if cameOnScreen { modelServers.cameOnScreen() }
    }

    // MARK: - Plan limits

    func refreshClaudeLimits() async {
        guard settings.claudeLimitsEnabled, !isFetchingLimits else { return }
        isFetchingLimits = true
        defer { isFetchingLimits = false }
        var epoch = limitsEpoch
        await fetchClaudeLimits(epoch: epoch)
        while epoch != limitsEpoch, settings.claudeLimitsEnabled {
            epoch = limitsEpoch
            await fetchClaudeLimits(epoch: epoch)
        }
    }

    private func fetchClaudeLimits(epoch: Int) async {
        let fetched = Date()
        let limits: ClaudeLimits
        do {
            limits = try await limitsClient.fetch()
        } catch {
            guard epoch == limitsEpoch else { return }
            claudeLimitsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        guard epoch == limitsEpoch else { return }
        claudeLimits = limits
        claudeLimitsFetchedAt = fetched
        claudeLimitsError = nil
        // `previous` must come from this write: reading the latest samples afterwards returns this fetch itself.
        let previous = await history.recordLimits(limits, at: fetched)
        guard epoch == limitsEpoch else { return }
        perform(policy.limitsUpdated(limits.samples(at: fetched), previous: previous, now: Date()))
        checkLimitedSessions(now: Date())
    }

    private func codexLimitsRead(_ samples: [LimitSample], previous: [LimitKind: LimitSample]) {
        perform(policy.limitsUpdated(samples, previous: previous, now: Date()))
    }

    func toggleNotifications() {
        var updated = settings
        updated.notificationsEnabled.toggle()
        apply(updated)
    }

    func enableClaudeLimits() {
        var updated = settings
        updated.claudeLimitsEnabled = true
        apply(updated)
    }

    // MARK: - Settings

    func update(_ change: (inout AppSettings) -> Void) {
        var updated = settings
        change(&updated)
        apply(updated)
    }

    func apply(_ updated: AppSettings) {
        let old = settings
        guard updated != old else { return }
        settings = updated
        updated.save()
        policy.preferences = NotificationPreferences(settings: updated)
        history.setPlan(updated)
        hotKey.update(enabled: updated.paletteEnabled, combo: updated.paletteHotKey)
        if updated.port != old.port {
            server.start(port: UInt16(clamping: updated.port))
        }
        if updated.approveFromHoply != old.approveFromHoply {
            server.setHoldsApprovals(updated.approveFromHoply)
            if !updated.approveFromHoply { approvals = [] }
        }
        if updated.modelServers != old.modelServers {
            perform(policy.modelServersChanged(updated.modelServers))
            modelServers.settingsChanged(from: old, to: updated)
        }
        if updated.claudeLimitsEnabled && !old.claudeLimitsEnabled {
            Task { await refreshClaudeLimits() }
        }
        if !updated.claudeLimitsEnabled {
            if old.claudeLimitsEnabled { limitsEpoch += 1 }
            claudeLimits = nil
            claudeLimitsFetchedAt = nil
            claudeLimitsError = nil
        }
        if updated.notificationsEnabled && !old.notificationsEnabled {
            notifier.requestAuthorization()
        }
        if updated.port != old.port || updated.claudeConfigDir != old.claudeConfigDir
            || updated.copilotHome != old.copilotHome || updated.codexHome != old.codexHome {
            connections.settingsChanged()
        }
        if updated.claudeConfigDir != old.claudeConfigDir || updated.copilotHome != old.copilotHome
            || updated.codexHome != old.codexHome {
            unresolvedCwds = []
            history.reopen(LedgerConfiguration(settings: updated))
        } else if updated.localModelPatterns != old.localModelPatterns || updated.referenceModel != old.referenceModel
                    || updated.priceAliases != old.priceAliases {
            history.updatePricing(localModelPatterns: updated.localModelPatterns, referenceModel: updated.referenceModel,
                                  priceAliases: updated.priceAliases)
        }
    }

    // MARK: - Editors

    func refreshEditors() {
        guard isLive else { return }
        let found = Editor.installed()
        if found != editors { editors = found }
    }

    func setDefaultEditor(_ id: String) {
        defaultEditorID = id
        UserDefaults.standard.set(id, forKey: Editor.defaultsKey)
    }

    func openInEditor(_ path: String, editor: Editor? = nil) {
        guard let editor = editor ?? defaultEditor else { return }
        WorkspaceActions.open(path, in: editor)
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = isBundledApp && SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard isBundledApp else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastNote = "Launch at login: \(error.localizedDescription)"
        }
        refreshLaunchAtLogin()
    }

    func quit() {
        server.stop()
        NSApp.terminate(nil)
    }
}

extension AppModel {
    static func preview(now: Date = Date()) -> AppModel {
        let model = AppModel(live: false)
        model.settings.notificationsEnabled = false
        model.policy.preferences = NotificationPreferences(settings: model.settings)
        model.ingest(PreviewData.events(now: now))
        model.settings = PreviewData.settings
        model.activity = PreviewData.activity(now: now)
        model.modelServers.show(PreviewData.modelServerStates(now: now))
        model.claudeLimits = PreviewData.claudeLimits(now: now)
        model.claudeLimitsFetchedAt = now
        model.serverStatus = .listening(UInt16(clamping: PreviewData.settings.port))
        model.history.show(PreviewData.history(now: now))
        model.projectsByCwd = PreviewData.projectsByCwd
        model.gitStats = PreviewData.gitStats
        model.editors = PreviewData.editors
        model.hotKey.show(status: .registered(PreviewData.settings.paletteHotKey))
        model.devServers.show(PreviewData.devServers(now: now))
        model.cleanup.show(PreviewData.cleanupScan(now: now), orphans: PreviewData.cleanupOrphans(now: now),
                           log: PreviewData.cleanupLog(now: now))
        model.projectEdits.show(PreviewData.projectEdits(now: now))
        model.connections.show(statuses: PreviewData.connectionStatuses, notices: PreviewData.connectionNotices)
        model.updates.showPreview(enabled: true)
        return model
    }

    static func firstRunPreview() -> AppModel {
        let model = AppModel(live: false)
        model.serverStatus = .listening(UInt16(clamping: model.settings.port))
        model.connections.show(statuses: PreviewData.connectionsNone)
        return model
    }

    func showPreview(settings: AppSettings) {
        self.settings = settings
    }

    func showPreview(approvals: [ApprovalRequest], events: [AgentEvent]) {
        ingest(events)
        self.approvals = approvals
    }
}
