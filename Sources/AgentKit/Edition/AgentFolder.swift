import Foundation

public enum AgentFolder: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case codex
    case copilot

    public var id: String { rawValue }

    public var agent: ConnectableAgent {
        switch self {
        case .claude: return .claudeCode
        case .codex: return .codexCLI
        case .copilot: return .copilotCLI
        }
    }

    public var displayName: String { agent.displayName }

    public var defaultName: String {
        switch self {
        case .claude: return ".claude"
        case .codex: return ".codex"
        case .copilot: return ".copilot"
        }
    }

    public var environmentKey: String {
        switch self {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex: return "CODEX_HOME"
        case .copilot: return "COPILOT_HOME"
        }
    }

    public func setting(in settings: AppSettings) -> String {
        switch self {
        case .claude: return settings.claudeConfigDir
        case .codex: return settings.codexHome
        case .copilot: return settings.copilotHome
        }
    }

    public func defaultPath(environment: [String: String], home: String) -> String {
        Self.directory(environment[environmentKey] ?? "", home: home,
                       default: PathScope.normalized(home) + "/" + defaultName)
    }

    public func path(settings: AppSettings, environment: [String: String], home: String) -> String {
        Self.directory(setting(in: settings), home: home, default: defaultPath(environment: environment, home: home))
    }

    public static func directory(_ configured: String, home: String, default fallback: String) -> String {
        let trimmed = configured.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? fallback : HomePath.expandingTilde(trimmed, home: home)
    }
}

extension ConnectableAgent {
    public var folder: AgentFolder {
        switch self {
        case .claudeCode: return .claude
        case .codexCLI: return .codex
        case .copilotCLI: return .copilot
        }
    }
}

public struct FolderGrant: Codable, Equatable, Sendable {
    public var folder: AgentFolder
    public var path: String
    public var readOnly: Bool

    public init(folder: AgentFolder, path: String, readOnly: Bool) {
        self.folder = folder
        self.path = PathScope.normalized(path)
        self.readOnly = readOnly
    }

    public func covers(_ path: String, needsWrite: Bool) -> Bool {
        PathScope.contains(self.path, path) && (!needsWrite || !readOnly)
    }
}

public enum FolderAccess: Equatable, Sendable {
    case notNeeded
    case granted(String)
    case missing
    case notFound
    case elsewhere(String)
    case readOnly(String)
    case broken(String)

    public var allowsReading: Bool {
        switch self {
        case .notNeeded, .granted: return true
        default: return false
        }
    }

    public var asksForGrant: Bool {
        switch self {
        case .missing, .elsewhere, .readOnly, .broken: return true
        case .notNeeded, .granted, .notFound: return false
        }
    }
}

public enum FolderPick: Equatable, Sendable {
    case expected
    case covering
    case other
}

public enum FolderGrantRules {
    public static func access(for folder: AgentFolder, at path: String, exists: Bool, edition: Edition,
                              grants: [FolderGrant], failures: [AgentFolder: String] = [:]) -> FolderAccess {
        guard edition.needsFolderGrants else { return .notNeeded }
        let ordered = grants.filter { $0.folder == folder } + grants.filter { $0.folder != folder }
        if let grant = ordered.first(where: { $0.covers(path, needsWrite: true) }) {
            return .granted(grant.path)
        }
        if let grant = ordered.first(where: { $0.covers(path, needsWrite: false) }) {
            return .readOnly(grant.path)
        }
        if let failure = failures[folder] { return .broken(failure) }
        if let own = grants.first(where: { $0.folder == folder }) { return .elsewhere(own.path) }
        return exists ? .missing : .notFound
    }

    public static func readable(_ access: [AgentFolder: FolderAccess]) -> Set<AgentFolder> {
        Set(access.filter { $0.value.allowsReading }.keys)
    }

    public static func pick(_ picked: String, expected: String) -> FolderPick {
        let picked = PathScope.normalized(picked)
        let expected = PathScope.normalized(expected)
        if picked == expected { return .expected }
        return PathScope.contains(picked, expected) ? .covering : .other
    }

    public static func covering(_ first: String, _ second: String) -> String {
        let first = PathScope.normalized(first).split(separator: "/", omittingEmptySubsequences: true)
        let second = PathScope.normalized(second).split(separator: "/", omittingEmptySubsequences: true)
        let shared = zip(first, second).prefix { $0 == $1 }.map(\.0)
        return "/" + shared.joined(separator: "/")
    }
}
