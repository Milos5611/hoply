import Foundation

/// Claude plan usage windows, as returned by the endpoint Claude Code's /usage screen uses.
/// Note: `/api/oauth/usage` is undocumented and may change without notice, so everything beyond `five_hour` and
/// `seven_day` is decoded only when present and well formed, and never fails the decode.
public struct ClaudeLimits: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        /// Percent used, 0…100.
        public var utilization: Double
        public var resetsAt: Date?

        public init(utilization: Double, resetsAt: Date?) {
            self.utilization = utilization
            self.resetsAt = resetsAt
        }
    }

    /// A weekly window for one model (the Agent SDK's `model_scoped`, or a `weekly_scoped` entry of `limits`).
    public struct ScopedWindow: Sendable, Equatable {
        /// As the API names it, e.g. "Opus".
        public var displayName: String
        public var kind: LimitKind
        public var window: Window
    }

    /// Pay-as-you-go usage past the plan. The API gives no unit for the amounts, so they stay raw numbers.
    public struct ExtraUsage: Sendable, Equatable {
        public var isEnabled: Bool?
        public var usedCredits: Double?
        public var monthlyLimit: Double?
        /// As sent, percent 0…100.
        public var utilization: Double?

        /// `utilization`, else used ÷ limit.
        public var percentUsed: Double? {
            if let utilization { return utilization }
            guard let usedCredits, let monthlyLimit, monthlyLimit > 0, usedCredits >= 0 else { return nil }
            return min(usedCredits / monthlyLimit * 100, 100)
        }
    }

    /// A spend budget (seen on Enterprise plans through the Agent SDK).
    public struct Spend: Sendable, Equatable {
        public struct Money: Sendable, Equatable {
            public var amountMinor: Double
            /// As sent; not checked against any list.
            public var currency: String
            public var exponent: Int

            /// `amountMinor ÷ 10^exponent`.
            public var amount: Double { amountMinor / pow(10, Double(exponent)) }
        }

        public var enabled: Bool?
        public var used: Money?
        public var limit: Money?

        /// used ÷ limit, only when both are in the same currency and scale.
        public var percentUsed: Double? {
            guard let used, let limit, used.currency == limit.currency, used.exponent == limit.exponent,
                  limit.amountMinor > 0, used.amountMinor >= 0 else { return nil }
            return min(used.amountMinor / limit.amountMinor * 100, 100)
        }
    }

    public var fiveHour: Window?
    public var sevenDay: Window?
    public var sevenDayOpus: Window?
    public var sevenDaySonnet: Window?
    public var scoped: [ScopedWindow] = []
    public var extraUsage: ExtraUsage?
    public var spend: Spend?
    /// Top-level keys of the response this build doesn't decode, sorted; surface them once to discover new windows.
    public var unrecognizedKeys: [String] = []

    static let knownKeys: Set<String> = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet",
                                         "model_scoped", "limits", "extra_usage", "spend"]

    public static func decode(_ data: Data) throws -> ClaudeLimits {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeLimitsError.malformedResponse
        }
        for wrapper in ["usage", "rate_limits"] {
            if let nested = root[wrapper] as? [String: Any] { root = nested }
        }
        return ClaudeLimits(
            fiveHour: window(root["five_hour"]),
            sevenDay: window(root["seven_day"]),
            sevenDayOpus: window(root["seven_day_opus"]),
            sevenDaySonnet: window(root["seven_day_sonnet"]),
            scoped: scopedWindows(modelScoped: root["model_scoped"], limits: root["limits"]),
            extraUsage: extraUsage(root["extra_usage"]),
            spend: spend(root["spend"]),
            unrecognizedKeys: root.keys.filter { !knownKeys.contains($0) }.sorted()
        )
    }

    /// Extracts the OAuth access token from the JSON Claude Code keeps in the macOS Keychain
    /// (service "Claude Code-credentials").
    public static func accessToken(fromCredentials data: Data, now: Date = Date()) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ClaudeLimitsError.noCredentials
        }
        if let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue {
            let expiry = Date(timeIntervalSince1970: expires > 10_000_000_000 ? expires / 1000 : expires)
            if expiry <= now { throw ClaudeLimitsError.tokenExpired }
        }
        return token
    }

    static func window(_ raw: Any?) -> Window? {
        guard let dict = raw as? [String: Any], let utilization = number(dict["utilization"]) else { return nil }
        return Window(utilization: min(max(utilization, 0), 100), resetsAt: Timestamps.date(dict["resets_at"]))
    }

    /// `model_scoped: [{display_name, utilization, resets_at}]` and `limits: [{kind: "weekly_scoped", percent,
    /// resets_at, scope: {model: {display_name}}}]`; the first entry of a kind wins.
    static func scopedWindows(modelScoped: Any?, limits: Any?) -> [ScopedWindow] {
        var entries: [(name: String?, utilization: Any?, resetsAt: Any?)] = []
        for case let entry as [String: Any] in (modelScoped as? [Any]) ?? [] {
            entries.append((entry["display_name"] as? String, entry["utilization"], entry["resets_at"]))
        }
        for case let entry as [String: Any] in (limits as? [Any]) ?? [] where entry["kind"] as? String == "weekly_scoped" {
            let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any]
            entries.append((model?["display_name"] as? String, entry["percent"], entry["resets_at"]))
        }
        var result: [ScopedWindow] = []
        for entry in entries {
            guard let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let kind = LimitKind.scoped(displayName: name), !result.contains(where: { $0.kind == kind }),
                  let window = window(["utilization": entry.utilization as Any, "resets_at": entry.resetsAt as Any])
            else { continue }
            result.append(ScopedWindow(displayName: name, kind: kind, window: window))
        }
        return result
    }

    static func extraUsage(_ raw: Any?) -> ExtraUsage? {
        guard let dict = raw as? [String: Any] else { return nil }
        return ExtraUsage(isEnabled: bool(dict["is_enabled"]), usedCredits: number(dict["used_credits"]),
                          monthlyLimit: number(dict["monthly_limit"]),
                          utilization: number(dict["utilization"]).map { min(max($0, 0), 100) })
    }

    static func spend(_ raw: Any?) -> Spend? {
        guard let dict = raw as? [String: Any] else { return nil }
        func money(_ raw: Any?) -> Spend.Money? {
            guard let money = raw as? [String: Any], let amount = number(money["amount_minor"]),
                  let currency = (money["currency"] as? String)?.trimmingCharacters(in: .whitespaces), !currency.isEmpty,
                  let exponent = number(money["exponent"]), exponent >= 0, exponent <= 18,
                  exponent == exponent.rounded() else { return nil }
            return Spend.Money(amountMinor: amount, currency: currency, exponent: Int(exponent))
        }
        return Spend(enabled: bool(dict["enabled"]), used: money(dict["used"]), limit: money(dict["limit"]))
    }

    /// A finite JSON number; booleans don't count.
    static func number(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    static func bool(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

public enum ClaudeLimitsError: Error, LocalizedError, Equatable {
    case noCredentials
    case tokenExpired
    case malformedResponse
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .noCredentials: return "Claude Code login not found in Keychain"
        case .tokenExpired: return "Login expired, open Claude Code to refresh it"
        case .malformedResponse: return "Unexpected response from Anthropic"
        case .http(let status): return "Anthropic returned HTTP \(status)"
        }
    }
}

#if os(macOS)
/// Reads Claude Code's login from the Keychain via /usr/bin/security (so the Keychain
/// "Always Allow" grant survives rebuilds of this app) and fetches the plan limits.
public struct ClaudeLimitsClient: Sendable {
    public init() {}

    public func fetch() async throws -> ClaudeLimits {
        let token = try readAccessToken()
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw ClaudeLimitsError.malformedResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Hoply/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeLimitsError.malformedResponse }
        guard http.statusCode == 200 else { throw ClaudeLimitsError.http(http.statusCode) }
        return try ClaudeLimits.decode(data)
    }

    func readAccessToken() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ClaudeLimitsError.noCredentials }
        return try ClaudeLimits.accessToken(fromCredentials: data)
    }
}
#endif
