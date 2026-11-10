import Foundation

public enum DevServerStop {
    public enum Refusal: Sendable, Equatable {
        case processGone
        case identityChanged
        case notOurUser
        case noProcessGroup
        case leaderGone
        case leaderOutsideProject
        case includesHoply
        case includesAgent

        public var reason: String {
            switch self {
            case .processGone: return "The server is no longer running."
            case .identityChanged: return "Another process now has this server's process id."
            case .notOurUser: return "The server belongs to another user."
            case .noProcessGroup: return "The server has no process group of its own."
            case .leaderGone: return "The process that started the server's group has exited."
            case .leaderOutsideProject: return "The server's process group was started outside this project."
            case .includesHoply: return "Stopping this group would stop Hoply."
            case .includesAgent: return "The server shares a process group with an agent session."
            }
        }
    }

    public struct Target: Sendable, Equatable {
        public var groupID: Int32
        public var leader: ProcessIdentity
        public var members: [ProcessIdentity]

        public init(groupID: Int32, leader: ProcessIdentity, members: [ProcessIdentity]) {
            self.groupID = groupID
            self.leader = leader
            self.members = members
        }
    }

    public enum Decision: Sendable, Equatable {
        case allowed(Target)
        case refused(Refusal)

        public var refusal: Refusal? {
            if case .refused(let refusal) = self { return refusal }
            return nil
        }

        public var target: Target? {
            if case .allowed(let target) = self { return target }
            return nil
        }
    }

    public static func decide(process identity: ProcessIdentity, root: String, in snapshot: ProcessSnapshot,
                              ownPID: Int32, uid: UInt32, protectedPIDs: Set<Int32> = []) -> Decision {
        guard let process = snapshot.process(identity.pid) else { return .refused(.processGone) }
        guard process.identity == identity else { return .refused(.identityChanged) }
        guard process.uid == uid else { return .refused(.notOurUser) }
        let groupID = process.groupID
        guard groupID > 1 else { return .refused(.noProcessGroup) }
        guard let leader = snapshot.process(groupID), leader.groupID == groupID else { return .refused(.leaderGone) }
        guard leader.uid == uid else { return .refused(.notOurUser) }
        guard let cwd = leader.cwd, PathScope.contains(root, cwd) else { return .refused(.leaderOutsideProject) }

        let members = snapshot.members(ofGroup: groupID)
        let lineage = ProcessLineage(snapshot)
        let hoply = Set([ownPID] + lineage.ancestors(of: ownPID).map(\.pid))
        if members.contains(where: { hoply.contains($0.pid) }) { return .refused(.includesHoply) }
        if members.contains(where: { protectedPIDs.contains($0.pid) || ProcessLineage.agentSource(of: $0) != nil }) {
            return .refused(.includesAgent)
        }
        return .allowed(Target(groupID: groupID, leader: leader.identity, members: members.map(\.identity)))
    }

    public static func decide(_ server: DevServer, in snapshot: ProcessSnapshot, ownPID: Int32, uid: UInt32,
                              protectedPIDs: Set<Int32> = []) -> Decision {
        decide(process: server.process, root: server.stopRoot, in: snapshot, ownPID: ownPID, uid: uid,
               protectedPIDs: protectedPIDs)
    }
}
