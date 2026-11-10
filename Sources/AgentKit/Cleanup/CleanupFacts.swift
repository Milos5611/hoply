import Foundation

public struct WorktreeFacts: Sendable, Equatable {
    public var isMain: Bool
    public var isTracked: Bool
    public var isLocked: Bool
    public var isClean: Bool?
    public var branch: String?
    public var defaultBranch: String?
    public var isMerged: Bool?
    public var hasLiveSession: Bool
    public var hasDevServer: Bool
    public var lastActive: Date?

    public init(isMain: Bool = false, isTracked: Bool = true, isLocked: Bool = false, isClean: Bool? = nil,
                branch: String? = nil, defaultBranch: String? = nil, isMerged: Bool? = nil,
                hasLiveSession: Bool = false, hasDevServer: Bool = false, lastActive: Date? = nil) {
        self.isMain = isMain
        self.isTracked = isTracked
        self.isLocked = isLocked
        self.isClean = isClean
        self.branch = branch
        self.defaultBranch = defaultBranch
        self.isMerged = isMerged
        self.hasLiveSession = hasLiveSession
        self.hasDevServer = hasDevServer
        self.lastActive = lastActive
    }
}

public struct CacheFacts: Sendable, Equatable {
    public enum IgnoreState: Sendable, Equatable {
        case notInRepository
        case ignored
        case notIgnored
        case unknown
    }

    public var bytes: Int64
    public var ignoreState: IgnoreState
    public var hasLiveSession: Bool
    public var hasDevServer: Bool
    public var projectLastActive: Date?

    public init(bytes: Int64, ignoreState: IgnoreState, hasLiveSession: Bool = false, hasDevServer: Bool = false,
                projectLastActive: Date? = nil) {
        self.bytes = bytes
        self.ignoreState = ignoreState
        self.hasLiveSession = hasLiveSession
        self.hasDevServer = hasDevServer
        self.projectLastActive = projectLastActive
    }
}

public struct TranscriptFacts: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        public var inode: UInt64
        public var size: Int64
        public var modified: Date
        public var ingestedInode: UInt64?
        public var ingestedOffset: Int64?

        public init(inode: UInt64, size: Int64, modified: Date, ingestedInode: UInt64? = nil,
                    ingestedOffset: Int64? = nil) {
            self.inode = inode
            self.size = size
            self.modified = modified
            self.ingestedInode = ingestedInode
            self.ingestedOffset = ingestedOffset
        }

        public var isFullyIngested: Bool { ingestedInode == inode && ingestedOffset == size }
    }

    public var files: [File]

    public init(files: [File]) {
        self.files = files
    }

    public var lastWritten: Date? { files.map(\.modified).max() }
}
