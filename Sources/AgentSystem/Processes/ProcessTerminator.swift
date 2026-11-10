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
        // A group id stays reserved while the group has members, so surviving members prove it is still theirs.
        return await settle(survivors: { survivors(of: target) }) { _ in
            killpg(target.groupID, SIGKILL) == 0 ? nil : errno
        }
    }

    public func stop(_ processes: [ProcessIdentity]) async -> Outcome {
        guard !processes.contains(where: { $0.pid <= 1 || $0.pid == getpid() }) else { return .refused(.includesHoply) }
        let alive = processes.filter(ProcessScanner.isAlive)
        guard !alive.isEmpty else { return .refused(.processGone) }
        guard alive.allSatisfy({ ProcessScanner.bsdInfo($0.pid)?.pbi_uid == getuid() }) else { return .refused(.notOurUser) }
        if let error = Self.signal(alive, SIGTERM) { return .failed(errno: error) }
        return await settle(survivors: { alive.filter(ProcessScanner.isAlive) }) { Self.signal($0, SIGKILL) }
    }

    private func settle(survivors: () -> [ProcessIdentity], kill: ([ProcessIdentity]) -> Int32?) async -> Outcome {
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if survivors().isEmpty { return .terminated }
            try? await Task.sleep(for: .seconds(pollInterval))
        }
        let remaining = survivors()
        guard !remaining.isEmpty else { return .terminated }
        if let error = kill(remaining) { return error == ESRCH ? .terminated : .failed(errno: error) }
        return .killed
    }

    // Each pid is checked against its start time right before its signal, so a reused pid is never signalled.
    private static func signal(_ processes: [ProcessIdentity], _ signal: Int32) -> Int32? {
        var failure: Int32?
        for process in processes where ProcessScanner.isAlive(process) {
            if kill(process.pid, signal) != 0, errno != ESRCH { failure = failure ?? errno }
        }
        return failure
    }

    private func survivors(of target: DevServerStop.Target) -> [ProcessIdentity] {
        target.members.filter { member in
            guard ProcessScanner.isAlive(member), let info = ProcessScanner.bsdInfo(member.pid) else { return false }
            return Int32(info.pbi_pgid) == target.groupID
        }
    }
}
