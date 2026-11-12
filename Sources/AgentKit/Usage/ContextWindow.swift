import Foundation

public struct SessionLastCall: Sendable, Equatable {
    public var key: SessionKey
    public var model: String?
    public var timestamp: Date
    public var tokens: TokenCounts
    public var contextLimit: Int?

    public init(key: SessionKey, model: String?, timestamp: Date, tokens: TokenCounts, contextLimit: Int? = nil) {
        self.key = key
        self.model = model
        self.timestamp = timestamp
        self.tokens = tokens
        self.contextLimit = contextLimit
    }
}

public struct ContextWindow: Sendable, Equatable {
    public static let standard = 200_000
    public static let extended = 1_000_000
    public static let warnFraction = 0.8

    public var used: Int
    public var limit: Int

    public init(used: Int, limit: Int) {
        self.used = max(used, 0)
        self.limit = max(limit, 1)
    }

    public init?(used: Int, model: String?, liveModel: String? = nil) {
        guard let limit = Self.limit(model: model, liveModel: liveModel, used: used) else { return nil }
        self.init(used: used, limit: limit)
    }

    // A reported window (Codex) counts the reply too: Codex's `tokens_in_context_window` is the call's total.
    public init?(lastCall: SessionLastCall, liveModel: String? = nil) {
        if let limit = lastCall.contextLimit, limit > 0 {
            self.init(used: lastCall.tokens.total, limit: limit)
            return
        }
        self.init(used: lastCall.tokens.promptTokens, model: lastCall.model, liveModel: liveModel)
    }

    public var fraction: Double { min(Double(used) / Double(limit), 1) }
    public var remaining: Int { max(limit - used, 0) }
    public var isWarning: Bool { fraction >= Self.warnFraction }

    // Only a hook's model name (`liveModel`) can carry `[1m]`; the transcript's API model id never does.
    public static func limit(model: String?, liveModel: String? = nil, used: Int = 0) -> Int? {
        let names = [model, liveModel].compactMap { $0?.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard names.contains(where: { $0.contains("claude") }) else { return nil }
        if names.contains(where: { $0.contains("[1m]") || hasNativeExtendedWindow($0) }) { return extended }
        // A prompt past 200k that went through proves the larger window, whatever the id says.
        return used > standard ? extended : standard
    }

    static func hasNativeExtendedWindow(_ model: String) -> Bool {
        guard let (family, version) = ModelName.claudeVersion(model) else { return false }
        let major = version.first ?? 0
        let minor = version.dropFirst().first ?? 0
        switch family {
        case "fable": return true
        case "sonnet": return major >= 5
        case "haiku": return (major, minor) >= (5, 5)
        case "opus": return (major, minor) >= (4, 7)
        default: return false
        }
    }
}
