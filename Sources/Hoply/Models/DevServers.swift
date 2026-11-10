import AgentKit
import AgentSystem
import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class DevServers {
    struct Context {
        var hubPort: Int
        var sessions: [DevServerClassifier.Session]
        var resolveProjects: DevServerMonitor.ProjectLookup?
    }

    enum StopState: Equatable {
        case confirming
        case stopping
        case failed(String)
    }

    struct Notice: Equatable {
        var text: String
        var isError: Bool
    }

    static let watchedInterval: Duration = .seconds(10)
    static let backgroundInterval: Duration = .seconds(60)
    static let graceSeconds = 5

    private(set) var scan: DevServerScan?
    private(set) var lastScan: Date?
    private(set) var isScanning = false
    private(set) var stops: [String: StopState] = [:]
    private(set) var notice: Notice?
    @ObservationIgnored var context: (() -> Context?)?
    @ObservationIgnored var onSnapshot: ((ProcessSnapshot) -> Void)?

    @ObservationIgnored private let monitor: DevServerMonitor?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanAgain = false
    @ObservationIgnored private var watched = false

    var servers: [DevServer] { scan?.servers ?? [] }

    init(live: Bool = true) {
        monitor = live ? DevServerMonitor(terminator: ProcessTerminator(grace: TimeInterval(Self.graceSeconds))) : nil
    }

    func start() {
        guard monitor != nil, loop == nil else { return }
        startLoop()
    }

    func setWatched(_ watched: Bool) {
        guard monitor != nil, watched != self.watched else { return }
        self.watched = watched
        guard watched else { return }
        let age = Date().timeIntervalSince(lastScan ?? .distantPast)
        let interval = TimeInterval(Self.watchedInterval.components.seconds)
        // The loop may be inside its 60 s wait: restart it so the next scan comes 10 s after the last one.
        startLoop(after: age >= interval ? .zero : .seconds(interval - age))
    }

    func refresh() {
        guard monitor != nil else { return }
        startLoop()
    }

    func stopState(of server: DevServer) -> StopState? {
        stops[server.id]
    }

    func processCount(of server: DevServer) -> Int {
        max(scan?.snapshot.members(ofGroup: server.groupID).count ?? 0, server.members.count)
    }

    func askStop(_ server: DevServer) {
        guard server.canStop, stops[server.id] != .stopping else { return }
        stops[server.id] = .confirming
    }

    func cancelStop(_ server: DevServer) {
        guard stops[server.id] != .stopping else { return }
        stops[server.id] = nil
    }

    func confirmStop(_ server: DevServer) {
        guard let monitor, stops[server.id] == .confirming else { return }
        stops[server.id] = .stopping
        let sessions = context?()?.sessions ?? []
        Task {
            let outcome = await monitor.stop(server, sessions: sessions)
            await rescan()
            finish(server, outcome: outcome)
        }
    }

    func rowServers(for session: SessionKey) -> [DevServer] {
        scan?.servers(for: session, match: .lineage) ?? []
    }

    func headerServers(inGroup key: String, sessions: [AgentSession]) -> [DevServer] {
        let keys = Set(sessions.map(\.key))
        return (scan?.servers(inGroup: key) ?? []).filter { !$0.isOnRow(of: keys) }
    }

    func unplacedServers(groups: [ProjectGroup], sessions: [AgentSession]) -> [DevServer] {
        let shown = Set(groups.map(\.id))
        let keys = Set(sessions.map(\.key))
        return servers.filter { !shown.contains($0.groupKey) && !$0.isOnRow(of: keys) }
    }

    private func finish(_ server: DevServer, outcome: ProcessTerminator.Outcome) {
        let name = "\(server.frameworkName) \(server.portLabel)"
        let stillRunning = servers.contains { $0.id == server.id }
        stops[server.id] = nil
        switch outcome {
        case .terminated:
            post(Notice(text: "Stopped \(name)", isError: false))
        case .killed:
            post(Notice(text: "\(name) did not exit within \(Self.graceSeconds) s and was force quit", isError: false))
        case .refused(let refusal):
            fail(server, reason: refusal.reason, stillRunning: stillRunning)
        case .failed(let code):
            fail(server, reason: "Could not signal \(name): \(String(cString: strerror(code)))",
                 stillRunning: stillRunning)
        }
    }

    private func fail(_ server: DevServer, reason: String, stillRunning: Bool) {
        if stillRunning {
            stops[server.id] = .failed(reason)
        } else {
            post(Notice(text: reason, isError: true))
        }
    }

    private func post(_ notice: Notice) {
        self.notice = notice
        Task {
            try? await Task.sleep(for: .seconds(8))
            if self.notice == notice { self.notice = nil }
        }
    }

    private var interval: Duration {
        watched ? Self.watchedInterval : Self.backgroundInterval
    }

    private func startLoop(after first: Duration = .zero) {
        loop?.cancel()
        loop = Task { [weak self] in
            if first > .zero {
                try? await Task.sleep(for: first)
                if Task.isCancelled { return }
            }
            while !Task.isCancelled {
                await self?.rescan()
                guard let delay = self?.interval, !Task.isCancelled else { return }
                try? await Task.sleep(for: delay)
            }
        }
    }

    // A caller that arrives during a scan waits for one that starts after it asked, so a rescan after Stop
    // never returns the process list from before the signal.
    private func rescan() async {
        if let scanTask {
            scanAgain = true
            await scanTask.value
            return
        }
        let task = Task {
            repeat {
                scanAgain = false
                await runScan()
            } while scanAgain
            scanTask = nil
            isScanning = false
        }
        scanTask = task
        isScanning = true
        await task.value
    }

    private func runScan() async {
        guard let monitor, let context = context?() else { return }
        let result = await monitor.refresh(hubPort: context.hubPort, sessions: context.sessions,
                                           resolveProjects: context.resolveProjects)
        if result != scan { scan = result }
        lastScan = result.snapshot.takenAt
        onSnapshot?(result.snapshot)
        let ids = Set(result.servers.map(\.id))
        stops = stops.filter { ids.contains($0.key) || $0.value == .stopping }
    }
}

private extension DevServer {
    func isOnRow(of sessions: Set<SessionKey>) -> Bool {
        sessionMatch == .lineage && session.map(sessions.contains) == true
    }
}

extension DevServers {
    func show(_ scan: DevServerScan, stops: [String: StopState] = [:], notice: Notice? = nil) {
        self.scan = scan
        lastScan = scan.snapshot.takenAt
        self.stops = stops
        self.notice = notice
    }
}
