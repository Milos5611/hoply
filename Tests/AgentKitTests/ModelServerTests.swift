import AgentKit
import Foundation
import XCTest

final class ModelServerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_196_800)

    private func shapes(_ name: String) throws -> Data {
        let all = try Fixture.object("synthetic_model_servers.json")
        return try JSONSerialization.data(withJSONObject: try XCTUnwrap(all[name]))
    }

    private func snapshot(_ answers: [ModelServerRoute: Result<Data, RemoteError>], engine: ModelEngine? = nil,
                          at offset: TimeInterval = 0) -> Result<ModelServerSnapshot, RemoteError> {
        ModelServerDetector.snapshot(from: answers, engine: engine, at: t0.addingTimeInterval(offset), endpoint: "Box")
    }

    private func missing(_ status: Int = 404) -> Result<Data, RemoteError> {
        .failure(RemoteError(.http(status: status), endpoint: "Box"))
    }

    // MARK: - Settings

    func testLegacySettingsBecomeOneServerWithTheFixedID() throws {
        let old = #"{"port":4400,"vllmBaseURL":"http://10.0.0.5:8000","vllmName":"ZGX","localModelAlertsEnabled":false}"#
        let settings = AppSettings.decode(Data(old.utf8))
        XCTAssertEqual(settings.modelServers, [ModelServer(id: "default", name: "ZGX", baseURL: "http://10.0.0.5:8000")])
        XCTAssertEqual(settings.modelServers.first?.id, ModelServer.legacyID)
        XCTAssertEqual(settings.legacyModelServer?.baseURL, "http://10.0.0.5:8000")
        XCTAssertEqual(settings.activeModelServers.count, 1)
        XCTAssertTrue(AppSettings.decode(Data(#"{"port":4400}"#.utf8)).modelServers.isEmpty)

        let saved = try XCTUnwrap(settings.encoded())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertNil(json["vllmBaseURL"], "the old keys are read, never written")
        XCTAssertNil(json["vllmName"])
        XCTAssertEqual((json["modelServers"] as? [[String: Any]])?.first?["engine"] as? String, "auto")
        XCTAssertEqual(AppSettings.decode(saved), settings)

        let removed = #"{"vllmBaseURL":"http://10.0.0.5:8000","modelServers":[]}"#
        XCTAssertTrue(AppSettings.decode(Data(removed.utf8)).modelServers.isEmpty, "a deleted server doesn't come back")
        XCTAssertEqual(AppSettings.decode(Data(#"{"vllmName":"ZGX"}"#.utf8)).modelServers,
                       [ModelServer(id: "default", name: "ZGX")], "a name alone still migrates")
        XCTAssertTrue(AppSettings.decode(Data(#"{"vllmBaseURL":"","vllmName":""}"#.utf8)).modelServers.isEmpty)
    }

    func testServersDecodeLenientlyPerKeyAndPerElement() {
        let json = #"""
        {"modelServers":[
          {"id":"a1","name":"Ollama","baseURL":"http://localhost:11434","engine":"ollama","enabled":"yes",
           "auth":{"kind":"bearer","username":7},"offlineAlerts":false,"future":1},
          "not a server",
          {"name":"no id"},
          {"id":"a1","name":"duplicate"},
          {"id":"b 2/x","baseURL":"https://llm.example.com/v1","engine":"warp","metricsPath":9,
           "auth":{"kind":"cloudflareAccess","clientID":"abc.access","headerNames":["X-Team"," x-team ",""]}}
        ],"port":"x"}
        """#
        let settings = AppSettings.decode(Data(json.utf8))
        XCTAssertEqual(settings.port, 4318)
        XCTAssertEqual(settings.modelServers.map(\.id), ["a1", "b-2-x"])
        let first = settings.modelServers[0]
        XCTAssertEqual(first.engine, .ollama)
        XCTAssertTrue(first.enabled, "a wrongly typed key falls back to its default")
        XCTAssertEqual(first.auth, ModelServerAuth(kind: .bearer))
        XCTAssertFalse(first.offlineAlerts)
        let second = settings.modelServers[1]
        XCTAssertNil(second.engine, "an unknown engine is auto")
        XCTAssertEqual(second.metricsPath, "")
        XCTAssertEqual(second.auth, ModelServerAuth(kind: .cloudflareAccess, clientID: "abc.access", headerNames: ["X-Team"]))
        XCTAssertEqual(second.endpoint?.baseURL.absoluteString, "https://llm.example.com", "a pasted /v1 is dropped")
        XCTAssertEqual(AppSettings.decode(settings.encoded()), settings)
    }

    func testTheLegacyServerIsFoundByItsFixedID() {
        var settings = AppSettings()
        settings.modelServers = [ModelServer(id: "x1", name: "Ollama", baseURL: "http://localhost:11434")]
        XCTAssertNil(settings.legacyModelServer)
        settings.modelServers.append(ModelServer(id: ModelServer.legacyID, name: "ZGX"))
        XCTAssertEqual(settings.legacyModelServer?.displayName, "ZGX")
        XCTAssertEqual(settings.activeModelServers.map(\.id), ["x1"], "no URL = not polled")
    }

    func testMetricsOverridesAndCredentialScope() throws {
        var server = ModelServer(id: "s", name: "Box", baseURL: "https://llm.example.com/proxy/")
        XCTAssertEqual(server.target(for: .openAIModels)?.path, "/v1/models")
        XCTAssertEqual(server.target(for: .metrics)?.path, "/metrics")
        server.metricsPath = "internal/metrics"
        XCTAssertEqual(server.target(for: .metrics)?.path, "/internal/metrics")
        XCTAssertEqual(server.target(for: .metrics)?.endpoint.baseURL.absoluteString, "https://llm.example.com/proxy")

        server.metricsPath = "https://llm.example.com:9090/metrics?format=prometheus"
        let samePort = try XCTUnwrap(server.target(for: .metrics))
        XCTAssertEqual(samePort.endpoint.url(path: samePort.path)?.absoluteString,
                       "https://llm.example.com:9090/metrics?format=prometheus")
        XCTAssertTrue(samePort.sendsCredentials)

        server.metricsPath = "http://metrics.internal:9090/metrics"
        XCTAssertEqual(server.target(for: .metrics)?.sendsCredentials, false, "another host never gets the secrets")
        XCTAssertEqual(server.target(for: .openAIModels)?.sendsCredentials, true)

        var edited = server
        edited.name = "Renamed"
        edited.offlineAlerts = false
        XCTAssertTrue(edited.hasSameConnection(as: server))
        edited.auth.kind = .bearer
        XCTAssertFalse(edited.hasSameConnection(as: server))
    }

    // MARK: - Auth

    func testCredentialsForEveryAuthKind() throws {
        let endpoint = try XCTUnwrap(RemoteEndpoint(baseURL: "https://llm.example.com", name: "Box"))
        func request(_ auth: ModelServerAuth, _ secrets: ModelServerSecrets) throws -> URLRequest {
            try endpoint.request(path: "/v1/models", credentials: try auth.credentials(secrets, endpoint: "Box"))
        }
        func kind(_ auth: ModelServerAuth, _ secrets: ModelServerSecrets) -> RemoteError.Kind? {
            do {
                _ = try request(auth, secrets)
                return nil
            } catch {
                return (error as? RemoteError)?.kind
            }
        }

        XCTAssertNil(try request(.none, ModelServerSecrets()).value(forHTTPHeaderField: "Authorization"))

        let bearer = try request(ModelServerAuth(kind: .bearer), ModelServerSecrets(token: " sk-local-123\n"))
        XCTAssertEqual(bearer.value(forHTTPHeaderField: "Authorization"), "Bearer sk-local-123")
        XCTAssertEqual(kind(ModelServerAuth(kind: .bearer), ModelServerSecrets()), .missingToken)

        let basic = try request(ModelServerAuth(kind: .basic, username: "milo"), ModelServerSecrets(password: "p:ä ss"))
        XCTAssertEqual(basic.value(forHTTPHeaderField: "Authorization"),
                       "Basic " + Data("milo:p:ä ss".utf8).base64EncodedString())
        XCTAssertEqual(kind(ModelServerAuth(kind: .basic, username: "milo"), ModelServerSecrets()),
                       .missingSecret(what: "password"))
        XCTAssertEqual(kind(ModelServerAuth(kind: .basic), ModelServerSecrets(password: "x")),
                       .missingSecret(what: "user name"))

        let access = ModelServerAuth(kind: .cloudflareAccess, clientID: "abc.access")
        let viaAccess = try request(access, ModelServerSecrets(clientSecret: "s3cret"))
        XCTAssertEqual(viaAccess.value(forHTTPHeaderField: "CF-Access-Client-Id"), "abc.access")
        XCTAssertEqual(viaAccess.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "s3cret")
        XCTAssertNil(viaAccess.value(forHTTPHeaderField: "Authorization"))
        let withKey = try request(access, ModelServerSecrets(token: "sk-origin", clientSecret: "s3cret"))
        XCTAssertEqual(withKey.value(forHTTPHeaderField: "Authorization"), "Bearer sk-origin", "an API key behind Access")
        XCTAssertEqual(kind(access, ModelServerSecrets()), .missingSecret(what: "Access client secret"))

        let custom = ModelServerAuth(kind: .headers, headerNames: ["X-Api-Key", "X-Team"])
        let headers = try request(custom, ModelServerSecrets(headerValues: ["x-api-key": "k1", "X-Team": "blue"]))
        XCTAssertEqual(headers.value(forHTTPHeaderField: "X-Api-Key"), "k1")
        XCTAssertEqual(headers.value(forHTTPHeaderField: "X-Team"), "blue")
        XCTAssertEqual(kind(custom, ModelServerSecrets(headerValues: ["X-Api-Key": "k1"])),
                       .missingSecret(what: "value for the X-Team header"))
        XCTAssertEqual(kind(ModelServerAuth(kind: .headers), ModelServerSecrets()), .missingSecret(what: "header"))
        XCTAssertEqual(kind(ModelServerAuth(kind: .headers, headerNames: ["Host"]), ModelServerSecrets(headerValues: ["Host": "x"])),
                       .invalidHeader(name: "Host"))
        XCTAssertEqual(kind(ModelServerAuth(kind: .headers, headerNames: ["X Bad"]),
                            ModelServerSecrets(headerValues: ["X Bad": "x"])), .invalidHeader(name: "X Bad"))
        XCTAssertEqual(kind(ModelServerAuth(kind: .headers, headerNames: ["X-Key"]),
                            ModelServerSecrets(headerValues: ["X-Key": "a\r\nX-Evil: 1"])), .invalidToken)

        let extra = try request(ModelServerAuth(kind: .bearer, headerNames: ["X-Team"]),
                                ModelServerSecrets(token: "sk-1", headerValues: ["X-Team": "blue"]))
        XCTAssertEqual(extra.value(forHTTPHeaderField: "Authorization"), "Bearer sk-1")
        XCTAssertEqual(extra.value(forHTTPHeaderField: "X-Team"), "blue", "extra headers ride along with any kind")
    }

    func testSecretsNeverPrintAndArePrunedToTheAuth() throws {
        let secrets = ModelServerSecrets(token: "sk-1", password: "pw", clientSecret: "cs", headerValues: ["X-Key": "hv", "Old": "x"])
        for text in [String(describing: secrets), String(reflecting: secrets), "\(secrets)"] {
            for value in ["sk-1", "pw", "cs", "hv"] { XCTAssertFalse(text.contains(value), text) }
        }
        let credentials = try ModelServerAuth(kind: .basic, username: "u").credentials(secrets, endpoint: "Box")
        XCTAssertFalse(String(describing: credentials).contains(Data("u:pw".utf8).base64EncodedString()))

        XCTAssertEqual(secrets.pruned(for: ModelServerAuth(kind: .bearer, headerNames: ["x-key"])),
                       ModelServerSecrets(token: "sk-1", headerValues: ["X-Key": "hv"]))
        XCTAssertEqual(secrets.pruned(for: ModelServerAuth(kind: .basic, username: "u")), ModelServerSecrets(password: "pw"))
        XCTAssertTrue(secrets.pruned(for: .none).isEmpty)
        XCTAssertTrue(ModelServerSecrets(token: "  ").isEmpty)
    }

    // MARK: - Classification

    func testClassificationPerAuthKind() throws {
        let endpoint = try XCTUnwrap(RemoteEndpoint(baseURL: "http://llm.example.com", name: "Box"))
        func kind(_ status: Int, auth: ModelServerAuthKind, type: String? = "application/json", location: String? = nil,
                  challenge: String? = nil, body: String = "") -> RemoteError.Kind? {
            if case .failure(let error) = endpoint.classify(status: status, contentType: type, location: location,
                                                            body: Data(body.utf8), auth: auth, challenge: challenge) {
                return error.kind
            }
            return nil
        }
        let page = "<!doctype html><html><body>nginx</body></html>"
        let accessPage = "<html><body>Forbidden. Sign in at https://team.cloudflareaccess.com</body></html>"
        let login = "https://team.cloudflareaccess.com/cdn-cgi/access/login/llm.example.com?kid=x"

        XCTAssertNil(kind(200, auth: .none, type: "text/plain; version=0.0.4", body: "vllm:x 1"))
        XCTAssertEqual(kind(401, auth: .none, body: #"{"error":"Unauthorized"}"#), .authRequired(scheme: nil))
        XCTAssertEqual(kind(401, auth: .none, type: "text/html", challenge: #"Basic realm="llm""#, body: page),
                       .authRequired(scheme: "basic"))
        XCTAssertEqual(kind(403, auth: .none), .http(status: 403))
        XCTAssertEqual(kind(401, auth: .bearer, body: #"{"error":{"message":"Invalid API key","type":"auth"}}"#),
                       .tokenRejected(status: 401, message: "Invalid API key"))
        XCTAssertEqual(kind(401, auth: .bearer, type: "text/html", body: page), .tokenRejected(status: 401, message: nil))
        XCTAssertEqual(kind(403, auth: .headers), .tokenRejected(status: 403, message: nil))
        XCTAssertEqual(kind(401, auth: .basic, type: "text/html", body: page), .credentialsRejected(status: 401))
        XCTAssertEqual(kind(403, auth: .basic), .credentialsRejected(status: 403))

        XCTAssertEqual(kind(302, auth: .cloudflareAccess, location: login), .accessRejected(status: 302))
        XCTAssertEqual(kind(302, auth: .none, location: login), .accessRequired(host: "team.cloudflareaccess.com"))
        XCTAssertEqual(kind(403, auth: .cloudflareAccess, type: "text/html", body: page), .accessRejected(status: 403))
        XCTAssertEqual(kind(403, auth: .cloudflareAccess), .accessRejected(status: 403))
        XCTAssertEqual(kind(200, auth: .cloudflareAccess, type: "text/html", body: accessPage), .accessRejected(status: 200))
        XCTAssertEqual(kind(200, auth: .bearer, type: "text/html", body: accessPage), .accessRequired(host: nil))
        XCTAssertEqual(kind(401, auth: .cloudflareAccess, body: #"{"error":"Unauthorized"}"#),
                       .tokenRejected(status: 401, message: "Unauthorized"), "past Access, the origin wants its own key")
        XCTAssertEqual(kind(200, auth: .cloudflareAccess, type: "text/html", body: page), .htmlPage(status: 200))

        XCTAssertEqual(kind(200, auth: .none, type: "text/html", body: page), .htmlPage(status: 200))
        XCTAssertEqual(kind(301, auth: .none, location: "https://llm.example.com/v1/models"), .httpsRequired)
        XCTAssertEqual(kind(301, auth: .none, location: "https://other.example.com/"),
                       .redirected(status: 301, host: "other.example.com"))
        XCTAssertEqual(kind(404, auth: .bearer), .http(status: 404))

        let rejected = RemoteError(.accessRejected(status: 403), endpoint: "Box")
        XCTAssertEqual(rejected.errorDescription, "Cloudflare Access rejected the service token for Box")
        XCTAssertTrue(rejected.isAuthFailure)
        XCTAssertFalse(rejected.isUnreachable)
    }

    func testTransportFailuresAreNamed() {
        func kind(_ code: URLError.Code) -> RemoteError.Kind { RemoteError(URLError(code), endpoint: "Box").kind }
        XCTAssertEqual(kind(.appTransportSecurityRequiresSecureConnection), .insecureHTTPBlocked)
        XCTAssertEqual(kind(.timedOut), .timedOut)
        XCTAssertEqual(kind(.cannotFindHost), .hostNotFound)
        XCTAssertEqual(kind(.dnsLookupFailed), .hostNotFound)
        XCTAssertEqual(kind(.cannotConnectToHost), .connectionRefused)
        for code in [URLError.Code.serverCertificateUntrusted, .serverCertificateHasBadDate, .secureConnectionFailed,
                     .clientCertificateRequired] {
            guard case .tlsFailure = kind(code) else { return XCTFail("\(code) is a TLS failure") }
        }
        guard case .transport = kind(.networkConnectionLost) else { return XCTFail("other errors keep their text") }

        XCTAssertTrue(RemoteError(.timedOut, endpoint: "Box").isUnreachable)
        XCTAssertTrue(RemoteError(.http(status: 502), endpoint: "Box").isUnreachable, "a proxy with no origin behind it")
        XCTAssertFalse(RemoteError(.http(status: 404), endpoint: "Box").isUnreachable)
        XCTAssertFalse(RemoteError(.http(status: 501), endpoint: "Box").isUnreachable, "llama.cpp without --metrics")
        XCTAssertFalse(RemoteError(.insecureHTTPBlocked, endpoint: "Box").isUnreachable)
        XCTAssertEqual(ModelServerAvailability(.failure(RemoteError(.connectionRefused, endpoint: "Box"))), .offline)
        XCTAssertEqual(ModelServerAvailability(.failure(RemoteError(.tokenRejected(status: 401, message: nil),
                                                                    endpoint: "Box"))), .blocked)
    }

    // MARK: - Plain HTTP

    func testPlainHTTPPolicyMatchesWhatATSAllows() {
        let plist: [String: Any] = ["CFBundleIdentifier": "x", "NSAppTransportSecurity": [
            "NSAllowsLocalNetworking": true,
            "NSExceptionDomains": ["192.168.0.0/16": ["NSExceptionAllowsInsecureHTTPLoads": true]]]]
        let policy = PlainHTTPPolicy(infoDictionary: plist)
        for allowed in ["http://127.0.0.1:8000", "http://localhost:11434", "http://[::1]:8080", "http://192.168.40.141:8888",
                        "http://10.1.2.3:8000", "http://172.16.5.5", "http://172.31.255.1", "http://169.254.3.3",
                        "http://[fd7a:115c:a1e0::1]:8000", "http://zgx:8000", "http://zgx.local:8000", "http://ZGX.Local.",
                        "https://llm.example.com", "https://100.64.0.9"] {
            XCTAssertTrue(policy.allows(allowed), allowed)
        }
        for blocked in ["http://llm.example.com", "http://203.0.113.1:8000", "http://100.64.0.9:8000", "http://172.32.0.1",
                        "http://box.tail1234.ts.net:8000", "http://nas.lan", "http://nas.home.arpa", "http://nas.internal",
                        "http://[2001:db8::1]:8000"] {
            XCTAssertFalse(policy.allows(blocked), blocked)
        }

        var wider = plist
        wider["NSAppTransportSecurity"] = ["NSAllowsLocalNetworking": true, "NSExceptionDomains": [
            "100.64.0.0/10": ["NSExceptionAllowsInsecureHTTPLoads": true],
            "ts.net": ["NSExceptionAllowsInsecureHTTPLoads": true, "NSIncludesSubdomains": true],
            "lan": ["NSExceptionAllowsInsecureHTTPLoads": true],
            "example.org": ["NSIncludesSubdomains": true]]]
        let tailscale = PlainHTTPPolicy(infoDictionary: wider)
        XCTAssertTrue(tailscale.allows("http://100.64.0.9:8000"))
        XCTAssertTrue(tailscale.allows("http://100.127.255.1:8000"))
        XCTAssertFalse(tailscale.allows("http://100.128.0.1:8000"))
        XCTAssertTrue(tailscale.allows("http://box.tail1234.ts.net:8000"))
        XCTAssertFalse(tailscale.allows("http://nas.lan"), "no NSIncludesSubdomains, so only the bare name")
        XCTAssertFalse(tailscale.allows("http://a.example.org"), "an exception that doesn't allow insecure loads")

        XCTAssertTrue(PlainHTTPPolicy(infoDictionary: nil).allows("http://llm.example.com"), "no Info.plist, no ATS")
        XCTAssertFalse(PlainHTTPPolicy(infoDictionary: ["CFBundleIdentifier": "x"]).allows("http://192.168.1.2"))
        XCTAssertTrue(PlainHTTPPolicy(infoDictionary: ["NSAppTransportSecurity": ["NSAllowsArbitraryLoads": true]])
            .allows("http://llm.example.com"))
    }

    // MARK: - Engines

    func testVLLMAndTensorfoldFixtures() throws {
        let expected: [(String, ModelEngine, ModelServerMetrics)] = [
            ("vllm_metrics.txt", .vllm, ModelServerMetrics(
                model: "Qwen/Qwen3-Coder-30B-A3B-Instruct", running: 2, waiting: 1, kvCacheUsage: 0.4375,
                promptTokensTotal: 120_000, generationTokensTotal: 45_000, generationTokensCounter: 45_000)),
            ("tensorfold_metrics.txt", .tensorfold, ModelServerMetrics(
                running: 0, waiting: 0, kvCacheUsage: 0, promptTokensTotal: 7_725_987, generationTokensTotal: 54_353,
                generationTokensCounter: 54_353, memoryBytes: 87_744_562_592)),
        ]
        for (name, engine, metrics) in expected {
            let samples = PrometheusParser.parse(try Fixture.text(name))
            let dialect = try XCTUnwrap(PrometheusDialect.detect(samples), name)
            XCTAssertEqual(dialect.engine, engine)
            XCTAssertEqual(dialect.metrics(from: samples), metrics, name)
        }
        let tensorfold = try XCTUnwrap(snapshot([.metrics: .success(try Fixture.data("tensorfold_metrics.txt")),
                                                 .openAIModels: missing()]).get())
        XCTAssertEqual(tensorfold.engine, .tensorfold)
        XCTAssertEqual(tensorfold.metrics.memoryBytes, 87_744_562_592)
        XCTAssertEqual(tensorfold.capabilities, [.generationRate, .promptRate, .running, .waiting, .kvCache, .memory])
        XCTAssertTrue(tensorfold.models.isEmpty)

        let vllm = try snapshot([.metrics: .success(try Fixture.data("vllm_metrics.txt")),
                                 .openAIModels: .success(try shapes("vllm_models"))]).get()
        XCTAssertEqual(vllm.engine, .vllm)
        XCTAssertEqual(vllm.models, [ServedModel(id: "Qwen/Qwen3-Coder-30B-A3B-Instruct", contextLength: 262_144, ownedBy: "vllm")])
        XCTAssertEqual(vllm.primaryModel, "Qwen/Qwen3-Coder-30B-A3B-Instruct")
        XCTAssertFalse(vllm.capabilities.contains(.memory))
        XCTAssertFalse(vllm.capabilities.contains(.loadedModels))
    }

    func testLlamaCppWithAndWithoutMetrics() throws {
        let full = try snapshot([.metrics: .success(try Fixture.data("synthetic_llamacpp_metrics.txt")),
                                 .openAIModels: .success(try shapes("llamacpp_models")),
                                 .llamaCppProps: .success(try shapes("llamacpp_props"))]).get()
        XCTAssertEqual(full.engine, .llamaCpp)
        XCTAssertEqual(full.metrics, ModelServerMetrics(running: 1, waiting: 2, kvCacheUsage: 0.25, promptTokensTotal: 18_240,
                                                        generationTokensTotal: 5_120, generationTokensCounter: 5_120))
        XCTAssertEqual(full.models.map(\.id), ["qwen2.5-coder-7b-q4_k_m.gguf"])
        XCTAssertEqual(full.models.first?.contextLength, 32_768)
        XCTAssertEqual(full.version, "b4589-abc1234")
        XCTAssertTrue(full.hints.isEmpty)

        let bare = try snapshot([.metrics: missing(501), .openAIModels: .success(try shapes("llamacpp_models")),
                                 .llamaCppProps: .success(try shapes("llamacpp_props"))]).get()
        XCTAssertEqual(bare.engine, .llamaCpp)
        XCTAssertEqual(bare.hints, [.metricsDisabled(.llamaCpp)])
        XCTAssertEqual(bare.capabilities, [.models, .version], "nothing it doesn't report is claimed")
        XCTAssertTrue(bare.metrics.isEmpty)

        let propsOnly = try snapshot([.llamaCppProps: .success(try shapes("llamacpp_props")), .openAIModels: missing()]).get()
        XCTAssertEqual(propsOnly.models, [ServedModel(id: "qwen2.5-coder-7b-q4_k_m.gguf", loaded: true, contextLength: 8_192)])
    }

    func testSGLangAndTGI() throws {
        let sglang = try snapshot([.metrics: .success(try Fixture.data("synthetic_sglang_metrics.txt"))]).get()
        XCTAssertEqual(sglang.engine, .sglang)
        XCTAssertEqual(sglang.metrics.running, 3)
        XCTAssertEqual(sglang.metrics.waiting, 1)
        XCTAssertEqual(sglang.metrics.kvCacheUsage, 0.31)
        XCTAssertEqual(sglang.metrics.generationTokensCounter, 31_200)
        XCTAssertEqual(sglang.metrics.reportedGenerationRate, 142.5)
        XCTAssertEqual(sglang.models, [ServedModel(id: "Qwen/Qwen2.5-Coder-32B-Instruct", loaded: true)])

        let tgi = try snapshot([.metrics: .success(try Fixture.data("synthetic_tgi_metrics.txt")),
                                .tgiInfo: .success(try shapes("tgi_info"))]).get()
        XCTAssertEqual(tgi.engine, .tgi)
        XCTAssertEqual(tgi.metrics, ModelServerMetrics(running: 2, waiting: 4, promptTokensTotal: 210_400,
                                                       generationTokensTotal: 48_800, generationTokensCounter: 48_800))
        XCTAssertEqual(tgi.models, [ServedModel(id: "mistralai/Mistral-7B-Instruct-v0.3", loaded: true, contextLength: 4_096)])
        XCTAssertEqual(tgi.version, "3.0.1")
        XCTAssertFalse(tgi.capabilities.contains(.kvCache))
    }

    func testOllamaAndLMStudioAndPlainOpenAI() throws {
        let ollama = try snapshot([.metrics: missing(), .openAIModels: .success(try shapes("ollama_openai_models")),
                                   .ollamaVersion: .success(try shapes("ollama_version")),
                                   .ollamaTags: .success(try shapes("ollama_tags")),
                                   .ollamaRunning: .success(try shapes("ollama_ps")),
                                   .lmStudioModels: missing(), .llamaCppProps: missing(), .tgiInfo: missing()]).get()
        XCTAssertEqual(ollama.engine, .ollama)
        XCTAssertEqual(ollama.version, "0.12.3")
        XCTAssertEqual(ollama.models, [
            ServedModel(id: "qwen3:8b", loaded: true, memoryBytes: 6_654_289_920, contextLength: 8_192, detail: "8.2B · Q4_K_M"),
            ServedModel(id: "llama3.2:latest", loaded: false, detail: "3.2B · Q4_K_M")])
        XCTAssertEqual(ollama.primaryModel, "qwen3:8b")
        XCTAssertEqual(ollama.memoryBytes, 6_654_289_920)
        XCTAssertEqual(ollama.capabilities, [.models, .loadedModels, .memory, .version])
        XCTAssertTrue(ollama.hints.isEmpty, "Ollama has no /metrics to miss")

        let studio = try snapshot([.lmStudioModels: .success(try shapes("lmstudio_models")),
                                   .openAIModels: .success(try shapes("lmstudio_openai_models")), .metrics: missing()]).get()
        XCTAssertEqual(studio.engine, .lmStudio)
        XCTAssertEqual(studio.models.map(\.loaded), [true, false])
        XCTAssertEqual(studio.models.first?.contextLength, 8_192)
        XCTAssertEqual(studio.primaryModel, "qwen2.5-coder-14b-instruct")

        let proxy = try snapshot([.openAIModels: .success(try shapes("litellm_models")), .metrics: missing(),
                                  .ollamaVersion: missing(), .lmStudioModels: missing()]).get()
        XCTAssertEqual(proxy.engine, .openAICompatible)
        XCTAssertEqual(proxy.models.map(\.id), ["claude-sonnet-4-5", "local-qwen"])
        XCTAssertNil(proxy.primaryModel, "several models and none marked loaded")
        XCTAssertEqual(proxy.capabilities, [.models])

        let renamed = "acme:num_requests_running 2\nacme:generation_tokens_total 10\nacme:prompt_tokens_total 40\n"
        let unknown = try snapshot([.metrics: .success(Data(renamed.utf8)), .openAIModels: missing()]).get()
        XCTAssertEqual(unknown.engine, .openAICompatible)
        XCTAssertEqual(unknown.metricsPrefix, "acme:")
        XCTAssertEqual(unknown.metrics.generationTokensCounter, 10)
    }

    func testAnExplicitEngineIsKeptAndItsRoutesAreFew() throws {
        XCTAssertEqual(ModelServerDetector.routes(for: nil), ModelServerRoute.allCases)
        XCTAssertEqual(ModelServerDetector.routes(for: .ollama), [.ollamaRunning, .ollamaTags, .ollamaVersion])
        XCTAssertEqual(ModelServerDetector.routes(for: .tensorfold), [.metrics, .openAIModels])
        let asVLLM = try snapshot([.metrics: .success(try Fixture.data("tensorfold_metrics.txt"))], engine: .vllm).get()
        XCTAssertEqual(asVLLM.engine, .vllm)
        XCTAssertEqual(asVLLM.metricsPrefix, "tensorfold:")
        XCTAssertEqual(asVLLM.metrics.promptTokensTotal, 7_725_987)
    }

    func testWhatAFailedDetectionReports() {
        func failure(_ answers: [ModelServerRoute: Result<Data, RemoteError>]) -> RemoteError.Kind? {
            if case .failure(let error) = snapshot(answers) { return error.kind }
            return nil
        }
        func failed(_ kind: RemoteError.Kind) -> Result<Data, RemoteError> { .failure(RemoteError(kind, endpoint: "Box")) }

        XCTAssertEqual(failure([.metrics: failed(.connectionRefused), .openAIModels: failed(.connectionRefused)]),
                       .connectionRefused)
        XCTAssertEqual(failure([.metrics: missing(), .openAIModels: failed(.tokenRejected(status: 401, message: nil))]),
                       .tokenRejected(status: 401, message: nil))
        XCTAssertEqual(failure([.metrics: failed(.htmlPage(status: 200)), .openAIModels: failed(.htmlPage(status: 200))]),
                       .htmlPage(status: 200))
        XCTAssertEqual(failure([.metrics: missing(), .openAIModels: missing(), .ollamaTags: failed(.timedOut)]), .noModelServer)
        XCTAssertEqual(failure([.metrics: .success(Data("go_goroutines 12\n".utf8)), .openAIModels: missing()]),
                       .noModelServer, "Prometheus text from something that isn't a model server")
        XCTAssertEqual(failure([.metrics: failed(.insecureHTTPBlocked), .openAIModels: failed(.insecureHTTPBlocked)]),
                       .insecureHTTPBlocked)
        XCTAssertEqual(failure([.metrics: missing(502), .openAIModels: missing(502)]), .http(status: 502))
        XCTAssertEqual(failure([.openAIModels: .success(Data(#"{"error":"not found"}"#.utf8))]), .noModelServer)
    }

    // MARK: - Status and series

    func testRatesComeFromCountersOrTheEnginesOwnGauge() throws {
        func llama(_ generated: Double, _ prompt: Double, at offset: TimeInterval) -> ModelServerSnapshot {
            ModelServerSnapshot(engine: .llamaCpp, metrics: ModelServerMetrics(promptTokensTotal: prompt,
                                                                               generationTokensTotal: generated,
                                                                               generationTokensCounter: generated),
                                takenAt: t0.addingTimeInterval(offset))
        }
        XCTAssertNil(ModelServerStatus.compute(previous: nil, current: llama(100, 400, at: 0)).generationTokensPerSecond)
        let moving = ModelServerStatus.compute(previous: llama(100, 400, at: 0), current: llama(350, 1_400, at: 5))
        XCTAssertEqual(moving.generationTokensPerSecond, 50)
        XCTAssertEqual(moving.promptTokensPerSecond, 200)
        XCTAssertNil(ModelServerStatus.compute(previous: llama(350, 1_400, at: 5), current: llama(20, 80, at: 10))
            .generationTokensPerSecond, "a restart")

        var other = llama(0, 0, at: 0)
        other.engine = .vllm
        XCTAssertNil(ModelServerStatus.compute(previous: other, current: llama(350, 1_400, at: 5)).generationTokensPerSecond,
                     "another engine's counters are no baseline")

        let gaugeOnly = ModelServerSnapshot(engine: .sglang, metrics: ModelServerMetrics(reportedGenerationRate: 142.5),
                                            takenAt: t0)
        XCTAssertEqual(ModelServerStatus.compute(previous: nil, current: gaugeOnly).generationTokensPerSecond, 142.5)

        let ollama = ModelServerSnapshot(engine: .ollama, models: [ServedModel(id: "qwen3:8b", loaded: true)], takenAt: t0)
        let idle = ModelServerStatus.compute(previous: ollama, current: ollama)
        XCTAssertNil(idle.generationTokensPerSecond)
        XCTAssertFalse(idle.capabilities.contains(.generationRate), "hidden, not zero")
    }

    func testSeriesAreKeyedByServerAndTheLegacyOneKeepsItsNames() throws {
        XCTAssertEqual(ModelServerSeries.name(ModelServerSeries.generatedTokens, server: ModelServer.legacyID),
                       "model.generation_tokens")
        XCTAssertEqual(ModelServerSeries.name(ModelServerSeries.generatedTokens, server: "a1b2"),
                       "model.a1b2.generation_tokens")
        XCTAssertEqual(ModelServerSeries.names(ModelServerSeries.counters, server: "a1b2"),
                       ["model.a1b2.generation_tokens", "model.a1b2.prompt_tokens"])

        let vllm = try XCTUnwrap(snapshot([.metrics: .success(try Fixture.data("vllm_metrics.txt"))]).get())
        var later = vllm
        later.takenAt = t0.addingTimeInterval(5)
        let polled = ModelServerStatus.compute(previous: vllm, current: later)
        XCTAssertEqual(ModelServerSeries.observations(polled, server: ModelServer.legacyID).map(\.series),
                       ["model.generation_tps", "model.prompt_tps", "model.kv_cache_pct", "model.running", "model.waiting",
                        "model.generation_tokens", "model.prompt_tokens"],
                       "the legacy server writes exactly the series it always did")

        let ollama = ModelServerSnapshot(engine: .ollama,
                                         models: [ServedModel(id: "qwen3:8b", loaded: true, memoryBytes: 6e9)], takenAt: t0)
        XCTAssertEqual(ModelServerSeries.observations(ModelServerStatus(snapshot: ollama), server: "ol"),
                       [SampleObservation(series: "model.ol.memory_bytes", ts: t0, value: 6e9, kind: .gauge)],
                       "an engine without counters writes no zero-valued series")
    }

    // MARK: - Local models

    func testExactLocalPatterns() {
        XCTAssertEqual(PricingTable.exactLocalPattern(for: " Qwen3.8-Flash-Next "), "=qwen3.8-flash-next")
        let patterns = ["qwen", "=local-llama"]
        XCTAssertEqual(PricingTable.localPattern(matching: "Qwen3.8-Flash-Next", in: patterns), "qwen")
        XCTAssertEqual(PricingTable.localPattern(matching: "Local-Llama", in: patterns), "=local-llama")
        XCTAssertNil(PricingTable.localPattern(matching: "local-llama-70b", in: patterns), "exact means the whole id")
        XCTAssertNil(PricingTable.localPattern(matching: "claude-sonnet-4-5", in: patterns))
        XCTAssertNil(PricingTable.localPattern(matching: nil, in: patterns))

        let added = PricingTable.treatingAsLocal("Mistral-7B", true, patterns: patterns)
        XCTAssertEqual(added, ["qwen", "=local-llama", "=mistral-7b"])
        XCTAssertEqual(PricingTable.treatingAsLocal("qwen3:8b", true, patterns: patterns), patterns, "already covered")
        XCTAssertEqual(PricingTable.treatingAsLocal("Mistral-7B", false, patterns: added), patterns)
        XCTAssertEqual(PricingTable.treatingAsLocal("qwen3:8b", false, patterns: patterns), patterns,
                       "a substring pattern isn't removed for one model")

        let table = PricingTable.bundled(localModelPatterns: added)
        XCTAssertTrue(table.isLocal("mistral-7b"))
        XCTAssertFalse(table.isLocal("mistral-7b-instruct"))
        XCTAssertEqual(table.price(model: "Mistral-7B", tokens: TokenCounts(input: 10, output: 10), speed: nil).costUSD, 0)
        XCTAssertNotEqual(PricingTable.bundled(localModelPatterns: patterns).revision, table.revision)
    }

    // MARK: - Discovery

    func testDiscoverySkipsTheHubAndConfiguredLoopbackServers() {
        let configured = [ModelServer(id: "a", baseURL: "http://127.0.0.1:11434"),
                          ModelServer(id: "b", baseURL: "http://localhost:8080/v1"),
                          ModelServer(id: "c", baseURL: "http://192.168.40.141:8000")]
        let ports = ModelServerDiscovery.ports(hubPort: 1234, configured: configured)
        XCTAssertFalse(ports.contains(11434))
        XCTAssertFalse(ports.contains(8080))
        XCTAssertFalse(ports.contains(1234), "the hub's own port")
        XCTAssertTrue(ports.contains(8000), "a LAN server on :8000 says nothing about this Mac's :8000")
        XCTAssertEqual(ModelServerDiscovery.ports([9001, 9001, 0, 70_000, 4318], hubPort: 4318, configured: []), [9001])
        XCTAssertEqual(ModelServerDiscovery.server(port: 11434).baseURL, "http://localhost:11434")
        XCTAssertNil(ModelServerDiscovery.server(port: 11434).engine)
    }
}
