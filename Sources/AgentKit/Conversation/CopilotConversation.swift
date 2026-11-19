import Foundation

enum CopilotConversation {
    static func messages<Lines: Sequence>(_ lines: Lines, cwd: String?) -> [RemoteTranscript.Message]
    where Lines.Element == Data {
        var builder = ConversationBuilder(cwd: cwd)
        for line in lines {
            if let type = CopilotEventsParser.leadingType(line), !readTypes.contains(type) { continue }
            guard let decoded = try? decoder.decode(Line.self, from: line), readTypes.contains(decoded.type ?? ""),
                  (decoded.agentId ?? "").isEmpty, let data = decoded.data else { continue }
            let time = decoded.timestamp.flatMap(Timestamps.parse)
            switch decoded.type {
            case "session.start":
                if let place = data.cwd, !place.isEmpty { builder.cwd = place }
            case "user.message":
                let text = data.content ?? ""
                builder.user(TurnReply.sentText(in: text) ?? text, at: time)
            case "assistant.message":
                builder.assistant(data.content ?? "", at: time)
            case "tool.execution_start":
                builder.tool(ToolLines.line(data.toolName ?? "", data.arguments ?? ToolInput(), cwd: builder.cwd),
                             at: time)
            default:
                continue
            }
        }
        return builder.messages
    }

    static let readTypes: Set<String> = ["session.start", "user.message", "assistant.message", "tool.execution_start"]
    private static let decoder = JSONDecoder()

    private struct Line: Decodable {
        var type: String?
        var timestamp: String?
        var agentId: String?
        var data: Payload?

        enum CodingKeys: String, CodingKey { case type, timestamp, agentId, data }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.lenient(String.self, .type)
            timestamp = c.lenient(String.self, .timestamp)
            agentId = c.lenient(String.self, .agentId)
            data = c.lenient(Payload.self, .data)
        }
    }

    private struct Payload: Decodable {
        var content: String?
        var toolName: String?
        var arguments: ToolInput?
        var cwd: String?

        enum CodingKeys: String, CodingKey { case content, toolName, arguments, context }
        enum ContextKeys: String, CodingKey { case cwd }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            content = c.lenient(String.self, .content)
            toolName = c.lenient(String.self, .toolName)
            arguments = c.lenient(ToolInput.self, .arguments)
            cwd = (try? c.nestedContainer(keyedBy: ContextKeys.self, forKey: .context))?.lenient(String.self, .cwd)
        }
    }
}
