import Foundation

enum ClaudeConversation {
    static func messages<Lines: Sequence>(_ lines: Lines, cwd: String?) -> [RemoteTranscript.Message]
    where Lines.Element == Data {
        var builder = ConversationBuilder(cwd: cwd)
        var seenLines: Set<String> = []
        var seenTools: Set<String> = []
        for line in lines {
            let leading = ClaudeTranscriptParser.leadingType(line)
            if let leading, !readTypes.contains(leading) { continue }
            let mentionsReply = line.range(of: replyMarker) != nil
            if leading == "system", !mentionsReply { continue }
            if !mentionsReply, line.range(of: attachmentMarker) != nil, line.range(of: queuedMarker) == nil { continue }
            guard let decoded = try? decoder.decode(Line.self, from: line), !decoded.isSidechain else { continue }
            if let uuid = decoded.uuid, !seenLines.insert(uuid).inserted { continue }
            if let lineCwd = decoded.cwd, !lineCwd.isEmpty { builder.cwd = lineCwd }
            let time = decoded.timestamp.flatMap(Timestamps.parse)
            switch decoded.type {
            case "assistant":
                assistant(decoded, at: time, seenTools: &seenTools, into: &builder)
            case "user":
                user(decoded, at: time, into: &builder)
            default:
                if let prompt = queuedPrompt(decoded) {
                    builder.user(TurnReply.sentText(in: prompt) ?? prompt, at: time)
                } else if mentionsReply, let reply = hookReply(line) {
                    builder.user(reply, at: time)
                }
            }
        }
        return builder.messages
    }

    static let readTypes: Set<String> = ["user", "assistant", "attachment", "system"]
    static let noisePrefixes = ["<local-command-", "<bash-", "<command-", "<system-reminder>", "<task-notification>",
                                "[Request interrupted by user", "Caveat: "]
    private static let replyMarker = Data(TurnReply.reasonPrefix.utf8)
    private static let attachmentMarker = Data(#""type":"attachment""#.utf8)
    private static let queuedMarker = Data(#""queued_command""#.utf8)
    private static let decoder = JSONDecoder()

    private static func assistant(_ line: Line, at time: Date?, seenTools: inout Set<String>,
                                  into builder: inout ConversationBuilder) {
        guard let message = line.message, message.model != "<synthetic>", !line.isApiErrorMessage,
              let content = message.content else { return }
        switch content {
        case .text(let text):
            builder.assistant(text, at: time, group: message.id)
        case .blocks(let blocks):
            for block in blocks {
                switch block.type {
                case "text":
                    builder.assistant(block.text ?? "", at: time, group: message.id)
                case "tool_use", "server_tool_use":
                    if let id = block.id, !seenTools.insert(id).inserted { continue }
                    builder.tool(ToolLines.line(block.name ?? "", block.input ?? ToolInput(), cwd: builder.cwd),
                                 at: time)
                default:
                    continue
                }
            }
        }
    }

    private static func user(_ line: Line, at time: Date?, into builder: inout ConversationBuilder) {
        guard !line.hasToolUseResult, let content = line.message?.content, !content.hasToolResult else { return }
        let text = content.text
        if let reply = TurnReply.sentText(in: text) {
            builder.user(reply, at: time)
            return
        }
        guard !line.isMeta, !line.isCompactSummary, !text.isEmpty else { return }
        if let kind = line.originKind, kind != "human" { return }
        if let command = slashCommand(text) {
            builder.user(command, at: time)
            return
        }
        if line.originKind == nil, text.hasPrefix("<") { return }
        if noisePrefixes.contains(where: text.hasPrefix) { return }
        builder.user(text, at: time)
    }

    private static func queuedPrompt(_ line: Line) -> String? {
        guard line.type == "attachment", let attachment = line.attachment, attachment.type == "queued_command"
        else { return nil }
        if let kind = attachment.originKind {
            guard kind == "human" else { return nil }
        } else {
            guard attachment.commandMode == "prompt", !attachment.isMeta else { return nil }
        }
        let text = attachment.prompt?.text ?? ""
        return text.isEmpty ? nil : text
    }

    static func slashCommand(_ text: String) -> String? {
        guard let name = tag("command-name", in: text), !name.isEmpty else { return nil }
        let command = name.hasPrefix("/") ? name : "/" + name
        guard let arguments = tag("command-args", in: text), !arguments.isEmpty else { return command }
        return command + " " + arguments
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Where Claude Code records a Stop hook's block reason isn't pinned down, so any non-assistant line carrying
    // Hoply's prefix counts, except tool output (a file or command result that merely contains the text).
    static func hookReply(_ line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["toolUseResult"] == nil, (object["isSidechain"] as? Bool) != true,
              object["type"] as? String != "assistant" else { return nil }
        if let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]],
           content.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
        return firstReply(in: object, depth: 0)
    }

    private static func firstReply(in value: Any, depth: Int) -> String? {
        guard depth < 8 else { return nil }
        switch value {
        case let text as String:
            return TurnReply.sentText(in: text)
        case let object as [String: Any]:
            for key in object.keys.sorted() {
                if let reply = firstReply(in: object[key] as Any, depth: depth + 1) { return reply }
            }
            return nil
        case let array as [Any]:
            return array.lazy.compactMap { firstReply(in: $0, depth: depth + 1) }.first
        default:
            return nil
        }
    }

    private struct Line: Decodable {
        var type: String?
        var uuid: String?
        var timestamp: String?
        var cwd: String?
        var isSidechain: Bool
        var isMeta: Bool
        var isCompactSummary: Bool
        var isApiErrorMessage: Bool
        var hasToolUseResult: Bool
        var originKind: String?
        var message: Message?
        var attachment: Attachment?

        enum CodingKeys: String, CodingKey {
            case type, uuid, timestamp, cwd, isSidechain, isMeta, isCompactSummary, isApiErrorMessage, toolUseResult
            case origin, message, attachment
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.lenient(String.self, .type)
            uuid = c.lenient(String.self, .uuid)
            timestamp = c.lenient(String.self, .timestamp)
            cwd = c.lenient(String.self, .cwd)
            isSidechain = c.lenient(Bool.self, .isSidechain) ?? false
            isMeta = c.lenient(Bool.self, .isMeta) ?? false
            isCompactSummary = c.lenient(Bool.self, .isCompactSummary) ?? false
            isApiErrorMessage = c.lenient(Bool.self, .isApiErrorMessage) ?? false
            hasToolUseResult = c.contains(.toolUseResult) && !((try? c.decodeNil(forKey: .toolUseResult)) ?? true)
            originKind = c.lenient(Origin.self, .origin)?.kind
            message = c.lenient(Message.self, .message)
            attachment = c.lenient(Attachment.self, .attachment)
        }
    }

    private struct Origin: Decodable {
        var kind: String?

        enum CodingKeys: String, CodingKey { case kind }

        init(from decoder: any Decoder) throws {
            kind = try decoder.container(keyedBy: CodingKeys.self).lenient(String.self, .kind)
        }
    }

    private struct Message: Decodable {
        var id: String?
        var model: String?
        var content: Content?

        enum CodingKeys: String, CodingKey { case id, model, content }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.lenient(String.self, .id)
            model = c.lenient(String.self, .model)
            content = c.lenient(Content.self, .content)
        }
    }

    private struct Attachment: Decodable {
        var type: String?
        var prompt: Content?
        var originKind: String?
        var commandMode: String?
        var isMeta: Bool

        enum CodingKeys: String, CodingKey { case type, prompt, origin, commandMode, isMeta }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.lenient(String.self, .type)
            prompt = c.lenient(Content.self, .prompt)
            originKind = c.lenient(Origin.self, .origin)?.kind
            commandMode = c.lenient(String.self, .commandMode)
            isMeta = c.lenient(Bool.self, .isMeta) ?? false
        }
    }

    private enum Content: Decodable {
        case text(String)
        case blocks([Block])

        init(from decoder: any Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let text = try? single.decode(String.self) {
                self = .text(text)
            } else {
                self = .blocks((try? single.decode([LenientBlock].self))?.compactMap(\.block) ?? [])
            }
        }

        var text: String {
            switch self {
            case .text(let text):
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            case .blocks(let blocks):
                return blocks.filter { $0.type == "text" }.compactMap(\.text)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
            }
        }

        var hasToolResult: Bool {
            if case .blocks(let blocks) = self { return blocks.contains { $0.type == "tool_result" } }
            return false
        }
    }

    private struct LenientBlock: Decodable {
        var block: Block?

        init(from decoder: any Decoder) throws {
            block = try? Block(from: decoder)
        }
    }

    private struct Block: Decodable {
        var type: String?
        var text: String?
        var id: String?
        var name: String?
        var input: ToolInput?

        enum CodingKeys: String, CodingKey { case type, text, id, name, input }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.lenient(String.self, .type)
            text = c.lenient(String.self, .text)
            id = c.lenient(String.self, .id)
            name = c.lenient(String.self, .name)
            input = c.lenient(ToolInput.self, .input)
        }
    }
}
