import Foundation

public struct ProcessLineage: Sendable {
    public let snapshot: ProcessSnapshot
    private let childrenByParent: [Int32: [Int32]]

    public init(_ snapshot: ProcessSnapshot) {
        self.snapshot = snapshot
        var children: [Int32: [Int32]] = [:]
        for process in snapshot.processes where process.parentPID > 0 {
            children[process.parentPID, default: []].append(process.pid)
        }
        childrenByParent = children
    }

    public func parent(of process: ScannedProcess) -> ScannedProcess? {
        guard process.parentPID > 1, process.parentPID != process.pid,
              let parent = snapshot.process(process.parentPID) else { return nil }
        // A "parent" that started after its child is a later process that got the old parent's pid.
        return parent.identity.startedAt <= process.identity.startedAt.addingTimeInterval(1) ? parent : nil
    }

    public func ancestors(of pid: Int32) -> [ScannedProcess] {
        guard var current = snapshot.process(pid) else { return [] }
        var chain: [ScannedProcess] = []
        var seen: Set<Int32> = [pid]
        while let next = parent(of: current), seen.insert(next.pid).inserted {
            chain.append(next)
            current = next
        }
        return chain
    }

    public func isAncestor(_ ancestor: Int32, of pid: Int32) -> Bool {
        ancestors(of: pid).contains { $0.pid == ancestor }
    }

    public func children(of pid: Int32) -> [ScannedProcess] {
        guard let process = snapshot.process(pid) else { return [] }
        return (childrenByParent[pid] ?? []).compactMap { snapshot.process($0) }.filter { parent(of: $0) == process }
    }

    public func descendants(of pid: Int32) -> [ScannedProcess] {
        var result: [ScannedProcess] = []
        var seen: Set<Int32> = [pid]
        var queue = [pid]
        while let next = queue.popLast() {
            for child in children(of: next) where seen.insert(child.pid).inserted {
                result.append(child)
                queue.append(child.pid)
            }
        }
        return result
    }

    public static func agentSource(of process: ScannedProcess) -> AgentSource? {
        let tokens = ([process.executable].compactMap { $0 } + process.arguments.prefix(2)).map { $0.lowercased() }
        let names = Set(tokens.map { ($0 as NSString).lastPathComponent })
        func mentions(_ fragment: String) -> Bool { tokens.contains { $0.contains(fragment) } }
        return AgentSource.allCases.first { source in
            let info = source.info
            return !names.isDisjoint(with: info.processNames) || info.processPathFragments.contains(where: mentions)
        }
    }
}
