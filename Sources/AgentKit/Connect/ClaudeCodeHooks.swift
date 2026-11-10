import Foundation

public struct ClaudeCodeHooks: Equatable, Sendable {
    public static let marker = "# hoply"
    public static let approvalEvent = "PermissionRequest"
    public static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
                                "Notification", "Elicitation", "ElicitationResult", "SubagentStart", "SubagentStop",
                                "Stop", "StopFailure", "SessionEnd"]
    public static let hookTimeout = 5
    // Must stay above curl's -m 590, which stays above Hoply's 570 s hold limit.
    public static let approvalTimeout = 600

    public let port: Int

    public init(port: Int) {
        self.port = port
    }

    public var endpoint: String { HoplyEndpoint.baseURL(port: port) }

    public var hookCommand: String {
        "curl -s -m 2 -o /dev/null -H 'Expect:' -H 'Content-Type: application/json' -H \"X-Hoply-Pid: $PPID\" "
            + "--data-binary @- \(endpoint)/hooks/claude-code || true \(Self.marker)"
    }

    public var approveCommand: String {
        "curl -sf -m 590 -H 'Expect:' -H 'Content-Type: application/json' -H 'X-Hoply-Approve: 1' "
            + "-H \"X-Hoply-Pid: $PPID\" --data-binary @- \(endpoint)/hooks/claude-code || true \(Self.marker)"
    }

    public var environment: [String: String] { Self.environment(port: port) }

    public static func environment(port: Int) -> [String: String] {
        ["CLAUDE_CODE_ENABLE_TELEMETRY": "1",
         "OTEL_LOGS_EXPORTER": "otlp",
         "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL": "http/json",
         "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": "\(HoplyEndpoint.baseURL(port: port))/v1/logs",
         "OTEL_LOGS_EXPORT_INTERVAL": "2000"]
    }

    public func hook(for event: String) -> [String: Any] {
        event == Self.approvalEvent
            ? ["type": "command", "command": approveCommand, "timeout": Self.approvalTimeout]
            : ["type": "command", "command": hookCommand, "timeout": Self.hookTimeout]
    }

    public func status(of settings: [String: Any]) -> ConnectionStatus {
        if let problem = Self.shapeProblem(settings) { return .unreadable(problem) }
        let ours = Self.ourHooks(in: settings)
        guard !ours.isEmpty else { return .notConnected }
        let byEvent = Dictionary(grouping: ours) { $0.event }
        guard Set(byEvent.keys) == Set(Self.events) else { return .outdated }
        for event in Self.events {
            guard let found = byEvent[event], found.count == 1, SettingsJSON.same(found[0].hook, hook(for: event)) else {
                return .outdated
            }
        }
        let env = settings["env"] as? [String: Any] ?? [:]
        guard environment.allSatisfy({ key, value in env[key] as? String == value }) else { return .outdated }
        return .connected
    }

    public func connect(_ settings: [String: Any]) throws(SettingsJSONError) -> [String: Any]? {
        if let problem = Self.shapeProblem(settings) { throw .wrongShape(problem) }
        if status(of: settings) == .connected { return nil }
        var result = Self.strip(settings, ports: [port]) ?? settings
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for event in Self.events {
            let groups = hooks[event] as? [Any] ?? []
            hooks[event] = groups + [["hooks": [hook(for: event)]]]
        }
        result["hooks"] = hooks
        let env = result["env"] as? [String: Any] ?? [:]
        result["env"] = env.merging(environment) { _, ours in ours }
        return result
    }

    public func disconnect(_ settings: [String: Any]) -> [String: Any]? {
        Self.strip(settings, ports: [port])
    }

    public static func shapeProblem(_ settings: [String: Any]) -> String? {
        if !SettingsJSON.isNull(settings["env"]), !(settings["env"] is [String: Any]) {
            return "\"env\" is not an object"
        }
        guard !SettingsJSON.isNull(settings["hooks"]) else { return nil }
        guard let hooks = settings["hooks"] as? [String: Any] else { return "\"hooks\" is not an object" }
        for event in events where !SettingsJSON.isNull(hooks[event]) && !(hooks[event] is [Any]) {
            return "\"hooks.\(event)\" is not a list"
        }
        return nil
    }

    static func isOurs(_ hook: Any) -> Bool {
        ((hook as? [String: Any])?["command"] as? String)?.contains(marker) ?? false
    }

    static func ourHooks(in settings: [String: Any]) -> [(event: String, hook: Any)] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        var found: [(event: String, hook: Any)] = []
        for (event, value) in hooks {
            for group in value as? [Any] ?? [] {
                for hook in (group as? [String: Any])?["hooks"] as? [Any] ?? [] where isOurs(hook) {
                    found.append((event, hook))
                }
            }
        }
        return found
    }

    static func port(inCommand command: String) -> Int? {
        guard let range = command.range(of: "http://127.0.0.1:") else { return nil }
        return Int(command[range.upperBound...].prefix { $0.isASCII && $0.isNumber })
    }

    // A group, event, `hooks` or `env` is dropped only when emptied here, so the user's own empty entries survive.
    static func strip(_ settings: [String: Any], ports: Set<Int>) -> [String: Any]? {
        var result = settings
        var changed = false
        var installedPorts = ports
        for (_, hook) in ourHooks(in: settings) {
            if let command = (hook as? [String: Any])?["command"] as? String, let port = port(inCommand: command) {
                installedPorts.insert(port)
            }
        }
        if var hooks = settings["hooks"] as? [String: Any] {
            var touched = false
            for (event, value) in hooks {
                guard let groups = value as? [Any] else { continue }
                var kept: [Any] = []
                var eventChanged = false
                for group in groups {
                    guard var object = group as? [String: Any], let entries = object["hooks"] as? [Any] else {
                        kept.append(group)
                        continue
                    }
                    let remaining = entries.filter { !isOurs($0) }
                    guard remaining.count != entries.count else {
                        kept.append(group)
                        continue
                    }
                    eventChanged = true
                    if !remaining.isEmpty {
                        object["hooks"] = remaining
                        kept.append(object)
                    }
                }
                guard eventChanged else { continue }
                touched = true
                hooks[event] = kept.isEmpty ? nil : kept
            }
            if touched {
                result["hooks"] = hooks.isEmpty ? nil : hooks
                changed = true
            }
        }
        if var env = settings["env"] as? [String: Any] {
            let ours = installedPorts.map(environment(port:))
            let before = env.count
            env = env.filter { key, value in
                guard let value = value as? String else { return true }
                return !ours.contains { $0[key] == value }
            }
            if env.count != before {
                result["env"] = env.isEmpty ? nil : env
                changed = true
            }
        }
        return changed ? result : nil
    }
}
