import AgentKit
import Foundation
import Observation

@MainActor
@Observable
final class ModelServerEditor: Identifiable {
    struct Header: Identifiable, Equatable {
        let id = UUID()
        var name = ""
        var value = ""
    }

    enum SignIn: String, CaseIterable, Identifiable {
        case none
        case bearer
        case basic
        case cloudflareAccess

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return "None"
            case .bearer: return "API key / Bearer token"
            case .basic: return "User name and password"
            case .cloudflareAccess: return "Cloudflare Access service token"
            }
        }
    }

    enum Test: Equatable {
        case idle
        case running
        case done(ModelServerProbe)
    }

    struct Note: Equatable, Identifiable {
        var text: String
        var isWarning: Bool
        var id: String { text }
    }

    let id: String
    let isNew: Bool
    var name: String
    var url: String
    var engine: ModelEngine?
    var signIn: SignIn
    var username: String
    var clientID: String
    var token = ""
    var password = ""
    var clientSecret = ""
    var headers: [Header]
    var metricsPath: String
    var offlineAlerts: Bool
    var enabled: Bool
    var stored = ModelServers.StoredSecrets()
    var test: Test = .idle
    var saveError: String?
    var isSaving = false
    var showsAdvanced: Bool
    var showsEndpoints = false

    init(_ server: ModelServer, isNew: Bool) {
        id = server.id
        self.isNew = isNew
        name = server.name
        url = server.baseURL
        engine = server.engine
        switch server.auth.kind {
        case .none, .headers: signIn = .none
        case .bearer: signIn = .bearer
        case .basic: signIn = .basic
        case .cloudflareAccess: signIn = .cloudflareAccess
        }
        username = server.auth.username
        clientID = server.auth.clientID
        headers = server.auth.headerNames.map { Header(name: $0) }
        metricsPath = server.metricsPath
        offlineAlerts = server.offlineAlerts
        enabled = server.enabled
        showsAdvanced = !server.metricsPath.isEmpty || !server.offlineAlerts
    }

    var normalizedURL: String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("://") else { return trimmed }
        return "http://" + trimmed
    }

    var server: ModelServer {
        let names = headers.map(\.name)
        let hasHeaders = names.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let kind: ModelServerAuthKind
        switch signIn {
        // With headers and no other sign-in, a 401 means the header was refused, not that a key is missing.
        case .none: kind = hasHeaders ? .headers : .none
        case .bearer: kind = .bearer
        case .basic: kind = .basic
        case .cloudflareAccess: kind = .cloudflareAccess
        }
        let auth = ModelServerAuth(kind: kind,
                                   username: signIn == .basic ? username.trimmingCharacters(in: .whitespaces) : "",
                                   clientID: signIn == .cloudflareAccess ? clientID.trimmingCharacters(in: .whitespaces) : "",
                                   headerNames: names)
        return ModelServer(id: id, name: name.trimmingCharacters(in: .whitespaces), baseURL: normalizedURL,
                           enabled: enabled, engine: engine,
                           metricsPath: metricsPath.trimmingCharacters(in: .whitespaces), auth: auth,
                           offlineAlerts: offlineAlerts)
    }

    var typedSecrets: ModelServerSecrets {
        var values: [String: String] = [:]
        for header in headers {
            let name = header.name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !header.value.isEmpty { values[name] = header.value }
        }
        return ModelServerSecrets(token: token.isEmpty ? nil : token, password: password.isEmpty ? nil : password,
                                  clientSecret: clientSecret.isEmpty ? nil : clientSecret, headerValues: values)
    }

    var canSave: Bool { server.isConfigured && !isSaving }

    var urlNotes: [Note] {
        let raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        let server = server
        guard server.isConfigured else {
            return [Note(text: "This isn't a valid http(s) address. Example: http://192.168.1.20:8000", isWarning: true)]
        }
        var notes: [Note] = []
        if !ModelServers.plainHTTP.allows(server.baseURL) {
            notes.append(Note(text: "macOS blocks plain http to this host: use https. Plain http works on this Mac, your local network, .local names and Tailscale.",
                              isWarning: true))
        }
        if (RemoteEndpoint.sanitizedBaseURL(server.baseURL) ?? "").lowercased().hasSuffix("/v1") {
            notes.append(Note(text: "The /v1 at the end is left out: Hoply talks to the server's root (\(server.endpoint?.baseURL.absoluteString ?? "")).",
                              isWarning: false))
        }
        if !raw.contains("://") {
            notes.append(Note(text: "No scheme given, so http:// is used.", isWarning: false))
        }
        return notes
    }

    var headerNotes: [Note] {
        headers.map { $0.name.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !RemoteEndpoint.isHeaderName($0) }
            .map { Note(text: "\"\($0)\" can't be sent as a header name.", isWarning: true) }
    }

    func isStored(header name: String) -> Bool {
        stored.headers.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    var probe: ModelServerProbe? {
        if case .done(let probe) = test { return probe }
        return nil
    }

    var isTestStale: Bool {
        guard let probe else { return false }
        return !probe.server.hasSameConnection(as: server)
    }
}
