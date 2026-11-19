import AgentKit
import Foundation

public actor ConversationReader {
    public static let tailBytes = 4 << 20
    static let missRetry: TimeInterval = 30

    struct Location: Sendable, Equatable {
        var key: SessionKey
        var path: String
        var cwd: String?
    }

    enum Lookup: Sendable, Equatable {
        case found(Location)
        case problem(RemoteTranscript.Problem)
    }

    public nonisolated let agents: [AgentSource]
    private let claude: ClaudeTranscriptIngester?
    private let codex: CodexRolloutIngester?
    private let copilot: CopilotEventsIngester?
    private let store: StoreReader?
    private let maxBytes: Int
    private var located: [String: Location] = [:]
    private var misses: [String: Date] = [:]

    public init(configuration: LedgerConfiguration, store: StoreReader? = nil, maxBytes: Int = tailBytes) {
        let folders = configuration.folders
        let claude = folders.contains(.claude)
            ? ClaudeTranscriptIngester(configDirectory: configuration.claudeConfigDirectory) : nil
        let codex = folders.contains(.codex) ? configuration.codexHome.map { CodexRolloutIngester(home: $0) } : nil
        let copilot = folders.contains(.copilot) ? CopilotEventsIngester(home: configuration.copilotHome) : nil
        agents = ConversationParser.agents.filter { source in
            switch source {
            case .claudeCode: claude != nil
            case .codexCLI: codex != nil
            case .copilotCLI: copilot != nil
            case .copilotIDE, .qwenCode: false
            }
        }
        self.claude = claude
        self.codex = codex
        self.copilot = copilot
        self.store = store
        self.maxBytes = maxBytes
    }

    public init(ledger: Ledger) {
        self.init(configuration: ledger.configuration, store: ledger.reader)
    }

    public init(settings: AppSettings) {
        self.init(configuration: LedgerConfiguration(settings: settings))
    }

    public func signals(for sessions: [String]) async -> [String: TranscriptSignal] {
        var result: [String: TranscriptSignal] = [:]
        for session in sessions {
            if let signal = await signal(for: session) { result[session] = signal }
        }
        return result
    }

    public func signal(for session: String) async -> TranscriptSignal? {
        guard case .found(let location) = await locate(session),
              let stat = FileTailer.status(of: location.path) else { return nil }
        return TranscriptSignal(path: location.path, size: stat.size, modified: stat.modified)
    }

    public func transcript(for session: String, device: String, answerID: String?,
                           now: Date = Date()) async -> RemoteTranscript {
        let agent = RemoteSchema.sessionKey(from: session)?.source.rawValue
            ?? session.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        func failed(_ problem: RemoteTranscript.Problem) -> RemoteTranscript {
            .failed(problem, device: device, session: session, agent: agent, answerID: answerID, now: now)
        }
        let location: Location
        switch await locate(session) {
        case .found(let found): location = found
        case .problem(let problem): return failed(problem)
        }
        guard let tail = FileTailer.lastLines(of: location.path, maxBytes: maxBytes) else {
            located[session] = nil
            return failed(.unreadable)
        }
        guard let messages = ConversationParser.messages(location.key.source, lines: tail.lines, cwd: location.cwd)
        else { return failed(.unsupportedAgent) }
        return .build(device: device, session: session, agent: agent, answerID: answerID, messages: messages,
                      earlierOmitted: !tail.fromStart, now: now)
    }

    // The session key comes from the phone and is only ever a lookup key into the Mac's own records and folders.
    func locate(_ session: String) async -> Lookup {
        guard let key = RemoteSchema.sessionKey(from: session) else { return .problem(.unknownSession) }
        guard ConversationParser.agents.contains(key.source) else { return .problem(.unsupportedAgent) }
        guard agents.contains(key.source) else { return .problem(.unreadable) }
        if let cached = located[session], FileTailer.status(of: cached.path) != nil { return .found(cached) }
        if let missed = misses[session], Date().timeIntervalSince(missed) < Self.missRetry {
            return .problem(.unknownSession)
        }
        let known = ((try? await store?.sessionFile(key)) ?? nil)
        var cwd = known?.cwd
        let path: String?
        switch key.source {
        case .claudeCode:
            path = claudePath(key.id, known: known?.transcriptPath)
        case .codexCLI:
            path = codexPath(key.id, known: known?.transcriptPath)
        case .copilotCLI:
            path = copilotPath(key.id)
            if let path, let workspace = copilot?.workspace(forEventsFile: path)?.cwd, !workspace.isEmpty {
                cwd = workspace
            }
        case .copilotIDE, .qwenCode:
            path = nil
        }
        guard let path else {
            located[session] = nil
            misses[session] = Date()
            return .problem(.unknownSession)
        }
        misses[session] = nil
        let location = Location(key: key, path: path, cwd: cwd.flatMap { $0.isEmpty ? nil : $0 })
        located[session] = location
        return .found(location)
    }

    private func claudePath(_ id: String, known: String?) -> String? {
        guard let claude, ResumeScript.isPlausibleSessionID(id) else { return nil }
        let name = id + ".jsonl"
        func isMain(_ path: String) -> Bool {
            let url = URL(fileURLWithPath: path)
            return Self.isClean(path) && claude.isTranscript(path) && url.lastPathComponent == name
                && url.deletingLastPathComponent().deletingLastPathComponent().path == claude.projectsDirectory
        }
        if let known, isMain(known), FileTailer.status(of: known) != nil { return known }
        let projects = claude.projectsDirectory
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? []
        for folder in folders where !folder.hasPrefix(".") {
            let path = projects + "/" + folder + "/" + name
            if isMain(path), FileTailer.status(of: path) != nil { return path }
        }
        return nil
    }

    private func codexPath(_ id: String, known: String?) -> String? {
        guard let codex else { return nil }
        if let known, Self.isClean(known), codex.isRollout(known), FileTailer.status(of: known) != nil { return known }
        guard ResumeScript.isPlausibleSessionID(id) else { return nil }
        let thread = id.lowercased()
        return codex.discover().first { CodexRolloutState.threadID(fromPath: $0.path) == thread }?.path
    }

    private func copilotPath(_ id: String) -> String? {
        guard let copilot, let path = copilot.eventsPath(sessionID: id), copilot.isEventsFile(path),
              FileTailer.status(of: path) != nil else { return nil }
        return path
    }

    static func isClean(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}
