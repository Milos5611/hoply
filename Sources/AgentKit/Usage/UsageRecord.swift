import Foundation

public struct TokenCounts: Sendable, Equatable, Hashable, Codable {
    /// Always uncached input. Sources that fold cache reads into input must subtract them first.
    public var input: Int
    public var output: Int
    /// Part of `output`, not extra: Claude bills thinking as output tokens.
    public var reasoning: Int
    public var cacheRead: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int

    public init(input: Int = 0, output: Int = 0, reasoning: Int = 0, cacheRead: Int = 0,
                cacheWrite5m: Int = 0, cacheWrite1h: Int = 0) {
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }

    public var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    public var promptTokens: Int { input + cacheRead + cacheWrite }
    public var total: Int { promptTokens + output }

    /// Field-wise maximum. Claude Code writes one line per content block and the later blocks of a
    /// streamed message carry the final output count, so merging must never lose the larger value.
    public func merged(with other: TokenCounts) -> TokenCounts {
        TokenCounts(input: max(input, other.input), output: max(output, other.output),
                    reasoning: max(reasoning, other.reasoning), cacheRead: max(cacheRead, other.cacheRead),
                    cacheWrite5m: max(cacheWrite5m, other.cacheWrite5m),
                    cacheWrite1h: max(cacheWrite1h, other.cacheWrite1h))
    }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                    reasoning: lhs.reasoning + rhs.reasoning, cacheRead: lhs.cacheRead + rhs.cacheRead,
                    cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
                    cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h)
    }
}

/// One model call in the usage ledger.
public struct UsageRecord: Sendable, Equatable, Hashable {
    public var dedupeKey: String
    public var source: AgentSource
    public var sessionID: String
    public var timestamp: Date
    public var model: String?
    public var isSidechain: Bool
    public var agentID: String?
    public var tokens: TokenCounts
    /// Claude's `usage.speed`; `"fast"` selects fast-mode prices.
    public var speed: String?
    /// The agent's own unit of charge (Copilot AIU).
    public var nativeCost: Double?
    /// The agent's own price in USD. When set it is both the cost and the API-equivalent, and re-pricing never
    /// replaces it.
    public var nativeUSD: Double?
    public var requestMultiplier: Double?
    public var turnIndex: Int?
    public var cwd: String?
    public var gitBranch: String?
    /// The emitting process (OTel `process.pid`), used to find a cwd when the record has none. Not stored.
    public var processID: Int32?

    public init(dedupeKey: String, source: AgentSource, sessionID: String, timestamp: Date, model: String?,
                isSidechain: Bool = false, agentID: String? = nil, tokens: TokenCounts, speed: String? = nil,
                nativeCost: Double? = nil, nativeUSD: Double? = nil, requestMultiplier: Double? = nil,
                turnIndex: Int? = nil, cwd: String? = nil, gitBranch: String? = nil, processID: Int32? = nil) {
        self.dedupeKey = dedupeKey
        self.source = source
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.model = model
        self.isSidechain = isSidechain
        self.agentID = agentID
        self.tokens = tokens
        self.speed = speed
        self.nativeCost = nativeCost
        self.nativeUSD = nativeUSD
        self.requestMultiplier = requestMultiplier
        self.turnIndex = turnIndex
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.processID = processID
    }

    /// Combines two sightings of the same call: the earliest time and the largest token counts.
    public func merged(with other: UsageRecord) -> UsageRecord {
        var result = self
        result.timestamp = min(timestamp, other.timestamp)
        result.tokens = tokens.merged(with: other.tokens)
        result.model = model ?? other.model
        result.speed = speed ?? other.speed
        result.agentID = agentID ?? other.agentID
        result.cwd = cwd ?? other.cwd
        result.gitBranch = gitBranch ?? other.gitBranch
        result.nativeCost = nativeCost.map { max($0, other.nativeCost ?? 0) } ?? other.nativeCost
        result.nativeUSD = nativeUSD.map { max($0, other.nativeUSD ?? 0) } ?? other.nativeUSD
        result.processID = processID ?? other.processID
        return result
    }
}
