import Foundation

/// Claude plan usage windows, as returned by the endpoint Claude Code's /usage screen uses.
/// Note: `/api/oauth/usage` is undocumented and may change without notice.
public struct ClaudeLimits: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        /// Percent used, 0…100.
        public var utilization: Double
        public var resetsAt: Date?
    }

    public var fiveHour: Window?
    public var sevenDay: Window?
    public var sevenDayOpus: Window?
    public var sevenDaySonnet: Window?

    public static func decode(_ data: Data) throws -> ClaudeLimits {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeLimitsError.malformedResponse
        }
        if let nested = root["usage"] as? [String: Any] { root = nested }
        return ClaudeLimits(
            fiveHour: window(root["five_hour"]),
            sevenDay: window(root["seven_day"]),
            sevenDayOpus: window(root["seven_day_opus"]),
            sevenDaySonnet: window(root["seven_day_sonnet"])
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
        guard let dict = raw as? [String: Any],
              let utilization = (dict["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return Window(utilization: min(max(utilization, 0), 100), resetsAt: date(dict["resets_at"]))
    }

    static func date(_ raw: Any?) -> Date? {
        if let number = raw as? NSNumber {
            let value = number.doubleValue
            return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
        }
        guard let text = raw as? String, !text.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        // Fractions longer than milliseconds trip up ISO8601DateFormatter; drop them.
        if let dot = text.firstIndex(of: "."),
           let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            return plain.date(from: String(text[..<dot]) + String(text[zone...]))
        }
        return nil
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
