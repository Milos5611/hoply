import Foundation

public enum ConversationParser {
    public static let agents: [AgentSource] = [.claudeCode, .codexCLI, .copilotCLI]

    public static func messages<Lines: Sequence>(_ source: AgentSource, lines: Lines, cwd: String? = nil)
        -> [RemoteTranscript.Message]? where Lines.Element == Data {
        switch source {
        case .claudeCode: ClaudeConversation.messages(lines, cwd: cwd)
        case .codexCLI: CodexConversation.messages(lines, cwd: cwd)
        case .copilotCLI: CopilotConversation.messages(lines, cwd: cwd)
        case .copilotIDE, .qwenCode: nil
        }
    }
}

struct ConversationBuilder {
    var cwd: String?
    private(set) var messages: [RemoteTranscript.Message] = []
    private var assistantGroup: String?

    init(cwd: String?) {
        self.cwd = cwd.flatMap { $0.isEmpty ? nil : $0 }
    }

    mutating func user(_ raw: String, at time: Date?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // A reply can land twice (the hook's own record and the message it becomes).
        if let last = messages.last, last.role == .user, last.text == text { return }
        messages.append(RemoteTranscript.Message(role: .user, text: text, at: time))
        assistantGroup = nil
    }

    mutating func assistant(_ raw: String, at time: Date?, group: String? = nil) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let group, group == assistantGroup, let last = messages.indices.last, messages[last].role == .assistant {
            messages[last].text += "\n\n" + text
            return
        }
        messages.append(RemoteTranscript.Message(role: .assistant, text: text, at: time))
        assistantGroup = group
    }

    mutating func tool(_ line: String?, at time: Date?) {
        guard let line, !line.isEmpty else { return }
        messages.append(RemoteTranscript.Message(role: .tool, text: line, at: time))
        assistantGroup = nil
    }
}

struct ToolInput: Decodable, Sendable {
    var values: [String: String]

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    init(from decoder: any Decoder) throws {
        values = [:]
        guard let container = try? decoder.container(keyedBy: AnyKey.self) else { return }
        for key in container.allKeys {
            if let text = try? container.decode(String.self, forKey: key) {
                values[key.stringValue] = text
            } else if let parts = try? container.decode([String].self, forKey: key) {
                values[key.stringValue] = ToolLines.command(parts)
            }
        }
    }

    func first(_ keys: String...) -> String? {
        keys.lazy.compactMap { values[$0] }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

enum ToolLines {
    static let skipped: Set<String> = ["report_intent", "write_stdin", "read_bash", "write_bash", "stop_bash",
                                       "list_bash"]

    static func line(_ name: String, _ input: ToolInput, cwd: String?) -> String? {
        let key = name.lowercased()
        guard !name.isEmpty, !skipped.contains(key) else { return nil }
        func path() -> String? { input.first("file_path", "path", "notebook_path").map { relative($0, to: cwd) } }
        switch key {
        case "bash", "shell", "shell_command", "exec_command", "container.exec", "local_shell", "exec", "powershell":
            return compose("Bash", input.first("command", "cmd"))
        case "read", "view", "view_image", "notebookread":
            return compose("Read", path())
        case "edit", "multiedit", "notebookedit", "str_replace", "str_replace_editor", "str_replace_based_edit_tool":
            return compose("Edit", path())
        case "write", "create":
            return compose("Write", path())
        case "glob":
            return compose("Glob", input.first("pattern"))
        case "grep", "rg":
            return compose("Grep", input.first("pattern", "query"))
        case "webfetch", "web_fetch":
            return compose("WebFetch", input.first("url").map(host))
        case "websearch", "web_search":
            return compose("WebSearch", input.first("query"))
        case "task", "agent":
            return compose("Task", input.first("description", "subagent_type", "agent_type"))
        case "todowrite", "update_plan", "update_todo", "todo":
            return "Todo"
        default:
            for argument in fallbackKeys {
                guard let value = input.first(argument) else { continue }
                switch argument {
                case "url": return compose(name, host(value))
                case "file_path", "path", "notebook_path": return compose(name, relative(value, to: cwd))
                default: return compose(name, value)
                }
            }
            return name
        }
    }

    static let fallbackKeys = ["file_path", "path", "notebook_path", "command", "cmd", "pattern", "query", "url",
                               "skill", "description", "name", "prompt"]

    static func compose(_ label: String, _ argument: String?) -> String {
        guard let argument = argument.flatMap(firstLine) else { return label }
        return label + " " + argument
    }

    static func firstLine(_ text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        return lines.count > 1 ? first + " …" : first
    }

    static func relative(_ path: String, to cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return path }
        let base = cwd.count > 1 && cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        if path == base { return "." }
        guard base != "/", path.hasPrefix(base + "/") else { return path }
        return String(path.dropFirst(base.count + 1))
    }

    static func host(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }

    static func command(_ parts: [String]) -> String {
        if parts.count >= 3, ["-lc", "-c"].contains(parts[1]), parts[0].hasSuffix("sh") { return parts[2] }
        return parts.joined(separator: " ")
    }

    static func patchPaths(_ patch: String, cwd: String?) -> String? {
        let markers = ["*** Update File: ", "*** Add File: ", "*** Delete File: "]
        var paths: [String] = []
        for line in patch.split(whereSeparator: \.isNewline) {
            guard let marker = markers.first(where: { line.hasPrefix($0) }) else { continue }
            let path = relative(line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces), to: cwd)
            if !path.isEmpty, !paths.contains(path) { paths.append(path) }
        }
        return paths.isEmpty ? nil : paths.joined(separator: ", ")
    }
}
