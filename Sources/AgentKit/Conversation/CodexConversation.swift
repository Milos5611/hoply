import Foundation

enum CodexConversation {
    static func messages<Lines: Sequence>(_ lines: Lines, cwd: String?) -> [RemoteTranscript.Message]
    where Lines.Element == Data {
        var builder = ConversationBuilder(cwd: cwd)
        var hasMeta = false
        for line in lines {
            if let type = CodexRolloutParser.leadingType(line), !readTypes.contains(type) { continue }
            if let kind = payloadType(line), !readPayloads.contains(kind) { continue }
            guard let decoded = try? decoder.decode(Line.self, from: line), let payload = decoded.payload
            else { continue }
            let time = decoded.timestamp.flatMap(Timestamps.parse)
            switch decoded.type {
            case "session_meta":
                // A fork copies its parent's lines, `session_meta` included; the first one is this file's.
                guard !hasMeta else { continue }
                hasMeta = true
                if let place = payload.cwd, !place.isEmpty { builder.cwd = place }
            case "turn_context":
                if let place = payload.cwd, !place.isEmpty { builder.cwd = place }
            case "event_msg":
                let text = payload.message ?? ""
                switch payload.type {
                case "user_message": builder.user(TurnReply.sentText(in: text) ?? text, at: time)
                case "agent_message": builder.assistant(text, at: time)
                default: continue
                }
            case "response_item":
                builder.tool(tool(payload, cwd: builder.cwd), at: time)
            default:
                continue
            }
        }
        return builder.messages
    }

    static let readTypes: Set<String> = ["session_meta", "turn_context", "event_msg", "response_item"]
    static let readPayloads: Set<String> = ["user_message", "agent_message", "function_call", "custom_tool_call",
                                            "local_shell_call", "web_search_call"]
    private static let decoder = JSONDecoder()
    private static let payloadMarker = Data(#""payload":{"type":""#.utf8)

    private static func tool(_ payload: Payload, cwd: String?) -> String? {
        switch payload.type {
        case "function_call":
            let name = payload.name ?? ""
            let input = payload.arguments.flatMap { try? decoder.decode(ToolInput.self, from: Data($0.utf8)) }
                ?? ToolInput()
            if name == "apply_patch" {
                return ToolLines.compose("Edit", ToolLines.patchPaths(input.first("input") ?? "", cwd: cwd))
            }
            return ToolLines.line(name, input, cwd: cwd)
        case "custom_tool_call":
            let name = payload.name ?? ""
            let input = payload.input ?? ""
            if name == "apply_patch" { return ToolLines.compose("Edit", ToolLines.patchPaths(input, cwd: cwd)) }
            return ToolLines.line(name, ToolInput(["command": input]), cwd: cwd)
        case "local_shell_call":
            return ToolLines.compose("Bash", payload.action?.command.map(ToolLines.command))
        case "web_search_call":
            if let query = payload.action?.query { return ToolLines.compose("WebSearch", query) }
            if let url = payload.action?.url { return ToolLines.compose("WebFetch", ToolLines.host(url)) }
            return "WebSearch"
        default:
            return nil
        }
    }

    static func payloadType(_ line: Data) -> String? {
        let head = line.prefix(256)
        guard let range = head.range(of: payloadMarker) else { return nil }
        let rest = head[range.upperBound...]
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: rest[..<end], as: UTF8.self)
    }

    private struct Line: Decodable {
        var type: String?
        var timestamp: String?
        var payload: Payload?

        enum CodingKeys: String, CodingKey { case type, timestamp, payload }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.lenient(String.self, .type)
            timestamp = c.lenient(String.self, .timestamp)
            payload = c.lenient(Payload.self, .payload)
        }
    }

    private struct Payload: Decodable {
        var type: String?
        var cwd: String?
        var message: String?
        var name: String?
        var arguments: String?
        var input: String?
        var action: Action?

        enum CodingKeys: String, CodingKey { case type, cwd, message, name, arguments, input, action }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.lenient(String.self, .type)
            cwd = c.lenient(String.self, .cwd)
            message = c.lenient(String.self, .message)
            name = c.lenient(String.self, .name)
            arguments = c.lenient(String.self, .arguments)
            input = c.lenient(String.self, .input)
            action = c.lenient(Action.self, .action)
        }
    }

    private struct Action: Decodable {
        var command: [String]?
        var query: String?
        var url: String?

        enum CodingKeys: String, CodingKey { case command, query, url }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = c.lenient([String].self, .command)
            query = c.lenient(String.self, .query)
            url = c.lenient(String.self, .url)
        }
    }
}
