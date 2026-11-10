import Foundation

public enum OrphanStop {
    public enum Decision: Sendable, Equatable {
        case allowed([ProcessIdentity])
        case refused(DevServerStop.Refusal)
    }

    public static func decide(_ identity: ProcessIdentity, in snapshot: ProcessSnapshot, ownPID: Int32,
                              uid: UInt32) -> Decision {
        guard let process = snapshot.process(identity.pid) else { return .refused(.processGone) }
        guard process.identity == identity else { return .refused(.identityChanged) }
        let lineage = ProcessLineage(snapshot)
        let tree = [process] + lineage.descendants(of: process.pid)
        guard tree.allSatisfy({ $0.uid == uid }) else { return .refused(.notOurUser) }
        let hoply = Set([ownPID] + lineage.ancestors(of: ownPID).map(\.pid))
        if tree.contains(where: { hoply.contains($0.pid) }) { return .refused(.includesHoply) }
        if tree.contains(where: { ProcessLineage.agentSource(of: $0) != nil }) { return .refused(.includesAgent) }
        return .allowed(tree.map(\.identity))
    }
}
