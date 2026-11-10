import AgentKit
import Darwin
import Foundation

public struct ProcessTerminator: Sendable {
    public enum Outcome: Sendable, Equatable {
        case terminated
        case killed
        case refused(DevServerStop.Refusal)
        case failed(errno: Int32)

        public var stopped: Bool { self == .terminated || self == .killed }
    }

    public var grace: TimeInterval
    public var pollInterval: TimeInterval

    public init(grace: TimeInterval = 5, pollInterval: TimeInterval = 0.1) {
        self.grace = grace
        self.pollInterval = pollInterval
    }

    public func stop(_ target: DevServerStop.Target) async -> Outcome {
        guard target.groupID > 1, target.groupID != getpgrp(), target.leader.pid == target.groupID else {
            return .refused(.noProcessGroup)
        }
        guard let leader = ProcessScanner.bsdInfo(target.leader.pid) else { return .refused(.processGone) }
        guard ProcessScanner.isAlive(target.leader), Int32(leader.pbi_pgid) == target.groupID else {
            return .refused(.identityChanged)
        }
        guard leader.pbi_uid == getuid() else { return .refused(.notOurUser) }
        guard killpg(target.groupID, SIGTERM) == 0 else { return .failed(errno: errno) }

        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if survivors(of: target).isEmpty { return .terminated }
            try? await Task.sleep(for: .seconds(pollInterval))
        }
        // A group id stays reserved while the group has members, so surviving members prove it is still theirs.
        guard !survivors(of: target).isEmpty else { return .terminated }
        guard killpg(target.groupID, SIGKILL) == 0 else { return errno == ESRCH ? .terminated : .failed(errno: errno) }
        return .killed
    }

    private func survivors(of target: DevServerStop.Target) -> [ProcessIdentity] {
        target.members.filter { member in
            guard ProcessScanner.isAlive(member), let info = ProcessScanner.bsdInfo(member.pid) else { return false }
            return Int32(info.pbi_pgid) == target.groupID
        }
    }
}
