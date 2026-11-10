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
    private(set) var vllm: VLLMStatus?
    private(set) var vllmError: String?
    private(set) var vllmLastSeen: Date?
    private(set) var claudeLimits: ClaudeLimits?
    private(set) var claudeLimitsFetchedAt: Date?
    private(set) var claudeLimitsError: String?
    private(set) var lastNote: String?
    private(set) var settings: AppSettings
    private(set) var launchAtLogin = false
    private(set) var activity = RollingSeries(bucketLength: 30, capacity: 20, now: Date())
    private(set) var throughput = RollingSeries(bucketLength: 30, capacity: 20, now: Date())
    private(set) var projectsByCwd: [String: ProjectRef] = [:]
    private(set) var gitStats: [String: GitDiffStat] = [:]
    private(set) var editors: [Editor] = []
    private(set) var defaultEditorID = ""
    var showingSettings = false
    let history = History()
    @ObservationIgnored var dashboardOpener: ((DashboardPage?) -> Void)?
    @ObservationIgnored var panelOpener: (() -> Void)?
    @ObservationIgnored var settingsOpener: (() -> Void)?

    @ObservationIgnored private var board = SessionBoard()
    @ObservationIgnored private let server = HubServer()
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var policy = NotificationPolicy()
    @ObservationIgnored private let limitsClient = ClaudeLimitsClient()
    @ObservationIgnored private var lastSnapshot: VLLMSnapshot?
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var resolvingCwds: Set<String> = []
    @ObservationIgnored private var unresolvedCwds: Set<String> = []
    @ObservationIgnored private var modelLoop: Task<Void, Never>?
    @ObservationIgnored private var isPollingModel = false
    @ObservationIgnored private var pollModelAgain = false
    @ObservationIgnored private var lastModelPoll: Date?
    @ObservationIgnored private var modelOfflineSince: Date?
    @ObservationIgnored private var panelOnScreen = false
    @ObservationIgnored private var dashboardOnScreen = false
    @ObservationIgnored private var modelServerEpoch = 0
    @ObservationIgnored private var isFetchingLimits = false
    @ObservationIgnored private var limitsEpoch = 0
    @ObservationIgnored private let gitCache = GitStatCache()
    @ObservationIgnored private var gitWatch: [SessionKey: GitWatch] = [:]
    @ObservationIgnored private let isLive: Bool

    private struct GitWatch: Equatable {
        var cwd: String
        var settled: Bool
    }

    static let fastModelPoll: Duration = .seconds(5)
    static let slowModelPoll: Duration = .seconds(30)

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
        guard let claudeLimits, let claudeLimitsFetchedAt else { return [] }
        return claudeLimits.samples(at: claudeLimitsFetchedAt)
    }
    var defaultEditor: Editor? {
        editors.first { $0.id == defaultEditorID } ?? editors.first
    }
    var vllmOnline: Bool { vllm != nil && vllmError == nil }
    var isBundledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    init(live: Bool = true) {
        isLive = live
        guard live else {
            settings = AppSettings()
            return
        }
        settings = AppSettings.load()
        policy.preferences = NotificationPreferences(settings: settings)
        history.setPlan(settings)
        notifier.onOpen = { [weak self] target in self?.open(target) }
        notifier.activate()

        server.onEvents = { [weak self] events in
            Task { @MainActor in self?.ingest(events) }
        }
        server.onUsage = { [weak self] usage in
            Task { @MainActor in self?.history.record(usage) }
        }
        server.onStatus = { [weak self] status in
            Task { @MainActor in self?.serverStatus = status }
        }
        server.onNote = { [weak self] note in
            Task { @MainActor in self?.lastNote = note }
        }
        server.start(port: UInt16(clamping: settings.port))
        history.open(LedgerConfiguration(settings: settings))
        Task { [weak self] in await self?.seedThroughput() }

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
        startModelLoop()
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
        for event in events {
            activity.add(at: event.time)
            guard let change = board.apply(event) else { continue }
            perform(policy.sessionChanged(change, project: project(of: change.session), now: now))
        }
        history.tail(Set(events.compactMap(\.transcriptPath)))
        if events.contains(where: { $0.key.source == .copilotCLI && $0.fromHook }) {
            history.pollCopilot()
        }
        publishSessions()
    }

    private func publishSessions() {
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

    private func resolveProjects() {
        guard history.isReady else { return }
        let cwds = Set(sessions.compactMap(\.cwd).filter { !$0.isEmpty })
            .subtracting(projectsByCwd.keys).subtracting(resolvingCwds).subtracting(unresolvedCwds)
        guard !cwds.isEmpty else { return }
        resolvingCwds.formUnion(cwds)
        Task {
            let found = await history.resolveProjects(Array(cwds))
            resolvingCwds.subtract(cwds)
            guard let found else { return }
            unresolvedCwds.formUnion(cwds.subtracting(found.keys))
            if !found.isEmpty { projectsByCwd.merge(found) { _, new in new } }
        }
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

    private func tick() {
        let now = Date()
        let sweep = board.sweep(now: now)
        for change in sweep.changes {
            perform(policy.sessionChanged(change, project: project(of: change.session), now: now))
        }
        for session in sweep.dropped {
            perform(policy.sessionDismissed(session.key))
        }
        activity.advance(to: now)
        throughput.advance(to: now)
        publishSessions()
        checkLimitedSessions(now: now)
    }

    private func checkLimitedSessions(now: Date) {
        perform(policy.limitedSessionsChecked(sessions, limits: limitSamples,
                                              localModelPatterns: settings.localModelPatterns, now: now))
    }

    func dismiss(_ key: SessionKey) {
        board.dismiss(key)
        perform(policy.sessionDismissed(key))
        publishSessions()
    }

    // MARK: - Notifications

    private func project(of session: AgentSession) -> ProjectRef? {
        session.cwd.flatMap { projectsByCwd[$0] }
    }

    private func perform(_ actions: NotificationActions) {
        guard !actions.isEmpty else { return }
        notifier.withdraw(actions.withdraw)
        for request in actions.post { notifier.post(request) }
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

    // MARK: - Local model (vLLM)

    func setPanelOnScreen(_ visible: Bool) {
        panelOnScreen = visible
        if visible { modelServerWatched() }
    }

    func setDashboardOnScreen(_ visible: Bool) {
        dashboardOnScreen = visible
        if visible { modelServerWatched() }
    }

    private func modelServerWatched() {
        let elapsed = Date().timeIntervalSince(lastModelPoll ?? .distantPast)
        if elapsed >= 4 {
            pollModelServerNow()
        } else if !isPollingModel {
            // The loop may be inside its 30 s wait: restart it so the next poll comes 5 s after the last one.
            // A running poll picks the fast pace by itself when it ends.
            startModelLoop(after: Self.fastModelPoll - .seconds(max(elapsed, 0)))
        }
    }

    /// Restarts the sleeping loop so the poll happens now. A poll already running is never cancelled (that
    /// would read as offline); the loop polls again right after it instead.
    private func pollModelServerNow() {
        if isPollingModel {
            pollModelAgain = true
        } else {
            startModelLoop()
        }
    }

    private func startModelLoop(after first: Duration = .zero) {
        modelLoop?.cancel()
        modelLoop = Task { [weak self] in
            if first > .zero { try? await Task.sleep(for: first) }
            while !Task.isCancelled {
                await self?.pollVLLM()
                guard let delay = self?.nextModelPollDelay() else { return }
                if delay > .zero { try? await Task.sleep(for: delay) }
            }
        }
    }

    private func nextModelPollDelay() -> Duration {
        if pollModelAgain {
            pollModelAgain = false
            return .zero
        }
        if panelOnScreen || dashboardOnScreen { return Self.fastModelPoll }
        // The offline alert counts from the first failed poll; confirming the outage at the fast pace keeps it
        // firing two minutes after that miss instead of up to 30 s later, and shows a recovery sooner.
        if let since = modelOfflineSince,
           Date().timeIntervalSince(since) < NotificationPolicy.offlineAlertAfter + 10 {
            return Self.fastModelPoll
        }
        return Self.slowModelPoll
    }

    func pollVLLM() async {
        isPollingModel = true
        let current = await fetchVLLM()
        isPollingModel = false
        // The URL changed during the poll: `apply` asked for another one, and this answer says nothing about
        // the new server.
        guard current else { return }
        let now = Date()
        lastModelPoll = now
        let configured = !settings.vllmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        modelOfflineSince = configured && !vllmOnline ? (modelOfflineSince ?? now) : nil
        perform(policy.localModelChecked(server: settings.vllmBaseURL, name: settings.vllmName, online: vllmOnline,
                                         now: now))
    }

    private func seedThroughput() async {
        let now = Date()
        let span = throughput.bucketLength * Double(throughput.values.count)
        guard let recent = await history.recentModelSamples(since: now.addingTimeInterval(-span)) else { return }
        for bucket in recent[ModelServerSeries.generationTokensPerSecond] ?? [] {
            guard let peak = bucket.max else { continue }
            for offset in stride(from: 0, to: TimeInterval(bucket.resolution), by: throughput.bucketLength) {
                let time = bucket.startDate.addingTimeInterval(offset)
                if time <= now { throughput.recordMax(peak, at: time) }
            }
        }
    }

    private func fetchVLLM() async -> Bool {
        let epoch = modelServerEpoch
        let raw = settings.vllmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            vllm = nil
            vllmError = nil
            lastSnapshot = nil
            vllmLastSeen = nil
            return true
        }
        guard let base = URL(string: raw) else {
            vllmError = "Invalid URL"
            return true
        }
        var request = URLRequest(url: base.appendingPathComponent("metrics"), timeoutInterval: 4)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let answer = try? await URLSession.shared.data(for: request)
        guard epoch == modelServerEpoch else { return false }
        guard let (data, response) = answer, (response as? HTTPURLResponse)?.statusCode == 200 else {
            vllmError = "Offline"
            lastSnapshot = nil
            return true
        }
        let samples = PrometheusParser.parse(String(decoding: data, as: UTF8.self))
        guard VLLMSnapshot.engine(of: samples) != nil else {
            vllmError = "No vLLM or tensorfold metrics at /metrics"
            return true
        }
        let snapshot = VLLMSnapshot.from(samples: samples, at: Date())
        let status = VLLMStatus.compute(previous: lastSnapshot, current: snapshot)
        vllm = status
        if let rate = status.generationTokensPerSecond { throughput.recordMax(rate, at: snapshot.takenAt) }
        lastSnapshot = snapshot
        vllmError = nil
        vllmLastSeen = snapshot.takenAt
        history.recordModelSamples(status)
        return true
    }

    // MARK: - Claude plan limits

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

    func apply(_ updated: AppSettings) {
        let old = settings
        guard updated != old else { return }
        settings = updated
        updated.save()
        policy.preferences = NotificationPreferences(settings: updated)
        history.setPlan(updated)
        if updated.port != old.port {
            server.start(port: UInt16(clamping: updated.port))
        }
        if updated.vllmBaseURL != old.vllmBaseURL {
            modelServerEpoch += 1
            lastSnapshot = nil
            vllm = nil
            vllmError = nil
            vllmLastSeen = nil
            modelOfflineSince = nil
            history.resetModelCounters()
            pollModelServerNow()
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
        if updated.claudeConfigDir != old.claudeConfigDir || updated.copilotHome != old.copilotHome {
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
        model.throughput = PreviewData.throughput(now: now)
        model.vllm = PreviewData.vllm(now: now)
        model.claudeLimits = PreviewData.claudeLimits(now: now)
        model.claudeLimitsFetchedAt = now
        model.vllmLastSeen = now
        model.serverStatus = .listening(UInt16(clamping: PreviewData.settings.port))
        model.history.show(PreviewData.history(now: now))
        model.projectsByCwd = PreviewData.projectsByCwd
        model.gitStats = PreviewData.gitStats
        model.editors = PreviewData.editors
        return model
    }

    func showPreview(settings: AppSettings) {
        self.settings = settings
    }

    func showPreview(vllm: VLLMStatus?, error: String?, lastSeen: Date?) {
        self.vllm = vllm
        vllmError = error
        vllmLastSeen = lastSeen
    }
}
