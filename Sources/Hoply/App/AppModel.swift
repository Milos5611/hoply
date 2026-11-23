import AgentKit
import AgentSystem
import AppKit
import Foundation
import Observation
import os
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
    private(set) var editors: [Editor] = []
    private(set) var defaultEditorID = ""
    private(set) var approvals: [ApprovalRequest] = []
    private(set) var replies: [TurnReplyRequest] = []
    private(set) var sample: AppModel?
    private(set) var isSampleData = false
    var showingSettings = false
    let history = History()
    let modelServers: ModelServers
    let palette: Palette
    let hotKey: HotKey
    let projectEdits: ProjectEdits
    let connections: AgentConnections
    #if Sparkle
    let updates: Updates
    #endif
    let runningVersion: String?
    let iCloudLink: ICloudLink
    @ObservationIgnored var paletteToggler: (() -> Void)?
    @ObservationIgnored var dashboardOpener: ((DashboardPage?) -> Void)?
    @ObservationIgnored var panelOpener: (() -> Void)?
    @ObservationIgnored var settingsOpener: (() -> Void)?

    @ObservationIgnored private var board = SessionBoard()
    @ObservationIgnored private let server = HubServer()
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private weak var sampleHost: AppModel?
    @ObservationIgnored private var policy = NotificationPolicy()
    @ObservationIgnored private let limitsClient = ClaudeLimitsClient()
    @ObservationIgnored private let keepAwake = KeepAwake()
    @ObservationIgnored private let replyReader = OSAllocatedUnfairLock(initialState: CopilotLastMessageReader())
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var resolvingCwds: Set<String> = []
    @ObservationIgnored private var unresolvedCwds: Set<String> = []
    @ObservationIgnored private var projectsEpoch = 0
    @ObservationIgnored private var panelOnScreen = false
    @ObservationIgnored private var dashboardOnScreen = false
    @ObservationIgnored private var isFetchingLimits = false
    @ObservationIgnored private var limitsEpoch = 0
    @ObservationIgnored let isLive: Bool

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
    var shown: AppModel { sample ?? self }
    var sampleDataOffered: Bool {
        !isSampleData && sample == nil && sessions.isEmpty && history.isEmpty == true
            && !connections.statuses.values.contains(.connected)
    }
    var awayProblem: AwayProblem? {
        guard settings.awayMode else { return nil }
        return AwayProblem(statuses: connections.statuses)
    }

    init(live: Bool = true) {
        isLive = live
        notifier = Notifier(enabled: live)
        modelServers = ModelServers(history: history, live: live)
        palette = Palette(live: live)
        hotKey = HotKey(live: live)
        projectEdits = ProjectEdits(history: history)
        connections = AgentConnections(live: live)
        #if Sparkle
        updates = Updates(live: live)
        #endif
        // Preview models get none, so --snapshot PNGs (the site's screenshots) never show a version that goes stale.
        runningVersion = live ? AppVersion.short : nil
        iCloudLink = ICloudLink(live: live)
        guard live else {
            settings = AppSettings()
            palette.model = self
            iCloudLink.model = self
            modelServers.settings = { [weak self] in self?.settings ?? AppSettings() }
            connections.settings = { [weak self] in self?.settings ?? AppSettings() }
            return
        }
        settings = AppSettings.load()
        palette.model = self
        iCloudLink.model = self
        hotKey.onPress = { [weak self] in self?.togglePalette() }
        hotKey.update(enabled: settings.paletteEnabled, combo: settings.paletteHotKey)
        policy.preferences = NotificationPreferences(settings: settings)
        history.setPlan(settings)
        notifier.onOpen = { [weak self] target in self?.open(target) }
        notifier.onDecision = { [weak self] id, decision in self?.decide(id, decision) }
        notifier.onReply = { [weak self] id, text in self?.reply(id, text: text) }
        notifier.onFinishReply = { [weak self] id in self?.finishReply(id) }
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
            Task { @MainActor in
                self?.approvals.removeAll { $0.id == id }
                self?.iCloudLink.changed()
            }
        }
        setReplyReader(for: settings)
        let replyReader = replyReader
        // Same order as approvals: the turn-end banner its events would post must see the reply and stay quiet.
        server.onReply = { [weak self] reply, events in
            let reply = replyReader.withLock { $0 }.completing(reply)
            Task { @MainActor in
                self?.replies.append(reply)
                self?.ingest(events)
                self?.notifyReply(reply)
            }
        }
        server.onReplyClosed = { [weak self] id in
            Task { @MainActor in self?.dropReplies([id]) }
        }
        server.setHoldsApprovals(Self.holdsApprovals(settings))
        server.setHoldsReplies(settings.awayMode)
        followAwayMode()
        server.start(port: UInt16(clamping: settings.port))
        history.onLoaded = { [weak self] _ in self?.projectEdits.reload() }
        history.onOpened = { [weak self] in self?.iCloudLink.ledgerOpened() }
        history.setThisMacName(CloudLink.deviceName)
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
        iCloudLink.follow(settings.iCloudLink)
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
        releaseReplies(TurnReply.answered(replies, by: events))
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
        iCloudLink.changed()
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
        releaseReplies(replies.filter { dropped.contains($0.key) }.map(\.id))
        history.closeStateSpans(for: sweep.dropped.map(\.key))
        activity.advance(to: now)
        modelServers.advance(to: now)
        publishSessions()
        checkLimitedSessions(now: now)
        #if Sparkle
        perform(updates.tick(now: now, notify: settings.notificationsEnabled && !policy.isQuiet(at: now)))
        #endif
    }

    private func checkLimitedSessions(now: Date) {
        perform(policy.limitedSessionsChecked(sessions, limits: limitSamples,
                                              localModelPatterns: settings.localModelPatterns, now: now))
    }

    func dismiss(_ key: SessionKey) {
        releaseApprovals(approvals.filter { $0.key == key }.map(\.id))
        releaseReplies(replies.filter { $0.key == key }.map(\.id))
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
            if let key = request.session, request.kind == .yourTurn || request.cause == .input,
               replies.contains(where: { $0.key == key }) { continue }
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
        iCloudLink.changed()
    }

    private func releaseApprovals(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        approvals.removeAll { ids.contains($0.id) }
        server.release(ids)
    }

    // MARK: - Away mode

    func replies(for key: SessionKey) -> [TurnReplyRequest] {
        replies.filter { $0.key == key }
    }

    func reply(_ id: String, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, replies.contains(where: { $0.id == id }) else { return }
        dropReplies([id])
        server.answer(id, text: text)
    }

    func finishReply(_ id: String) {
        guard replies.contains(where: { $0.id == id }) else { return }
        dropReplies([id])
        server.answer(id, text: nil)
    }

    func setAwayMode(_ enabled: Bool) {
        update { $0.awayMode = enabled }
    }

    private func releaseReplies(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        dropReplies(ids)
        server.release(ids)
    }

    private func dropReplies(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        replies.removeAll { ids.contains($0.id) }
        notifier.withdraw(ids.map(Notifier.replyNotificationID))
        iCloudLink.changed()
    }

    private func notifyReply(_ reply: TurnReplyRequest) {
        guard replies.contains(where: { $0.id == reply.id }) else { return }
        let now = Date()
        let session = session(reply.key)
        let project = session.flatMap(project(of:))
        guard policy.preferences.enabled, !policy.isQuiet(at: now),
              !(session.map { policy.isMuted($0, project: project) } ?? false) else { return }
        let place = project?.title ?? session?.project
        let title = ["\(reply.key.source.displayName) finished", place].compactMap { $0 }.joined(separator: " · ")
        let body = reply.message.map { Format.tail($0, characters: 180, lines: 3) }
            ?? "Its turn is over. Reply to tell it what to do next."
        let threadID = project?.root ?? session?.cwd.flatMap { $0.isEmpty ? nil : $0 } ?? reply.key.source.rawValue
        notifier.withdraw([NotificationPolicy.notificationID(for: reply.key)])
        notifier.post(NotificationRequest(id: Notifier.replyNotificationID(reply.id), kind: .yourTurn,
                                          interruption: .active, title: title, body: body, threadID: threadID,
                                          session: reply.key),
                      reply: reply, subtitle: session?.title.flatMap { $0 == place ? nil : $0 })
    }

    private func setReplyReader(for settings: AppSettings) {
        let reader = CopilotLastMessageReader(settings: settings)
        replyReader.withLock { $0 = reader }
    }

    private static func holdsApprovals(_ settings: AppSettings) -> Bool {
        settings.approveFromHoply || settings.awayMode
    }

    private func followAwayMode() {
        guard isLive else { return }
        if !settings.awayMode {
            keepAwake.end()
        } else if !keepAwake.begin() {
            lastNote = "Away mode couldn't keep this Mac awake"
        }
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
            #if Sparkle
            if updates.pending == nil { openPanel() } else { updates.update() }
            #else
            openPanel()
            #endif
        case .panel:
            openPanel()
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
        // Sample data runs on a preview model: it must never save settings or restart the listener.
        guard isLive else { return }
        updated.save()
        policy.preferences = NotificationPreferences(settings: updated)
        history.setPlan(updated)
        hotKey.update(enabled: updated.paletteEnabled, combo: updated.paletteHotKey)
        if updated.port != old.port {
            server.start(port: UInt16(clamping: updated.port))
        }
        if Self.holdsApprovals(updated) != Self.holdsApprovals(old) {
            server.setHoldsApprovals(Self.holdsApprovals(updated))
            if !Self.holdsApprovals(updated) { approvals = [] }
            iCloudLink.changed()
        }
        if updated.awayMode != old.awayMode {
            server.setHoldsReplies(updated.awayMode)
            if !updated.awayMode { dropReplies(replies.map(\.id)) }
            followAwayMode()
            connections.refresh()
            iCloudLink.awayModeChanged()
        }
        if updated.iCloudLink != old.iCloudLink {
            iCloudLink.follow(updated.iCloudLink)
        }
        if updated.iPhoneLaunch != old.iPhoneLaunch || updated.iPhoneConversations != old.iPhoneConversations
            || updated.iCloudHistory != old.iCloudHistory {
            iCloudLink.changed()
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
        if updated.copilotHome != old.copilotHome {
            setReplyReader(for: updated)
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
        if isLive { UserDefaults.standard.set(id, forKey: Editor.defaultsKey) }
    }

    func openInEditor(_ path: String, editor: Editor? = nil) {
        guard let editor = editor ?? defaultEditor else { return }
        WorkspaceActions.open(path, in: editor)
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = isBundledApp && SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard isLive, isBundledApp else { return }
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

    func restartListener() {
        guard isLive else { return }
        server.start(port: UInt16(clamping: settings.port))
    }

    func quit() {
        if let sampleHost { return sampleHost.quit() }
        server.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Sample data

    func showSampleData() {
        guard isLive, sample == nil else { return }
        let preview = AppModel.preview()
        preview.isSampleData = true
        preview.sampleHost = self
        preview.settings.port = settings.port
        preview.serverStatus = serverStatus
        preview.paletteToggler = paletteToggler
        preview.dashboardOpener = dashboardOpener
        preview.panelOpener = panelOpener
        preview.settingsOpener = settingsOpener
        preview.history.select(history.page)
        showingSettings = false
        sample = preview
    }

    func hideSampleData() {
        if let sampleHost { return sampleHost.hideSampleData() }
        guard let sample else { return }
        showingSettings = sample.showingSettings
        self.sample = nil
    }

    func selectDashboardPage(_ page: DashboardPage) {
        history.select(page)
        sample?.history.select(page)
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
        model.editors = PreviewData.editors
        model.hotKey.show(status: .registered(PreviewData.settings.paletteHotKey))
        model.projectEdits.show(PreviewData.projectEdits(now: now))
        model.connections.show(statuses: PreviewData.connectionStatuses, notices: PreviewData.connectionNotices)
        #if Sparkle
        model.updates.showPreview(enabled: true)
        #endif
        return model
    }

    static func firstRunPreview() -> AppModel {
        let model = AppModel(live: false)
        model.serverStatus = .listening(UInt16(clamping: model.settings.port))
        model.connections.show(statuses: PreviewData.connectionsNone)
        return model
    }

    static func storeFirstRunPreview(portInUse: Bool = false) -> AppModel {
        let model = AppModel(live: false)
        let port = UInt16(clamping: model.settings.port)
        model.serverStatus = portInUse ? .portInUse(port) : .listening(port)
        model.connections.show(statuses: PreviewData.storeFirstRunStatuses)
        model.connections.show(access: PreviewData.storeFirstRunAccess, problems: PreviewData.storeFirstRunProblems)
        model.history.showEmptyLedger()
        return model
    }

    static func samplePreview(now: Date = Date()) -> AppModel {
        let model = preview(now: now)
        model.isSampleData = true
        return model
    }

    func showPreview(settings: AppSettings) {
        self.settings = settings
    }

    func showPreview(claudeLimits: ClaudeLimits?) {
        self.claudeLimits = claudeLimits
    }

    func showPreview(approvals: [ApprovalRequest], events: [AgentEvent]) {
        ingest(events)
        self.approvals = approvals
    }

    func showPreview(replies: [TurnReplyRequest], events: [AgentEvent]) {
        ingest(events)
        self.replies = replies
    }
}
