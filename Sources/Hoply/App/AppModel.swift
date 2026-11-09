import AgentKit
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
    private(set) var claudeLimits: ClaudeLimits?
    private(set) var claudeLimitsError: String?
    private(set) var lastNote: String?
    private(set) var settings: AppSettings
    private(set) var launchAtLogin = false
    private(set) var activity = RollingSeries(bucketLength: 30, capacity: 20, now: Date())
    private(set) var throughput = RollingSeries(bucketLength: 30, capacity: 20, now: Date())
    var showingSettings = false

    @ObservationIgnored private var board = SessionBoard()
    @ObservationIgnored private let server = HubServer()
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private let limitsClient = ClaudeLimitsClient()
    @ObservationIgnored private var lastSnapshot: VLLMSnapshot?
    @ObservationIgnored private var loops: [Task<Void, Never>] = []

    var attentionCount: Int { sessions.filter { $0.state.needsAttention }.count }
    var workingCount: Int { sessions.filter { $0.state == .working }.count }
    var activeCount: Int { sessions.filter { $0.state != .ended }.count }
    var grouping: SessionGrouping { SessionGrouping(sessions: sessions) }
    var vllmOnline: Bool { vllm != nil && vllmError == nil }
    var liveTokens: Int { sessions.reduce(0) { $0 + $1.totalTokens } }
    var liveCost: Double { sessions.reduce(0) { $0 + $1.costUSD } }
    var tokensBySource: [(source: AgentSource, tokens: Double)] {
        AgentSource.allCases.compactMap { source in
            let tokens = sessions.filter { $0.key.source == source }.reduce(0) { $0 + $1.totalTokens }
            return tokens > 0 ? (source, Double(tokens)) : nil
        }
    }
    var isBundledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// `live: false` builds an inert model (no listener, no polling) for snapshots.
    init(live: Bool = true) {
        guard live else {
            settings = AppSettings()
            return
        }
        settings = AppSettings.load()

        server.onEvents = { [weak self] events in
            Task { @MainActor in self?.ingest(events) }
        }
        server.onStatus = { [weak self] status in
            Task { @MainActor in self?.serverStatus = status }
        }
        server.onNote = { [weak self] note in
            Task { @MainActor in self?.lastNote = note }
        }
        server.start(port: UInt16(clamping: settings.port))

        if settings.notificationsEnabled { notifier.requestAuthorization() }
        refreshLaunchAtLogin()

        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(5))
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollVLLM()
                try? await Task.sleep(for: .seconds(5))
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshClaudeLimits()
                try? await Task.sleep(for: .seconds(180))
            }
        })
    }

    // MARK: - Sessions

    func ingest(_ events: [AgentEvent]) {
        for event in events {
            activity.add(at: event.time)
            guard let change = board.apply(event) else { continue }
            if shouldNotify(change) { notifier.post(change.session) }
        }
        sessions = board.ordered
    }

    private func shouldNotify(_ change: StateChange) -> Bool {
        guard settings.notificationsEnabled, change.from != change.to else { return false }
        switch change.to {
        case .needsPermission:
            return true
        case .yourTurn:
            // Only after real work, so quick back-and-forth in a terminal you're watching stays quiet.
            return change.from == .working && change.previousDuration >= 30
        default:
            return false
        }
    }

    private func tick() {
        let now = Date()
        board.tick(now: now)
        activity.advance(to: now)
        throughput.advance(to: now)
        sessions = board.ordered
    }

    func dismiss(_ key: SessionKey) {
        board.dismiss(key)
        sessions = board.ordered
    }

    // MARK: - Local model (vLLM)

    func pollVLLM() async {
        let raw = settings.vllmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            vllm = nil
            vllmError = nil
            lastSnapshot = nil
            return
        }
        guard let base = URL(string: raw) else {
            vllmError = "Invalid URL"
            return
        }
        do {
            var request = URLRequest(url: base.appendingPathComponent("metrics"), timeoutInterval: 4)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let samples = PrometheusParser.parse(String(decoding: data, as: UTF8.self))
            guard VLLMSnapshot.engine(of: samples) != nil else {
                vllmError = "No vLLM or tensorfold metrics at /metrics"
                return
            }
            let snapshot = VLLMSnapshot.from(samples: samples, at: Date())
            let status = VLLMStatus.compute(previous: lastSnapshot, current: snapshot)
            vllm = status
            if let rate = status.generationTokensPerSecond { throughput.recordMax(rate, at: snapshot.takenAt) }
            lastSnapshot = snapshot
            vllmError = nil
        } catch {
            vllmError = "Offline"
            lastSnapshot = nil
        }
    }

    // MARK: - Claude plan limits

    func refreshClaudeLimits() async {
        guard settings.claudeLimitsEnabled else { return }
        do {
            claudeLimits = try await limitsClient.fetch()
            claudeLimitsError = nil
        } catch {
            claudeLimitsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
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
        if updated.port != old.port {
            server.start(port: UInt16(clamping: updated.port))
        }
        if updated.vllmBaseURL != old.vllmBaseURL {
            lastSnapshot = nil
            vllm = nil
            Task { await pollVLLM() }
        }
        if updated.claudeLimitsEnabled && !old.claudeLimitsEnabled {
            Task { await refreshClaudeLimits() }
        }
        if !updated.claudeLimitsEnabled {
            claudeLimits = nil
            claudeLimitsError = nil
        }
        if updated.notificationsEnabled && !old.notificationsEnabled {
            notifier.requestAuthorization()
        }
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
        model.ingest(PreviewData.events(now: now))
        model.settings = PreviewData.settings
        model.activity = PreviewData.activity(now: now)
        model.throughput = PreviewData.throughput(now: now)
        model.vllm = PreviewData.vllm(now: now)
        model.claudeLimits = PreviewData.claudeLimits(now: now)
        model.serverStatus = .listening(UInt16(clamping: PreviewData.settings.port))
        return model
    }
}
