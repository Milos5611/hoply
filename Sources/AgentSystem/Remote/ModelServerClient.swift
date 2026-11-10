import AgentKit
import Foundation

public actor ModelServerClient {
    public static let slowRouteInterval: TimeInterval = 60

    private struct State {
        var server: ModelServer
        var detected: ModelEngine?
        var previous: ModelServerSnapshot?
        var cached: [ModelServerRoute: (data: Data, at: Date)] = [:]
    }

    private let secretStore: any SecretStore
    private let transport: Transport
    private let policy: PlainHTTPPolicy
    private var states: [String: State] = [:]
    private var generations: [String: Int] = [:]
    private var secretCache: [String: ModelServerSecrets] = [:]

    public init(secrets: any SecretStore = Keychain(), configuration: URLSessionConfiguration = .ephemeral,
                policy: PlainHTTPPolicy = .main) {
        secretStore = secrets
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        transport = Transport(session: URLSession(configuration: configuration))
        self.policy = policy
    }

    // MARK: - Secrets

    public func secrets(for serverID: String) throws -> ModelServerSecrets {
        if let cached = secretCache[serverID] { return cached }
        let stored = try secretStore.modelServerSecrets(for: serverID)
        secretCache[serverID] = stored
        return stored
    }

    public func saveSecrets(_ secrets: ModelServerSecrets, for server: ModelServer) throws {
        let kept = secrets.pruned(for: server.auth)
        try secretStore.setModelServerSecrets(kept, for: server.id)
        secretCache[server.id] = kept
        forget(server.id)
    }

    public func deleteSecrets(for serverID: String) throws {
        try secretStore.deleteModelServerSecrets(for: serverID)
        secretCache[serverID] = nil
        forget(serverID)
    }

    public func forget(_ serverID: String) {
        states[serverID] = nil
        generations[serverID, default: 0] += 1
    }

    // MARK: - Poll

    public func poll(_ server: ModelServer, timeout: TimeInterval = 4) async -> ModelServerPoll? {
        if let known = states[server.id], !known.server.hasSameConnection(as: server) { forget(server.id) }
        let generation = generations[server.id, default: 0]
        var state = states[server.id] ?? State(server: server)
        state.server = server
        let started = Date()

        let engine = server.engine ?? state.detected
        var answers: [ModelServerRoute: Result<Data, RemoteError>] = [:]
        let slow = ModelServerDetector.slowRoutes(for: engine)
        var routes = ModelServerDetector.routes(for: engine)
        for route in routes where slow.contains(route) {
            guard let cached = state.cached[route], started.timeIntervalSince(cached.at) < Self.slowRouteInterval else {
                continue
            }
            answers[route] = .success(cached.data)
        }
        routes.removeAll { answers[$0] != nil }
        let fetched = await transport.fetch(routes, server: server, credentials: credentials(for: server, override: nil),
                                            timeout: timeout)
        guard generation == generations[server.id, default: 0] else { return nil }

        let now = Date()
        // A remembered model list must not keep a server that stopped answering looking alive.
        let down = !fetched.isEmpty && fetched.allSatisfy { answer in
            if case .failure(let error) = answer.result { return error.isUnreachable }
            return false
        }
        if down { answers = [:] }
        for answer in fetched {
            answers[answer.route] = answer.result
            if case .success(let data) = answer.result, answer.route != .metrics, answer.route != .ollamaRunning {
                state.cached[answer.route] = (data, now)
            }
        }
        let result = ModelServerDetector.snapshot(from: answers, engine: server.engine, at: now,
                                                  endpoint: server.displayName)
            .map { snapshot -> ModelServerStatus in
                let status = ModelServerStatus.compute(previous: state.previous, current: snapshot)
                state.previous = snapshot
                state.detected = snapshot.engine
                return status
            }
        if case .failure = result {
            // Whatever answered before may be gone: the next poll looks at every endpoint again.
            state = State(server: server)
        }
        states[server.id] = state
        return ModelServerPoll(server: server, result: result, at: now)
    }

    // MARK: - Probe

    public func probe(_ server: ModelServer, secrets unsaved: ModelServerSecrets? = nil,
                      timeout: TimeInterval = 5) async -> ModelServerProbe {
        let allowed = policy.allows(server.baseURL)
        guard server.isConfigured else {
            return ModelServerProbe(server: server, result: .failure(RemoteError(.invalidURL, endpoint: server.displayName)),
                                    endpoints: [], plainHTTPAllowed: allowed, at: Date())
        }
        let fetched = await transport.fetch(ModelServerDetector.routes(for: server.engine), server: server,
                                            credentials: credentials(for: server, override: unsaved), timeout: timeout)
        return Self.probe(server, fetched, plainHTTPAllowed: allowed)
    }

    private static func probe(_ server: ModelServer, _ fetched: [Transport.Answer],
                              plainHTTPAllowed: Bool) -> ModelServerProbe {
        let now = Date()
        let answers = Dictionary(fetched.map { ($0.route, $0.result) }, uniquingKeysWith: { first, _ in first })
        let result = ModelServerDetector.snapshot(from: answers, engine: server.engine, at: now,
                                                  endpoint: server.displayName)
            .map { ModelServerStatus.compute(previous: nil, current: $0) }
        return ModelServerProbe(server: server, result: result, endpoints: fetched.map(\.report),
                                plainHTTPAllowed: plainHTTPAllowed, at: now)
    }

    // MARK: - Discovery

    public func discover(ports: [Int] = ModelServerDiscovery.wellKnownPorts.map(\.port), hubPort: Int,
                         configured: [ModelServer], timeout: TimeInterval = 1) async -> [ModelServerCandidate] {
        let wanted = ModelServerDiscovery.ports(ports, hubPort: hubPort, configured: configured)
        let transport = transport
        let found = await withTaskGroup(of: (Int, ModelServerCandidate?).self) { group in
            for port in wanted {
                group.addTask {
                    let server = ModelServerDiscovery.server(port: port)
                    let none: Result<RemoteCredentials, RemoteError> = .success(RemoteCredentials())
                    // One request tells a closed port from an open one before the rest are sent.
                    let first = await transport.fetch([.openAIModels], server: server, credentials: none, timeout: timeout)
                    if case .failure(let error)? = first.first?.result, Self.isClosedPort(error) { return (port, nil) }
                    let rest = await transport.fetch(ModelServerRoute.allCases.filter { $0 != .openAIModels },
                                                     server: server, credentials: none, timeout: timeout)
                    return (port, ModelServerDiscovery.candidate(Self.probe(server, first + rest, plainHTTPAllowed: true)))
                }
            }
            var result: [Int: ModelServerCandidate] = [:]
            for await (port, candidate) in group { result[port] = candidate }
            return result
        }
        return wanted.compactMap { found[$0] }
    }

    private static func isClosedPort(_ error: RemoteError) -> Bool {
        if case .http = error.kind { return false }
        return error.isUnreachable
    }

    private func credentials(for server: ModelServer,
                             override: ModelServerSecrets?) -> Result<RemoteCredentials, RemoteError> {
        do {
            let secrets: ModelServerSecrets
            if let override {
                secrets = override
            } else if server.auth.needsSecrets {
                secrets = try self.secrets(for: server.id)
            } else {
                secrets = ModelServerSecrets()
            }
            return .success(try server.auth.credentials(secrets, endpoint: server.displayName))
        } catch let error as RemoteError {
            return .failure(error)
        } catch {
            return .failure(RemoteError(.missingSecret(what: "readable Keychain entry"), endpoint: server.displayName))
        }
    }
}

struct Transport: Sendable {
    let session: URLSession

    struct Answer: Sendable {
        var route: ModelServerRoute
        var result: Result<Data, RemoteError>
        var report: ModelServerRouteReport
    }

    func fetch(_ routes: [ModelServerRoute], server: ModelServer, credentials: Result<RemoteCredentials, RemoteError>,
               timeout: TimeInterval) async -> [Answer] {
        await withTaskGroup(of: Answer.self) { group in
            for route in routes {
                group.addTask { await fetch(route, server: server, credentials: credentials, timeout: timeout) }
            }
            var answers: [ModelServerRoute: Answer] = [:]
            for await answer in group { answers[answer.route] = answer }
            return routes.compactMap { answers[$0] }
        }
    }

    func fetch(_ route: ModelServerRoute, server: ModelServer, credentials: Result<RemoteCredentials, RemoteError>,
               timeout: TimeInterval) async -> Answer {
        let name = server.displayName
        func answer(_ result: Result<Data, RemoteError>, url: URL? = nil, status: Int? = nil,
                    latency: TimeInterval? = nil) -> Answer {
            var error: RemoteError?
            if case .failure(let failure) = result { error = failure }
            return Answer(route: route, result: result,
                          report: ModelServerRouteReport(route: route, url: url?.absoluteString ?? "", status: status,
                                                         error: error, latency: latency))
        }
        guard let target = server.target(for: route) else { return answer(.failure(RemoteError(.invalidURL, endpoint: name))) }
        let request: URLRequest
        do {
            let sent = target.sendsCredentials ? try credentials.get() : RemoteCredentials()
            request = try target.endpoint.request(path: target.path, credentials: sent, timeout: timeout, accept: route.accept)
        } catch let error as RemoteError {
            return answer(.failure(error), url: target.endpoint.url(path: target.path))
        } catch {
            return answer(.failure(RemoteError(.invalidURL, endpoint: name)))
        }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (data, response) = try await session.data(for: request, delegate: RedirectRefusal())
            let elapsed = clock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return answer(target.endpoint.classify(response, body: data, auth: target.sendsCredentials ? server.auth.kind : .none),
                          url: request.url, status: (response as? HTTPURLResponse)?.statusCode, latency: seconds)
        } catch let error as URLError {
            return answer(.failure(RemoteError(error, endpoint: name)), url: request.url)
        } catch {
            return answer(.failure(RemoteError(.transport(error.localizedDescription), endpoint: name)), url: request.url)
        }
    }
}

private final class RedirectRefusal: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
