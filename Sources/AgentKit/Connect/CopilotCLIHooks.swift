import Foundation

public struct CopilotCLIHooks: Equatable, Sendable {
    public static let fileName = "hoply.json"
    public static let replyEvent = "agentStop"
    public static let events = ["sessionStart", "userPromptSubmitted", "preToolUse", "postToolUse", "permissionRequest",
                                "notification", "agentStop", "sessionEnd", "errorOccurred"]

    public let port: Int

    public init(port: Int) {
        self.port = port
    }

    public var endpoint: String { HoplyEndpoint.baseURL(port: port) }

    public func command(for event: String) -> String {
        guard event != Self.replyEvent else { return replyCommand }
        return "curl -s -m 2 -o /dev/null -H 'Expect:' -H 'Content-Type: application/json' -H \"X-Hoply-Pid: $PPID\" "
            + "--data-binary @- \(endpoint)/hooks/copilot-cli/\(event) || true"
    }

    public var replyCommand: String {
        "curl -sf -m \(TurnReply.curlTimeout) -H 'Expect:' -H 'Content-Type: application/json' -H 'X-Hoply-Reply: 1' "
            + "-H \"X-Hoply-Pid: $PPID\" --data-binary @- \(endpoint)/hooks/copilot-cli/\(Self.replyEvent) || true"
    }

    func timeout(for event: String) -> Int? {
        event == Self.replyEvent ? TurnReply.hookTimeout : nil
    }

    public func hook(for event: String) -> [String: Any] {
        var hook: [String: Any] = ["type": "command", "bash": command(for: event)]
        hook["timeoutSec"] = timeout(for: event)
        return hook
    }

    public var file: [String: Any] {
        var hooks: [String: Any] = [:]
        for event in Self.events {
            hooks[event] = [hook(for: event)]
        }
        return ["version": 1, "hooks": hooks]
    }

    // Keeps the layout install.sh's jq wrote (key order, indent); SettingsJSON.encode would sort the keys.
    public var fileContents: Data {
        var lines = ["{", "  \"version\": 1,", "  \"hooks\": {"]
        for (index, event) in Self.events.enumerated() {
            let bash = "        \"bash\": \(SettingsJSON.quoted(command(for: event)))"
            lines += ["    \(SettingsJSON.quoted(event)): [",
                      "      {",
                      "        \"type\": \"command\","]
            if let timeout = timeout(for: event) {
                lines += [bash + ",", "        \"timeoutSec\": \(timeout)"]
            } else {
                lines += [bash]
            }
            lines += ["      }",
                      index == Self.events.count - 1 ? "    ]" : "    ],"]
        }
        lines += ["  }", "}"]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    public func status(ofFile data: Data?) -> ConnectionStatus {
        guard let data else { return .notConnected }
        guard let object = try? JSONSerialization.jsonObject(with: data), SettingsJSON.same(object, file) else {
            return .outdated
        }
        return .connected
    }
}
