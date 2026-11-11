import Foundation

public enum ConnectableAgent: String, CaseIterable, Codable, Identifiable, Sendable {
    case claudeCode = "claude-code"
    case copilotCLI = "copilot-cli"
    case codexCLI = "codex-cli"

    public var id: String { rawValue }

    public var source: AgentSource {
        switch self {
        case .claudeCode: return .claudeCode
        case .copilotCLI: return .copilotCLI
        case .codexCLI: return .codexCLI
        }
    }

    public var displayName: String { source.displayName }

    public init?(source: AgentSource) {
        self.init(rawValue: source.rawValue)
    }
}

public enum ConnectionStatus: Equatable, Sendable {
    case notInstalled
    case notConnected
    case connected
    case outdated
    case unreadable(String)

    public var isConnected: Bool { self == .connected }
}

public enum HoplyEndpoint {
    public static let defaultPort = 4318

    public static func baseURL(port: Int) -> String { "http://127.0.0.1:\(port)" }

    public static func isValidPort(_ port: Int) -> Bool { (1...65_535).contains(port) }
}
