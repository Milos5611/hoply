import AgentKit
import AgentSystem
import AppKit
import Observation

@Observable
final class ICloudLink {
    enum Status: Equatable {
        case off
        case unavailable
        case connecting
        case running
        case noAccount
        case restricted
        case storageFull(retryAt: Date)
        case limited(retryAt: Date)
        case offline(retryAt: Date)
        case failed(String, retryAt: Date)
        case removing
        case removeFailed(retryAt: Date)
    }

    static let withdrawPendingKey = "HoplyICloudWithdrawPending"
    private static let maxBackoff: TimeInterval = 300
    private static let accountRetry: TimeInterval = 600
    private static let storageRetry: TimeInterval = 900
    private static let coalesce: Duration = .milliseconds(250)

    private(set) var status: Status = .off
    private(set) var lastSync: Date?
    private(set) var isAvailable: Bool
    @ObservationIgnored weak var model: AppModel?

    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private var cloud: CloudLink?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var withdrawal: Task<Void, Never>?
    @ObservationIgnored private var napTask: Task<Void, Never>?
    @ObservationIgnored private var napInterruptible = false
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var needsPrepare = true
    @ObservationIgnored private var fetchRequested = false
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var opened: Set<String> = []
    @ObservationIgnored private var published: RemoteSnapshot?
    @ObservationIgnored private var publishedAt: Date?
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var handled: Set<String> = []
    @ObservationIgnored private var awaySetAt: Date?
    @ObservationIgnored private var applyingAnswer = false
    @ObservationIgnored private var deviceName: String?
    @ObservationIgnored private var accountObserver: (any NSObjectProtocol)?

    private struct AccountRestricted: Error {}

    init(live: Bool) {
        isLive = live
        isAvailable = live && CloudLink.isAvailable
    }

    func follow(_ enabled: Bool) {
        guard isLive, isAvailable else { return }
        if enabled, !isRunning {
            start()
        } else if !enabled, isRunning {
            stop()
        } else if !enabled, withdrawal == nil, UserDefaults.standard.bool(forKey: Self.withdrawPendingKey) {
            let cloud = link()
            status = .removing
            withdrawal = Task { [weak self] in await self?.withdraw(cloud) }
        }
    }

    func changed() {
        guard isRunning else { return }
        pending = true
        if napInterruptible { napTask?.cancel() }
    }

    func awayModeChanged() {
        if !applyingAnswer { awaySetAt = Date() }
        changed()
    }

    func receivedPush(_ userInfo: [String: Any]) {
        guard isRunning, CloudLink.isAnswerNotification(userInfo) else { return }
        fetchRequested = true
        changed()
    }

    private func link() -> CloudLink {
        if let cloud { return cloud }
        let made = CloudLink()
        cloud = made
        deviceName = CloudLink.deviceName
        return made
    }

    private func start() {
        isRunning = true
        let cloud = link()
        let previous = withdrawal
        previous?.cancel()
        withdrawal = nil
        UserDefaults.standard.removeObject(forKey: Self.withdrawPendingKey)
        needsPrepare = true
        fetchRequested = true
        failures = 0
        published = nil
        publishedAt = nil
        fetchedAt = nil
        // Away answers the phone wrote before this run started would undo the Mac's current setting.
        awaySetAt = Date()
        status = .connecting
        accountObserver = NotificationCenter.default.addObserver(forName: CloudLink.accountChanged, object: nil,
                                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.accountChanged() }
        }
        runner = Task { [weak self] in
            await previous?.value
            await self?.run(cloud)
        }
    }

    private func stop() {
        isRunning = false
        let cloud = link()
        let runner = runner
        runner?.cancel()
        self.runner = nil
        napTask?.cancel()
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
        accountObserver = nil
        NSApp.unregisterForRemoteNotifications()
        UserDefaults.standard.set(true, forKey: Self.withdrawPendingKey)
        status = .removing
        // The withdraw waits for the runner, so a save still in flight can't land after the records are removed.
        withdrawal = Task { [weak self] in
            await runner?.value
            await self?.withdraw(cloud)
        }
    }

    private func accountChanged() {
        guard isRunning else { return }
        needsPrepare = true
        pending = true
        napTask?.cancel()
    }

    private func run(_ cloud: CloudLink) async {
        while !Task.isCancelled {
            let wait: TimeInterval
            do {
                if needsPrepare { try await connect(cloud) }
                let talked = try await sync(cloud)
                guard !Task.isCancelled else { return }
                failures = 0
                if status != .running { status = .running }
                if talked { lastSync = Date() }
                wait = RemoteLinkPolicy.pollInterval(openRequests: opened.count)
                    - Date().timeIntervalSince(fetchedAt ?? .distantPast)
            } catch {
                guard !Task.isCancelled else { return }
                guard let delay = failed(error) else { return }
                wait = delay
            }
            guard !Task.isCancelled else { return }
            await nap(max(wait, 1))
        }
    }

    private func connect(_ cloud: CloudLink) async throws {
        status = .connecting
        switch try await cloud.accountStatus() {
        case .available: break
        case .noAccount, .temporarilyUnavailable: throw CloudLinkError.noAccount
        case .restricted: throw AccountRestricted()
        case .couldNotDetermine: throw CloudLinkError.network
        }
        try await cloud.prepare()
        let open = await cloud.openRequestIDs
        try Task.checkCancellation()
        opened = Set(open)
        published = nil
        publishedAt = nil
        needsPrepare = false
        NSApp.registerForRemoteNotifications()
    }

    private func sync(_ cloud: CloudLink) async throws -> Bool {
        guard let model else { return false }
        var talked = false
        let device = cloud.device
        let projects = model.projectsByCwd
        let requests = model.approvals.map {
            RemoteRequest.approval($0, session: model.session($0.key), projects: projects, device: device)
        } + model.replies.map {
            RemoteRequest.reply($0, session: model.session($0.key), projects: projects, device: device)
        }
        for request in requests where !opened.contains(request.id) && Self.held(by: model).contains(request.id) {
            try Task.checkCancellation()
            try await cloud.open(request)
            opened.insert(request.id)
            talked = true
        }
        for id in opened.subtracting(Self.held(by: model)) {
            try Task.checkCancellation()
            try await cloud.close(requestID: id)
            opened.remove(id)
            talked = true
        }
        let now = Date()
        let snapshot = snapshot(of: model, device: device, now: now)
        if RemoteLinkPolicy.shouldPublish(snapshot, last: published, at: publishedAt, now: now) {
            try Task.checkCancellation()
            try await cloud.publish(snapshot)
            published = snapshot
            publishedAt = now
            talked = true
        }
        let pollDue = Date().timeIntervalSince(fetchedAt ?? .distantPast)
            >= RemoteLinkPolicy.pollInterval(openRequests: opened.count)
        if fetchRequested || pollDue {
            try Task.checkCancellation()
            fetchRequested = false
            try await answer(cloud)
            fetchedAt = Date()
            talked = true
        }
        return talked
    }

    private static func held(by model: AppModel) -> Set<String> {
        Set(model.approvals.map(\.id) + model.replies.map(\.id))
    }

    private func snapshot(of model: AppModel, device: String, now: Date) -> RemoteSnapshot {
        let history = model.history
        let week = history.isReady ? history.week : nil
        // `today` is empty, not unknown, until the ledger's first refresh, which is also the one that sets `week`.
        let today = week == nil ? nil : history.today
        return RemoteSnapshot.build(device: device, deviceName: deviceName, away: model.settings.awayMode,
                                    sessions: model.sessions, projects: model.projectsByCwd,
                                    sessionTotals: history.sessionTotals, limitedUntil: model.grouping.limitedUntil,
                                    approvals: model.approvals, replies: model.replies, today: today, week: week,
                                    now: now)
    }

    private func answer(_ cloud: CloudLink) async throws {
        let answers = try await cloud.fetchAnswers()
        guard !Task.isCancelled, let model else { return }
        let resolution = RemoteAnswers.resolve(answers, approvals: model.approvals, replies: model.replies,
                                               device: cloud.device, handled: handled, awaySetAt: awaySetAt,
                                               now: Date())
        handled.formUnion(resolution.acknowledged)
        for action in resolution.actions {
            apply(action, to: model)
        }
        // Always, even with nothing to delete: it is what keeps the fetch's change token.
        try await cloud.acknowledge(resolution.acknowledged)
        handled.subtract(resolution.acknowledged)
    }

    private func apply(_ action: RemoteAction, to model: AppModel) {
        switch action {
        case .decide(let id, let decision):
            model.decide(id, decision)
        case .reply(let id, let text):
            model.reply(id, text: text)
        case .finish(let id):
            model.finishReply(id)
        case .setAway(let on):
            applyingAnswer = true
            model.setAwayMode(on)
            applyingAnswer = false
        }
    }

    private func failed(_ error: any Error) -> TimeInterval? {
        failures += 1
        let backoff = Self.backoff(after: failures)
        let now = Date()
        if error is AccountRestricted {
            status = .restricted
            needsPrepare = true
            return Self.accountRetry
        }
        switch CloudLinkError(error) {
        case .unavailable:
            status = .unavailable
            return nil
        case .noAccount:
            status = .noAccount
            needsPrepare = true
            return Self.accountRetry
        case .quotaExceeded:
            status = .storageFull(retryAt: now + Self.storageRetry)
            return Self.storageRetry
        case .limited(let retryAfter):
            let delay = max(retryAfter ?? backoff, 1)
            status = .limited(retryAt: now + delay)
            return delay
        case .network:
            status = .offline(retryAt: now + backoff)
            return backoff
        case .other(let message):
            status = .failed(message, retryAt: now + backoff)
            return backoff
        }
    }

    private static func backoff(after failures: Int) -> TimeInterval {
        min(5 * pow(2, Double(min(max(failures, 1), 10) - 1)), maxBackoff)
    }

    private func nap(_ seconds: TimeInterval) async {
        napInterruptible = status == .running
        if !(napInterruptible && pending) {
            let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(seconds)) }
            napTask = task
            await task.value
            napTask = nil
        }
        if pending, napInterruptible { try? await Task.sleep(for: Self.coalesce) }
        pending = false
    }

    private func withdraw(_ cloud: CloudLink) async {
        var failures = 0
        while !Task.isCancelled {
            do {
                try await cloud.withdraw()
                guard !Task.isCancelled else { return }
                UserDefaults.standard.removeObject(forKey: Self.withdrawPendingKey)
                status = .off
                lastSync = nil
                withdrawal = nil
                return
            } catch {
                guard !Task.isCancelled else { return }
                failures += 1
                let delay: TimeInterval
                switch CloudLinkError(error) {
                case .unavailable, .noAccount:
                    status = .off
                    withdrawal = nil
                    return
                case .limited(let retryAfter):
                    delay = max(retryAfter ?? 0, Self.backoff(after: failures))
                case .quotaExceeded, .network, .other:
                    delay = Self.backoff(after: failures)
                }
                status = .removeFailed(retryAt: Date() + delay)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }
}

extension ICloudLink {
    func show(available: Bool, status: Status = .off, lastSync: Date? = nil) {
        isAvailable = available
        self.status = status
        self.lastSync = lastSync
    }
}
