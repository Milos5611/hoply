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

    static let pageSize = 50

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
            }
        }
    }

    /// A different Claude config directory means a different set of transcripts and cursors. The new ledger
    /// opens only after the old ingest has stopped, so the two never write to the database at once.
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
        guard let reader = ledger?.reader else { return }
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
                let list = try await reader.sessions(in: sessionsRange.interval(now: now),
                                                     limit: Self.pageSize, offset: sessionsOffset)
                var selected = selectedSession
                if autoSelect {
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
                if list != sessionList { sessionList = list }
                if selected != selectedSession { selectedSession = selected }
            }
        } catch {
            note = "Reading history failed: \(Self.describe(error))"
        }
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
        self.page = page
    }
}
