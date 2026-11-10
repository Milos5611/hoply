import AgentKit
import Darwin
import Foundation

public struct DevServerScan: Sendable, Equatable {
    public var servers: [DevServer]
    public var snapshot: ProcessSnapshot
    public var duration: TimeInterval

    public init(servers: [DevServer] = [], snapshot: ProcessSnapshot = ProcessSnapshot(source: .unavailable, processes: []),
                duration: TimeInterval = 0) {
        self.servers = servers
        self.snapshot = snapshot
        self.duration = duration
    }

    public func servers(inGroup key: String) -> [DevServer] {
        servers.filter { $0.groupKey == key }
    }

    public func servers(for session: SessionKey, match: DevServer.SessionMatch? = nil) -> [DevServer] {
        servers.filter { $0.session == session && (match == nil || $0.sessionMatch == match) }
    }
}

public actor DevServerMonitor {
    public typealias ProjectLookup = @Sendable ([String]) async -> [String: ProjectRef]

    private let scanner: ProcessScanner
    private let terminator: ProcessTerminator
    private let homeDirectory: String
    public private(set) var latest: DevServerScan?

    public init(scanner: ProcessScanner = ProcessScanner(), terminator: ProcessTerminator = ProcessTerminator(),
                homeDirectory: String = NSHomeDirectory()) {
        self.scanner = scanner
        self.terminator = terminator
        self.homeDirectory = homeDirectory
    }

    @discardableResult
    public func refresh(hubPort: Int, sessions: [DevServerClassifier.Session] = [],
                        resolveProjects: ProjectLookup? = nil) async -> DevServerScan {
        let started = Date()
        let scanner = scanner
        let snapshot = await Task.detached(priority: .utility) { scanner.scan() }.value
        let classifier = classifier(hubPort: hubPort)
        let projects = await resolveProjects?(classifier.candidateDirectories(in: snapshot)) ?? [:]
        let scan = DevServerScan(servers: classifier.servers(in: snapshot, projects: projects, sessions: sessions),
                                 snapshot: snapshot, duration: Date().timeIntervalSince(started))
        if latest.map({ $0.snapshot.takenAt <= snapshot.takenAt }) ?? true { latest = scan }
        return scan
    }

    public func stop(_ server: DevServer, sessions: [DevServerClassifier.Session] = []) async -> ProcessTerminator.Outcome {
        let scanner = scanner
        let snapshot = await Task.detached(priority: .userInitiated) { scanner.scan() }.value
        let agents = classifier(hubPort: 0).verified(sessions, in: snapshot).compactMap(\.pid)
        let decision = DevServerStop.decide(server, in: snapshot, ownPID: getpid(), uid: getuid(),
                                            protectedPIDs: Set(agents))
        switch decision {
        case .refused(let refusal): return .refused(refusal)
        case .allowed(let target): return await terminator.stop(target)
        }
    }

    private func classifier(hubPort: Int) -> DevServerClassifier {
        DevServerClassifier(hubPort: hubPort, ownPID: getpid(), uid: getuid(), homeDirectory: homeDirectory)
    }
}
