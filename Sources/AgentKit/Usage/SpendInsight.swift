import Foundation

public struct ModelEfficiency: Sendable, Equatable, Identifiable {
    public var model: String
    public var totals: LedgerTotals
    public var fastCalls: Int
    public var fastUSD: Double
    public var fastPremiumUSD: Double

    public init(model: String, totals: LedgerTotals = .zero, fastCalls: Int = 0, fastUSD: Double = 0,
                fastPremiumUSD: Double = 0) {
        self.model = model
        self.totals = totals
        self.fastCalls = fastCalls
        self.fastUSD = fastUSD
        self.fastPremiumUSD = fastPremiumUSD
    }

    public var id: String { model }
    public var cacheHitRate: Double? { Self.cacheHitRate(totals.tokens) }

    public var usdPerMillionTokens: Double? {
        guard totals.tokens.total > 0, !totals.hasUnpriced else { return nil }
        return totals.apiEquivUSD / Double(totals.tokens.total) * 1_000_000
    }

    public static func cacheHitRate(_ tokens: TokenCounts) -> Double? {
        guard tokens.promptTokens > 0 else { return nil }
        return Double(tokens.cacheRead) / Double(tokens.promptTokens)
    }
}

public struct UnpricedModel: Sendable, Equatable, Identifiable {
    public var model: String
    public var calls: Int
    public var tokens: TokenCounts
    public var firstSeen: Date?
    public var lastSeen: Date?

    public init(model: String, calls: Int, tokens: TokenCounts, firstSeen: Date? = nil, lastSeen: Date? = nil) {
        self.model = model
        self.calls = calls
        self.tokens = tokens
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }

    public var id: String { model }
}

public struct SubagentInfo: Sendable, Equatable, Hashable {
    public var session: SessionKey
    public var agentID: String
    public var agentType: String?
    public var description: String?

    public init(session: SessionKey, agentID: String, agentType: String? = nil, description: String? = nil) {
        self.session = session
        self.agentID = agentID
        self.agentType = agentType
        self.description = description
    }

    public init?(meta: Data, session: SessionKey, agentID: String) {
        guard let json = try? JSONSerialization.jsonObject(with: meta) as? [String: Any] else { return nil }
        func text(_ key: String) -> String? {
            let value = (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        self.init(session: session, agentID: agentID, agentType: text("agentType"), description: text("description"))
        guard agentType != nil || description != nil else { return nil }
    }
}

public struct SubagentSummary: Sendable, Equatable, Identifiable {
    public var agentID: String
    public var agentType: String?
    public var description: String?
    public var model: String?
    public var firstAt: Date
    public var lastAt: Date
    public var totals: LedgerTotals

    public init(agentID: String, agentType: String? = nil, description: String? = nil, model: String? = nil,
                firstAt: Date, lastAt: Date, totals: LedgerTotals) {
        self.agentID = agentID
        self.agentType = agentType
        self.description = description
        self.model = model
        self.firstAt = firstAt
        self.lastAt = lastAt
        self.totals = totals
    }

    public var id: String { agentID }
    public var name: String { agentType ?? description ?? "Subagent" }
    public var duration: TimeInterval { lastAt.timeIntervalSince(firstAt) }
}
