import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var port = 4318
    public var vllmBaseURL = ""
    public var vllmName = ""
    public var claudeLimitsEnabled = false
    public var notificationsEnabled = true
    /// Models whose name contains one of these (case-insensitive) run locally: $0 cost, API-equivalent at `referenceModel`.
    public var localModelPatterns = PricingTable.defaultLocalModelPatterns
    public var referenceModel = PricingTable.defaultReferenceModel
    /// Claude Code's config directory; empty means `~/.claude`.
    public var claudeConfigDir = ""

    public init() {}

    /// Every key is optional and a wrongly typed value falls back to its default, so settings saved by an
    /// older or newer build keep the rest of their values instead of resetting wholesale.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        port = container.lenient(Int.self, .port) ?? defaults.port
        vllmBaseURL = container.lenient(String.self, .vllmBaseURL) ?? defaults.vllmBaseURL
        vllmName = container.lenient(String.self, .vllmName) ?? defaults.vllmName
        claudeLimitsEnabled = container.lenient(Bool.self, .claudeLimitsEnabled) ?? defaults.claudeLimitsEnabled
        notificationsEnabled = container.lenient(Bool.self, .notificationsEnabled) ?? defaults.notificationsEnabled
        localModelPatterns = container.lenient([String].self, .localModelPatterns) ?? defaults.localModelPatterns
        referenceModel = container.lenient(String.self, .referenceModel) ?? defaults.referenceModel
        claudeConfigDir = container.lenient(String.self, .claudeConfigDir) ?? defaults.claudeConfigDir
    }

    public static func decode(_ data: Data?) -> AppSettings {
        guard let data, let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
