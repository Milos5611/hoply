import AgentKit
import Foundation

public struct AgentConnectorError: Error, Equatable, LocalizedError, Sendable {
    public enum Kind: Equatable, Sendable {
        case unreadable
        case writeFailed
    }

    public let kind: Kind
    public let path: String
    public let message: String

    public var errorDescription: String? { message }
}

public struct ConnectOutcome: Equatable, Sendable {
    public let agent: ConnectableAgent
    public let path: String
    public let changed: Bool
    public var backupPath: String?
    public var renamedPath: String?
}

public struct AgentConnector: Sendable {
    public let claudeConfigDirectory: String
    public let copilotHome: String
    public let codexHome: String
    public let port: Int
    private let now: @Sendable () -> Date

    public init(claudeConfigDirectory: String, copilotHome: String, codexHome: String, port: Int,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.claudeConfigDirectory = URL(fileURLWithPath: claudeConfigDirectory).standardized.path
        self.copilotHome = URL(fileURLWithPath: copilotHome).standardized.path
        self.codexHome = URL(fileURLWithPath: codexHome).standardized.path
        self.port = port
        self.now = now
    }

    public init(settings: AppSettings, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.init(claudeConfigDirectory: Self.directory(settings.claudeConfigDir,
                                                        default: Self.defaultClaudeConfigDirectory(environment: environment,
                                                                                                   home: home)),
                  copilotHome: Self.directory(settings.copilotHome,
                                              default: Self.defaultCopilotHome(environment: environment, home: home)),
                  codexHome: Self.directory(settings.codexHome,
                                            default: Self.defaultCodexHome(environment: environment, home: home)),
                  port: settings.port)
    }

    public static func defaultClaudeConfigDirectory(environment: [String: String], home: String) -> String {
        directory(environment["CLAUDE_CONFIG_DIR"] ?? "", default: home + "/.claude")
    }

    public static func defaultCopilotHome(environment: [String: String], home: String) -> String {
        directory(environment["COPILOT_HOME"] ?? "", default: home + "/.copilot")
    }

    public static func defaultCodexHome(environment: [String: String], home: String) -> String {
        directory(environment["CODEX_HOME"] ?? "", default: home + "/.codex")
    }

    static func directory(_ configured: String, default fallback: String) -> String {
        let trimmed = configured.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? fallback : (trimmed as NSString).expandingTildeInPath
    }

    public var claudeSettingsPath: String { claudeConfigDirectory + "/settings.json" }
    public var copilotHooksPath: String { copilotHome + "/hooks/" + CopilotCLIHooks.fileName }
    public var codexHooksPath: String { codexHome + "/" + CodexHooks.fileName }
    public var claudeHooks: ClaudeCodeHooks { ClaudeCodeHooks(port: port) }
    public var copilotHooks: CopilotCLIHooks { CopilotCLIHooks(port: port) }
    public var codexHooks: CodexHooks { CodexHooks(port: port) }

    public func configDirectory(for agent: ConnectableAgent) -> String {
        switch agent {
        case .claudeCode: return claudeConfigDirectory
        case .copilotCLI: return copilotHome
        case .codexCLI: return codexHome
        }
    }

    public func configPath(for agent: ConnectableAgent) -> String {
        switch agent {
        case .claudeCode: return claudeSettingsPath
        case .copilotCLI: return copilotHooksPath
        case .codexCLI: return codexHooksPath
        }
    }

    public func isInstalled(_ agent: ConnectableAgent) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: configDirectory(for: agent), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    public func status(of agent: ConnectableAgent) -> ConnectionStatus {
        guard isInstalled(agent) else { return .notInstalled }
        let data: Data?
        do {
            data = try Self.read(configPath(for: agent))
        } catch {
            return .unreadable(error.message)
        }
        switch agent {
        case .claudeCode:
            guard let data else { return .notConnected }
            do {
                return claudeHooks.status(of: try SettingsJSON.parse(data))
            } catch {
                return .unreadable(Self.unreadable(claudeSettingsPath, error).message)
            }
        case .copilotCLI:
            return copilotHooks.status(ofFile: data)
        case .codexCLI:
            guard let data else { return .notConnected }
            do {
                return codexHooks.status(of: try SettingsJSON.parse(data))
            } catch {
                return .unreadable(Self.unreadable(codexHooksPath, error).message)
            }
        }
    }

    public func statuses() -> [ConnectableAgent: ConnectionStatus] {
        Dictionary(uniqueKeysWithValues: ConnectableAgent.allCases.map { ($0, status(of: $0)) })
    }

    @discardableResult
    public func connect(_ agent: ConnectableAgent) throws(AgentConnectorError) -> ConnectOutcome {
        switch agent {
        case .claudeCode: return try editJSON(.claudeCode) { settings throws(SettingsJSONError) in
            try claudeHooks.connect(settings)
        }
        case .copilotCLI: return try connectCopilot()
        case .codexCLI: return try editJSON(.codexCLI) { file throws(SettingsJSONError) in
            try codexHooks.connect(file)
        }
        }
    }

    @discardableResult
    public func disconnect(_ agent: ConnectableAgent) throws(AgentConnectorError) -> ConnectOutcome {
        switch agent {
        case .claudeCode: return try editJSON(.claudeCode) { settings in claudeHooks.disconnect(settings) }
        case .copilotCLI: return try disconnectCopilot()
        case .codexCLI: return try editJSON(.codexCLI) { file in codexHooks.disconnect(file) }
        }
    }

    private func editJSON(
        _ agent: ConnectableAgent, _ transform: ([String: Any]) throws(SettingsJSONError) -> [String: Any]?
    ) throws(AgentConnectorError) -> ConnectOutcome {
        let path = configPath(for: agent)
        let original = try Self.read(path)
        let settings: [String: Any]
        let edited: [String: Any]?
        do {
            settings = try original.map(SettingsJSON.parse) ?? [:]
            edited = try transform(settings)
        } catch {
            throw Self.unreadable(path, error)
        }
        guard let edited else { return ConnectOutcome(agent: agent, path: path, changed: false) }
        try Self.createDirectory(configDirectory(for: agent))
        let target = Self.resolvingLinks(path)
        let permissions = Self.permissions(of: target) ?? 0o600
        var backup: String?
        if let original {
            backup = try Self.writeBackup(original, of: path, stamp: stamp(), permissions: permissions)
        }
        try Self.writeAtomically(SettingsJSON.encode(edited), to: target, permissions: permissions)
        return ConnectOutcome(agent: agent, path: path, changed: true, backupPath: backup)
    }

    private func connectCopilot() throws(AgentConnectorError) -> ConnectOutcome {
        let path = copilotHooksPath
        let hooks = copilotHooks
        if hooks.status(ofFile: try? Self.read(path)) == .connected {
            return ConnectOutcome(agent: .copilotCLI, path: path, changed: false)
        }
        try Self.createDirectory((path as NSString).deletingLastPathComponent)
        let target = Self.resolvingLinks(path)
        try Self.writeAtomically(hooks.fileContents, to: target, permissions: Self.permissions(of: target) ?? 0o644)
        return ConnectOutcome(agent: .copilotCLI, path: path, changed: true)
    }

    private func disconnectCopilot() throws(AgentConnectorError) -> ConnectOutcome {
        let path = copilotHooksPath
        var info = stat()
        guard lstat(path, &info) == 0 else { return ConnectOutcome(agent: .copilotCLI, path: path, changed: false) }
        let base = "\(path).removed-\(stamp())"
        for attempt in 1...100 {
            let destination = attempt == 1 ? base : "\(base)-\(attempt)"
            if renamex_np(path, destination, UInt32(RENAME_EXCL)) == 0 {
                return ConnectOutcome(agent: .copilotCLI, path: path, changed: true, renamedPath: destination)
            }
            guard errno == EEXIST else { throw Self.writeFailed(path, errno) }
        }
        throw Self.writeFailed(path, EEXIST)
    }

    private func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: now())
    }

    static func read(_ path: String) throws(AgentConnectorError) -> Data? {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw AgentConnectorError(kind: .unreadable, path: path,
                                      message: "\(display(path)) can't be read: \(error.localizedDescription)")
        }
    }

    static func unreadable(_ path: String, _ error: SettingsJSONError) -> AgentConnectorError {
        AgentConnectorError(kind: .unreadable, path: path, message: "\(display(path)) \(error.reason); fix it first.")
    }

    static func writeFailed(_ path: String, _ code: Int32) -> AgentConnectorError {
        AgentConnectorError(kind: .writeFailed, path: path,
                            message: "\(display(path)) can't be written: \(String(cString: strerror(code)))")
    }

    static func display(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    static func createDirectory(_ path: String) throws(AgentConnectorError) {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            throw AgentConnectorError(kind: .writeFailed, path: path,
                                      message: "\(display(path)) can't be created: \(error.localizedDescription)")
        }
    }

    // Dotfile managers link settings.json into a repo: edit the file the link points to, keep the link.
    static func resolvingLinks(_ path: String) -> String {
        var current = path
        for _ in 0..<32 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else { break }
            current = destination.hasPrefix("/")
                ? destination
                : ((current as NSString).deletingLastPathComponent as NSString).appendingPathComponent(destination)
        }
        return current
    }

    static func permissions(of path: String) -> mode_t? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_mode & 0o7777
    }

    static func writeBackup(_ data: Data, of path: String, stamp: String,
                            permissions: mode_t) throws(AgentConnectorError) -> String {
        let base = "\(path).hoply-backup-\(stamp)"
        for attempt in 1...100 {
            let backup = attempt == 1 ? base : "\(base)-\(attempt)"
            let descriptor = open(backup, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
            if descriptor < 0 {
                guard errno == EEXIST else { throw writeFailed(backup, errno) }
                continue
            }
            try write(data, to: descriptor, path: backup, permissions: permissions)
            return backup
        }
        throw writeFailed(base, EEXIST)
    }

    static func writeAtomically(_ data: Data, to path: String, permissions: mode_t) throws(AgentConnectorError) {
        let directory = (path as NSString).deletingLastPathComponent
        let temporary = "\(directory)/.\((path as NSString).lastPathComponent).hoply-\(UUID().uuidString)"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
        guard descriptor >= 0 else { throw writeFailed(path, errno) }
        do {
            try write(data, to: descriptor, path: path, permissions: permissions)
        } catch {
            unlink(temporary)
            throw error
        }
        guard rename(temporary, path) == 0 else {
            let code = errno
            unlink(temporary)
            throw writeFailed(path, code)
        }
    }

    private static func write(_ data: Data, to descriptor: Int32, path: String,
                              permissions: mode_t) throws(AgentConnectorError) {
        defer { close(descriptor) }
        // open() applies the umask; the copy must keep the original's mode (settings.json is often 0600).
        guard fchmod(descriptor, permissions) == 0 else { throw writeFailed(path, errno) }
        let failure: Int32? = data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += written
            }
            return fsync(descriptor) == 0 ? nil : errno
        }
        if let failure { throw writeFailed(path, failure) }
    }
}
