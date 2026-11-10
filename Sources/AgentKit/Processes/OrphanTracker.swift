import Foundation

public struct OrphanProcess: Sendable, Equatable, Identifiable {
    public var identity: ProcessIdentity
    public var name: String
    public var cwd: String?
    public var memoryBytes: UInt64
    public var agent: AgentSource
    public var members: [ProcessIdentity]

    public init(identity: ProcessIdentity, name: String, cwd: String? = nil, memoryBytes: UInt64 = 0,
                agent: AgentSource, members: [ProcessIdentity]) {
        self.identity = identity
        self.name = name
        self.cwd = cwd
        self.memoryBytes = memoryBytes
        self.agent = agent
        self.members = members
    }

    public var id: ProcessIdentity { identity }
}

public struct OrphanTracker: Sendable {
    private struct Origin: Sendable {
        var agent: ProcessIdentity
        var source: AgentSource
    }

    private var origins: [ProcessIdentity: Origin] = [:]

    public init() {}

    public mutating func observe(_ snapshot: ProcessSnapshot, uid: UInt32, ownPID: Int32) -> [OrphanProcess] {
        // The lsof fallback lists only listening processes, so an agent missing from it proves nothing.
        guard snapshot.source == .libproc else { return [] }
        let lineage = ProcessLineage(snapshot)
        remember(lineage)
        origins = origins.filter { snapshot.process($0.key) != nil }

        let hoply = Set([ownPID] + lineage.ancestors(of: ownPID).map(\.pid))
        var orphans: [OrphanProcess] = []
        for (identity, origin) in origins where snapshot.process(origin.agent) == nil {
            guard let process = snapshot.process(identity), process.parentPID == 1, process.uid == uid else { continue }
            let tree = [process] + lineage.descendants(of: process.pid)
            guard !tree.contains(where: { hoply.contains($0.pid) || ProcessLineage.agentSource(of: $0) != nil }) else {
                continue
            }
            orphans.append(OrphanProcess(identity: identity, name: process.name, cwd: process.cwd,
                                         memoryBytes: tree.reduce(0) { $0 + ($1.memoryBytes ?? 0) },
                                         agent: origin.source, members: tree.map(\.identity)))
        }
        return orphans.sorted { $0.identity.pid < $1.identity.pid }
    }

    private mutating func remember(_ lineage: ProcessLineage) {
        for process in lineage.snapshot.processes where ProcessLineage.agentSource(of: process) == nil {
            for ancestor in lineage.ancestors(of: process.pid) {
                guard let source = ProcessLineage.agentSource(of: ancestor) else { continue }
                origins[process.identity] = Origin(agent: ancestor.identity, source: source)
                break
            }
        }
    }
}
