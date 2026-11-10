import Foundation

public struct ApprovalRequest: Sendable, Equatable, Identifiable {
    public let id: String
    public let key: SessionKey
    public let tool: String
    public let detail: String?
    public let agentID: String?
    public let received: Date

    public init(id: String = UUID().uuidString, key: SessionKey, tool: String, detail: String?,
                agentID: String? = nil, received: Date) {
        self.id = id
        self.key = key
        self.tool = tool
        self.detail = detail
        self.agentID = agentID
        self.received = received
    }

    public var summary: String {
        detail.map { "\(tool): \($0)" } ?? tool
    }
}

public enum ApprovalDecision: Sendable, Equatable {
    case allow
    case deny
}

public enum PermissionApproval {
    public static let header = "x-hoply-approve"
    // Released before the hook's curl (-m 590) and Claude Code's hook timeout (600 s) give up.
    public static let holdLimit: TimeInterval = 570
    public static let denyMessage = "The user denied this from Hoply."

    // Allow alone does not answer these: they need the user's answers or plan choice in `updatedInput`.
    static let interactiveTools: Set<String> = ["askuserquestion", "exitplanmode"]

    public static func request(source: AgentSource, eventName: String?, json: [String: Any],
                               headers: [String: String], now: Date = Date()) -> ApprovalRequest? {
        guard source == .claudeCode, headers[header] == "1" else { return nil }
        let name = HookMapper.normalize(eventName ?? HookMapper.string(json, ["hook_event_name"]) ?? "")
        guard name == "permissionrequest", let tool = HookMapper.string(json, ["tool_name"]),
              !interactiveTools.contains(tool.lowercased()), !HookMapper.isQuestionTool(tool) else { return nil }
        let session = HookMapper.string(json, ["session_id"]) ?? "unknown"
        return ApprovalRequest(key: SessionKey(source: source, id: session), tool: tool,
                               detail: detail(tool: tool, input: json["tool_input"] as? [String: Any]),
                               agentID: HookMapper.string(json, ["agent_id"]), received: now)
    }

    static func detail(tool: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        let keys = ["command", "file_path", "notebook_path", "url", "query", "pattern", "path", "description", "prompt"]
        for key in keys {
            if let value = input[key] as? String, let text = oneLine(value) { return text }
        }
        return nil
    }

    static func oneLine(_ text: String, limit: Int = 300) -> String? {
        let collapsed = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ⏎ ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    public static func response(_ decision: ApprovalDecision?) -> HTTPResponse {
        guard let decision else { return .json() }
        var verdict: [String: Any] = ["behavior": decision == .allow ? "allow" : "deny"]
        if decision == .deny {
            verdict["message"] = denyMessage
            verdict["interrupt"] = false
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": verdict]]
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) else {
            return .json()
        }
        return .json(String(decoding: data, as: UTF8.self))
    }

    // The terminal dialog stays answerable while a hook is held; these events show it was answered there.
    public static func answered(_ pending: [ApprovalRequest], by events: [AgentEvent]) -> [String] {
        pending.filter { approval in
            events.contains { event in
                guard event.key == approval.key, event.fromHook, event.time >= approval.received else { return false }
                switch event.kind {
                case .sessionStarted, .sessionEnded:
                    return true
                case .subagentStopped(let id, _):
                    return id == approval.agentID
                default:
                    break
                }
                guard event.agentID.flatMap({ $0.isEmpty ? nil : $0 }) == approval.agentID else { return false }
                switch event.kind {
                case .promptSubmitted, .turnFinished, .turnFailed:
                    return true
                case .toolFinished(let tool):
                    return tool == approval.tool
                default:
                    return false
                }
            }
        }.map(\.id)
    }
}
