import Foundation

/// A remote HTTP service Hoply reads with a secret (sparkDash's Bearer token now; M1 adds Cloudflare Access
/// headers through `RemoteCredentials.headers`). Builds requests and classifies responses; the transport is
/// AgentSystem's `MetricsClient`. Secrets only ever travel in headers, never in a URL.
public struct RemoteEndpoint: Sendable, Equatable {
    /// Scheme, host, port and an optional path prefix; no query, fragment or user info.
    public let baseURL: URL
    /// Names the service in messages, e.g. "sparkDash".
    public var name: String

    /// Nil unless `raw` is an http(s) URL with a host. A query, fragment or user info is dropped, so a pasted
    /// `?token=…` never ends up in a request.
    public init?(baseURL raw: String, name: String) {
        guard let sanitized = Self.sanitizedBaseURL(raw), let url = URL(string: sanitized) else { return nil }
        baseURL = url
        self.name = name
    }

    /// What to store as the endpoint's URL setting: `raw` without query, fragment, user info or trailing slash.
    public static func sanitizedBaseURL(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string
    }

    /// The Keychain account for this endpoint's secrets.
    public var host: String { baseURL.host()?.lowercased() ?? "" }

    /// `path` (with an optional query) under the base URL. Query items that look like credentials are dropped.
    public func url(path: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let route = parts.first.map(String.init) ?? ""
        components.percentEncodedPath += route.hasPrefix("/") || route.isEmpty ? route : "/" + route
        if parts.count == 2 {
            let items = (URLComponents(string: "?" + parts[1])?.queryItems ?? [])
                .filter { !Self.credentialQueryNames.contains($0.name.lowercased()) }
            components.queryItems = items.isEmpty ? nil : items
        }
        return components.url
    }

    static let credentialQueryNames: Set<String> = ["token", "access_token", "api_key", "apikey", "secret"]

    public func request(path: String, credentials: RemoteCredentials, timeout: TimeInterval = 10) throws -> URLRequest {
        guard let url = url(path: path) else { throw RemoteError(.invalidURL, endpoint: name) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Hoply", forHTTPHeaderField: "User-Agent")
        if let raw = credentials.bearerToken {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw RemoteError(.missingToken, endpoint: name) }
            guard Self.isHeaderSafe(token) else { throw RemoteError(.invalidToken, endpoint: name) }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in credentials.headers {
            guard Self.isHeaderSafe(value) else { throw RemoteError(.invalidToken, endpoint: name) }
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    /// Printable ASCII only, so a pasted secret can't smuggle in another header line.
    static func isHeaderSafe(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
    }

    public func classify(_ response: URLResponse, body: Data) -> Result<Data, RemoteError> {
        guard let http = response as? HTTPURLResponse else { return .failure(RemoteError(.http(status: 0), endpoint: name)) }
        return classify(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"),
                        location: http.value(forHTTPHeaderField: "Location"), body: body)
    }

    /// Redirects are never followed (a login page in front of the service answers with one), so a 3xx arrives
    /// here. An HTML body means a web page (the dashboard's own UI, or a login page), not the JSON API.
    public func classify(status: Int, contentType: String?, location: String?, body: Data) -> Result<Data, RemoteError> {
        if (300..<400).contains(status) {
            let target = location.flatMap { URL(string: $0, relativeTo: baseURL)?.host() }
            return .failure(RemoteError(.redirected(status: status, host: target), endpoint: name))
        }
        if Self.isHTML(contentType: contentType, body: body) {
            return .failure(RemoteError(.htmlPage(status: status), endpoint: name))
        }
        if status == 401 || status == 403 {
            return .failure(RemoteError(.tokenRejected(status: status, message: Self.errorMessage(body)), endpoint: name))
        }
        guard (200..<300).contains(status) else { return .failure(RemoteError(.http(status: status), endpoint: name)) }
        return .success(body)
    }

    static func isHTML(contentType: String?, body: Data) -> Bool {
        if let contentType, contentType.lowercased().contains("html") { return true }
        let head = String(decoding: body.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return head.lowercased().hasPrefix("<!doctype") || head.lowercased().hasPrefix("<html")
    }

    /// The server's own `error` or `message` string, e.g. sparkDash's "Authentication required".
    static func errorMessage(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let message = (object["error"] as? String) ?? (object["message"] as? String)
        return message.map { String($0.prefix(200)) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// What a request carries besides the URL. Never printed: `description` hides the values.
public struct RemoteCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var bearerToken: String?
    /// Extra header fields (M1: `CF-Access-Client-Id` / `CF-Access-Client-Secret`).
    public var headers: [String: String]

    public init(bearerToken: String? = nil, headers: [String: String] = [:]) {
        self.bearerToken = bearerToken
        self.headers = headers
    }

    public var description: String {
        "RemoteCredentials(bearerToken: \(bearerToken == nil ? "none" : "redacted"), headers: \(headers.keys.sorted()))"
    }

    public var debugDescription: String { description }
}

public struct RemoteError: Error, Equatable, Sendable, LocalizedError {
    public enum Kind: Equatable, Sendable {
        case invalidURL
        case missingToken
        case invalidToken
        /// 401/403 with a JSON (or empty) body: the service saw the token and refused it.
        case tokenRejected(status: Int, message: String?)
        /// A web page instead of JSON: a wrong URL or path, or a login page in front of the service.
        case htmlPage(status: Int)
        /// `host` is where it pointed (only the host, since a login URL can carry our address in its query).
        case redirected(status: Int, host: String?)
        case http(status: Int)
        case transport(String)
    }

    public var kind: Kind
    /// The endpoint's name, for the message.
    public var endpoint: String

    public init(_ kind: Kind, endpoint: String) {
        self.kind = kind
        self.endpoint = endpoint
    }

    public var errorDescription: String? {
        switch kind {
        case .invalidURL: return "The \(endpoint) URL isn't a valid http(s) address"
        case .missingToken: return "No \(endpoint) token saved"
        case .invalidToken: return "The \(endpoint) token contains characters that can't be sent"
        case .tokenRejected(let status, _): return "\(endpoint) rejected the token (HTTP \(status))"
        case .htmlPage: return "\(endpoint) returned a web page instead of data; check the URL"
        case .redirected(_, let host):
            return "\(endpoint) redirected to \(host ?? "another address"); check the URL, or a login page may be in front of it"
        case .http(let status): return "\(endpoint) returned HTTP \(status)"
        case .transport(let reason): return "\(endpoint) is unreachable: \(reason)"
        }
    }
}

/// sparkDash (on the ZGX) routes and settings. Its JSON shapes are decoded once a capture exists.
public enum SparkDash {
    public static let name = "sparkDash"
    public static let fleetEnergy = "/api/fleet-energy"

    /// From `sparkDashURL`; nil while it is blank or not an http(s) URL.
    public static func endpoint(settings: AppSettings) -> RemoteEndpoint? {
        RemoteEndpoint(baseURL: settings.sparkDashURL, name: name)
    }

    /// `/api/sparks/<spark>/<route>`, e.g. `sparkPath("zgx-ff24", "metrics")`; nil for a blank spark id.
    public static func sparkPath(_ spark: String, _ route: String) -> String? {
        let id = spark.trimmingCharacters(in: .whitespacesAndNewlines)
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard !id.isEmpty, let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        let suffix = route.hasPrefix("/") ? String(route.dropFirst()) : route
        return "/api/sparks/\(encoded)" + (suffix.isEmpty ? "" : "/\(suffix)")
    }
}
