import AgentKit
import AgentSystem
import Foundation
import Observation

enum ModelServerHealth: Equatable {
    case paused
    case invalid
    case connecting
    case live
    case offline
    case signIn
    case setup
}

@MainActor
@Observable
final class ModelServers {
    struct State: Equatable {
        var status: ModelServerStatus?
        var error: RemoteError?
        var availability: ModelServerAvailability?
        var lastSeen: Date?
        var throughput: RollingSeries

        init(now: Date = Date()) {
            throughput = RollingSeries(bucketLength: 30, capacity: 20, now: now)
        }

        var online: ModelServerStatus? { availability == .online ? status : nil }
    }

    struct StoredSecrets: Equatable {
        var token = false
        var password = false
        var clientSecret = false
        var headers: Set<String> = []
    }

    enum Discovery: Equatable {
        case idle
        case searching
        case found([ModelServerCandidate])
    }

    static let fastPoll: Duration = .seconds(5)
    static let slowPoll: Duration = .seconds(30)
    static let selectionKey = "HoplyLocalModelServer"
    static let plainHTTP = PlainHTTPPolicy.main

    private(set) var states: [String: State] = [:]
    private(set) var discovery: Discovery = .idle
    private(set) var selectedID: String?
    var editor: ModelServerEditor?

    @ObservationIgnored var settings: (() -> AppSettings)?
    @ObservationIgnored var onChecked: ((ModelServer, ModelServerAvailability, Date) -> Void)?

    @ObservationIgnored private let history: History
    @ObservationIgnored private let client: ModelServerClient?
    @ObservationIgnored private var loops: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var polling: Set<String> = []
    @ObservationIgnored private var pollAgain: Set<String> = []
    @ObservationIgnored private var lastPoll: [String: Date] = [:]
    @ObservationIgnored private var offlineSince: [String: Date] = [:]
    @ObservationIgnored private var watched = false

    init(history: History, live: Bool = true) {
        self.history = history
        client = live ? ModelServerClient() : nil
        if live { selectedID = UserDefaults.standard.string(forKey: Self.selectionKey) }
    }

    private var servers: [ModelServer] { settings?().modelServers ?? [] }

    // MARK: - Reading

    func state(of id: String) -> State? { states[id] }

    func health(of server: ModelServer) -> ModelServerHealth {
        guard server.enabled else { return .paused }
        guard server.isConfigured else { return .invalid }
        guard let state = states[server.id], let availability = state.availability else { return .connecting }
        switch availability {
        case .online: return .live
        case .offline: return .offline
        case .blocked: return state.error?.isAuthFailure == true ? .signIn : .setup
        }
    }

    func selected(in servers: [ModelServer]) -> ModelServer? {
        servers.first { $0.id == selectedID } ?? servers.first(where: \.isActive) ?? servers.first
    }

    func select(_ id: String) {
        selectedID = id
        if client != nil { UserDefaults.standard.set(id, forKey: Self.selectionKey) }
        syncSelection()
    }

    private func syncSelection() {
        history.setLocalModelServer(selected(in: servers)?.id)
    }

    var combinedThroughput: [Double] {
        let series = servers.filter(\.isActive).compactMap { states[$0.id]?.throughput.values }
        guard var sum = series.first else { return [] }
        for values in series.dropFirst() {
            for index in sum.indices where index < values.count { sum[index] += values[index] }
        }
        return sum
    }

    // MARK: - Polling

    func start() {
        guard client != nil else { return }
        for server in servers where server.isActive { begin(server.id) }
        syncSelection()
    }

    func setWatched(_ watched: Bool) {
        self.watched = watched
    }

    func cameOnScreen() {
        let now = Date()
        for server in servers where server.isActive {
            let id = server.id
            let elapsed = now.timeIntervalSince(lastPoll[id] ?? .distantPast)
            if elapsed >= 4 {
                pollNow(id)
            } else if !polling.contains(id) {
                // The loop may be inside its 30 s wait: restart it so the next poll comes 5 s after the last one.
                startLoop(id, after: Self.fastPoll - .seconds(max(elapsed, 0)))
            }
        }
    }

    func advance(to now: Date) {
        for (id, state) in states {
            var series = state.throughput
            series.advance(to: now)
            if series != state.throughput { states[id]?.throughput = series }
        }
    }

    func settingsChanged(from old: AppSettings, to new: AppSettings) {
        guard let client else { return }
        let before = Dictionary(old.modelServers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(new.modelServers.map(\.id))
        for server in new.modelServers {
            let id = server.id
            let previous = before[id]
            let reconnected = previous.map { !$0.hasSameConnection(as: server) } ?? false
            if reconnected { history.resetModelCounters(server: id) }
            switch (previous?.isActive ?? false, server.isActive) {
            case (false, true): begin(id)
            case (true, false): end(id)
            case (true, true) where reconnected: restart(id, with: State())
            default: break
            }
        }
        for id in before.keys where !kept.contains(id) {
            end(id)
            Task { try? await client.deleteSecrets(for: id) }
        }
        syncSelection()
    }

    func refresh(_ id: String) {
        guard client != nil, servers.first(where: { $0.id == id })?.isActive == true else { return }
        var fresh = State()
        if let series = states[id]?.throughput { fresh.throughput = series }
        restart(id, with: fresh)
    }

    private func restart(_ id: String, with state: State) {
        states[id] = state
        offlineSince[id] = nil
        pollNow(id)
    }

    private func begin(_ id: String) {
        states[id] = State()
        offlineSince[id] = nil
        lastPoll[id] = nil
        seed(id)
        pollNow(id)
    }

    private func end(_ id: String) {
        states[id] = nil
        offlineSince[id] = nil
        lastPoll[id] = nil
        // A poll in flight ends the loop by itself: its result is dropped and the server is no longer active.
        guard !polling.contains(id) else { return }
        loops[id]?.cancel()
        loops[id] = nil
    }

    // A running poll is never cancelled (that would read as offline); the loop polls again right after it.
    private func pollNow(_ id: String) {
        if polling.contains(id) {
            pollAgain.insert(id)
        } else {
            startLoop(id)
        }
    }

    private func startLoop(_ id: String, after first: Duration = .zero) {
        loops[id]?.cancel()
        loops[id] = Task { [weak self] in
            if first > .zero { try? await Task.sleep(for: first) }
            while !Task.isCancelled {
                await self?.poll(id)
                guard let delay = self?.nextDelay(id) else { return }
                if delay > .zero { try? await Task.sleep(for: delay) }
            }
        }
    }

    private func nextDelay(_ id: String) -> Duration? {
        guard servers.first(where: { $0.id == id })?.isActive == true else {
            pollAgain.remove(id)
            return nil
        }
        if pollAgain.remove(id) != nil { return .zero }
        if watched { return Self.fastPoll }
        // The offline alert counts from the first failed poll; confirming the outage at the fast pace keeps it
        // firing two minutes after that miss instead of up to 30 s later, and shows a recovery sooner.
        if let since = offlineSince[id], Date().timeIntervalSince(since) < NotificationPolicy.offlineAlertAfter + 10 {
            return Self.fastPoll
        }
        return Self.slowPoll
    }

    private func poll(_ id: String) async {
        guard let client, let server = servers.first(where: { $0.id == id }), server.isActive else { return }
        polling.insert(id)
        let poll = await client.poll(server)
        polling.remove(id)
        // The connection changed during the poll: `settingsChanged` asked for another one, and this answer says
        // nothing about the new server.
        guard let poll, let current = servers.first(where: { $0.id == id }), poll.isCurrent(for: current) else { return }
        let now = Date()
        lastPoll[id] = now
        var state = states[id] ?? State(now: now)
        state.availability = poll.availability
        switch poll.result {
        case .success(let status):
            state.status = status
            state.error = nil
            state.lastSeen = status.snapshot.takenAt
            if let rate = status.generationTokensPerSecond {
                state.throughput.recordMax(rate, at: status.snapshot.takenAt)
            }
            history.recordModelSamples(status, server: id)
        case .failure(let error):
            state.error = error
        }
        if state != states[id] { states[id] = state }
        offlineSince[id] = poll.availability == .offline ? (offlineSince[id] ?? now) : nil
        onChecked?(current, poll.availability, now)
    }

    private func seed(_ id: String) {
        Task {
            let now = Date()
            guard let series = states[id]?.throughput else { return }
            let span = series.bucketLength * Double(series.values.count)
            guard let recent = await history.recentModelSamples(server: id, since: now.addingTimeInterval(-span)),
                  var throughput = states[id]?.throughput else { return }
            for bucket in recent[ModelServerSeries.generationTokensPerSecond] ?? [] {
                guard let peak = bucket.max else { continue }
                for offset in stride(from: 0, to: TimeInterval(bucket.resolution), by: throughput.bucketLength) {
                    let time = bucket.startDate.addingTimeInterval(offset)
                    if time <= now { throughput.recordMax(peak, at: time) }
                }
            }
            states[id]?.throughput = throughput
        }
    }

    // MARK: - Secrets, test and discovery

    func storedSecrets(for id: String) async -> StoredSecrets {
        guard let client, let secrets = try? await client.secrets(for: id) else { return StoredSecrets() }
        return StoredSecrets(token: !Self.blank(secrets.token), password: !(secrets.password ?? "").isEmpty,
                             clientSecret: !Self.blank(secrets.clientSecret),
                             headers: Set(secrets.headerValues.filter { !Self.blank($0.value) }.keys.map { $0.lowercased() }))
    }

    func probe(_ server: ModelServer, typed: ModelServerSecrets) async -> ModelServerProbe? {
        guard let client else { return nil }
        let stored = (try? await client.secrets(for: server.id)) ?? ModelServerSecrets()
        return await client.probe(server, secrets: Self.merged(stored, typed, for: server))
    }

    @discardableResult
    func save(_ server: ModelServer, typed: ModelServerSecrets) async throws -> Bool {
        guard let client else { return false }
        let stored = try await client.secrets(for: server.id)
        let merged = Self.merged(stored, typed, for: server)
        guard merged != stored else { return false }
        try await client.saveSecrets(merged, for: server)
        return true
    }

    // An empty field means "keep what the Keychain has".
    private static func merged(_ stored: ModelServerSecrets, _ typed: ModelServerSecrets,
                               for server: ModelServer) -> ModelServerSecrets {
        var result = stored
        if !blank(typed.token) { result.token = typed.token }
        if let password = typed.password, !password.isEmpty { result.password = password }
        if !blank(typed.clientSecret) { result.clientSecret = typed.clientSecret }
        for (name, value) in typed.headerValues where !blank(value) {
            for key in result.headerValues.keys where key.lowercased() == name.lowercased() {
                result.headerValues[key] = nil
            }
            result.headerValues[name] = value
        }
        return result.pruned(for: server.auth)
    }

    private static func blank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    func discover() {
        guard let client, discovery != .searching, let settings = settings?() else { return }
        discovery = .searching
        Task {
            let found = await client.discover(hubPort: settings.port, configured: settings.modelServers)
            discovery = .found(found)
        }
    }

    func clearDiscovery() {
        if discovery != .searching { discovery = .idle }
    }
}

extension ModelServers {
    func show(_ states: [String: State], selected: String? = nil, discovery: Discovery = .idle,
              editor: ModelServerEditor? = nil) {
        self.states = states
        selectedID = selected
        self.discovery = discovery
        self.editor = editor
    }
}
