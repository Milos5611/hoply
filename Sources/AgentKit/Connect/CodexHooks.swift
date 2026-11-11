import Foundation

public struct CodexHooks: Equatable, Sendable {
    public static let fileName = "hooks.json"
    public static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
                                "SubagentStart", "SubagentStop", "Stop", "SessionEnd"]
    public static let hookTimeout = 5
    // Codex caps SessionEnd hooks at 3 s and warns about a longer timeout.
    public static let sessionEndTimeout = 3

    public let port: Int

    public init(port: Int) {
        self.port = port
    }

    public var endpoint: String { HoplyEndpoint.baseURL(port: port) }

    // PermissionRequest gets the same observe-only command: Codex runs hooks before its own prompt, so a held
    // request would freeze the prompt, and no output means Codex's prompt decides.
    public var hookCommand: String {
        "curl -s -m 2 -o /dev/null -H 'Expect:' -H 'Content-Type: application/json' -H \"X-Hoply-Pid: $PPID\" "
            + "--data-binary @- \(endpoint)/hooks/codex-cli || true \(ClaudeCodeHooks.marker)"
    }

    public func hook(for event: String) -> [String: Any] {
        ["type": "command", "command": hookCommand,
         "timeout": event == "SessionEnd" ? Self.sessionEndTimeout : Self.hookTimeout]
    }

    public func status(of file: [String: Any]) -> ConnectionStatus {
        if let problem = Self.shapeProblem(file) { return .unreadable(problem) }
        let ours = ClaudeCodeHooks.ourHooks(in: file)
        guard !ours.isEmpty else { return .notConnected }
        let byEvent = Dictionary(grouping: ours) { $0.event }
        guard Set(byEvent.keys) == Set(Self.events) else { return .outdated }
        for event in Self.events {
            guard let found = byEvent[event], found.count == 1, SettingsJSON.same(found[0].hook, hook(for: event)) else {
                return .outdated
            }
        }
        return .connected
    }

    // Codex keys each hook's trust by its position, so Hoply's groups go after the user's own.
    public func connect(_ file: [String: Any]) throws(SettingsJSONError) -> [String: Any]? {
        if let problem = Self.shapeProblem(file) { throw .wrongShape(problem) }
        if status(of: file) == .connected { return nil }
        var result = ClaudeCodeHooks.strip(file, ports: [port]) ?? file
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for event in Self.events {
            let groups = hooks[event] as? [Any] ?? []
            hooks[event] = groups + [["hooks": [hook(for: event)]]]
        }
        result["hooks"] = hooks
        return result
    }

    public func disconnect(_ file: [String: Any]) -> [String: Any]? {
        ClaudeCodeHooks.strip(file, ports: [port])
    }

    public static func shapeProblem(_ file: [String: Any]) -> String? {
        guard !SettingsJSON.isNull(file["hooks"]) else { return nil }
        guard let hooks = file["hooks"] as? [String: Any] else { return "\"hooks\" is not an object" }
        for event in events where !SettingsJSON.isNull(hooks[event]) && !(hooks[event] is [Any]) {
            return "\"hooks.\(event)\" is not a list"
        }
        return nil
    }
}
