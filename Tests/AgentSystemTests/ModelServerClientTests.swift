@testable import AgentSystem
import AgentKit
import Foundation
import Network
import Synchronization
import XCTest

private final class RoutedServer: Sendable {
    private final class Shared: Sendable {
        let requests = Mutex<[String]>([])
        let routes: Mutex<[String: String]>

        init(_ routes: [String: String]) { self.routes = Mutex(routes) }
    }

    private final class Once: Sendable {
        private let done = Mutex(false)

        func claim() -> Bool {
            done.withLock { done in
                defer { done = true }
                return !done
            }
        }
    }

    private let listener: NWListener
    private let shared: Shared
    let port: UInt16

    var requests: [String] { shared.requests.withLock { $0 } }
    var paths: [String] { requests.compactMap { $0.split(separator: " ").dropFirst().first.map(String.init) } }

    func requests(to path: String) -> [String] { requests.filter { $0.hasPrefix("GET \(path) ") } }
    func set(_ path: String, _ response: String?) { shared.routes.withLock { $0[path] = response } }

    static func response(status: String = "200 OK", type: String = "application/json", headers: [String] = [],
                         _ body: String = "") -> String {
        (["HTTP/1.1 \(status)", "Content-Type: \(type)", "Content-Length: \(body.utf8.count)", "Connection: close"] + headers)
            .joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    init(_ routes: [String: String], fallback: String = RoutedServer.response(status: "404 Not Found", #"{"detail":"Not Found"}"#),
         requiring header: String? = nil,
         refusal: String = RoutedServer.response(status: "401 Unauthorized", #"{"error":"Unauthorized"}"#)) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let shared = Shared(routes)
        self.shared = shared
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                shared.requests.withLock { $0.append(request) }
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                var response = shared.routes.withLock { $0[path] } ?? fallback
                if let header, !request.lowercased().contains("\r\n" + header.lowercased() + "\r\n") { response = refusal }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let once = Once()
        port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                let value: Result<UInt16, Error>? = switch state {
                case .ready: .success(listener.port?.rawValue ?? 0)
                case .failed(let error): .failure(error)
                default: nil
                }
                guard let value, once.claim() else { return }
                continuation.resume(with: value)
            }
            listener.start(queue: .global())
        }
    }

    deinit { listener.cancel() }
}

final class ModelServerClientTests: XCTestCase {
    private typealias R = RoutedServer

    private let ollamaRoutes = [
        "/api/version": R.response(#"{"version":"0.12.3"}"#),
        "/api/tags": R.response(#"{"models":[{"name":"qwen3:8b","size":5225388164},{"name":"llama3.2:latest","size":2019393189}]}"#),
        "/api/ps": R.response(#"{"models":[{"name":"qwen3:8b","size":6654289920,"size_vram":6654289920}]}"#),
        "/v1/models": R.response(#"{"object":"list","data":[{"id":"qwen3:8b","object":"model","owned_by":"library"}]}"#),
    ]

    private func vllmMetrics(generated: Int, prompt: Int = 1_000) -> String {
        R.response(type: "text/plain; version=0.0.4; charset=utf-8", """
            vllm:num_requests_running{model_name="local-qwen"} 2.0
            vllm:num_requests_waiting{model_name="local-qwen"} 0.0
            vllm:kv_cache_usage_perc{model_name="local-qwen"} 0.5
            vllm:prompt_tokens_total{model_name="local-qwen"} \(prompt).0
            vllm:generation_tokens_total{model_name="local-qwen"} \(generated).0

            """)
    }

    private let models = R.response(#"{"object":"list","data":[{"id":"local-qwen","object":"model","owned_by":"vllm","max_model_len":32768}]}"#)

    private func server(_ stub: RoutedServer, id: String = "s1", engine: ModelEngine? = nil,
                        auth: ModelServerAuth = .none) -> ModelServer {
        ModelServer(id: id, name: "Box", baseURL: "http://127.0.0.1:\(stub.port)", engine: engine, auth: auth)
    }

    private func header(_ name: String, in request: String) -> String? {
        request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
            .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Probe

    func testProbeDetectsOllamaAndReportsEveryEndpoint() async throws {
        let stub = try await RoutedServer(ollamaRoutes)
        let probe = await ModelServerClient(secrets: InMemorySecretStore()).probe(server(stub))
        XCTAssertTrue(probe.isReachable)
        XCTAssertEqual(probe.engine, .ollama)
        XCTAssertEqual(probe.models.map(\.id), ["qwen3:8b", "llama3.2:latest"])
        XCTAssertEqual(probe.models.map(\.loaded), [true, false])
        XCTAssertEqual(probe.status?.snapshot.version, "0.12.3")
        XCTAssertEqual(probe.endpoints.map(\.route), ModelServerRoute.allCases)
        XCTAssertEqual(Set(probe.endpoints.filter(\.answered).map(\.route)),
                       [.openAIModels, .ollamaVersion, .ollamaTags, .ollamaRunning])
        let metrics = try XCTUnwrap(probe.endpoints.first { $0.route == .metrics })
        XCTAssertEqual(metrics.status, 404)
        XCTAssertEqual(metrics.error?.kind, .http(status: 404))
        XCTAssertEqual(metrics.url, "http://127.0.0.1:\(stub.port)/metrics")
        XCTAssertNotNil(probe.latency)
        XCTAssertEqual(Set(stub.paths), Set(ModelServerRoute.allCases.map(\.path)), "plain GETs to the known routes only")
        XCTAssertTrue(stub.requests.allSatisfy { $0.hasPrefix("GET ") })
    }

    func testProbeDetectsVLLMFromMetricsAndAnExplicitEngineAsksLess() async throws {
        let stub = try await RoutedServer(["/metrics": vllmMetrics(generated: 500), "/v1/models": models])
        let client = ModelServerClient(secrets: InMemorySecretStore())
        let auto = await client.probe(server(stub))
        XCTAssertEqual(auto.engine, .vllm)
        XCTAssertEqual(auto.models, [ServedModel(id: "local-qwen", contextLength: 32_768, ownedBy: "vllm")])
        XCTAssertEqual(auto.status?.snapshot.metrics.running, 2)
        XCTAssertEqual(auto.status?.capabilities, [.models, .generationRate, .promptRate, .running, .waiting, .kvCache])

        let before = stub.requests.count
        let explicit = await client.probe(server(stub, engine: .vllm))
        XCTAssertEqual(explicit.engine, .vllm)
        XCTAssertEqual(stub.requests.count - before, 2)
        XCTAssertEqual(explicit.endpoints.map(\.route), [.metrics, .openAIModels])
    }

    func testProbeFailuresAreClassified() async throws {
        let client = ModelServerClient(secrets: InMemorySecretStore())

        let page = try await RoutedServer([:], fallback: R.response(type: "text/html; charset=utf-8",
                                                                    "<!doctype html><title>Open WebUI</title>"))
        let html = await client.probe(server(page))
        XCTAssertEqual(html.error?.kind, .htmlPage(status: 200))
        XCTAssertEqual(html.availability, .blocked)

        let other = try await RoutedServer([:])
        let nothing = await client.probe(server(other))
        XCTAssertEqual(nothing.error?.kind, .noModelServer)

        let locked = try await RoutedServer(["/v1/models": models], requiring: "Authorization: Bearer sk-right")
        let keyless = await client.probe(server(locked))
        XCTAssertEqual(keyless.error?.kind, .authRequired(scheme: nil))
        let wrong = await client.probe(server(locked, auth: ModelServerAuth(kind: .bearer)),
                                       secrets: ModelServerSecrets(token: "sk-wrong"))
        XCTAssertEqual(wrong.error?.kind, .tokenRejected(status: 401, message: "Unauthorized"))
        XCTAssertEqual(wrong.error?.errorDescription, "Box rejected the token (HTTP 401)")
        let right = await client.probe(server(locked, auth: ModelServerAuth(kind: .bearer)),
                                       secrets: ModelServerSecrets(token: "sk-right"))
        XCTAssertEqual(right.engine, .vllm, "owned_by names the engine when /metrics doesn't")
        XCTAssertEqual(right.hints, [.metricsDisabled(.vllm)])

        let login = "https://team.cloudflareaccess.com/cdn-cgi/access/login/x"
        let access = try await RoutedServer([:], fallback: R.response(status: "302 Found", type: "text/html",
                                                                      headers: ["Location: \(login)"]))
        let tokenless = await client.probe(server(access))
        XCTAssertEqual(tokenless.error?.kind, .accessRequired(host: "team.cloudflareaccess.com"))
        let token = await client.probe(server(access, auth: ModelServerAuth(kind: .cloudflareAccess, clientID: "abc.access")),
                                       secrets: ModelServerSecrets(clientSecret: "nope"))
        XCTAssertEqual(token.error?.kind, .accessRejected(status: 302))
        XCTAssertEqual(access.paths.count, 16, "no redirect was followed")

        let down = ModelServer(id: "d", name: "Gone", baseURL: "http://127.0.0.1:9")
        let refused = await client.probe(down, timeout: 2)
        XCTAssertEqual(refused.error?.kind, .connectionRefused)
        XCTAssertEqual(refused.availability, .offline)
        let invalid = await client.probe(ModelServer(id: "x", baseURL: "not a url"))
        XCTAssertEqual(invalid.error?.kind, .invalidURL)
    }

    // MARK: - Auth

    func testEveryAuthKindReachesTheWire() async throws {
        let stub = try await RoutedServer(["/v1/models": models])
        let store = InMemorySecretStore()
        let client = ModelServerClient(secrets: store)

        func sent(_ auth: ModelServerAuth, _ secrets: ModelServerSecrets, id: String) async throws -> String {
            let server = server(stub, id: id, engine: .openAICompatible, auth: auth)
            try await client.saveSecrets(secrets, for: server)
            let poll = await client.poll(server)
            XCTAssertNotNil(poll?.status, "\(auth.kind)")
            return try XCTUnwrap(stub.requests(to: "/v1/models").last)
        }

        let bearer = try await sent(ModelServerAuth(kind: .bearer), ModelServerSecrets(token: "sk-local-1"), id: "b")
        XCTAssertEqual(header("Authorization", in: bearer), "Bearer sk-local-1")
        XCTAssertFalse(try XCTUnwrap(bearer.components(separatedBy: "\r\n").first).contains("sk-local-1"), "never in the URL")

        let basic = try await sent(ModelServerAuth(kind: .basic, username: "milo"), ModelServerSecrets(password: "pw"), id: "ba")
        XCTAssertEqual(header("Authorization", in: basic), "Basic " + Data("milo:pw".utf8).base64EncodedString())

        let access = try await sent(ModelServerAuth(kind: .cloudflareAccess, clientID: "abc.access"),
                                    ModelServerSecrets(clientSecret: "cf-secret"), id: "cf")
        XCTAssertEqual(header("CF-Access-Client-Id", in: access), "abc.access")
        XCTAssertEqual(header("CF-Access-Client-Secret", in: access), "cf-secret")
        XCTAssertNil(header("Authorization", in: access))

        let custom = try await sent(ModelServerAuth(kind: .headers, headerNames: ["X-Api-Key"]),
                                    ModelServerSecrets(headerValues: ["X-Api-Key": "k-9"]), id: "h")
        XCTAssertEqual(header("X-Api-Key", in: custom), "k-9")

        let none = try await sent(.none, ModelServerSecrets(), id: "n")
        XCTAssertNil(header("Authorization", in: none))
        XCTAssertNil(header("Cookie", in: none))
    }

    func testSecretsLiveInOneKeychainItemPerServerAndCanBeDeleted() async throws {
        let store = InMemorySecretStore()
        let client = ModelServerClient(secrets: store)
        let auth = ModelServerAuth(kind: .cloudflareAccess, clientID: "abc.access", headerNames: ["X-Team"])
        let server = ModelServer(id: "srv9", name: "Box", baseURL: "https://llm.example.com", auth: auth)
        try await client.saveSecrets(ModelServerSecrets(token: "sk-1", password: "stale", clientSecret: "cs",
                                                        headerValues: ["X-Team": "blue", "X-Old": "gone"]), for: server)
        let raw = try XCTUnwrap(try store.secret(service: "com.coolcraftcoders.hoply.model-server", account: "srv9"))
        XCTAssertFalse(raw.contains("stale"), "what the auth kind doesn't use isn't kept")
        XCTAssertFalse(raw.contains("gone"))
        let saved = try await client.secrets(for: "srv9")
        XCTAssertEqual(saved, ModelServerSecrets(token: "sk-1", clientSecret: "cs", headerValues: ["X-Team": "blue"]))
        XCTAssertEqual(try store.modelServerSecrets(for: "other"), ModelServerSecrets())

        let settings = try XCTUnwrap(String(data: try JSONEncoder().encode(server), encoding: .utf8))
        for secret in ["sk-1", "\"cs\"", "blue"] { XCTAssertFalse(settings.contains(secret), settings) }
        XCTAssertTrue(settings.contains("abc.access"), "the client id is not a secret")

        try await client.deleteSecrets(for: "srv9")
        XCTAssertNil(try store.secret(service: KeychainService.modelServer, account: "srv9"))
        let gone = try await client.secrets(for: "srv9")
        XCTAssertTrue(gone.isEmpty)

        try await client.saveSecrets(ModelServerSecrets(), for: server)
        XCTAssertNil(try store.secret(service: KeychainService.modelServer, account: "srv9"), "nothing to keep, no item")

        let query = Keychain.query(service: KeychainService.modelServer, account: "srv9")
        XCTAssertNil(query[kSecAttrSynchronizable as String], "never synced to iCloud")
    }

    func testAMissingSecretFailsBeforeAnyRequest() async throws {
        let stub = try await RoutedServer(["/v1/models": models])
        let client = ModelServerClient(secrets: InMemorySecretStore())
        let poll = await client.poll(server(stub, engine: .openAICompatible, auth: ModelServerAuth(kind: .bearer)))
        XCTAssertEqual(poll?.error?.kind, .missingToken)
        XCTAssertEqual(poll?.availability, .blocked)
        XCTAssertEqual(stub.requests, [])
    }

    func testAMetricsURLOnAnotherHostGetsNoCredentials() async throws {
        let api = try await RoutedServer(["/v1/models": models])
        let metrics = try await RoutedServer(["/stats/metrics": vllmMetrics(generated: 10)])
        var server = server(api, engine: .vllm, auth: ModelServerAuth(kind: .bearer))
        server.metricsPath = "http://localhost:\(metrics.port)/stats/metrics"
        let client = ModelServerClient(secrets: InMemorySecretStore())
        let probe = await client.probe(server, secrets: ModelServerSecrets(token: "sk-only-for-the-api"))
        XCTAssertEqual(probe.status?.snapshot.metrics.generationTokensCounter, 10)
        XCTAssertEqual(header("Authorization", in: try XCTUnwrap(api.requests.first)), "Bearer sk-only-for-the-api")
        XCTAssertNil(header("Authorization", in: try XCTUnwrap(metrics.requests.first)))
    }

    // MARK: - Poll

    func testPollsComputeRatesPerServerAndRememberTheEngine() async throws {
        let stub = try await RoutedServer(["/metrics": vllmMetrics(generated: 1_000), "/v1/models": models])
        let client = ModelServerClient(secrets: InMemorySecretStore())
        let server = server(stub)

        let firstPoll = await client.poll(server)
        let first = try XCTUnwrap(firstPoll)
        XCTAssertEqual(first.status?.engine, .vllm)
        XCTAssertNil(first.status?.generationTokensPerSecond, "no baseline yet")
        XCTAssertEqual(stub.requests.count, ModelServerRoute.allCases.count, "auto-detection asks everything once")

        try await Task.sleep(for: .milliseconds(700))
        stub.set("/metrics", vllmMetrics(generated: 1_700, prompt: 2_400))
        let before = stub.requests.count
        let secondPoll = await client.poll(server)
        let second = try XCTUnwrap(secondPoll)
        XCTAssertEqual(stub.paths.dropFirst(before), ["/metrics"], "then only what the engine needs; the model list is remembered")
        XCTAssertEqual(second.status?.models.map(\.id), ["local-qwen"])
        let rate = try XCTUnwrap(second.status?.generationTokensPerSecond)
        let seconds = second.at.timeIntervalSince(first.at)
        XCTAssertEqual(rate, 700 / seconds, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(second.status?.promptTokensPerSecond), 1_400 / seconds, accuracy: 2)
        XCTAssertTrue(second.isCurrent(for: server))

        var moved = server
        moved.baseURL = "http://127.0.0.1:9"
        XCTAssertFalse(second.isCurrent(for: moved), "an answer from the old address is dropped by the caller")
        XCTAssertFalse(second.isCurrent(for: nil))
        var renamed = server
        renamed.name = "Other name"
        XCTAssertTrue(second.isCurrent(for: renamed))
    }

    func testAServerThatStopsAnsweringIsOfflineDespiteTheRememberedModels() async throws {
        let stub = try await RoutedServer(["/metrics": vllmMetrics(generated: 1_000), "/v1/models": models])
        let client = ModelServerClient(secrets: InMemorySecretStore())
        let server = server(stub)
        let online = await client.poll(server)
        XCTAssertEqual(online?.availability, .online)

        stub.set("/metrics", R.response(status: "502 Bad Gateway", type: "text/plain", ""))
        let down = await client.poll(server)
        XCTAssertEqual(down?.error?.kind, .http(status: 502))
        XCTAssertEqual(down?.availability, .offline)

        stub.set("/metrics", vllmMetrics(generated: 5))
        let before = stub.requests.count
        let back = await client.poll(server)
        XCTAssertEqual(back?.status?.engine, .vllm)
        XCTAssertNil(back?.status?.generationTokensPerSecond, "an outage clears the rate baseline")
        XCTAssertEqual(stub.requests.count - before, ModelServerRoute.allCases.count, "and detection starts over")
    }

    func testLlamaCppWithoutMetricsStaysOnline() async throws {
        let stub = try await RoutedServer([
            "/v1/models": R.response(#"{"object":"list","data":[{"id":"q.gguf","object":"model","owned_by":"llamacpp"}]}"#),
            "/props": R.response(#"{"total_slots":1,"model_path":"/m/q.gguf","build_info":"b1"}"#),
            "/metrics": R.response(status: "501 Not Implemented", #"{"error":{"code":501,"message":"This server does not support metrics endpoint. Start it with `--metrics`","type":"not_supported_error"}}"#),
        ])
        let client = ModelServerClient(secrets: InMemorySecretStore())
        for _ in 0..<3 {
            let poll = await client.poll(server(stub))
            XCTAssertEqual(poll?.status?.engine, .llamaCpp)
            XCTAssertEqual(poll?.status?.snapshot.hints, [.metricsDisabled(.llamaCpp)])
            XCTAssertEqual(poll?.availability, .online)
        }
    }

    func testSavingSecretsWhileAPollRunsLeavesLaterPollsWorking() async throws {
        let stub = try await RoutedServer(["/v1/models": models])
        let client = ModelServerClient(secrets: InMemorySecretStore())
        let server = server(stub, engine: .openAICompatible)
        async let running = client.poll(server)
        try await client.saveSecrets(ModelServerSecrets(), for: server)
        let answer = await running
        let later = await client.poll(server)
        XCTAssertNotNil(later?.status)
        if let answer { XCTAssertNotNil(answer.status) }
    }

    // MARK: - Discovery

    func testDiscoveryFindsServersOnTheGivenPorts() async throws {
        let ollama = try await RoutedServer(ollamaRoutes)
        let vllm = try await RoutedServer(["/metrics": vllmMetrics(generated: 1), "/v1/models": models])
        let web = try await RoutedServer([:], fallback: R.response(type: "text/html", "<html>dev server</html>"))
        let airplay = try await RoutedServer([:], fallback: R.response(status: "403 Forbidden", type: "text/plain", ""))
        let known = try await RoutedServer(ollamaRoutes)
        let hub = try await RoutedServer(ollamaRoutes)
        let closed = 9

        let client = ModelServerClient(secrets: InMemorySecretStore())
        let configured = [ModelServer(id: "k", name: "Mine", baseURL: "http://127.0.0.1:\(known.port)")]
        let ports = [vllm, web, airplay, known, hub, ollama].map { Int($0.port) } + [closed]
        let found = await client.discover(ports: ports, hubPort: Int(hub.port), configured: configured, timeout: 2)

        XCTAssertEqual(found.map(\.server.baseURL), ["http://localhost:\(vllm.port)", "http://localhost:\(ollama.port)"],
                       "in the order asked")
        XCTAssertEqual(found.map(\.probe.engine), [.vllm, .ollama])
        XCTAssertEqual(found.map(\.server.name), ["vLLM", "Ollama"])
        XCTAssertEqual(found.last?.probe.models.map(\.id), ["qwen3:8b", "llama3.2:latest"])
        XCTAssertTrue(found.allSatisfy { $0.server.engine == nil && $0.server.auth == .none && $0.server.enabled })
        XCTAssertEqual(Set(found.map(\.id)).count, 2)
        XCTAssertEqual(known.requests, [], "already configured")
        XCTAssertEqual(hub.requests, [], "Hoply's own listener")
        XCTAssertTrue((ollama.requests + vllm.requests + web.requests + airplay.requests).allSatisfy { $0.hasPrefix("GET ") })
    }
}

final class ModelServerHistoryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_196_800)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func status(generated: Double, prompt: Double, rate: Double?, at offset: TimeInterval,
                        engine: ModelEngine = .llamaCpp) -> ModelServerStatus {
        let metrics = ModelServerMetrics(running: 1, waiting: 0, kvCacheUsage: 0.5, promptTokensTotal: prompt,
                                         generationTokensTotal: generated, generationTokensCounter: generated)
        return ModelServerStatus(snapshot: ModelServerSnapshot(engine: engine, metrics: metrics,
                                                               takenAt: t0.addingTimeInterval(offset)),
                                 generationTokensPerSecond: rate)
    }

    private func ledger(_ directory: TempDirectory) throws -> Ledger {
        try Ledger(configuration: LedgerConfiguration(databasePath: directory.path("hoply.sqlite"),
                                                      claudeConfigDirectory: directory.path("claude"),
                                                      copilotHome: directory.path("copilot"), pricingOverridesURL: nil,
                                                      watchForChanges: false))
    }

    func testEachServerHasItsOwnSeriesAndCounterBaseline() async throws {
        let directory = try TempDirectory()
        let ledger = try ledger(directory)
        let legacy = ModelServer.legacyID
        let now = t0.addingTimeInterval(120)

        try await ledger.recordModelSamples(status(generated: 1_000, prompt: 4_000, rate: nil, at: 0), server: legacy)
        try await ledger.recordModelSamples(status(generated: 50, prompt: 90, rate: nil, at: 1), server: "ol1")
        try await ledger.recordModelSamples(status(generated: 1_300, prompt: 5_000, rate: 60, at: 5), server: legacy)
        try await ledger.recordModelSamples(status(generated: 80, prompt: 190, rate: 6, at: 6), server: "ol1")

        let mine = try await ledger.modelTokensPerDay(server: legacy, days: 1, now: now, calendar: utc)
        XCTAssertEqual(mine.map(\.generated), [300], "50 on the other server is no restart of this one")
        XCTAssertEqual(mine.map(\.prompt), [1_000])
        let other = try await ledger.modelTokensPerDay(server: "ol1", days: 1, now: now, calendar: utc)
        XCTAssertEqual(other.map(\.generated), [30])
        XCTAssertEqual(other.map(\.prompt), [100])
        let unseen = try await ledger.modelTokensPerDay(server: "never", days: 1, now: now, calendar: utc)
        XCTAssertEqual(unseen.map(\.observed), [false])

        let old = try await ledger.modelTokensPerDay(days: 1, now: now, calendar: utc)
        XCTAssertEqual(old, mine, "the legacy id reads the series the single-server build wrote")
        let all = DateInterval(start: .distantPast, end: .distantFuture)
        let bare = try await ledger.samples(ModelServerSeries.generationTokensPerSecond, in: all)
        let keyed = try await ledger.modelSamples(ModelServerSeries.generationTokensPerSecond, server: "ol1", in: all)
        XCTAssertEqual(bare.map(\.sum), [60])
        XCTAssertEqual(keyed.map(\.sum), [6])
        XCTAssertEqual(keyed.first?.series, "model.ol1.generation_tps")

        let recent = try await ledger.recentModelSamples(server: "ol1", since: t0.addingTimeInterval(-60), now: now)
        XCTAssertEqual(recent[ModelServerSeries.generationTokensPerSecond]?.map(\.sum), [6], "keyed by the plain metric name")
        XCTAssertEqual(recent[ModelServerSeries.kvCachePercent]?.first?.mean, 50)
        XCTAssertNil(recent[ModelServerSeries.memoryBytes])

        let lastSeen = try await ledger.modelServerLastSeen(server: "ol1", now: t0.addingTimeInterval(3_600))
        XCTAssertEqual(lastSeen, t0.addingTimeInterval(60))
        let capped = try await ledger.modelServerLastSeen(server: "ol1", now: t0.addingTimeInterval(10))
        XCTAssertEqual(capped, t0.addingTimeInterval(10))
        let never = try await ledger.modelServerLastSeen(server: "never", now: now)
        XCTAssertNil(never)
        let ids = try await ledger.modelServerIDsWithSamples()
        XCTAssertEqual(ids, ["default", "ol1"], "a removed server's samples stay and can be found")
    }

    func testResettingOneServersBaselineLeavesTheOthers() async throws {
        let directory = try TempDirectory()
        let ledger = try ledger(directory)
        let now = t0.addingTimeInterval(120)
        for id in ["a", "b"] {
            try await ledger.recordModelSamples(status(generated: 1_000, prompt: 1_000, rate: nil, at: 0), server: id)
        }
        await ledger.resetModelCounters(server: "a")
        for id in ["a", "b"] {
            try await ledger.recordModelSamples(status(generated: 400, prompt: 400, rate: nil, at: 5), server: id)
            try await ledger.recordModelSamples(status(generated: 450, prompt: 420, rate: nil, at: 10), server: id)
        }
        let a = try await ledger.modelTokensPerDay(server: "a", days: 1, now: now, calendar: utc)
        XCTAssertEqual(a.map(\.generated), [50], "the new address's first reading is a baseline, not usage")
        let b = try await ledger.modelTokensPerDay(server: "b", days: 1, now: now, calendar: utc)
        XCTAssertEqual(b.map(\.generated), [450], "a drop on a server that didn't change is a restart, counted from 0")
    }

    func testBaselinesSurviveARelaunchPerServer() async throws {
        let directory = try TempDirectory()
        let now = t0.addingTimeInterval(600)
        do {
            let ledger = try ledger(directory)
            try await ledger.recordModelSamples(status(generated: 1_000, prompt: 2_000, rate: nil, at: 0), server: "a")
            try await ledger.recordModelSamples(status(generated: 7_000, prompt: 9_000, rate: nil, at: 0), server: "b")
        }
        let reopened = try ledger(directory)
        try await reopened.recordModelSamples(status(generated: 1_250, prompt: 2_100, rate: nil, at: 300), server: "a")
        try await reopened.recordModelSamples(status(generated: 7_010, prompt: 9_001, rate: nil, at: 300), server: "b")
        let a = try await reopened.modelTokensPerDay(server: "a", days: 1, now: now, calendar: utc)
        let b = try await reopened.modelTokensPerDay(server: "b", days: 1, now: now, calendar: utc)
        XCTAssertEqual(a.map(\.generated), [250])
        XCTAssertEqual(b.map(\.generated), [10])
    }
}
