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

    var total: LedgerTotals { models.reduce(.zero) { $0 + $1.totals } }
}

struct ProjectsData: Equatable {
    var range: HistoryRange
    /// Largest spend first, Unassigned included (`project == nil`).
    var projects: [ProjectSummary]
}

/// The project the Projects page shows in detail; `project == nil` is Unassigned.
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
    /// The chart's samples, oldest first.
    var samples: [LimitSample]
    var projections: [LimitKind: LimitsProjection]
    /// Claude Code's ledger totals from each window's start until now.
    var windowSpend: [LimitKind: LedgerTotals]
    var copilot: CopilotAllowance
    /// Copilot CLI's totals over the allowance month (AIU, API-equivalent).
    var copilotMonth: LedgerTotals
}

struct LocalModelData: Equatable {
    var range: LocalModelRange
    /// The speed and KV cache charts' span.
    var interval: DateInterval
    var generation: [SampleBucket]
    var kvCache: [SampleBucket]
    var tokenDays: [ModelTokenDay]
    /// Local-model usage in the ledger by source; `apiEquivUSD` is what it saved vs the API.
    var saved: DailySpendSeries
    /// The end of the latest bucket with a reading, for "last seen" while the server is offline.
    var lastSeen: Date?

    var savedTotal: LedgerTotals { saved.points.reduce(.zero) { $0 + $1.totals } }
}

/// Everything the UI reads from the usage ledger: ingest progress, totals for the live sessions and today,
/// and the Dashboard pages. The panel and the Dashboard both read these ledger totals, so they always agree.
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

    static let pageSize = 50
    static let limitDayChoices = [7, 30]
    private static let pendingUsageLimit = 5_000

    @ObservationIgnored private var ledger: Ledger?
    @ObservationIgnored private var liveKeys: Set<SessionKey> = []
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
    @ObservationIgnored private var recordTask: Task<Void, Never>?
    @ObservationIgnored private var sampleTask: Task<Void, Never>?
    @ObservationIgnored private var localModelLoadedAt: Date?
    /// A session to select on the Sessions page whatever its range (a notification click).
    @ObservationIgnored private var requestedSession: SessionKey?
    /// The Copilot plan the Limits page measures against.
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
            let previous = stopping
            stopping = Task {
                await previous?.value
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
        if !pendingUsage.isEmpty {
            let held = pendingUsage
            pendingUsage = []
            record(held)
        }
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

    func track(_ keys: [SessionKey]) {
        let keys = Set(keys)
        guard keys != liveKeys else { return }
        let added = !keys.isSubset(of: liveKeys)
        liveKeys = keys
        if added { scheduleRefresh(after: .milliseconds(50)) }
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
    func record(_ usage: [UsageRecord]) {
        guard !usage.isEmpty else { return }
        guard let ledger else {
            if status == .opening {
                pendingUsage.append(contentsOf: usage.prefix(max(0, Self.pendingUsageLimit - pendingUsage.count)))
            }
            return
        }
        let previous = recordTask
        recordTask = Task {
            await previous?.value
            await ledger.record(usage)
        }
    }

    func pollCopilot() {
        guard let ledger else { return }
        Task { await ledger.pollCopilot() }
    }

    /// nil while no ledger is open, so the caller can ask again later.
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

    /// One successful model-server poll into the `samples` series. Dropped while no ledger is open: the Store
    /// re-seeds counter baselines from what it stored, so a missed poll costs nothing but its gauge readings.
    /// Writes are chained, because a counter reading that lands after a later one is skipped.
    /// Chained behind pending sample writes, so the old server's last reading still lands on its baseline.
    func resetModelCounters() {
        guard let ledger else { return }
        let previous = sampleTask
        sampleTask = Task {
            await previous?.value
            await ledger.resetModelCounters()
        }
    }

    func recordModelSamples(_ status: VLLMStatus) {
        guard let ledger else { return }
        let previous = sampleTask
        sampleTask = Task {
            await previous?.value
            do {
                try await ledger.recordModelSamples(status)
            } catch {
                note = "Recording model samples failed: \(Self.describe(error))"
                return
            }
            // The charts are per minute at best, so the visible page re-reads at most twice a minute.
            if isDashboardVisible, page == .localModel,
               Date().timeIntervalSince(localModelLoadedAt ?? .distantPast) >= 30 {
                reload(.localModel)
            }
        }
    }

    /// The model-server series since `since`, waiting for the ledger to open; nil when History is off.
    func recentModelSamples(since: Date) async -> [String: [SampleBucket]]? {
        await waitForOpen()
        guard let ledger else { return nil }
        return try? await ledger.recentModelSamples(since: since)
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

    func updatePricing(localModelPatterns: [String], referenceModel: String) {
        guard let ledger else { return }
        Task {
            do {
                try await ledger.updatePricing(localModelPatterns: localModelPatterns, referenceModel: referenceModel)
                note = nil
            } catch {
                note = "Pricing update failed: \(Self.describe(error))"
            }
            scheduleRefresh(after: .zero)
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
    }

    /// Shows one session on the Sessions page, selected even when it falls outside the page's range.
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

    func setProjectsRange(_ range: HistoryRange) {
        guard range != projectsRange else { return }
        projectsRange = range
        projectSessionsOffset = 0
        projectAutoSelect = true
        reload(.projects)
    }

    /// Shows a project's detail on the Projects page. `range` carries over the range of the figure the user
    /// clicked (Overview's 30 days, Spending's range), so the detail starts with the same numbers.
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
        guard let reader = ledger?.reader else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let now = Date()
        do {
            let totals = try await reader.sessionTotals(for: Array(liveKeys))
            let today = try await reader.todayBySource(now: now)
            guard generation == refreshGeneration else { return }
            if totals != sessionTotals { sessionTotals = totals }
            if today != self.today { self.today = today }
            refreshedDay = Calendar.current.startOfDay(for: now)
        } catch {
            note = "Reading history failed: \(Self.describe(error))"
        }
        if isDashboardVisible { await load(page) }
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
                                        models: try await reader.spendByModel(in: interval))
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
            case .localModel:
                let range = localModelRange
                let interval = range.interval(now: now)
                let generationRate = try await ledger.samples(ModelServerSeries.generationTokensPerSecond,
                                                              resolution: range.resolution, in: interval)
                let kvCache = try await ledger.samples(ModelServerSeries.kvCachePercent, resolution: range.resolution,
                                                       in: interval)
                let tokenDays = try await ledger.modelTokensPerDay(days: range.dailyDays, now: now)
                let saved = try await ledger.localModelSpend(days: range.dailyDays, split: .source, now: now)
                let lastSeen = try await lastModelReading(ledger, now: now)
                let data = LocalModelData(range: range, interval: interval, generation: generationRate,
                                          kvCache: kvCache, tokenDays: tokenDays, saved: saved, lastSeen: lastSeen)
                guard generation == pageGeneration[page] else { return }
                localModelLoadedAt = now
                if data != localModel { localModel = data }
            }
        } catch {
            note = "Reading history failed: \(Self.describe(error))"
        }
    }

    /// Every successful poll writes `model.running`, so its latest bucket is when the server last answered.
    /// The last day is read per minute; older stretches only exist hourly.
    private func lastModelReading(_ ledger: Ledger, now: Date) async throws -> Date? {
        let series = ModelServerSeries.running
        let recent = try await ledger.samples(series, in: DateInterval(start: now.addingTimeInterval(-86_400), end: now))
        var bucket = recent.last
        if bucket == nil {
            bucket = try await ledger.samples(series, resolution: 3_600,
                                              in: DateInterval(start: now.addingTimeInterval(-90 * 86_400), end: now)).last
        }
        return bucket.map { min($0.startDate.addingTimeInterval(TimeInterval($0.resolution)), now) }
    }

    /// "All time" charts start at the project's first usage, but never show fewer than 30 days.
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

/// Fixed ledger state for `--snapshot`; never touches the real database.
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
    var limits: LimitsData?
    var localModel: LocalModelData?
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
        self.page = page
    }

    func showProjectDetail(_ preview: HistoryPreview) {
        guard let detail = preview.projectDetail else { return }
        show(preview, page: .projects)
        openedProject = OpenedProject(project: detail.summary.project)
        projectDetail = detail
        projectsRange = detail.range
        selectedProjectSession = detail.sessions.sessions.first
    }
}
