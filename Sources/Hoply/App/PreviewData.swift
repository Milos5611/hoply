import AgentKit
import AgentSystem
import Foundation

enum PreviewData {
    static var settings: AppSettings {
        var settings = AppSettings()
        settings.modelServers = [zgxServer]
        settings.claudeLimitsEnabled = true
        settings.quietHoursEnabled = true
        settings.mutedProjectRoots = ["\(NSHomeDirectory())/Project/hoply"]
        settings.priceAliases = ["claude-sonnet-4-5": "claude-sonnet-5"]
        return settings
    }

    static let approvalSession = SessionKey(source: .claudeCode, id: "approval")

    static func approvalEvents(now: Date) -> [AgentEvent] {
        [AgentEvent(key: approvalSession, kind: .promptSubmitted("Upgrade the build to Node 24"), time: now - 300,
                    cwd: "\(NSHomeDirectory())/Project/fiba", model: "claude-opus-5", fromHook: true),
         AgentEvent(key: approvalSession, kind: .needsPermission("Allow Bash?"), time: now - 20, fromHook: true)]
    }

    static func approvals(now: Date) -> [ApprovalRequest] {
        [ApprovalRequest(key: approvalSession, tool: "Bash", detail: "rm -rf node_modules && npm ci && npm run build",
                         received: now - 20)]
    }

    static func events(now: Date) -> [AgentEvent] {
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        func key(_ source: AgentSource, _ id: String) -> SessionKey { SessionKey(source: source, id: id) }
        let auth = key(.claudeCode, "auth")
        let orders = key(.copilotCLI, "orders")
        let tests = key(.qwenCode, "tests")
        let pricing = key(.claudeCode, "pricing")
        let docs = key(.claudeCode, "docs")
        let hero = key(.codexCLI, "hero")
        let store = key(.copilotCLI, "store")
        let schema = key(.claudeCode, "schema")
        let notes = key(.claudeCode, "notes")
        let lint = key(.claudeCode, "lint")
        let home = NSHomeDirectory()
        return [
            AgentEvent(key: auth, kind: .promptSubmitted("Refactor the auth middleware to use refresh tokens"),
                       time: at(46), cwd: "\(home)/Project/fiba", model: "claude-opus-5", fromHook: true),
            AgentEvent(key: auth, kind: .usage(.init(inputTokens: 21_000, outputTokens: 9_000, cacheTokens: 24_000, costUSD: 0.21)),
                       time: at(5), fromHook: false),
            AgentEvent(key: auth, kind: .turnFinished("Middleware now refreshes tokens; all 214 tests pass."),
                       time: at(4), fromHook: true),
            AgentEvent(key: orders, kind: .promptSubmitted("Add pagination to the orders endpoint"),
                       time: at(12), cwd: "\(home)/Project/yasm-backend", fromHook: true),
            AgentEvent(key: orders, kind: .needsPermission("Run `dotnet test` in yasm-backend?"),
                       time: at(1), fromHook: true),
            AgentEvent(key: schema, kind: .promptSubmitted("Add the invoices table and its migration"),
                       time: at(9), cwd: "\(home)/Project/yasm-backend", model: "claude-opus-5", fromHook: true),
            AgentEvent(key: schema, kind: .questionAsked("Which migration tool should this use: EF Core or DbUp?"),
                       time: at(2), fromHook: true),
            AgentEvent(key: notes, kind: .promptSubmitted("Summarise this week's meeting notes"),
                       time: at(35), cwd: "\(home)/Documents/notes", model: "claude-haiku-4-5", fromHook: true),
            AgentEvent(key: notes, kind: .turnFinished("Stopped at the Thursday notes: usage limit reached."),
                       time: at(21), fromHook: true),
            AgentEvent(key: lint, kind: .promptSubmitted("Fix the analyzer warnings in the rule engine"),
                       time: at(14), cwd: "\(home)/Project/FIBA3x3.RuleEngine", model: "claude-sonnet-5", fromHook: true),
            AgentEvent(key: lint, kind: .turnFailed(error: "overloaded_error", message: "API Error: 529 Overloaded"),
                       time: at(6), fromHook: true),
            AgentEvent(key: pricing, kind: .promptSubmitted("Build the pricing section"),
                       time: at(42), cwd: "\(home)/Project/fiba", model: "claude-sonnet-5", fromHook: true),
            AgentEvent(key: pricing, kind: .subagentStarted(id: "a1", type: "Explore"), time: at(30), fromHook: true),
            AgentEvent(key: pricing, kind: .subagentStopped(id: "a1", type: "Explore"), time: at(24), fromHook: true),
            AgentEvent(key: pricing, kind: .subagentStarted(id: "a2", type: "code-reviewer"), time: at(3), fromHook: true),
            AgentEvent(key: pricing, kind: .subagentStarted(id: "a3", type: "test-runner"), time: at(1), fromHook: true),
            AgentEvent(key: pricing, kind: .toolStarted("Edit"), time: at(0.2), fromHook: true),
            AgentEvent(key: pricing, kind: .usage(.init(inputTokens: 80_000, outputTokens: 30_000, cacheTokens: 300_000, costUSD: 0.64)),
                       time: at(0.5), fromHook: false),
            AgentEvent(key: tests, kind: .promptSubmitted("Write unit tests for the Prometheus parser"),
                       time: at(6), cwd: "\(home)/Project/hoply", model: "qwen3-coder", fromHook: false),
            AgentEvent(key: tests, kind: .usage(.init(inputTokens: 2_100, outputTokens: 900)), time: at(0.3), fromHook: false),
            AgentEvent(key: docs, kind: .sessionStarted, time: at(8), cwd: "\(home)/Project/hoply",
                       model: "claude-opus-5", fromHook: true),
            AgentEvent(key: hero, kind: .promptSubmitted("Polish the landing page hero animation"),
                       time: at(18), cwd: "\(home)/Project/fiba.worktrees/landing-hero", model: "gpt-6.1-sol",
                       fromHook: true),
            AgentEvent(key: hero, kind: .toolStarted("Bash"), time: at(0.4), fromHook: true),
            AgentEvent(key: store, kind: .promptSubmitted("Speed up the Copilot store reader"),
                       time: at(25), cwd: "\(home)/Project/hoply/Sources/AgentSystem", model: "claude-opus-5",
                       fromHook: true),
            AgentEvent(key: store, kind: .sessionEnded(nil), time: at(3), fromHook: true),
        ]
    }

    static func activity(now: Date) -> RollingSeries {
        series(now: now, values: [1, 0, 2, 3, 1, 4, 6, 3, 2, 5, 7, 4, 3, 6, 8, 5, 9, 7, 11, 8], max: false)
    }

    static func throughput(now: Date) -> RollingSeries {
        series(now: now, values: [0, 0, 12, 38, 41, 40, 22, 0, 0, 35, 44, 43, 39, 30, 41, 45, 44, 38, 42, 43], max: true)
    }

    // MARK: - Model servers

    static let zgxServer = ModelServer(id: ModelServer.legacyID, name: "ZGX", baseURL: "http://zgx.local:8000")
    static let ollamaServer = ModelServer(id: "ollama", name: "Ollama", baseURL: "http://localhost:11434")
    static let teamServer = ModelServer(id: "team", name: "Team vLLM", baseURL: "https://llm.example.com", engine: .vllm,
                                        auth: ModelServerAuth(kind: .cloudflareAccess,
                                                              clientID: "5f1c0a9d2b7e4c63.access"))
    static let studioServer = ModelServer(id: "studio", name: "LM Studio", baseURL: "http://localhost:1234",
                                          enabled: false)

    static var severalServersSettings: AppSettings {
        var settings = settings
        settings.modelServers = [zgxServer, ollamaServer, teamServer, studioServer]
        return settings
    }

    static var twoServersSettings: AppSettings {
        var settings = settings
        settings.modelServers = [zgxServer, ollamaServer]
        return settings
    }

    static func vllmStatus(now: Date) -> ModelServerStatus {
        let name = "Qwen/Qwen3.8-Flash-Next"
        let metrics = ModelServerMetrics(model: name, running: 2, waiting: 1, kvCacheUsage: 0.44,
                                         promptTokensTotal: 61_406_100, generationTokensTotal: 2_845_215,
                                         generationTokensCounter: 2_845_215)
        let snapshot = ModelServerSnapshot(engine: .vllm, metricsPrefix: "vllm:",
                                           models: [ServedModel(id: name, loaded: true, contextLength: 262_144,
                                                                ownedBy: "vllm")],
                                           metrics: metrics, takenAt: now)
        return ModelServerStatus(snapshot: snapshot, generationTokensPerSecond: 43, promptTokensPerSecond: 1_220)
    }

    static func ollamaStatus(now: Date) -> ModelServerStatus {
        let models = [
            ServedModel(id: "qwen3-coder:30b", loaded: true, memoryBytes: 19_800_000_000, contextLength: 32_768,
                        detail: "Q4_K_M"),
            ServedModel(id: "nomic-embed-text:latest", loaded: true, memoryBytes: 610_000_000, detail: "F16"),
            ServedModel(id: "llama3.3:70b", loaded: false, detail: "Q4_K_M"),
            ServedModel(id: "gemma3:12b", loaded: false, detail: "Q4_K_M"),
            ServedModel(id: "claude-sonnet-5:cloud", loaded: false, detail: "remote"),
        ]
        return ModelServerStatus(snapshot: ModelServerSnapshot(engine: .ollama, version: "0.12.6", models: models,
                                                               takenAt: now))
    }

    static let accessRejected = RemoteError(.accessRejected(status: 403), endpoint: teamServer.displayName)

    static func modelServerStates(now: Date) -> [String: ModelServers.State] {
        var zgx = ModelServers.State(now: now)
        zgx.status = vllmStatus(now: now)
        zgx.availability = .online
        zgx.lastSeen = now
        zgx.throughput = throughput(now: now)
        var ollama = ModelServers.State(now: now)
        ollama.status = ollamaStatus(now: now)
        ollama.availability = .online
        ollama.lastSeen = now
        var team = ModelServers.State(now: now)
        team.availability = .blocked
        team.error = accessRejected
        return [zgxServer.id: zgx, ollamaServer.id: ollama, teamServer.id: team]
    }

    static func discovered(now: Date) -> [ModelServerCandidate] {
        var server = ModelServerDiscovery.server(port: 8080)
        server.name = ModelEngine.llamaCpp.displayName
        let model = ServedModel(id: "Qwen3-Coder-30B-Q4_K_M.gguf", loaded: true, contextLength: 32_768)
        let status = ModelServerStatus(snapshot: ModelServerSnapshot(engine: .llamaCpp, version: "b6715", models: [model],
                                                                     takenAt: now))
        return [ModelServerCandidate(server: server,
                                     probe: ModelServerProbe(server: server, result: .success(status), endpoints: [],
                                                             plainHTTPAllowed: true, at: now))]
    }

    static func editor(failed: Bool, now: Date) -> ModelServerEditor {
        func report(_ server: ModelServer, _ route: ModelServerRoute, _ status: Int?, _ error: RemoteError.Kind?,
                    _ milliseconds: Double) -> ModelServerRouteReport {
            ModelServerRouteReport(route: route, url: (server.endpoint?.url(path: route.path)?.absoluteString ?? ""),
                                   status: status, error: error.map { RemoteError($0, endpoint: server.displayName) },
                                   latency: milliseconds / 1_000)
        }
        if failed {
            let editor = ModelServerEditor(teamServer, isNew: false)
            editor.stored = ModelServers.StoredSecrets(clientSecret: true)
            editor.headers = [ModelServerEditor.Header(name: "X-Team")]
            editor.stored.headers = ["x-team"]
            let endpoints = [report(teamServer, .metrics, 403, .accessRejected(status: 403), 212),
                             report(teamServer, .openAIModels, 403, .accessRejected(status: 403), 187)]
            editor.test = .done(ModelServerProbe(server: editor.server, result: .failure(accessRejected),
                                                 endpoints: endpoints, plainHTTPAllowed: true, at: now))
            editor.showsEndpoints = true
            return editor
        }
        var server = ollamaServer
        server.name = ""
        server.baseURL = "localhost:11434/v1"
        let editor = ModelServerEditor(server, isNew: true)
        let tested = editor.server
        let missing = RemoteError.Kind.http(status: 404)
        let endpoints = [report(tested, .metrics, 404, missing, 3), report(tested, .openAIModels, 200, nil, 9),
                         report(tested, .ollamaVersion, 200, nil, 4), report(tested, .ollamaTags, 200, nil, 11),
                         report(tested, .ollamaRunning, 200, nil, 6), report(tested, .lmStudioModels, 404, missing, 3),
                         report(tested, .llamaCppProps, 404, missing, 2), report(tested, .tgiInfo, 404, missing, 3)]
        editor.test = .done(ModelServerProbe(server: tested, result: .success(ollamaStatus(now: now)),
                                             endpoints: endpoints, plainHTTPAllowed: true, at: now))
        editor.showsEndpoints = true
        return editor
    }

    static func ollamaLocalModel(_ data: LocalModelData?) -> LocalModelData? {
        guard var data else { return nil }
        data.serverID = ollamaServer.id
        data.memory = data.kvCache.map { bucket in
            let bytes = (bucket.mean ?? 0) > 12 ? 20_410_000_000.0 : 610_000_000.0
            return SampleBucket(series: ModelServerSeries.memoryBytes, resolution: bucket.resolution, start: bucket.start,
                                n: bucket.n, sum: bytes * Double(bucket.n), min: bytes, max: bytes)
        }
        data.generation = []
        data.kvCache = []
        data.tokenDays = []
        return data
    }

    static func claudeLimits(now: Date) -> ClaudeLimits? {
        let fiveHour = Int(now.addingTimeInterval(2.6 * 3_600).timeIntervalSince1970)
        let week = Int(now.addingTimeInterval(3.7 * 86_400).timeIntervalSince1970)
        let json = #"""
        {"five_hour":{"utilization":62,"resets_at":\#(fiveHour)},"seven_day":{"utilization":25,"resets_at":\#(week)},
         "model_scoped":[{"display_name":"Sonnet 4.5","utilization":\#(scopedShare * 25),"resets_at":\#(week)},
                         {"display_name":"Haiku 4.5","utilization":100,"resets_at":\#(fiveHour)}],
         "extra_usage":{"is_enabled":true,"used_credits":1240,"monthly_limit":5000,"utilization":24.8},
         "spend":{"enabled":true,"used":{"amount_minor":1240,"currency":"USD","exponent":2},
                  "limit":{"amount_minor":10000,"currency":"USD","exponent":2}},
         "seven_day_oauth_apps":null,"iguana_necktie":null}
        """#
        return try? ClaudeLimits.decode(Data(json.utf8))
    }

    private static let scopedShare = 0.48
    static let scopedKind = LimitKind.scoped(displayName: "Sonnet 4.5") ?? .sevenDaySonnet

    private static func series(now: Date, values: [Double], max: Bool) -> RollingSeries {
        var series = RollingSeries(bucketLength: 30, capacity: values.count, now: now)
        for (index, value) in values.enumerated() {
            let time = now.addingTimeInterval(-Double(values.count - 1 - index) * 30)
            if max { series.recordMax(value, at: time) } else { series.add(value, at: time) }
        }
        return series
    }

    // MARK: - Ledger

    static let backfilling = IngestProgress(filesDone: 51, filesTotal: 122, bytesDone: 112_000_000,
                                            bytesTotal: 261_000_000, isBackfilling: true,
                                            copilot: .ready(schemaVersion: 7))

    static var projectRefs: [ProjectRef] {
        let home = NSHomeDirectory()
        return [
            ProjectRef(id: 1, root: "\(home)/Project/fiba", name: "fiba", kind: .repo),
            ProjectRef(id: 2, root: "\(home)/Project/yasm-backend", name: "yasm-backend", kind: .repo),
            ProjectRef(id: 3, root: "\(home)/Project/hoply", name: "hoply", kind: .repo),
            ProjectRef(id: 4, root: "\(home)/Project/FIBA3x3.RuleEngine", name: "FIBA3x3.RuleEngine", kind: .repo),
            ProjectRef(id: 5, root: "\(home)/Documents/notes", name: "notes", kind: .folder),
            ProjectRef(id: 6, root: home, name: "Home", kind: .home),
        ]
    }

    static var projectsByCwd: [String: ProjectRef] {
        let home = NSHomeDirectory()
        let refs = projectRefs
        return ["\(home)/Project/fiba": refs[0], "\(home)/Project/fiba.worktrees/landing-hero": refs[0],
                "\(home)/Project/yasm-backend": refs[1], "\(home)/Project/hoply": refs[2],
                "\(home)/Project/hoply/Sources/AgentSystem": refs[2],
                "\(home)/Project/FIBA3x3.RuleEngine": refs[3], "\(home)/Documents/notes": refs[4]]
    }

    static func devServers(now: Date) -> DevServerScan {
        let home = NSHomeDirectory()
        let uid: UInt32 = 501
        func process(_ pid: Int32, parent: Int32 = 1, group: Int32? = nil, minutesAgo: Double, executable: String,
                     arguments: [String], cwd: String, megabytes: UInt64 = 0, port: Int? = nil,
                     addresses: [String] = ["127.0.0.1"]) -> ScannedProcess {
            ScannedProcess(identity: ProcessIdentity(pid: pid, startedAt: now.addingTimeInterval(-minutesAgo * 60)),
                           parentPID: parent, groupID: group ?? pid, uid: uid,
                           name: (executable as NSString).lastPathComponent, executable: executable,
                           arguments: arguments, cwd: cwd, memoryBytes: megabytes * 1_048_576,
                           listeners: port.map { port in
                               addresses.map { ListeningSocket(port: port, family: $0.contains(":") ? .ipv6 : .ipv4, address: $0) }
                           } ?? [])
        }
        let fiba = "\(home)/Project/fiba", backend = "\(home)/Project/yasm-backend"
        let sparkdash = "\(home)/Project/sparkdash"
        let node = "/opt/homebrew/bin/node"
        let snapshot = ProcessSnapshot(takenAt: now.addingTimeInterval(-6), processes: [
            process(4100, minutesAgo: 42, executable: "\(home)/.local/bin/claude", arguments: ["claude"], cwd: fiba),
            process(4210, parent: 4100, minutesAgo: 40, executable: node,
                    arguments: ["node", "\(fiba)/node_modules/next/dist/bin/next", "dev"], cwd: fiba, megabytes: 96),
            process(4211, parent: 4210, group: 4210, minutesAgo: 40, executable: node,
                    arguments: ["next-server (v15.4.1)"], cwd: fiba, megabytes: 316, port: 3000),
            process(5300, minutesAgo: 190, executable: node,
                    arguments: ["node", "\(fiba)/node_modules/vite/bin/vite.js"], cwd: "\(fiba)/apps/admin",
                    megabytes: 148, port: 5173, addresses: ["127.0.0.1", "::1"]),
            process(6100, minutesAgo: 1_500, executable: "/opt/homebrew/bin/python3.13",
                    arguments: ["python3.13", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0"], cwd: sparkdash,
                    megabytes: 86, port: 8000, addresses: ["0.0.0.0"]),
            process(7000, minutesAgo: 13, executable: "/opt/homebrew/bin/copilot", arguments: ["copilot"], cwd: backend),
            process(7040, parent: 7000, group: 7000, minutesAgo: 11, executable: "/usr/local/share/dotnet/dotnet",
                    arguments: ["dotnet", "run"], cwd: backend, megabytes: 231, port: 5080),
        ])
        var projects = projectsByCwd
        projects["\(fiba)/apps/admin"] = projectRefs[0]
        projects[sparkdash] = ProjectRef(id: 7, root: sparkdash, name: "sparkdash", kind: .repo)
        let sessions = [
            DevServerClassifier.Session(key: SessionKey(source: .claudeCode, id: "pricing"), pid: 4100, cwd: fiba),
            DevServerClassifier.Session(key: SessionKey(source: .claudeCode, id: "auth"), cwd: fiba),
            DevServerClassifier.Session(key: SessionKey(source: .copilotCLI, id: "orders"), cwd: backend),
            DevServerClassifier.Session(key: SessionKey(source: .claudeCode, id: "schema"), cwd: backend),
        ]
        let classifier = DevServerClassifier(ownPID: 1, uid: uid, homeDirectory: home)
        return DevServerScan(servers: classifier.servers(in: snapshot, projects: projects, sessions: sessions),
                             snapshot: snapshot, duration: 0.04)
    }

    static func devServerStops(_ scan: DevServerScan) -> [String: DevServers.StopState] {
        var stops: [String: DevServers.StopState] = [:]
        for server in scan.servers {
            switch server.port {
            case 3000: stops[server.id] = .confirming
            case 5173: stops[server.id] = .stopping
            case 8000: stops[server.id] = .failed(DevServerStop.Refusal.leaderGone.reason)
            default: break
            }
        }
        return stops
    }

    static var gitStats: [String: GitDiffStat] {
        let home = NSHomeDirectory()
        return ["\(home)/Project/fiba": GitDiffStat(filesChanged: 5, added: 120, removed: 34, untracked: 3),
                "\(home)/Project/fiba.worktrees/landing-hero": GitDiffStat(filesChanged: 2, added: 48, removed: 6),
                "\(home)/Project/hoply": GitDiffStat(untracked: 2)]
    }

    static var editors: [Editor] {
        [Editor(id: "com.todesktop.230313mzl4w4u92", name: "Cursor", url: URL(fileURLWithPath: "/Applications/Cursor.app")),
         Editor(id: "com.apple.dt.Xcode", name: "Xcode", url: URL(fileURLWithPath: "/Applications/Xcode.app"))]
    }

    static func paletteSessions(now: Date) -> [RecentSession] {
        history(now: now).sessions.sessions.compactMap { session in
            session.lastAt.map {
                RecentSession(key: session.key, project: session.project, title: session.title, cwd: session.cwd ?? "",
                              branch: session.branch, lastAt: $0)
            }
        }
    }

    static func paletteProjects(now: Date) -> [RecentProject] {
        let sessions = paletteSessions(now: now)
        return projectRefs.compactMap { project in
            let own = sessions.filter { $0.project == project }
            return own.map(\.lastAt).max().map {
                RecentProject(project: project, lastActive: $0, sessionCount: own.count * 3 + 1)
            }
        }
    }

    private static let liveKey = SessionKey(source: .claudeCode, id: "pricing")

    private static func insights(now: Date) -> [SessionKey: SessionInsight] {
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        return [liveKey: SessionInsight(context: ContextWindow(used: 172_400, limit: ContextWindow.standard), subagents: [
            SubagentSummary(agentID: "a1", agentType: "Explore", description: "Find where plan prices are defined",
                            model: "claude-haiku-4-5", firstAt: at(30), lastAt: at(24), totals: totals(usd: 0.31, local: false)),
            SubagentSummary(agentID: "a2", agentType: "code-reviewer", description: "Review the pricing table markup",
                            model: "claude-sonnet-5", firstAt: at(3), lastAt: at(0.5), totals: totals(usd: 0.84, local: false)),
            SubagentSummary(agentID: "a3", agentType: "test-runner", description: "Run the pricing component tests",
                            model: "claude-sonnet-5", firstAt: at(1), lastAt: at(0.3), totals: totals(usd: 0.12, local: false)),
        ], spans: liveSpans(now: now))]
    }

    private static func spans(now: Date, _ stretches: [(state: SessionState, from: Double, to: Double?)]) -> [StateSpan] {
        stretches.map { stretch in
            StateSpan(state: stretch.state, start: now.addingTimeInterval(-stretch.from * 60),
                      end: stretch.to.map { now.addingTimeInterval(-$0 * 60) })
        }
    }

    static func liveSpans(now: Date) -> [StateSpan] {
        spans(now: now, [(.working, 42, 31), (.yourTurn, 31, 29.5), (.working, 29.5, 18), (.needsPermission, 18, 17.2),
                         (.working, 17.2, 9), (.yourTurn, 9, 6), (.working, 6, nil)])
    }

    static func timelineSamples(now: Date) -> [[StateSpan]] {
        let short = spans(now: now, [(.working, 2.1, 1.3), (.needsPermission, 1.3, 1.05), (.working, 1.05, 0.4),
                                     (.yourTurn, 0.4, 0.1)])
        var long: [(state: SessionState, from: Double, to: Double?)] = []
        var cursor = 360.0
        var step = 0
        while cursor > 12 {
            let working = 4 + Double((step * 7) % 23)
            let waiting = step % 5 == 3 ? 46 : 0.4 + Double((step * 3) % 8)
            long.append((.working, cursor, cursor - working))
            cursor -= working
            if step % 4 == 1 {
                long.append((.needsPermission, cursor, cursor - 0.4))
                long.append((.working, cursor - 0.4, cursor - 3))
                cursor -= 3
            }
            if step == 6 {
                long.append((.yourTurn, cursor, cursor - 0.75))
                long.append((.idle, cursor - 0.75, cursor - 38))
                cursor -= 58
            } else {
                long.append((.yourTurn, cursor, max(cursor - waiting, 12)))
                cursor -= waiting
            }
            step += 1
        }
        long.append((.working, 12, 3))
        long.append((.yourTurn, 3, nil))
        return [short, liveSpans(now: now), spans(now: now, long)]
    }

    static let fibaCopy = ProjectRef(id: 8, root: "\(NSHomeDirectory())/Work/fiba-copy", name: "fiba-copy", kind: .repo)

    static func projectEdits(now: Date) -> ProjectEditsPreview {
        let home = NSHomeDirectory()
        let refs = projectRefs
        let archived = ProjectRef(id: 9, root: "\(home)/Project/archive/fiba-web", name: "fiba-web", kind: .repo)
        let scratch = ProjectRef(id: 10, root: "\(home)/Project/fiba-spike", name: "fiba-spike", kind: .folder)
        let suggestion = MergeSuggestion(id: "clone:github.com/acme/fiba:1,8", remote: "github.com/acme/fiba",
                                         projects: [refs[0], fibaCopy])
        return ProjectEditsPreview(
            projects: refs + [fibaCopy],
            merged: [MergedProject(project: archived, into: refs[0]), MergedProject(project: scratch, into: refs[0])],
            folders: [PathAssignment(path: "\(home)/Design/fiba-assets", project: refs[0])],
            sessions: [SessionAssignment(key: liveKey, title: "Build the pricing section", project: refs[0])],
            suggestions: [suggestion],
            usage: [refs[0].id: ProjectEdits.Usage(sessions: 163, totals: totals(usd: 1_284, local: false),
                                                   firstActive: now.addingTimeInterval(-212 * 86_400)),
                    fibaCopy.id: ProjectEdits.Usage(sessions: 41, totals: totals(usd: 96.4, local: false),
                                                    firstActive: now.addingTimeInterval(-34 * 86_400))])
    }

    private struct Stream {
        let model: String
        let source: AgentSource
        let scale: Double
        var local = false
        var every = 1
        let projects: [(project: Int?, share: Double)]
    }

    private static let streams: [Stream] = [
        Stream(model: "claude-opus-5", source: .claudeCode, scale: 16,
               projects: [(0, 0.40), (1, 0.22), (2, 0.20), (3, 0.13), (5, 0.05)]),
        Stream(model: "claude-sonnet-5", source: .claudeCode, scale: 7,
               projects: [(0, 0.45), (1, 0.25), (2, 0.15), (4, 0.15)]),
        Stream(model: "claude-haiku-4-5", source: .claudeCode, scale: 0.9,
               projects: [(0, 0.3), (2, 0.3), (3, 0.2), (4, 0.2)]),
        Stream(model: "Qwen3.8-Flash-Next", source: .qwenCode, scale: 2.4, local: true,
               projects: [(2, 0.6), (nil, 0.4)]),
        Stream(model: "claude-opus-5", source: .copilotCLI, scale: 3.2, every: 3,
               projects: [(0, 0.6), (3, 0.35), (5, 0.05)]),
        Stream(model: "gpt-6.1-sol", source: .codexCLI, scale: 2.1, every: 2,
               projects: [(0, 0.5), (1, 0.3), (4, 0.2)]),
        Stream(model: "claude-sonnet-5", source: .copilotIDE, scale: 0.8, every: 2,
               projects: [(1, 0.5), (nil, 0.5)]),
        Stream(model: "Qwen3.8-Flash-Next", source: .claudeCode, scale: 0.7, local: true, every: 2,
               projects: [(2, 0.7), (0, 0.3)]),
    ]

    private struct Entry {
        let day: Date
        let model: String
        let source: AgentSource
        let project: Int?
        let totals: LedgerTotals
    }

    static func history(now: Date) -> HistoryPreview {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let days = (0..<90).compactMap { calendar.date(byAdding: .day, value: $0 - 89, to: today) }

        var entries: [Entry] = []
        for (index, day) in days.enumerated() {
            let weekday = calendar.component(.weekday, from: day)
            let weekend = weekday == 1 || weekday == 7 ? 0.25 : 1
            let ramp = 0.55 + 0.45 * Double(index) / Double(days.count)
            for (offset, stream) in streams.enumerated() where (index + offset) % stream.every == 0 {
                if stream.local, index == days.count - 1 - serverOffDaysAgo { continue }
                let wave = 0.55 + 0.45 * sin(Double(index) * 0.9 + Double(offset) * 1.7)
                let usd = stream.scale * weekend * ramp * wave
                guard usd > 0.05 else { continue }
                for (project, share) in stream.projects {
                    entries.append(Entry(day: day, model: stream.model, source: stream.source, project: project,
                                         totals: totals(usd: usd * share, local: stream.local, source: stream.source)))
                }
            }
        }

        func points(_ entries: [Entry], series: (Entry) -> String) -> [DailySpendPoint] {
            var sums: [Date: [String: LedgerTotals]] = [:]
            for entry in entries { sums[entry.day, default: [:]][series(entry), default: .zero] += entry.totals }
            return sums.flatMap { day, byKey in byKey.map { DailySpendPoint(day: day, series: $0.key, totals: $0.value) } }
                .sorted { ($0.day, $0.series) < ($1.day, $1.series) }
        }
        func window(_ count: Int) -> [Date] { Array(days.suffix(count)) }
        func series(_ points: [DailySpendPoint], lastDays count: Int) -> DailySpendSeries {
            let range = window(count)
            return DailySpendSeries(days: range, points: points.filter { $0.day >= range[0] })
        }
        func sum(lastDays count: Int) -> LedgerTotals {
            entries.filter { $0.day >= window(count)[0] }.reduce(.zero) { $0 + $1.totals }
        }

        let byModel = points(entries) { $0.model }
        let bySource = points(entries) { $0.source.rawValue }
        let month = entries.filter { $0.day >= window(30)[0] }

        let unpriced = SpendSlice(id: "claude-nova-preview", label: "claude-nova-preview", totals: unpricedTotals,
                                  sessionCount: 1)
        var modelTotals: [String: LedgerTotals] = [:]
        for entry in month { modelTotals[entry.model, default: .zero] += entry.totals }
        let modelSlices = modelTotals.map { model, totals in
            SpendSlice(id: model, label: model, totals: totals, sessionCount: Int(totals.apiEquivUSD / 9) + 2)
        }.sorted { $0.totals.apiEquivUSD > $1.totals.apiEquivUSD } + [unpriced]

        let summaries = projectSummaries(month, now: now)
        let projectSlices = summaries.map { summary in
            SpendSlice(id: summary.id, label: summary.title, project: summary.project, totals: summary.totals,
                       sessionCount: summary.sessionCount)
        }

        let overview = OverviewData(
            totals: SpendOverview(today: sum(lastDays: 1), last7Days: sum(lastDays: 7), last30Days: sum(lastDays: 30),
                                  allTime: scaled(sum(lastDays: 90), by: 1.42)),
            daily: series(bySource, lastDays: 30),
            projects: Array(projectSlices.prefix(5)),
            models: Array(modelSlices.prefix(5)))
        let efficiency = modelSlices.map { slice in
            let fast = slice.id == "claude-opus-5" && !slice.totals.hasUnpriced
            return ModelEfficiency(model: slice.id, totals: slice.totals, fastCalls: fast ? 38 : 0,
                                   fastUSD: fast ? slice.totals.apiEquivUSD * 0.11 : 0,
                                   fastPremiumUSD: fast ? slice.totals.apiEquivUSD * 0.055 : 0)
        }
        let spending = SpendingData(range: .month, split: .model, daily: series(byModel, lastDays: 30),
                                    projects: projectSlices, models: modelSlices, efficiency: efficiency)

        let sessions = sessionSummaries(now: now, projects: projectRefs)
        let fiba = summaries[0]
        let fibaDaily = series(points(month.filter { $0.project == 0 }) { $0.model }, lastDays: 30)
        let fibaSessions = sessions.filter { $0.project?.id == fiba.project?.id }
        let unassigned = summaries.first { $0.project == nil }.map { summary in
            ProjectDetailData(range: .month, summary: summary,
                              daily: series(points(month.filter { $0.project == nil }) { $0.model }, lastDays: 30),
                              sessions: SessionPage(sessions: sessions.filter { $0.project == nil },
                                                    totalCount: summary.sessionCount))
        }
        let todayBySource = Dictionary(grouping: entries.filter { $0.day == today }, by: \.source)
            .mapValues { $0.reduce(LedgerTotals.zero) { $0 + $1.totals } }
        return HistoryPreview(
            progress: IngestProgress(filesDone: 122, filesTotal: 122, bytesDone: 261_000_000, bytesTotal: 261_000_000,
                                     copilot: .ready(schemaVersion: 7)),
            sessionTotals: [
                SessionKey(source: .claudeCode, id: "auth"): totals(usd: 4.12, local: false),
                SessionKey(source: .claudeCode, id: "pricing"): totals(usd: 11.80, local: false),
                SessionKey(source: .claudeCode, id: "docs"): totals(usd: 0.86, local: false),
                SessionKey(source: .codexCLI, id: "hero"): totals(usd: 2.35, local: false, source: .codexCLI),
                SessionKey(source: .copilotCLI, id: "orders"): totals(usd: 1.83, local: false, source: .copilotCLI),
                SessionKey(source: .copilotCLI, id: "store"): totals(usd: 4.07, local: false, source: .copilotCLI),
                SessionKey(source: .qwenCode, id: "tests"): totals(usd: 1.94, local: true, source: .qwenCode),
                SessionKey(source: .claudeCode, id: "schema"): totals(usd: 1.26, local: false),
                SessionKey(source: .claudeCode, id: "notes"): totals(usd: 0.38, local: false),
                SessionKey(source: .claudeCode, id: "lint"): totals(usd: 0.92, local: false),
            ],
            today: todayBySource, overview: overview, spending: spending,
            sessions: SessionPage(sessions: sessions, totalCount: 86), selectedSession: sessions.first,
            projects: ProjectsData(range: .month, projects: summaries),
            projectDetail: ProjectDetailData(range: .month, summary: fiba, daily: fibaDaily,
                                             sessions: SessionPage(sessions: fibaSessions, totalCount: fiba.sessionCount)),
            unassignedDetail: unassigned,
            limits: limits(now: now, entries: entries),
            localModel: localModel(now: now, entries: entries, days: days),
            contextWindows: [liveKey: ContextWindow(used: 172_400, limit: ContextWindow.standard),
                             SessionKey(source: .claudeCode, id: "auth"): ContextWindow(used: 61_000,
                                                                                         limit: ContextWindow.standard)],
            subagentCounts: [liveKey: 3, SessionKey(source: .claudeCode, id: "auth"): 2],
            insights: insights(now: now),
            unpricedModels: [UnpricedModel(model: "claude-nova-preview", calls: unpricedTotals.calls,
                                           tokens: unpricedTotals.tokens)],
            pricedModels: ["claude-fable-5", "claude-haiku-4-5", "claude-opus-5", "claude-sonnet-5"])
    }

    // MARK: - Local model

    private static let serverOffDaysAgo = 4

    private static func localModel(now: Date, entries: [Entry], days: [Date],
                                   range: LocalModelRange = .day) -> LocalModelData {
        let calendar = Calendar.current
        let interval = range.interval(now: now)
        let step = range.resolution
        let first = Int((interval.start.timeIntervalSince1970 / Double(step)).rounded(.down)) * step
        var generation: [SampleBucket] = []
        var kvCache: [SampleBucket] = []
        for start in stride(from: first, to: Int(now.timeIntervalSince1970), by: step) {
            let date = Date(timeIntervalSince1970: TimeInterval(start))
            let hour = Double(calendar.component(.hour, from: date)) + Double(calendar.component(.minute, from: date)) / 60
            if (2.5..<5.5).contains(hour) { continue }
            let minutesAgo = now.timeIntervalSince(date) / 60
            let wave = 0.5 + 0.5 * sin(Double(start / step) * 0.37) * cos(Double(start / step) * 0.11)
            var busy = (9..<12.5).contains(hour) || (13.5..<19).contains(hour) ? 0.35 + 0.65 * wave
                : (20..<23).contains(hour) ? 0.15 * wave : 0
            if minutesAgo < 25 { busy = 0.9 }
            let mean = busy * (minutesAgo < 25 ? 31 : 9)
            let peak = busy > 0.05 ? min(48, 22 + busy * 26) : mean
            let readings = 10
            generation.append(SampleBucket(series: ModelServerSeries.generationTokensPerSecond, resolution: step,
                                           start: start, n: readings, sum: mean * Double(readings), min: 0, max: peak))
            let kv = minutesAgo < 25 ? 44 : 6 + busy * 46
            kvCache.append(SampleBucket(series: ModelServerSeries.kvCachePercent, resolution: step, start: start,
                                        n: readings, sum: kv * Double(readings), min: kv * 0.7, max: min(kv * 1.35, 100)))
        }

        let window = Array(days.suffix(range.dailyDays))
        let local = entries.filter { $0.day >= window[0] && $0.totals.costUSD == 0 && $0.totals.apiEquivUSD > 0 }
        let offDay = days[days.count - 1 - serverOffDaysAgo]
        let tokenDays = window.map { day in
            let tokens = local.filter { $0.day == day }.reduce(TokenCounts()) { $0 + $1.totals.tokens }
            return ModelTokenDay(day: day,
                                 generated: Double(tokens.output + tokens.reasoning) * 3.2,
                                 prompt: Double(tokens.input + tokens.cacheRead + tokens.cacheWrite5m + tokens.cacheWrite1h) * 1.1,
                                 observed: day != offDay)
        }
        var bySource: [Date: [String: LedgerTotals]] = [:]
        for entry in local { bySource[entry.day, default: [:]][entry.source.rawValue, default: .zero] += entry.totals }
        let points = bySource.flatMap { day, sums in sums.map { DailySpendPoint(day: day, series: $0.key, totals: $0.value) } }
            .sorted { ($0.day, $0.series) < ($1.day, $1.series) }
        return LocalModelData(serverID: zgxServer.id, range: range, interval: interval, generation: generation,
                              kvCache: kvCache,
                              tokenDays: tokenDays, saved: DailySpendSeries(days: window, points: points), lastSeen: now)
    }

    // MARK: - Limits

    static func limitSamples(now: Date, days: Int = 7) -> [LimitSample] {
        let calendar = Calendar.current
        let five: TimeInterval = 5 * 3_600, week: TimeInterval = 7 * 86_400
        let fiveReset = now.addingTimeInterval(2.6 * 3_600)
        let weekReset = now.addingTimeInterval(3.7 * 86_400)
        var times = Array(stride(from: now.addingTimeInterval(-Double(days) * 86_400), to: now, by: 900))
        times.append(now)

        var samples: [LimitSample] = []
        var activity: [Double] = []
        for time in times {
            let windowsBack = (fiveReset.timeIntervalSince(time) / five).rounded(.down)
            let windowEnd = fiveReset.addingTimeInterval(-windowsBack * five)
            let windowStart = windowEnd.addingTimeInterval(-five)
            let hour = calendar.component(.hour, from: windowStart)
            let weekday = calendar.component(.weekday, from: windowStart)
            let workday = !(weekday == 1 || weekday == 7)
            let active = windowsBack == 0 || (workday ? (8..<19).contains(hour) : (11..<14).contains(hour))
            activity.append((activity.last ?? 0) + (active ? 1 : 0.03))
            guard active else { continue }
            let used = windowsBack == 0
                ? 62 * time.timeIntervalSince(windowStart) / now.timeIntervalSince(windowStart)
                : min(100, (35 + 75 * abs(sin(windowsBack * 1.7))) * pow(time.timeIntervalSince(windowStart) / five, 0.85))
                    .rounded()
            samples.append(LimitSample(kind: .fiveHour, ts: time, utilization: used, resetsAt: windowEnd))
        }

        for (index, time) in times.enumerated() {
            let weeksBack = (weekReset.timeIntervalSince(time) / week).rounded(.down)
            let weekEnd = weekReset.addingTimeInterval(-weeksBack * week)
            let weekStart = weekEnd.addingTimeInterval(-week)
            let inWeek = times.indices.filter { times[$0] >= weekStart && times[$0] < weekEnd }
            guard let first = inWeek.first, let last = inWeek.last else { continue }
            let peak = weeksBack == 0 ? 25 : [81.0, 64][Int(weeksBack - 1) % 2]
            let floor = weeksBack == 0 ? 0 : peak * max(0, times[first].timeIntervalSince(weekStart) / week)
            let progress = (activity[index] - activity[first]) / max(activity[last] - activity[first], 1)
            let used = floor + (peak - floor) * progress
            samples.append(LimitSample(kind: .sevenDay, ts: time, utilization: used, resetsAt: weekEnd))
            samples.append(LimitSample(kind: scopedKind, ts: time, utilization: used * scopedShare, resetsAt: weekEnd))
        }
        return samples.sorted { $0.ts < $1.ts }
    }

    private static func limits(now: Date, entries: [Entry]) -> LimitsData {
        let calendar = Calendar.current
        let samples = limitSamples(now: now)
        let projections = LimitsProjection.projections(samples)
        func claude(since day: Date) -> LedgerTotals {
            entries.filter { $0.source == .claudeCode && $0.day >= day }.reduce(.zero) { $0 + $1.totals }
        }
        var spend = [LimitKind.fiveHour: scaled(claude(since: calendar.startOfDay(for: now)), by: 0.6)]
        if let weekStart = projections[.sevenDay]?.windowStart {
            spend[.sevenDay] = claude(since: calendar.startOfDay(for: weekStart))
            spend[scopedKind] = spend[.sevenDay]
        }
        let month = CopilotAllowance.month(containing: now)
        let copilot = entries.filter { $0.source == .copilotCLI && $0.day >= month.start }
            .reduce(LedgerTotals.zero) { $0 + $1.totals }
        return LimitsData(days: 7, samples: samples, projections: projections, windowSpend: spend,
                          copilot: CopilotAllowance(used: copilot.premiumRequests, settings: settings, now: now),
                          copilotMonth: copilot)
    }

    private static func projectSummaries(_ entries: [Entry], now: Date) -> [ProjectSummary] {
        let refs = projectRefs
        let home = NSHomeDirectory()
        let facts: [Int?: (sessions: Int, minutesAgo: Double, branches: [String], worktrees: [String])] = [
            0: (41, 0.4, ["auth-refresh", "feature/pricing", "landing-hero", "main"],
                ["\(home)/Project/fiba.worktrees/landing-hero"]),
            1: (26, 1, ["async-client", "main", "orders-paging"], []),
            2: (33, 3, ["main", "v2-ledger"], []),
            3: (12, 1_400, ["fix/flaky-ref", "main"], []),
            4: (5, 4_400, [], []),
            5: (3, 2_900, [], []),
            nil: (7, 400, [], []),
        ]
        let grouped = Dictionary(grouping: entries, by: \.project)
        return grouped.map { project, entries in
            var totals = entries.reduce(LedgerTotals.zero) { $0 + $1.totals }
            var bySource: [AgentSource: LedgerTotals] = [:]
            var byModel: [String: LedgerTotals] = [:]
            for entry in entries {
                bySource[entry.source, default: .zero] += entry.totals
                byModel[entry.model, default: .zero] += entry.totals
            }
            if project == 2 {
                totals += unpricedTotals
                bySource[.claudeCode, default: .zero] += unpricedTotals
                byModel["claude-nova-preview"] = unpricedTotals
            }
            let fact = facts[project] ?? (1, 60, [], [])
            return ProjectSummary(
                project: project.map { refs[$0] }, totals: totals, sessionCount: fact.sessions, bySource: bySource,
                topModels: byModel.map { ModelShare(model: $0.key, totals: $0.value) }
                    .sorted { $0.totals.apiEquivUSD > $1.totals.apiEquivUSD },
                firstActive: entries.map(\.day).min(), lastActive: now.addingTimeInterval(-fact.minutesAgo * 60),
                branches: fact.branches, worktrees: fact.worktrees)
        }.sorted { $0.totals.apiEquivUSD > $1.totals.apiEquivUSD }
    }

    private struct SessionRowSeed {
        let title: String?
        var source: AgentSource = .claudeCode
        let project: Int?
        let branch: String?
        let minutesAgo: Double
        let hours: Double
        let turns: Int
        let usd: Double
        let mix: [(String, Double)]
        var native = false
        var id: String?
    }

    private static func sessionSummaries(now: Date, projects: [ProjectRef]) -> [SessionSummary] {
        let home = NSHomeDirectory()
        let rows: [SessionRowSeed] = [
            SessionRowSeed(title: "Build the pricing section", project: 0, branch: "feature/pricing", minutesAgo: 0.5,
                           hours: 0.7, turns: 14, usd: 11.80, mix: [("claude-sonnet-5", 0.82), ("claude-haiku-4-5", 0.18)],
                           native: true, id: liveKey.id),
            SessionRowSeed(title: "Add pagination to the orders endpoint", source: .copilotCLI, project: 1,
                           branch: "orders-paging", minutesAgo: 1, hours: 0.2, turns: 3, usd: 1.83,
                           mix: [("claude-opus-5", 1)]),
            SessionRowSeed(title: "Speed up the Copilot store reader", source: .copilotCLI, project: 2,
                           branch: "v2-ledger", minutesAgo: 3, hours: 0.4, turns: 5, usd: 4.07,
                           mix: [("claude-opus-5", 0.86), ("claude-haiku-4.5", 0.14)]),
            SessionRowSeed(title: "Refactor the auth middleware to use refresh tokens", project: 0, branch: "auth-refresh",
                           minutesAgo: 4, hours: 0.8, turns: 9, usd: 4.12, mix: [("claude-opus-5", 1)]),
            SessionRowSeed(title: nil, source: .qwenCode, project: 2, branch: nil, minutesAgo: 6, hours: 0.3, turns: 0,
                           usd: 1.94, mix: [("Qwen3.8-Flash-Next", 1)]),
            SessionRowSeed(title: "Update the README for v2", project: 2, branch: "main", minutesAgo: 8, hours: 0.4,
                           turns: 3, usd: 0.86, mix: [("claude-opus-5", 1)]),
            SessionRowSeed(title: "Polish the landing page hero animation", source: .codexCLI, project: 0,
                           branch: "landing-hero", minutesAgo: 9, hours: 0.3, turns: 6, usd: 2.35, mix: [("gpt-6.1-sol", 1)]),
            SessionRowSeed(title: "Store and Claude history", project: 2, branch: "v2-ledger", minutesAgo: 95, hours: 3.1,
                           turns: 41, usd: 38.40, mix: [("claude-opus-5", 0.91), ("claude-haiku-4-5", 0.09)]),
            SessionRowSeed(title: "Pagination for the orders endpoint", project: 1, branch: "orders-paging",
                           minutesAgo: 180, hours: 1.2, turns: 12, usd: 6.25, mix: [("claude-sonnet-5", 1)]),
            SessionRowSeed(title: "Write unit tests for the Prometheus parser", project: 2, branch: "main",
                           minutesAgo: 260, hours: 0.6, turns: 7, usd: 1.94,
                           mix: [("Qwen3.8-Flash-Next", 0.7), ("claude-sonnet-5", 0.3)]),
            SessionRowSeed(title: nil, source: .qwenCode, project: nil, branch: nil, minutesAgo: 400, hours: 0.5, turns: 0,
                           usd: 0.71, mix: [("Qwen3.8-Flash-Next", 1)]),
            SessionRowSeed(title: "Seed the fixtures for the draw", source: .copilotCLI, project: 0, branch: "main",
                           minutesAgo: 1_100, hours: 0.6, turns: 3, usd: 3.12, mix: [("claude-opus-5", 1)]),
            SessionRowSeed(title: "Investigate the flaky referee assignment test", project: 3, branch: "fix/flaky-ref",
                           minutesAgo: 1_400, hours: 2.2, turns: 18, usd: 9.71,
                           mix: [("claude-opus-5", 0.64), ("claude-sonnet-5", 0.36)]),
            SessionRowSeed(title: "Explain the bracket seeding rules", project: 3, branch: nil, minutesAgo: 1_700,
                           hours: 0.3, turns: 2, usd: 0.42, mix: [("claude-haiku-4-5", 1)]),
            SessionRowSeed(title: "Referee assignment edge cases", source: .copilotCLI, project: 3, branch: "fix/flaky-ref",
                           minutesAgo: 2_000, hours: 1.1, turns: 4, usd: 6.90,
                           mix: [("claude-opus-5", 0.8), ("claude-haiku-4.5", 0.2)]),
            SessionRowSeed(title: "Migrate the API client to async/await", project: 1, branch: "async-client",
                           minutesAgo: 2_900, hours: 4.5, turns: 33, usd: 27.15,
                           mix: [("claude-opus-5", 0.77), ("claude-sonnet-5", 0.23)]),
            SessionRowSeed(title: "Quick shell question", project: 5, branch: nil, minutesAgo: 3_100, hours: 0.1, turns: 1,
                           usd: 0.08, mix: [("claude-haiku-4-5", 1)]),
            SessionRowSeed(title: "Try the nova preview model", project: 2, branch: "main", minutesAgo: 3_300, hours: 0.2,
                           turns: 2, usd: 0, mix: [("claude-nova-preview", 1)]),
            SessionRowSeed(title: "Landing page hero animation", project: 0, branch: "landing-hero", minutesAgo: 4_300,
                           hours: 1.7, turns: 15, usd: 7.02, mix: [("claude-sonnet-5", 1)]),
            SessionRowSeed(title: "Profile the ingest coordinator", project: 2, branch: "v2-ledger", minutesAgo: 5_800,
                           hours: 0.9, turns: 6, usd: 3.30, mix: [("Qwen3.8-Flash-Next", 1)]),
            SessionRowSeed(title: nil, source: .copilotIDE, project: nil, branch: nil, minutesAgo: 6_500, hours: 0.4,
                           turns: 0, usd: 1.12, mix: [("claude-sonnet-5", 1)]),
            SessionRowSeed(title: nil, source: .qwenCode, project: nil, branch: nil, minutesAgo: 7_200, hours: 1.3, turns: 4,
                           usd: 2.05, mix: [("Qwen3.8-Flash-Next", 1)]),
        ]
        return rows.enumerated().map { index, row in
            let project = row.project.flatMap { projects.indices.contains($0) ? projects[$0] : nil }
            let last = now.addingTimeInterval(-row.minutesAgo * 60)
            let models = row.mix.map { model, share in
                ModelShare(model: model, totals: row.usd == 0 ? unpricedTotals
                                                               : totals(usd: row.usd * share, local: model.hasPrefix("Qwen"),
                                                                        source: row.source))
            }
            let total = models.reduce(LedgerTotals.zero) { $0 + $1.totals }
            let id = row.id ?? String(format: "%08x-preview-%02d", 0x5e55_1000 + index * 7_919, index)
            let cwd = row.branch == "landing-hero" && row.minutesAgo < 60
                ? "\(home)/Project/fiba.worktrees/landing-hero" : project?.root
            return SessionSummary(
                key: SessionKey(source: row.source, id: id), project: project, title: row.title, cwd: cwd,
                branch: row.branch, firstAt: last.addingTimeInterval(-row.hours * 3_600), lastAt: last,
                turns: row.turns, totals: total, models: models,
                nativeCostUSD: row.native ? row.usd * 0.987 : nil,
                linesAdded: row.source == .claudeCode ? row.turns * 23 : nil,
                linesRemoved: row.source == .claudeCode ? row.turns * 7 : nil,
                prURL: row.native ? "https://github.com/fiba/fiba-web/pull/482" : nil,
                transcriptPath: row.source == .claudeCode ? "\(home)/.claude/projects/-preview/\(id).jsonl" : nil)
        }
    }

    private static let unpricedTotals = LedgerTotals(tokens: TokenCounts(input: 4_100, output: 2_300, cacheRead: 61_000),
                                                     calls: 9, hasUnpriced: true)

    private static func totals(usd: Double, local: Bool, source: AgentSource = .claudeCode) -> LedgerTotals {
        let tokens = Int(usd * 420_000)
        let copilot = source == .copilotCLI
        return LedgerTotals(costUSD: local ? 0 : usd, apiEquivUSD: usd,
                            tokens: TokenCounts(input: tokens / 60, output: tokens / 45, reasoning: tokens / 200,
                                                cacheRead: tokens * 84 / 100, cacheWrite5m: tokens * 9 / 100),
                            calls: max(1, Int(usd * 11)), aiu: copilot ? usd * 100 : 0,
                            premiumRequests: copilot ? (usd * 6.4 * 2).rounded() / 2 : 0)
    }

    private static func scaled(_ totals: LedgerTotals, by factor: Double) -> LedgerTotals {
        let t = totals.tokens
        func s(_ value: Int) -> Int { Int(Double(value) * factor) }
        return LedgerTotals(costUSD: totals.costUSD * factor, apiEquivUSD: totals.apiEquivUSD * factor,
                            tokens: TokenCounts(input: s(t.input), output: s(t.output), reasoning: s(t.reasoning),
                                                cacheRead: s(t.cacheRead), cacheWrite5m: s(t.cacheWrite5m),
                                                cacheWrite1h: s(t.cacheWrite1h)),
                            calls: s(totals.calls), hasUnpriced: totals.hasUnpriced, aiu: totals.aiu * factor,
                            premiumRequests: totals.premiumRequests * factor)
    }
}

private extension LedgerTotals {
    static func += (lhs: inout LedgerTotals, rhs: LedgerTotals) { lhs = lhs + rhs }
}
