import Foundation

public struct CopilotUsageEvent: Sendable, Equatable {
    public var id: Int64
    public var sessionID: String
    public var turnIndex: Int?
    public var agentID: String?
    public var model: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var reasoningTokens: Int
    public var totalNanoAIU: Int64?
    public var requestMultiplier: Double?
    public var tokenDetailsJSON: String?
    public var createdAt: String?

    public init(id: Int64, sessionID: String, turnIndex: Int? = nil, agentID: String? = nil, model: String?,
                inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0,
                reasoningTokens: Int = 0, totalNanoAIU: Int64? = nil, requestMultiplier: Double? = nil,
                tokenDetailsJSON: String? = nil, createdAt: String?) {
        self.id = id
        self.sessionID = sessionID
        self.turnIndex = turnIndex
        self.agentID = agentID
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.totalNanoAIU = totalNanoAIU
        self.requestMultiplier = requestMultiplier
        self.tokenDetailsJSON = tokenDetailsJSON
        self.createdAt = createdAt
    }
}

public struct CopilotSession: Sendable, Equatable {
    public var id: String
    public var cwd: String?
    public var branch: String?
    public var summary: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var turns: Int

    public init(id: String, cwd: String? = nil, branch: String? = nil, summary: String? = nil, createdAt: String? = nil,
                updatedAt: String? = nil, turns: Int = 0) {
        self.id = id
        self.cwd = cwd
        self.branch = branch
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.turns = turns
    }
}

public enum CopilotUsageMapper {
    public static let keyPrefix = "cp:"
    public static let nanoAIUPerAIU = 1e9
    public static let usdPerAIU = 0.01
    public static let titleRank = 2

    public static func batch(events: [CopilotUsageEvent], sessions: [String: CopilotSession]) -> LedgerBatch {
        let usage = events.compactMap { Self.usage($0, session: sessions[$0.sessionID]) }
        let bySession = Dictionary(grouping: usage, by: \.sessionID)
        // Copilot does not enforce its foreign keys; an event without a session row still gets a ledger session.
        let updates = bySession.keys.sorted().map { id in
            sessionUpdate(sessions[id] ?? CopilotSession(id: id), usage: bySession[id] ?? [])
        }
        return LedgerBatch(usage: usage, sessions: updates, origin: keyPrefix)
    }

    public static func usage(_ event: CopilotUsageEvent, session: CopilotSession?) -> UsageRecord? {
        guard let timestamp = date(event.createdAt) ?? date(session?.createdAt) else { return nil }
        let tokens = tokens(input: event.inputTokens, output: event.outputTokens, cacheRead: event.cacheReadTokens,
                            cacheWrite: event.cacheWriteTokens, reasoning: event.reasoningTokens,
                            details: tokenDetails(event.tokenDetailsJSON))
        let nano = event.totalNanoAIU.map(Double.init)
        return UsageRecord(
            dedupeKey: "\(keyPrefix)\(event.sessionID):\(event.id):\(event.createdAt ?? "")",
            source: .copilotCLI, sessionID: event.sessionID, timestamp: timestamp, model: event.model,
            isSidechain: event.agentID != nil, agentID: event.agentID, tokens: tokens,
            nativeCost: nano.map { $0 / nanoAIUPerAIU }, nativeUSD: nano.map { $0 / nanoAIUPerAIU * usdPerAIU },
            requestMultiplier: event.requestMultiplier, turnIndex: event.turnIndex,
            cwd: nonEmpty(session?.cwd), gitBranch: nonEmpty(session?.branch))
    }

    // Copilot counts cache reads and writes inside `inputTokens`.
    public static func tokens(input: Int, output: Int, cacheRead: Int, cacheWrite: Int, reasoning: Int,
                              details: [String: Int] = [:]) -> TokenCounts {
        let cacheRead = details["cache_read"] ?? cacheRead
        let cacheWrite = details["cache_write"] ?? cacheWrite
        let uncached = details["input"] ?? max(0, input - cacheRead - cacheWrite)
        let output = details["output"] ?? output
        // Copilot gives no 5m/1h split; like unsplit Claude writes, the default 5 minute TTL is assumed.
        return TokenCounts(input: uncached, output: output, reasoning: min(reasoning, output), cacheRead: cacheRead,
                           cacheWrite5m: cacheWrite)
    }

    public static func sessionUpdate(_ session: CopilotSession, usage: [UsageRecord] = []) -> SessionUpdate {
        let times = usage.map(\.timestamp)
        let created = date(session.createdAt)
        let updated = date(session.updatedAt)
        let firstAt = ([created].compactMap { $0 } + times).min()
        let lastAt = ([updated, created].compactMap { $0 } + times).max()
        let title = title(session.summary)
        return SessionUpdate(key: SessionKey(source: .copilotCLI, id: session.id), firstAt: firstAt, lastAt: lastAt,
                             cwd: nonEmpty(session.cwd), branch: nonEmpty(session.branch),
                             placeIsAuthoritative: nonEmpty(session.cwd) != nil, title: title,
                             titleRank: title == nil ? 0 : titleRank, prompts: session.turns, resetsTurns: true)
    }

    public static func title(_ summary: String?) -> String? {
        guard let line = summary?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty, !line.hasPrefix("<") else { return nil }
        return line
    }

    public static func date(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return Timestamps.parse(text) ?? Timestamps.parse(text + "Z")
    }

    static func tokenDetails(_ json: String?) -> [String: Int] {
        guard let json, let data = json.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var counts: [String: Int] = [:]
        for item in list {
            guard let type = item["tokenType"] as? String, let count = (item["tokenCount"] as? NSNumber)?.intValue else {
                continue
            }
            counts[type, default: 0] += count
        }
        return counts
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
