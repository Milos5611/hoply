import Foundation

public struct CleanupRules: Sendable, Equatable {
    public struct Thresholds: Sendable, Equatable {
        public var worktreeIdleDays: Int
        public var cacheIdleDays: Int
        public var cacheMinimumBytes: Int64
        public var transcriptAgeDays: Int
        public var includeNodeModules: Bool

        public init(worktreeIdleDays: Int = 7, cacheIdleDays: Int = 14, cacheMinimumBytes: Int64 = 50 * 1_048_576,
                    transcriptAgeDays: Int = 90, includeNodeModules: Bool = false) {
            self.worktreeIdleDays = worktreeIdleDays
            self.cacheIdleDays = cacheIdleDays
            self.cacheMinimumBytes = cacheMinimumBytes
            self.transcriptAgeDays = transcriptAgeDays
            self.includeNodeModules = includeNodeModules
        }

        public init(settings: AppSettings) {
            self.init(includeNodeModules: settings.cleanupIncludesNodeModules)
        }
    }

    public var thresholds: Thresholds

    public init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    public func keepReasons(for facts: WorktreeFacts, now: Date) -> [CleanupKeepReason] {
        guard facts.isTracked else { return [.untrackedWorktree] }
        var reasons: [CleanupKeepReason] = []
        if facts.isMain { reasons.append(.mainWorktree) }
        if facts.isLocked { reasons.append(.locked) }
        if facts.isClean == nil || facts.isMerged == nil || facts.defaultBranch == nil {
            reasons.append(.gitStateUnknown)
        }
        if facts.isClean == false { reasons.append(.uncommittedChanges) }
        if facts.isMerged == false, let defaultBranch = facts.defaultBranch {
            reasons.append(.notMerged(branch: facts.branch, into: defaultBranch))
        }
        if facts.hasLiveSession { reasons.append(.sessionRunning) }
        if facts.hasDevServer { reasons.append(.devServerRunning) }
        reasons += idleReasons(lastActive: facts.lastActive, requiredDays: thresholds.worktreeIdleDays, now: now)
        return reasons
    }

    public func keepReasons(for facts: CacheFacts, now: Date) -> [CleanupKeepReason] {
        var reasons: [CleanupKeepReason] = []
        switch facts.ignoreState {
        case .notInRepository, .ignored: break
        case .notIgnored: reasons.append(.notIgnored)
        case .unknown: reasons.append(.gitStateUnknown)
        }
        if facts.hasLiveSession { reasons.append(.sessionRunning) }
        if facts.hasDevServer { reasons.append(.devServerRunning) }
        reasons += idleReasons(lastActive: facts.projectLastActive, requiredDays: thresholds.cacheIdleDays, now: now)
        if facts.bytes <= thresholds.cacheMinimumBytes {
            reasons.append(.tooSmall(bytes: facts.bytes, minimumBytes: thresholds.cacheMinimumBytes))
        }
        return reasons
    }

    public func keepReasons(for facts: TranscriptFacts, now: Date) -> [CleanupKeepReason] {
        guard let lastWritten = facts.lastWritten else { return [.missing] }
        var reasons: [CleanupKeepReason] = []
        let age = now.timeIntervalSince(lastWritten)
        if age <= Self.seconds(days: thresholds.transcriptAgeDays) {
            reasons.append(.recentlyWritten(ageDays: Self.wholeDays(age), requiredDays: thresholds.transcriptAgeDays))
        }
        if !facts.files.allSatisfy(\.isFullyIngested) { reasons.append(.notFullyIngested) }
        return reasons
    }

    public static func isPrivacyProtected(_ path: String, home: String) -> Bool {
        ["Documents", "Desktop", "Downloads", "Library/Mobile Documents"].contains {
            PathScope.contains(PathScope.normalized(home) + "/" + $0, path)
        }
    }

    private func idleReasons(lastActive: Date?, requiredDays: Int, now: Date) -> [CleanupKeepReason] {
        guard let lastActive else { return [.activityUnknown] }
        let idle = now.timeIntervalSince(lastActive)
        guard idle <= Self.seconds(days: requiredDays) else { return [] }
        return [.recentlyActive(idleDays: Self.wholeDays(idle), requiredDays: requiredDays)]
    }

    private static func seconds(days: Int) -> TimeInterval { TimeInterval(days) * 86_400 }

    private static func wholeDays(_ interval: TimeInterval) -> Int { max(0, Int(interval / 86_400)) }
}
