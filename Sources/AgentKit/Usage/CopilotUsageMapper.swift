import Foundation

/// One `assistant_usage_events` row from Copilot CLI's `session-store.db`.
public struct CopilotUsageEvent: Sendable, Equatable {
    public var id: Int64
    public var sessionID: String
    public var turnIndex: Int?
    public var agentID: String?
    public var model: String?
    /// Copilot's `input_tokens` includes cache reads and cache writes.
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

/// One `sessions` row from Copilot CLI's `session-store.db`, with its count of `turns` rows.
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

/// Turns Copilot CLI's own usage rows into ledger rows. Copilot prices every call itself in nano-AIU, and
/// 1 AIU is $0.01 at API list price (Haiku 4.5 costs 100 / 500 AIU per 1M tokens, i.e. $1 / $5), so its figure
/// is used as both the cost and the API-equivalent.
public enum CopilotUsageMapper {
    public static let nanoAIUPerAIU = 1e9
    public static let usdPerAIU = 0.01
    /// Copilot's summaries are generated, like Claude Code's AI titles.
    public static let titleRank = 2

    public static func batch(events: [CopilotUsageEvent], sessions: [String: CopilotSession]) -> LedgerBatch {
        let usage = events.compactMap { usage($0, session: sessions[$0.sessionID]) }
        let bySession = Dictionary(grouping: usage, by: \.sessionID)
        // Copilot does not enforce its foreign keys; an event without a session row still gets a ledger session.
        let updates = bySession.keys.sorted().map { id in
            sessionUpdate(sessions[id] ?? CopilotSession(id: id), usage: bySession[id] ?? [])
        }
        return LedgerBatch(usage: usage, sessions: updates)
    }

    /// Nil when the row has no usable time at all, since a ledger row must have one.
    public static func usage(_ event: CopilotUsageEvent, session: CopilotSession?) -> UsageRecord? {
        guard let timestamp = date(event.createdAt) ?? date(session?.createdAt) else { return nil }
        let details = tokenDetails(event.tokenDetailsJSON)
        let cacheRead = details["cache_read"] ?? event.cacheReadTokens
        let cacheWrite = details["cache_write"] ?? event.cacheWriteTokens
        let input = details["input"] ?? max(0, event.inputTokens - cacheRead - cacheWrite)
        let output = details["output"] ?? event.outputTokens
        // Copilot gives no 5m/1h split; like unsplit Claude writes, the default 5 minute TTL is assumed.
        let tokens = TokenCounts(input: input, output: output, reasoning: min(event.reasoningTokens, output),
                                 cacheRead: cacheRead, cacheWrite5m: cacheWrite)
        let nano = event.totalNanoAIU.map(Double.init)
        return UsageRecord(
            dedupeKey: "cp:\(event.sessionID):\(event.id):\(event.createdAt ?? "")",
            source: .copilotCLI, sessionID: event.sessionID, timestamp: timestamp, model: event.model,
            isSidechain: event.agentID != nil, agentID: event.agentID, tokens: tokens,
            nativeCost: nano.map { $0 / nanoAIUPerAIU }, nativeUSD: nano.map { $0 / nanoAIUPerAIU * usdPerAIU },
            requestMultiplier: event.requestMultiplier, turnIndex: event.turnIndex,
            cwd: nonEmpty(session?.cwd), gitBranch: nonEmpty(session?.branch))
    }

    /// `usage` widens first/last activity beyond the session row's own timestamps.
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

    /// The first line of the summary. Empty summaries and harness-injected text (`<…>`) never name a session.
    public static func title(_ summary: String?) -> String? {
        guard let line = summary?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty, !line.hasPrefix("<") else { return nil }
        return line
    }

    /// ISO 8601 (`2026-09-17T17:45:32.462Z`) or SQLite's `datetime('now')` (`2026-09-17 17:45:32`, UTC).
    public static func date(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return Timestamps.parse(text) ?? Timestamps.parse(text + "Z")
    }

    /// `tokenType` → `tokenCount` from `token_details_json`; empty when absent or malformed.
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
