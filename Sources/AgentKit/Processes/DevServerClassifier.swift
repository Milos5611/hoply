import Foundation

public struct DevServer: Identifiable, Equatable, Sendable {
    public enum SessionMatch: String, Sendable {
        case lineage
        case directory
    }

    public var id: String
    public var process: ProcessIdentity
    public var groupID: Int32
    public var members: [ProcessIdentity]
    public var port: Int
    public var listeners: [ListeningSocket]
    public var cwd: String
    public var project: ProjectRef?
    public var framework: DevServerFramework
    public var processName: String
    public var memoryBytes: UInt64?
    public var session: SessionKey?
    public var sessionMatch: SessionMatch?
    public var stopRefusal: DevServerStop.Refusal?

    public var url: URL { URL(string: "http://localhost:\(port)") ?? URL(fileURLWithPath: "/") }

    public var groupKey: String { project.map { "project:\($0.id)" } ?? cwd }

    public var projectName: String {
        project?.title ?? (cwd as NSString).lastPathComponent
    }

    public var frameworkName: String {
        framework == .other && !processName.isEmpty ? processName : framework.displayName
    }

    public var portLabel: String { ":\(port)" }

    public var memoryLabel: String? {
        guard let bytes = memoryBytes else { return nil }
        let megabytes = Double(bytes) / 1_048_576
        if megabytes < 1024 { return "\(Int(megabytes.rounded())) MB" }
        return String(format: "%.1f GB", locale: Locale(identifier: "en_US_POSIX"), megabytes / 1024)
    }

    public var displayName: String {
        (["\(projectName) · \(frameworkName) \(portLabel)"] + [memoryLabel].compactMap { $0 }).joined(separator: " · ")
    }

    public var isReachableFromNetwork: Bool {
        listeners.contains { $0.reach != .loopback }
    }

    public var canStop: Bool { stopRefusal == nil }

    var stopRoot: String {
        guard let project, project.kind == .repo || project.kind == .folder else { return cwd }
        // A linked worktree lives outside the repo root, so its servers are scoped to their own directory.
        return PathScope.contains(project.root, cwd) ? project.root : cwd
    }

    public static func id(process: ProcessIdentity, port: Int) -> String {
        "\(process.pid):\(process.startMicroseconds):\(port)"
    }
}

public struct DevServerClassifier: Sendable {
    public struct Session: Sendable, Equatable {
        public var key: SessionKey
        public var pid: Int32?
        public var cwd: String?
        public var reportedPID: Int32?
        public var reportedAt: Date?

        public init(key: SessionKey, pid: Int32? = nil, cwd: String? = nil, reportedPID: Int32? = nil,
                    reportedAt: Date? = nil) {
            self.key = key
            self.pid = pid
            self.cwd = cwd
            self.reportedPID = reportedPID
            self.reportedAt = reportedAt
        }
    }

    public static let defaultExcludedPorts: Set<Int> = [
        1433, 1521, 2181, 2375, 2376, 3283, 3306, 4317, 5037, 5432, 5672, 5900, 5984, 6379, 6443, 9092, 9200, 9229,
        9230, 9300, 11211, 11434, 15672, 27017, 33060,
    ]
    public static let firstEphemeralPort = 49_152
    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]

    public var hubPort: Int
    public var ownPID: Int32
    public var uid: UInt32
    public var homeDirectory: String
    public var excludedPorts: Set<Int>

    public init(hubPort: Int = 4318, ownPID: Int32, uid: UInt32, homeDirectory: String,
                excludedPorts: Set<Int> = DevServerClassifier.defaultExcludedPorts) {
        self.hubPort = hubPort
        self.ownPID = ownPID
        self.uid = uid
        self.homeDirectory = PathScope.normalized(homeDirectory)
        self.excludedPorts = excludedPorts
    }

    public func candidateDirectories(in snapshot: ProcessSnapshot) -> [String] {
        var seen: Set<String> = []
        return snapshot.listening.compactMap { process in
            guard let cwd = usableDirectory(of: process), !ports(of: process).isEmpty,
                  seen.insert(cwd).inserted else { return nil }
            return cwd
        }
    }

    public func servers(in snapshot: ProcessSnapshot, projects: [String: ProjectRef] = [:],
                        sessions: [Session] = []) -> [DevServer] {
        let lineage = ProcessLineage(snapshot)
        let sessions = verified(sessions, lineage: lineage)
        var byPort: [Int: [ScannedProcess]] = [:]
        for process in snapshot.listening where isCandidate(process, projects: projects) {
            for port in ports(of: process) { byPort[port, default: []].append(process) }
        }
        let protected = Set(sessions.compactMap(\.pid))
        var servers: [DevServer] = []
        for (port, processes) in byPort {
            for cluster in clusters(processes, lineage: lineage) {
                guard let owner = owner(of: cluster, lineage: lineage), let cwd = owner.cwd else { continue }
                let members = [owner] + cluster.filter { $0.pid != owner.pid }.sorted { $0.pid < $1.pid }
                let framework = framework(of: members + launchers(of: owner, lineage: lineage))
                if port >= Self.firstEphemeralPort, !framework.isSpecific { continue }
                let launchers = launchers(of: owner, lineage: lineage)
                let top = launchers.last ?? owner
                var tree: [Int32: ScannedProcess] = [:]
                for process in members + [top] + lineage.descendants(of: top.pid) { tree[process.pid] = process }
                let footprints = tree.values.compactMap(\.memoryBytes)
                let match = session(for: owner, cwd: cwd, sessions: sessions, lineage: lineage)
                var server = DevServer(
                    id: DevServer.id(process: owner.identity, port: port), process: owner.identity,
                    groupID: owner.groupID, members: members.map(\.identity), port: port,
                    listeners: unique(members.flatMap { $0.listeners.filter { $0.port == port } }), cwd: cwd,
                    project: projects[cwd], framework: framework, processName: owner.name,
                    memoryBytes: footprints.isEmpty ? nil : footprints.reduce(0, +), session: match?.key,
                    sessionMatch: match?.match, stopRefusal: nil)
                server.stopRefusal = DevServerStop.decide(server, in: snapshot, ownPID: ownPID, uid: uid,
                                                          protectedPIDs: protected).refusal
                servers.append(server)
            }
        }
        return servers.sorted { a, b in
            let left = a.projectName.lowercased(), right = b.projectName.lowercased()
            return left != right ? left < right : (a.port, a.process.pid) < (b.port, b.process.pid)
        }
    }

    public func verified(_ sessions: [Session], in snapshot: ProcessSnapshot) -> [Session] {
        verified(sessions, lineage: ProcessLineage(snapshot))
    }

    private func verified(_ sessions: [Session], lineage: ProcessLineage) -> [Session] {
        sessions.map { session in
            guard session.pid == nil, let reported = session.reportedPID, let at = session.reportedAt else { return session }
            var session = session
            session.pid = SessionProcess.agent(reportedPID: reported, source: session.key.source, reportedAt: at,
                                               uid: uid, lineage: lineage)?.pid
            return session
        }
    }

    private func ports(of process: ScannedProcess) -> [Int] {
        unique(process.listeners.map(\.port)).filter { $0 >= 1024 && $0 != hubPort && !excludedPorts.contains($0) }
    }

    private func usableDirectory(of process: ScannedProcess) -> String? {
        guard process.pid != ownPID, let cwd = process.cwd.map(PathScope.normalized), !cwd.isEmpty, cwd != "/",
              !PathScope.contains(homeDirectory + "/Library", cwd) else { return nil }
        if let path = process.executable, Self.systemPrefixes.contains(where: path.hasPrefix) { return nil }
        return cwd
    }

    private func isCandidate(_ process: ScannedProcess, projects: [String: ProjectRef]) -> Bool {
        guard let cwd = usableDirectory(of: process) else { return false }
        guard let path = process.executable, isInstalledApp(path) else { return true }
        return projects[cwd]?.kind == .repo || DevServerFramework.detect(process) != .other
    }

    private func isInstalledApp(_ path: String) -> Bool {
        guard path.contains(".app/Contents/") else { return false }
        let prefixes = ["/Applications/", "/System/", "/Library/", homeDirectory + "/Applications/"]
        return prefixes.contains(where: path.hasPrefix)
    }

    private func clusters(_ processes: [ScannedProcess], lineage: ProcessLineage) -> [[ScannedProcess]] {
        var group = Array(processes.indices)
        func find(_ index: Int) -> Int {
            var index = index
            while group[index] != index { index = group[index] }
            return index
        }
        let ancestors = processes.map { Set(lineage.ancestors(of: $0.pid).map(\.pid)) }
        for a in processes.indices {
            for b in processes.indices where b > a {
                let related = processes[a].groupID == processes[b].groupID
                    || ancestors[a].contains(processes[b].pid) || ancestors[b].contains(processes[a].pid)
                if related { group[find(b)] = find(a) }
            }
        }
        var result: [Int: [ScannedProcess]] = [:]
        for index in processes.indices { result[find(index), default: []].append(processes[index]) }
        return result.keys.sorted().compactMap { result[$0] }
    }

    private func owner(of cluster: [ScannedProcess], lineage: ProcessLineage) -> ScannedProcess? {
        let pids = Set(cluster.map(\.pid))
        let top = cluster.filter { process in !lineage.ancestors(of: process.pid).contains { pids.contains($0.pid) } }
        return top.first(where: \.isGroupLeader) ?? top.min { a, b in
            (a.identity.startedAt, a.pid) < (b.identity.startedAt, b.pid)
        }
    }

    private func launchers(of owner: ScannedProcess, lineage: ProcessLineage) -> [ScannedProcess] {
        Array(lineage.ancestors(of: owner.pid).prefix {
            $0.groupID == owner.groupID && ProcessLineage.agentSource(of: $0) == nil
        })
    }

    private func framework(of processes: [ScannedProcess]) -> DevServerFramework {
        var best = DevServerFramework.other
        for process in processes {
            let found = DevServerFramework.detect(process)
            if found.specificity > best.specificity { best = found }
        }
        return best
    }

    private func session(for owner: ScannedProcess, cwd: String, sessions: [Session],
                         lineage: ProcessLineage) -> (key: SessionKey, match: DevServer.SessionMatch)? {
        guard !sessions.isEmpty else { return nil }
        let ancestors = lineage.ancestors(of: owner.pid)
        for ancestor in ancestors {
            if let session = sessions.first(where: { $0.pid == ancestor.pid }) { return (session.key, .lineage) }
        }
        func deepest(_ candidates: [Session]) -> [Session] {
            let containing = candidates.filter { $0.cwd.map { PathScope.contains($0, cwd) } ?? false }
            let depth = containing.compactMap { $0.cwd.map(PathScope.normalized)?.count }.max()
            return containing.filter { $0.cwd.map(PathScope.normalized)?.count == depth }
        }
        var pool = sessions.filter { $0.pid == nil }
        if let agent = ancestors.first(where: { ProcessLineage.agentSource(of: $0) != nil }),
           let source = ProcessLineage.agentSource(of: agent) {
            pool = pool.filter { $0.key.source == source }
            let sameDirectory = pool.filter { session in
                guard let a = session.cwd, let b = agent.cwd else { return false }
                return PathScope.normalized(a) == PathScope.normalized(b)
            }
            if sameDirectory.count == 1 { return (sameDirectory[0].key, .lineage) }
            let inside = deepest(pool)
            if inside.count == 1 { return (inside[0].key, .lineage) }
        }
        return deepest(pool).first.map { ($0.key, .directory) }
    }

    private func unique<Value: Hashable>(_ values: [Value]) -> [Value] {
        var seen: Set<Value> = []
        return values.filter { seen.insert($0).inserted }
    }
}
