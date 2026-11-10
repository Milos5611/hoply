import Foundation

public struct RemoteEndpoint: Sendable, Equatable {
    public let baseURL: URL
    public var name: String

    public init?(baseURL raw: String, name: String) {
        guard let sanitized = Self.sanitizedBaseURL(raw), let url = URL(string: sanitized) else { return nil }
        baseURL = url
        self.name = name
    }

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

    public var host: String { baseURL.host()?.lowercased() ?? "" }

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

    public func request(path: String, credentials: RemoteCredentials, timeout: TimeInterval = 10,
                        accept: String = "application/json") throws -> URLRequest {
        guard let url = url(path: path) else { throw RemoteError(.invalidURL, endpoint: name) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Hoply", forHTTPHeaderField: "User-Agent")
        if let raw = credentials.bearerToken {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw RemoteError(.missingToken, endpoint: name) }
            guard Self.isHeaderSafe(token) else { throw RemoteError(.invalidToken, endpoint: name) }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in credentials.headers {
            guard Self.isHeaderName(field) else { throw RemoteError(.invalidHeader(name: field), endpoint: name) }
            guard Self.isHeaderSafe(value) else { throw RemoteError(.invalidToken, endpoint: name) }
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    static let refusedHeaderNames: Set<String> = ["host", "content-length", "connection", "transfer-encoding", "upgrade"]

    public static func isHeaderName(_ name: String) -> Bool {
        let symbols = Set("!#$%&'*+-.^_`|~")
        return !name.isEmpty && !refusedHeaderNames.contains(name.lowercased())
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || symbols.contains($0)) }
    }

    static func isHeaderSafe(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
    }

    public func classify(_ response: URLResponse, body: Data,
                         auth: ModelServerAuthKind = .bearer) -> Result<Data, RemoteError> {
        guard let http = response as? HTTPURLResponse else { return .failure(RemoteError(.http(status: 0), endpoint: name)) }
        return classify(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"),
                        location: http.value(forHTTPHeaderField: "Location"), body: body, auth: auth,
                        challenge: http.value(forHTTPHeaderField: "WWW-Authenticate"))
    }

    public func classify(status: Int, contentType: String?, location: String?, body: Data,
                         auth: ModelServerAuthKind = .bearer, challenge: String? = nil) -> Result<Data, RemoteError> {
        func fail(_ kind: RemoteError.Kind) -> Result<Data, RemoteError> { .failure(RemoteError(kind, endpoint: name)) }
        let html = Self.isHTML(contentType: contentType, body: body)
        let viaAccess = auth == .cloudflareAccess
        if (300..<400).contains(status) {
            let target = location.flatMap { URL(string: $0, relativeTo: baseURL) }
            let host = target?.host()?.lowercased()
            if let host, Self.isAccessHost(host) {
                return fail(viaAccess ? .accessRejected(status: status) : .accessRequired(host: host))
            }
            if baseURL.scheme == "http", target?.scheme?.lowercased() == "https", host == self.host {
                return fail(.httpsRequired)
            }
            return fail(.redirected(status: status, host: host))
        }
        if html, Self.mentionsAccess(body) {
            return fail(viaAccess ? .accessRejected(status: status) : .accessRequired(host: nil))
        }
        if status == 401 || status == 403 {
            // Access answers a bad service token with a 403 page; JSON behind a passing token is the origin's own answer.
            if viaAccess, status == 403 || html { return fail(.accessRejected(status: status)) }
            switch auth {
            case .basic:
                return fail(.credentialsRejected(status: status))
            case .none where !html || status == 401:
                return fail(status == 401 ? .authRequired(scheme: Self.challengeScheme(challenge)) : .http(status: status))
            case .none:
                return fail(.htmlPage(status: status))
            case .bearer, .cloudflareAccess, .headers:
                // sparkDash-era callers classify a 403 page as a login page in front of the service.
                if html, auth == .bearer, status == 403 { return fail(.htmlPage(status: status)) }
                return fail(.tokenRejected(status: status, message: html ? nil : Self.errorMessage(body)))
            }
        }
        if html { return fail(.htmlPage(status: status)) }
        guard (200..<300).contains(status) else { return fail(.http(status: status)) }
        return .success(body)
    }

    static func isAccessHost(_ host: String) -> Bool {
        host == "cloudflareaccess.com" || host.hasSuffix(".cloudflareaccess.com")
    }

    static func mentionsAccess(_ body: Data) -> Bool {
        let text = String(decoding: body.prefix(8_192), as: UTF8.self).lowercased()
        return text.contains("cloudflareaccess.com") || text.contains("cloudflare access")
    }

    static func challengeScheme(_ challenge: String?) -> String? {
        let scheme = challenge?.split(whereSeparator: { $0 == " " || $0 == "," }).first.map { $0.lowercased() }
        return scheme.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func isHTML(contentType: String?, body: Data) -> Bool {
        if let contentType, contentType.lowercased().contains("html") { return true }
        let head = String(decoding: body.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return head.lowercased().hasPrefix("<!doctype") || head.lowercased().hasPrefix("<html")
    }

    static func errorMessage(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let nested = (object["error"] as? [String: Any])?["message"] as? String
        let message = (object["error"] as? String) ?? nested ?? (object["message"] as? String)
            ?? (object["detail"] as? String)
        return message.map { String($0.prefix(200)) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}

public struct RemoteCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var bearerToken: String?
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
        case missingSecret(what: String)
        case invalidHeader(name: String)
        case tokenRejected(status: Int, message: String?)
        case credentialsRejected(status: Int)
        case authRequired(scheme: String?)
        case accessRejected(status: Int)
        case accessRequired(host: String?)
        case htmlPage(status: Int)
        case redirected(status: Int, host: String?)
        case httpsRequired
        case http(status: Int)
        case noModelServer
        case insecureHTTPBlocked
        case timedOut
        case hostNotFound
        case connectionRefused
        case tlsFailure(String)
        case transport(String)
    }

    public var kind: Kind
    public var endpoint: String

    public init(_ kind: Kind, endpoint: String) {
        self.kind = kind
        self.endpoint = endpoint
    }

    public init(_ error: URLError, endpoint: String) {
        self.init(Kind(code: error.code.rawValue, description: error.localizedDescription), endpoint: endpoint)
    }

    public var errorDescription: String? {
        switch kind {
        case .invalidURL: return "The \(endpoint) URL isn't a valid http(s) address"
        case .missingToken: return "No \(endpoint) token saved"
        case .invalidToken: return "The \(endpoint) token contains characters that can't be sent"
        case .missingSecret(let what): return "No \(what) saved for \(endpoint)"
        case .invalidHeader(let name): return "\"\(name)\" can't be sent as a header name"
        case .tokenRejected(let status, _): return "\(endpoint) rejected the token (HTTP \(status))"
        case .credentialsRejected(let status): return "\(endpoint) rejected the user name or password (HTTP \(status))"
        case .authRequired(let scheme):
            return scheme == "basic" ? "\(endpoint) needs a user name and password" : "\(endpoint) needs an API key"
        case .accessRejected: return "Cloudflare Access rejected the service token for \(endpoint)"
        case .accessRequired: return "\(endpoint) is behind Cloudflare Access; add a service token"
        case .htmlPage: return "\(endpoint) returned a web page instead of data; check the URL"
        case .redirected(_, let host):
            return "\(endpoint) redirected to \(host ?? "another address"); check the URL, or a login page may be in front of it"
        case .httpsRequired: return "\(endpoint) only answers over https; change the URL to https://"
        case .http(let status): return "\(endpoint) returned HTTP \(status)"
        case .noModelServer: return "\(endpoint) answered, but no model server API was found there; check the URL and port"
        case .insecureHTTPBlocked:
            return "macOS blocks plain http to \(endpoint) because it isn't on the local network; use https://"
        case .timedOut: return "\(endpoint) didn't answer in time"
        case .hostNotFound: return "The \(endpoint) host name couldn't be found"
        case .connectionRefused: return "Nothing is listening at the \(endpoint) address"
        case .tlsFailure(let reason): return "No secure connection to \(endpoint): \(reason)"
        case .transport(let reason): return "\(endpoint) is unreachable: \(reason)"
        }
    }

    public var isUnreachable: Bool {
        switch kind {
        case .timedOut, .hostNotFound, .connectionRefused, .transport: return true
        case .http(let status): return (502...504).contains(status)
        default: return false
        }
    }

    public var isAuthFailure: Bool {
        switch kind {
        case .missingToken, .invalidToken, .missingSecret, .invalidHeader, .tokenRejected, .credentialsRejected,
             .authRequired, .accessRejected, .accessRequired:
            return true
        default: return false
        }
    }
}

extension RemoteError.Kind {
    public init(code: Int, description: String) {
        switch code {
        case URLError.Code.appTransportSecurityRequiresSecureConnection.rawValue: self = .insecureHTTPBlocked
        case URLError.Code.timedOut.rawValue: self = .timedOut
        case URLError.Code.cannotFindHost.rawValue, URLError.Code.dnsLookupFailed.rawValue: self = .hostNotFound
        case URLError.Code.cannotConnectToHost.rawValue: self = .connectionRefused
        case URLError.Code.serverCertificateUntrusted.rawValue, URLError.Code.serverCertificateHasUnknownRoot.rawValue:
            self = .tlsFailure("its certificate isn't trusted (self-signed or a private CA)")
        case URLError.Code.serverCertificateHasBadDate.rawValue, URLError.Code.serverCertificateNotYetValid.rawValue:
            self = .tlsFailure("its certificate is expired or not valid yet")
        case URLError.Code.clientCertificateRequired.rawValue, URLError.Code.clientCertificateRejected.rawValue:
            self = .tlsFailure("it asks for a client certificate")
        case URLError.Code.secureConnectionFailed.rawValue:
            self = .tlsFailure("the TLS handshake failed; the port may speak plain http")
        default: self = .transport(description)
        }
    }
}

public enum SparkDash {
    public static let name = "sparkDash"
    public static let fleetEnergy = "/api/fleet-energy"

    public static func endpoint(settings: AppSettings) -> RemoteEndpoint? {
        RemoteEndpoint(baseURL: settings.sparkDashURL, name: name)
    }

    public static func sparkPath(_ spark: String, _ route: String) -> String? {
        let id = spark.trimmingCharacters(in: .whitespacesAndNewlines)
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard !id.isEmpty, let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        let suffix = route.hasPrefix("/") ? String(route.dropFirst()) : route
        return "/api/sparks/\(encoded)" + (suffix.isEmpty ? "" : "/\(suffix)")
    }
}
