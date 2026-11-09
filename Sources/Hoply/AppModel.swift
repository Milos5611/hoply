import AgentKit
import AppKit
import Foundation
import ServiceManagement

struct AppSettings: Codable, Equatable {
    var port: Int = 4318
    var vllmBaseURL: String = ""
    var vllmName: String = ""
    var claudeLimitsEnabled: Bool = false
    var notificationsEnabled: Bool = true

    private static let defaultsKey = "HoplySettings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var serverStatus: HubServer.Status = .stopped
    @Published private(set) var vllm: VLLMStatus?
    @Published private(set) var vllmError: String?
    @Published private(set) var claudeLimits: ClaudeLimits?
    @Published private(set) var claudeLimitsError: String?
    @Published private(set) var lastNote: String?
    @Published private(set) var settings: AppSettings
    @Published var showingSettings = false

    private var board = SessionBoard()
    private let server = HubServer()
    private let notifier = Notifier()
    private let limitsClient = ClaudeLimitsClient()
    private var lastSnapshot: VLLMSnapshot?
    private var loops: [Task<Void, Never>] = []

    var attentionCount: Int { sessions.filter { $0.state.needsAttention }.count }
    var workingCount: Int { sessions.filter { $0.state == .working }.count }
    var isBundledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    init() {
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

        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollVLLM()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshClaudeLimits()
                try? await Task.sleep(nanoseconds: 180_000_000_000)
            }
        })
    }

    // MARK: - Sessions

    func ingest(_ events: [AgentEvent]) {
        for event in events {
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
        board.tick(now: Date())
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
            guard samples.contains(where: { $0.name.hasPrefix("vllm:") }) else {
                vllmError = "No vLLM metrics at /metrics"
                return
            }
            let snapshot = VLLMSnapshot.from(samples: samples, at: Date())
            vllm = VLLMStatus.compute(previous: lastSnapshot, current: snapshot)
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

    var launchAtLogin: Bool {
        isBundledApp && SMAppService.mainApp.status == .enabled
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
        objectWillChange.send()
    }

    func quit() {
        server.stop()
        NSApp.terminate(nil)
    }
}
