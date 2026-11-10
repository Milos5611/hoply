import Foundation

public struct CopilotCLIHooks: Equatable, Sendable {
    public static let fileName = "hoply.json"
    public static let events = ["sessionStart", "userPromptSubmitted", "preToolUse", "postToolUse", "permissionRequest",
                                "notification", "agentStop", "sessionEnd", "errorOccurred"]

    public let port: Int

    public init(port: Int) {
        self.port = port
    }

    public var endpoint: String { HoplyEndpoint.baseURL(port: port) }

    public func command(for event: String) -> String {
        "curl -s -m 2 -o /dev/null -H 'Expect:' -H 'Content-Type: application/json' -H \"X-Hoply-Pid: $PPID\" "
            + "--data-binary @- \(endpoint)/hooks/copilot-cli/\(event) || true"
    }

    public var file: [String: Any] {
        var hooks: [String: Any] = [:]
        for event in Self.events {
            hooks[event] = [["type": "command", "bash": command(for: event)]]
        }
        return ["version": 1, "hooks": hooks]
    }

    // Byte-identical to what install.sh's jq wrote; SettingsJSON.encode would sort the keys.
    public var fileContents: Data {
        var lines = ["{", "  \"version\": 1,", "  \"hooks\": {"]
        for (index, event) in Self.events.enumerated() {
            lines += ["    \(SettingsJSON.quoted(event)): [",
                      "      {",
                      "        \"type\": \"command\",",
                      "        \"bash\": \(SettingsJSON.quoted(command(for: event)))",
                      "      }",
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
