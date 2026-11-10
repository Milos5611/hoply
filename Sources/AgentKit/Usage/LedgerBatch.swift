import Foundation

public struct SessionUpdate: Sendable, Equatable {
    public var key: SessionKey
    public var firstAt: Date?
    public var lastAt: Date?
    public var cwd: String?
    public var branch: String?
    public var placeIsAuthoritative: Bool
    public var title: String?
    public var titleRank: Int
    public var prURL: String?
    public var nativeCostUSD: Double?
    public var linesAdded: Int?
    public var linesRemoved: Int?
    public var transcriptPath: String?
    public var prompts: Int
    public var resetsTurns: Bool

    public init(key: SessionKey, firstAt: Date? = nil, lastAt: Date? = nil, cwd: String? = nil, branch: String? = nil,
                placeIsAuthoritative: Bool = true, title: String? = nil, titleRank: Int = 0, prURL: String? = nil,
                nativeCostUSD: Double? = nil, linesAdded: Int? = nil, linesRemoved: Int? = nil,
                transcriptPath: String? = nil, prompts: Int = 0, resetsTurns: Bool = false) {
        self.key = key
        self.firstAt = firstAt
        self.lastAt = lastAt
        self.cwd = cwd
        self.branch = branch
        self.placeIsAuthoritative = placeIsAuthoritative
        self.title = title
        self.titleRank = titleRank
        self.prURL = prURL
        self.nativeCostUSD = nativeCostUSD
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.transcriptPath = transcriptPath
        self.prompts = prompts
        self.resetsTurns = resetsTurns
    }
}

public struct LedgerBatch: Sendable, Equatable {
    public var usage: [UsageRecord]
    public var sessions: [SessionUpdate]
    public var subagents: [SubagentInfo]

    public init(usage: [UsageRecord] = [], sessions: [SessionUpdate] = [], subagents: [SubagentInfo] = []) {
        self.usage = usage
        self.sessions = sessions
        self.subagents = subagents
    }

    public var isEmpty: Bool { usage.isEmpty && sessions.isEmpty && subagents.isEmpty }
}

extension ClaudeTranscriptBatch {
    public func ledgerBatch(transcriptPath: String, startsAtFileStart: Bool) -> LedgerBatch {
        let isSubagentFile = transcriptPath.contains("/subagents/")
        let stem = URL(fileURLWithPath: transcriptPath).deletingPathExtension().lastPathComponent
        let updates = sessions.keys.sorted().compactMap { id -> SessionUpdate? in
            guard let facts = sessions[id] else { return nil }
            return SessionUpdate(
                key: SessionKey(source: .claudeCode, id: id),
                firstAt: facts.firstAt, lastAt: facts.lastAt,
                cwd: facts.effectiveCwd, branch: facts.effectiveBranch,
                placeIsAuthoritative: !isSubagentFile && facts.cwd != nil,
                title: facts.title, titleRank: facts.titleKind?.rawValue ?? 0,
                prURL: facts.prURL,
                nativeCostUSD: facts.costState?.totalCostUSD,
                linesAdded: facts.costState?.linesAdded, linesRemoved: facts.costState?.linesRemoved,
                transcriptPath: !isSubagentFile && stem == id ? transcriptPath : nil,
                prompts: facts.prompts,
                resetsTurns: startsAtFileStart && !isSubagentFile)
        }
        return LedgerBatch(usage: usage, sessions: updates)
    }
}
