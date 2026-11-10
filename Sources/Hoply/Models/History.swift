import AgentKit
import AgentSystem
import Foundation
import Observation

struct OverviewData: Equatable {
    var totals: SpendOverview
    var daily: DailySpendSeries
    var projects: [SpendSlice]
    var models: [SpendSlice]
}

struct SpendingData: Equatable {
    var range: HistoryRange
    var split: SpendSeriesSplit
    var daily: DailySpendSeries
    var projects: [SpendSlice]
    var models: [SpendSlice]
    var efficiency: [ModelEfficiency] = []

    var total: LedgerTotals { models.reduce(.zero) { $0 + $1.totals } }
}

struct SessionInsight: Equatable {
    var context: ContextWindow?
    var subagents: [SubagentSummary] = []
    var spans: [StateSpan] = []
}

struct ProjectsData: Equatable {
    var range: HistoryRange
    var projects: [ProjectSummary]
}

struct OpenedProject: Equatable {
    var project: ProjectRef?

    var filter: ProjectFilter { project.map { .project($0.id) } ?? .unassigned }
}

struct ProjectDetailData: Equatable {
    var range: HistoryRange
    var summary: ProjectSummary
    var daily: DailySpendSeries
    var sessions: SessionPage
}

struct LimitsData: Equatable {
    var days: Int
    var samples: [LimitSample]
    var projections: [LimitKind: LimitsProjection]
    var windowSpend: [LimitKind: LedgerTotals]
    var copilot: CopilotAllowance
    var copilotMonth: LedgerTotals
}

struct LocalModelData: Equatable {
    var serverID: String?
    var range: LocalModelRange
    var interval: DateInterval
    var generation: [SampleBucket]
    var kvCache: [SampleBucket]
    var memory: [SampleBucket] = []
    var tokenDays: [ModelTokenDay]
    var saved: DailySpendSeries
    var lastSeen: Date?

    var savedTotal: LedgerTotals { saved.points.reduce(.zero) { $0 + $1.totals } }
}

@MainActor
@Observable
final class History {
    enum Status: Equatable {
        case off
        case opening
        case ready
        case unavailable(String)
    }

    private(set) var status: Status = .off
    private(set) var progress = IngestProgress()
    private(set) var sessionTotals: [SessionKey: LedgerTotals] = [:]
    private(set) var today: [AgentSource: LedgerTotals] = [:]
    private(set) var contextWindows: [SessionKey: ContextWindow] = [:]
    private(set) var subagentCounts: [SessionKey: Int] = [:]
    private(set) var insights: [SessionKey: SessionInsight] = [:]
    private(set) var unpricedModels: [UnpricedModel] = []
    private(set) var pricedModels: [String] = []
    private(set) var note: String?

    private(set) var page: DashboardPage = .overview
    private(set) var isDashboardVisible = false
    private(set) var overview: OverviewData?
    private(set) var spending: SpendingData?
    private(set) var spendingRange: HistoryRange = .month
    private(set) var spendingSplit: SpendSeriesSplit = .model
    private(set) var sessionList: SessionPage?
    private(set) var sessionsRange: HistoryRange = .week
    private(set) var sessionsOffset = 0
    private(set) var selectedSession: SessionSummary?
    private(set) var projectList: ProjectsData?
    private(set) var projectsRange: HistoryRange = .month
    private(set) var openedProject: OpenedProject?
    private(set) var projectDetail: ProjectDetailData?
    private(set) var projectSessionsOffset = 0
    private(set) var selectedProjectSession: SessionSummary?
    private(set) var limits: LimitsData?
    private(set) var limitsDays = 7
    private(set) var localModel: LocalModelData?
    private(set) var localModelRange: LocalModelRange = .day
    private(set) var localModelServerID: String?

    static let pageSize = 50
    static let limitDayChoices = [7, 30]
    private static let pendingUsageLimit = 5_000

    @ObservationIgnored private(set) var ledger: Ledger?
    @ObservationIgnored private var liveSessions: [AgentSession] = []
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var stopping: Task<Void, Never>?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var ingestTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var openGeneration = 0
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var pageGeneration: [DashboardPage: Int] = [:]
    @ObservationIgnored private var refreshedDay: Date?
    @ObservationIgnored private var autoSelect = true
    @ObservationIgnored private var projectAutoSelect = true
    @ObservationIgnored private var pendingUsage: [UsageRecord] = []
    @ObservationIgnored private var pendingPrompts: [PromptRecord] = []
    @ObservationIgnored private var recordTask: Task<Void, Never>?
    @ObservationIgnored private var spanTask: Task<Void, Never>?
    @ObservationIgnored private var isQuitting = false
    @ObservationIgnored var onLoaded: ((DashboardPage) -> Void)?
    @ObservationIgnored private var sampleTask: Task<Void, Never>?
    // Counter resets asked for per server, and how many a later sample write has settled. A Store opened in
    // between re-seeds its baselines from the old connection's buckets, so an unsettled reset is repeated on it.
    @ObservationIgnored private var counterResets: [String: Int] = [:]
    @ObservationIgnored private var settledCounterResets: [String: Int] = [:]
    @ObservationIgnored private var localModelLoadedAt: Date?
    @ObservationIgnored private var requestedSession: SessionKey?
    @ObservationIgnored private var plan = AppSettings()

    var todayTotal: LedgerTotals { today.values.reduce(.zero, +) }
    var isReady: Bool { status == .ready }
    var unavailableReason: String? {
        if case .unavailable(let reason) = status { return reason }
        return nil
    }

    // MARK: - Lifecycle

    func open(_ configuration: LedgerConfiguration) {
        status = .opening
        openGeneration += 1
        let generation = openGeneration
        let stopping = stopping
        openTask = Task { [weak self] in
            await stopping?.value
            do {
                let ledger = try await Ledger.open(configuration)
                guard let self, generation == self.openGeneration else { return }
                attach(ledger)
            } catch {
                guard let self, generation == self.openGeneration else { return }
                status = .unavailable("History is off: \(Self.describe(error))")
                pendingUsage = []
                pendingPrompts = []
            }
        }
    }

    /// A different Claude config or Copilot home means different files and cursors. The new ledger opens
    /// only after the old ingest has stopped, so the two never write to the database at once.
    func reopen(_ configuration: LedgerConfiguration) {
        openTask?.cancel()
        consumer?.cancel()
        ingestTask?.cancel()
        if let old = ledger {
            let previous = stopping, spans = spanTask
            spanTask = nil
            stopping = Task {
                await previous?.value
                await spans?.value
                try? await old.closeAllStateSpans()
                await old.ingest.stop()
            }
        }
        ledger = nil
        progress = IngestProgress()
        open(configuration)
    }

    private func attach(_ ledger: Ledger) {
        self.ledger = ledger
        status = .ready
        let updates = ledger.ingest.updates
        consumer = Task { [weak self] in
            for await update in updates {
                self?.receive(update)
            }
        }
        ingestTask = Task { await ledger.ingest.start() }
        for (id, asked) in counterResets where settledCounterResets[id, default: 0] < asked {
            resetCounters(on: ledger, server: id)
        }
        if !pendingUsage.isEmpty || !pendingPrompts.isEmpty {
            let held = pendingUsage, prompts = pendingPrompts
            pendingUsage = []
            pendingPrompts = []
            record(held, prompts: prompts)
        }
        let sessions = liveSessions
        writeSpans(on: ledger, touching: Set(sessions.map(\.key))) { try await ledger.trackStateSpans(of: sessions) }
        scheduleRefresh(after: .zero)
    }

    private func receive(_ update: IngestUpdate) {
        if progress != update.progress { progress = update.progress }
        let day = Calendar.current.startOfDay(for: Date())
        if !update.changedSessions.isEmpty || day != refreshedDay {
            scheduleRefresh()
        }
    }

    // MARK: - Requests from the app

    func track(_ sessions: [AgentSession]) {
        let known = Set(liveSessions.map(\.key))
        liveSessions = sessions
        if sessions.contains(where: { !known.contains($0.key) }) { scheduleRefresh(after: .milliseconds(50)) }
    }

    func tail(_ paths: Set<String>) {
        guard let ingest = ledger?.ingest, !paths.isEmpty else { return }
        Task {
            for path in paths { await ingest.tailTranscript(atPath: path) }
        }
    }

    /// Telemetry usage from `HubServer.onUsage`. OTLP can arrive while the ledger is still opening, so a
    /// bounded backlog waits for it. Batches are recorded in arrival order, because a record without a cwd
    /// takes its session's cwd from earlier records.
    func record(_ usage: [UsageRecord], prompts: [PromptRecord] = []) {
        guard !usage.isEmpty || !prompts.isEmpty else { return }
        guard let ledger else {
            if status == .opening {
                pendingUsage.append(contentsOf: usage.prefix(max(0, Self.pendingUsageLimit - pendingUsage.count)))
                pendingPrompts.append(contentsOf: prompts.prefix(max(0, Self.pendingUsageLimit - pendingPrompts.count)))
            }
            return
        }
        let previous = recordTask
        recordTask = Task {
            await previous?.value
            await ledger.record(usage, prompts: prompts)
        }
    }

    func recordStateChanges(_ changes: [StateChange]) {
        guard let ledger, !changes.isEmpty else { return }
        writeSpans(on: ledger, touching: Set(changes.map(\.session.key))) { try await ledger.recordStateChanges(changes) }
    }

    func closeStateSpans(for keys: [SessionKey]) {
        guard let ledger, !keys.isEmpty else { return }
        let time = Date()
        writeSpans(on: ledger, touching: Set(keys)) { try await ledger.closeStateSpans(for: keys, at: time) }
    }

    // Chained: a span is closed by the change that follows it, so the writes must land in the order they happened.
    private func writeSpans(on ledger: Ledger, touching keys: Set<SessionKey>, _ write: @escaping () async throws -> Void) {
        guard !isQuitting else { return }
        let previous = spanTask
        spanTask = Task {
            await previous?.value
            do {
                try await write()
            } catch {
                note = "Recording session states failed: \(Self.describe(error))"
                return
            }
            if isDashboardVisible, !keys.isDisjoint(with: shownSessions) { await refreshInsights() }
        }
    }

    func closeStateSpans(within limit: Duration) async {
        guard let ledger, !isQuitting else { return }
        let pending = spanTask
        isQuitting = true
        let (finished, signal) = AsyncStream<Void>.makeStream()
        Task {
            await pending?.value
            try? await ledger.closeAllStateSpans()
            signal.yield()
        }
        Task {
            try? await Task.sleep(for: limit)
            signal.yield()
        }
        for await _ in finished { break }
    }

    func ledgerEdited() {
        scheduleRefresh(after: .zero)
    }

    func pollCopilot() {
        guard let ledger else { return }
        Task { await ledger.pollCopilot() }
    }

    func resolveProjects(_ cwds: [String]) async -> [String: ProjectRef]? {
        guard let ledger else { return nil }
        return await ledger.resolveProjects(cwds)
    }

    /// Stores a Claude limits fetch and returns each window's last sample from before it: the `previous` that
    /// `NotificationPolicy.limitsUpdated` needs. A fetch at launch can return before the ledger opens; it waits,
    /// so it is compared with what an earlier run stored and a restart doesn't repeat an alert. nil when History
    /// is off or the write failed.
    func recordLimits(_ limits: ClaudeLimits, at time: Date) async -> [LimitKind: LimitSample]? {
        await waitForOpen()
        guard let ledger else { return nil }
        do {
            let previous = try await ledger.recordLimits(limits, at: time)
            if isDashboardVisible, page == .limits { reload(.limits) }
            return previous
        } catch {
            note = "Recording limits failed: \(Self.describe(error))"
            return nil
        }
    }

    // Chained behind pending sample writes, so the old connection's last reading still lands on its baseline.
    func resetModelCounters(server id: String) {
        counterResets[id, default: 0] += 1
        if let ledger { resetCounters(on: ledger, server: id) }
    }

    private func resetCounters(on ledger: Ledger, server id: String) {
        let previous = sampleTask
        sampleTask = Task {
            await previous?.value
            await ledger.resetModelCounters(server: id)
        }
    }

    // Writes are chained: a counter reading that lands after a later one is skipped.
    func recordModelSamples(_ status: ModelServerStatus, server id: String) {
        guard let ledger else { return }
        let previous = sampleTask
        let resets = counterResets[id, default: 0]
        sampleTask = Task {
            await previous?.value
            do {
                try await ledger.recordModelSamples(status, server: id)
            } catch {
                note = "Recording model samples failed: \(Self.describe(error))"
                return
            }
            settledCounterResets[id] = max(settledCounterResets[id, default: 0], resets)
            if isDashboardVisible, page == .localModel, id == localModelServerID,
               Date().timeIntervalSince(localModelLoadedAt ?? .distantPast) >= 30 {
                reload(.localModel)
            }
        }
    }

    func recentModelSamples(server id: String, since: Date) async -> [String: [SampleBucket]]? {
        await waitForOpen()
        guard let ledger else { return nil }
        return try? await ledger.recentModelSamples(server: id, since: since)
    }

    private func waitForOpen() async {
        while status == .opening, let task = openTask {
            await task.value
            if task == openTask, status == .opening { break }
        }
    }

    func setPlan(_ settings: AppSettings) {
        guard settings.copilotMonthlyAllowance != plan.copilotMonthlyAllowance
            || settings.copilotUSDPerPremiumRequest != plan.copilotUSDPerPremiumRequest else { return }
        plan = settings
        if isDashboardVisible, page == .limits { reload(.limits) }
    }

    func reindex() {
        guard let ingest = ledger?.ingest else { return }
        Task { await ingest.reindex() }
    }

    func updatePricing(localModelPatterns: [String], referenceModel: String, priceAliases: [String: String]) {
        guard let ledger else { return }
        Task {
            do {
                try await ledger.updatePricing(localModelPatterns: localModelPatterns, referenceModel: referenceModel,
                                               priceAliases: priceAliases)
                note = nil
            } catch {
                note = "Pricing update failed: \(Self.describe(error))"
            }
            scheduleRefresh(after: .zero)
            loadPricing()
        }
    }

    func loadPricing() {
        guard let ledger else { return }
        Task {
            let priced = await ledger.pricedModels()
            guard let unpriced = try? await ledger.unpricedModels(), ledger.store === self.ledger?.store else { return }
            if priced != pricedModels { pricedModels = priced }
            if unpriced != unpricedModels { unpricedModels = unpriced }
        }
    }

    // MARK: - Dashboard

    func setDashboardVisible(_ visible: Bool) {
        isDashboardVisible = visible
        if visible { reload(page) }
    }

    func select(_ page: DashboardPage) {
        guard page != self.page else { return }
        self.page = page
        if isDashboardVisible { reload(page) }
    }

    func setSpending(range: HistoryRange? = nil, split: SpendSeriesSplit? = nil) {
        if let range { spendingRange = range }
        if let split { spendingSplit = split }
        reload(.spending)
    }

    func setSessionsRange(_ range: HistoryRange) {
        guard range != sessionsRange else { return }
        sessionsRange = range
        sessionsOffset = 0
        autoSelect = true
        reload(.sessions)
    }

    func showSessionsPage(offset: Int) {
        sessionsOffset = max(0, offset)
        autoSelect = true
        reload(.sessions)
    }

    func selectSession(id: SessionSummary.ID?) {
        selectedSession = id.flatMap { id in sessionList?.sessions.first { $0.id == id } }
        loadInsights()
    }

    func openSession(_ key: SessionKey) {
        requestedSession = key
        sessionsOffset = 0
        autoSelect = false
        page = .sessions
        if isDashboardVisible { reload(.sessions) }
    }

    func setLimitsDays(_ days: Int) {
        guard days != limitsDays else { return }
        limitsDays = days
        reload(.limits)
    }

    func setLocalModelRange(_ range: LocalModelRange) {
        guard range != localModelRange else { return }
        localModelRange = range
        reload(.localModel)
    }

    func setLocalModelServer(_ id: String?) {
        guard id != localModelServerID else { return }
        localModelServerID = id
        if isDashboardVisible { reload(.localModel) }
    }

    func setProjectsRange(_ range: HistoryRange) {
        guard range != projectsRange else { return }
        projectsRange = range
        projectSessionsOffset = 0
        projectAutoSelect = true
        reload(.projects)
    }

    func openProject(_ project: ProjectRef?, range: HistoryRange? = nil) {
        let opened = OpenedProject(project: project)
        if opened != openedProject {
            openedProject = opened
            projectDetail = nil
            selectedProjectSession = nil
        }
        if let range { projectsRange = range }
        projectSessionsOffset = 0
        projectAutoSelect = true
        page = .projects
        if isDashboardVisible { reload(.projects) }
    }

    func closeProject() {
        openedProject = nil
        projectDetail = nil
        selectedProjectSession = nil
        reload(.projects)
    }

    func showProjectSessionsPage(offset: Int) {
        projectSessionsOffset = max(0, offset)
        projectAutoSelect = true
        reload(.projects)
    }

    func selectProjectSession(id: SessionSummary.ID?) {
        selectedProjectSession = id.flatMap { id in projectDetail?.sessions.sessions.first { $0.id == id } }
        loadInsights()
    }

    private func loadInsights() {
        Task { await refreshInsights() }
    }

    private var shownSessions: Set<SessionKey> {
        Set([selectedSession?.key, selectedProjectSession?.key].compactMap { $0 })
    }

    private func refreshInsights() async {
        guard let ledger else { return }
        let keys = shownSessions
        var loaded: [SessionKey: SessionInsight] = [:]
        do {
            let calls = try await ledger.lastMainCalls(for: Array(keys))
            for key in keys {
                let live = liveSessions.first { $0.key == key }?.model
                loaded[key] = SessionInsight(context: calls[key].flatMap { ContextWindow(lastCall: $0, liveModel: live) },
                                             subagents: try await ledger.subagents(of: key),
                                             spans: try await ledger.stateSpans(of: key))
            }
        } catch {
            note = "Reading history failed: \(Self.describe(error))"
            return
        }
        guard keys == shownSessions else { return }
        if loaded != insights { insights = loaded }
    }

    // MARK: - Refresh

    /// Backfill reports about four times a second; a one-second window keeps the panel from re-querying
    /// on each of them, while a hook-triggered tail outside backfill still shows within a few hundred ms.
    private func scheduleRefresh(after delay: Duration? = nil) {
        guard refreshTask == nil else { return }
        let delay = delay ?? (progress.isBackfilling ? .seconds(1) : .milliseconds(150))
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.refresh()
        }
    }

    private func refresh() async {
        refreshTask = nil
        guard let ledger else { return }
        let reader = ledger.reader
        refreshGeneration += 1
        let generation = refreshGeneration
        let now = Date()
        do {
            let sessions = liveSessions
            let keys = sessions.map(\.key)
            let totals = try await reader.sessionTotals(for: keys)
            let today = try await reader.todayBySource(now: now)
            let windows = try await ledger.contextWindows(for: sessions)
            let subagents = try await ledger.subagentCounts(for: keys)
            guard generation == refreshGeneration else { return }
            if totals != sessionTotals { sessionTotals = totals }
            if today != self.today { self.today = today }
            if windows != contextWindows { contextWindows = windows }
            if subagents != subagentCounts { subagentCounts = subagents }
            refreshedDay = Calendar.current.startOfDay(for: now)
        } catch {
            note = "Reading history failed: \(Self.describe(error))"
        }
        if isDashboardVisible {
            await load(page)
            await refreshInsights()
        }
    }

    private func reload(_ page: DashboardPage) {
        Task { await load(page) }
    }

    private func load(_ page: DashboardPage) async {
        guard let ledger else { return }
        let reader = ledger.reader
        let generation = (pageGeneration[page] ?? 0) + 1
        pageGeneration[page] = generation
        let now = Date()
        do {
            switch page {
            case .overview:
                let month = StoreReader.days(30, endingAt: now)
                let data = OverviewData(totals: try await reader.overview(now: now),
                                        daily: try await reader.dailySpend(days: 30, split: .source, now: now),
                                        projects: Array(try await reader.spendByProject(in: month).prefix(5)),
                                        models: Array(try await reader.spendByModel(in: month).prefix(5)))
                guard generation == pageGeneration[page] else { return }
                if data != overview { overview = data }
            case .spending:
                let range = spendingRange, split = spendingSplit
                let interval = range.interval(now: now)
                let data = SpendingData(range: range, split: split,
                                        daily: try await reader.dailySpend(days: range.days ?? 30, split: split, now: now),
                                        projects: try await reader.spendByProject(in: interval),
                                        models: try await reader.spendByModel(in: interval),
                                        efficiency: try await ledger.modelEfficiency(in: interval))
                guard generation == pageGeneration[page] else { return }
                if data != spending { spending = data }
            case .sessions:
                let requested = requestedSession
                let list = try await reader.sessions(in: sessionsRange.interval(now: now),
                                                     limit: Self.pageSize, offset: sessionsOffset)
                var selected = selectedSession
                if let requested {
                    if let found = list.sessions.first(where: { $0.key == requested }) {
                        selected = found
                    } else {
                        selected = try await reader.session(requested) ?? selected ?? list.sessions.first
                    }
                } else if autoSelect {
                    selected = list.sessions.first
                } else if let key = selected?.key {
                    if let fresh = list.sessions.first(where: { $0.key == key }) {
                        selected = fresh
                    } else {
                        selected = try await reader.session(key)
                    }
                }
                guard generation == pageGeneration[page] else { return }
                autoSelect = false
                if requested != nil, requested == requestedSession { requestedSession = nil }
                if list != sessionList { sessionList = list }
                if selected != selectedSession { selectedSession = selected }
                await refreshInsights()
            case .projects:
                let range = projectsRange, opened = openedProject
                let interval = range.interval(now: now)
                let projects = try await reader.projects(in: interval, topModels: 8)
                var detail: ProjectDetailData?
                var selected = selectedProjectSession
                if let opened {
                    let summary = projects.first { $0.filter == opened.filter } ?? ProjectSummary(project: opened.project)
                    let days = range.days ?? Self.dayCount(since: summary.firstActive, now: now)
                    let sessions = try await reader.sessions(in: interval, project: opened.filter,
                                                             limit: Self.pageSize, offset: projectSessionsOffset)
                    detail = ProjectDetailData(
                        range: range, summary: summary,
                        daily: try await reader.dailySpend(days: days, split: .model, project: opened.filter, now: now),
                        sessions: sessions)
                    if projectAutoSelect {
                        selected = sessions.sessions.first
                    } else if let key = selected?.key {
                        if let fresh = sessions.sessions.first(where: { $0.key == key }) {
                            selected = fresh
                        } else {
                            selected = try await reader.session(key)
                        }
                    }
                }
                guard generation == pageGeneration[page] else { return }
                let list = ProjectsData(range: range, projects: projects)
                if list != projectList { projectList = list }
                if let opened, opened == openedProject {
                    projectAutoSelect = false
                    if detail != projectDetail { projectDetail = detail }
                    if selected != selectedProjectSession { selectedProjectSession = selected }
                    await refreshInsights()
                }
            case .limits:
                let days = limitsDays, plan = self.plan
                let samples = try await ledger.limitHistory(days: days, now: now, bucket: days > 7 ? 3_600 : 600)
                let projections = try await ledger.limitProjections(now: now)
                var spend: [LimitKind: LedgerTotals] = [:]
                for (kind, projection) in projections {
                    guard let start = projection.windowStart, start < now else { continue }
                    let end = min(projection.resetsAt ?? now, now)
                    spend[kind] = try await reader.totalsBySource(in: DateInterval(start: start, end: max(end, start)))[
                        .claudeCode] ?? .zero
                }
                let copilot = try await ledger.copilotAllowance(settings: plan, now: now)
                let month = try await reader.totalsBySource(in: copilot.month)[.copilotCLI] ?? .zero
                let data = LimitsData(days: days, samples: samples, projections: projections, windowSpend: spend,
                                      copilot: copilot, copilotMonth: month)
                guard generation == pageGeneration[page] else { return }
                if data != limits { limits = data }
            case .devServers, .cleanUp:
                break
            case .localModel:
                let range = localModelRange, server = localModelServerID
                let interval = range.interval(now: now)
                var data = LocalModelData(serverID: server, range: range, interval: interval, generation: [], kvCache: [],
                                          tokenDays: [],
                                          saved: try await ledger.localModelSpend(days: range.dailyDays, split: .source,
                                                                                  now: now))
                if let server {
                    func series(_ name: String) async throws -> [SampleBucket] {
                        try await ledger.modelSamples(name, server: server, resolution: range.resolution, in: interval)
                    }
                    data.generation = try await series(ModelServerSeries.generationTokensPerSecond)
                    data.kvCache = try await series(ModelServerSeries.kvCachePercent)
                    data.memory = try await series(ModelServerSeries.memoryBytes)
                    data.tokenDays = try await ledger.modelTokensPerDay(server: server, days: range.dailyDays, now: now)
                    data.lastSeen = try await ledger.modelServerLastSeen(server: server, now: now)
                }
                guard generation == pageGeneration[page] else { return }
                localModelLoadedAt = now
                if data != localModel { localModel = data }
            }
        } catch {
            note = "Reading history failed: \(Self.describe(error))"
            return
        }
        if page == .projects || page == .sessions { onLoaded?(page) }
    }

    private static func dayCount(since first: Date?, now: Date) -> Int {
        guard let first else { return 30 }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: first),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        return min(max(days + 1, 30), 3_650)
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

struct HistoryPreview {
    var progress: IngestProgress
    var sessionTotals: [SessionKey: LedgerTotals]
    var today: [AgentSource: LedgerTotals]
    var overview: OverviewData
    var spending: SpendingData
    var sessions: SessionPage
    var selectedSession: SessionSummary?
    var projects: ProjectsData
    var projectDetail: ProjectDetailData?
    var unassignedDetail: ProjectDetailData?
    var limits: LimitsData?
    var localModel: LocalModelData?
    var contextWindows: [SessionKey: ContextWindow] = [:]
    var subagentCounts: [SessionKey: Int] = [:]
    var insights: [SessionKey: SessionInsight] = [:]
    var unpricedModels: [UnpricedModel] = []
    var pricedModels: [String] = []
}

extension History {
    func show(_ preview: HistoryPreview, page: DashboardPage = .overview) {
        status = .ready
        progress = preview.progress
        sessionTotals = preview.sessionTotals
        today = preview.today
        overview = preview.overview
        spending = preview.spending
        spendingRange = preview.spending.range
        spendingSplit = preview.spending.split
        sessionList = preview.sessions
        selectedSession = preview.selectedSession
        projectList = preview.projects
        projectsRange = preview.projects.range
        openedProject = nil
        projectDetail = nil
        selectedProjectSession = nil
        limits = preview.limits
        limitsDays = preview.limits?.days ?? 7
        localModel = preview.localModel
        localModelRange = preview.localModel?.range ?? .day
        localModelServerID = preview.localModel?.serverID
        contextWindows = preview.contextWindows
        subagentCounts = preview.subagentCounts
        insights = preview.insights
        unpricedModels = preview.unpricedModels
        pricedModels = preview.pricedModels
        self.page = page
    }

    func showProjectDetail(_ preview: HistoryPreview, unassigned: Bool = false) {
        guard let detail = unassigned ? preview.unassignedDetail : preview.projectDetail else { return }
        show(preview, page: .projects)
        openedProject = OpenedProject(project: detail.summary.project)
        projectDetail = detail
        projectsRange = detail.range
        selectedProjectSession = detail.sessions.sessions.first
    }
}
