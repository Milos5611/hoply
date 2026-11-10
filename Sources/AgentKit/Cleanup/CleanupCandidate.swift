import Foundation

public enum CleanupKind: String, Sendable, CaseIterable {
    case worktree
    case buildCache = "build-cache"
    case transcript
    case orphanProcess = "orphan-process"
}

public struct CleanupCandidate: Identifiable, Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case path(String)
        case process(OrphanProcess)
    }

    public var kind: CleanupKind
    public var target: Target
    public var title: String
    public var project: ProjectRef?
    public var branch: String?
    public var bytes: Int64
    public var lastActive: Date?
    public var keepReasons: [CleanupKeepReason]

    public init(kind: CleanupKind, path: String, title: String, project: ProjectRef? = nil, branch: String? = nil,
                bytes: Int64 = 0, lastActive: Date? = nil, keepReasons: [CleanupKeepReason] = []) {
        self.kind = kind
        self.target = .path(path)
        self.title = title
        self.project = project
        self.branch = branch
        self.bytes = bytes
        self.lastActive = lastActive
        self.keepReasons = keepReasons
    }

    public init(orphan: OrphanProcess) {
        kind = .orphanProcess
        target = .process(orphan)
        title = orphan.name
        bytes = Int64(clamping: orphan.memoryBytes)
        keepReasons = []
    }

    public var id: String {
        switch target {
        case .path(let path): return "\(kind.rawValue):\(path)"
        case .process(let orphan): return "\(kind.rawValue):\(orphan.identity.pid):\(orphan.identity.startMicroseconds)"
        }
    }

    public var isEligible: Bool { keepReasons.isEmpty }

    public var path: String? {
        if case .path(let path) = target { return path }
        return nil
    }

    public var orphan: OrphanProcess? {
        if case .process(let orphan) = target { return orphan }
        return nil
    }
}

public struct CleanupScan: Sendable, Equatable {
    public var candidates: [CleanupCandidate]
    public var scannedAt: Date
    public var duration: TimeInterval

    public init(candidates: [CleanupCandidate] = [], scannedAt: Date = Date(), duration: TimeInterval = 0) {
        self.candidates = candidates
        self.scannedAt = scannedAt
        self.duration = duration
    }

    public var eligible: [CleanupCandidate] { candidates.filter(\.isEligible) }

    public var reclaimableBytes: Int64 {
        CleanupCandidate.distinctBytes(of: eligible)
    }
}

extension CleanupCandidate {
    public func isInside(anyOf paths: [String]) -> Bool {
        guard let path else { return false }
        return paths.contains { $0 != path && PathScope.contains($0, path) }
    }

    static func distinctBytes(of candidates: [CleanupCandidate]) -> Int64 {
        let paths = candidates.compactMap(\.path)
        return candidates.filter { $0.path != nil && !$0.isInside(anyOf: paths) }.reduce(0) { $0 + $1.bytes }
    }
}
