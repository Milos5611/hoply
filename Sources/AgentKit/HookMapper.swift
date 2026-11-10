import Foundation

public enum HookMapper {
    public static func events(source: AgentSource, eventName pathEventName: String?,
                              json: [String: Any], agentPID: Int32? = nil,
                              now: Date = Date()) -> [AgentEvent] {
        let rawName = pathEventName ?? string(json, ["hook_event_name", "hookEventName", "event"]) ?? ""
        let name = normalize(rawName)
        let sessionID = string(json, ["session_id", "sessionId"]) ?? "unknown"
        let key = SessionKey(source: source, id: sessionID)
        let cwd = string(json, ["cwd"])
        let model = string(json, ["model"])
        let transcriptPath = string(json, ["transcript_path", "transcriptPath"])
        // Claude Code sets `agent_id` on hooks that fire inside a subagent; `agent_type` alone is `--agent`.
        let agentID = string(json, ["agent_id", "agentId"])
        let agentType = string(json, ["agent_type", "agentType"])

        func make(_ kind: AgentEvent.Kind) -> AgentEvent {
            AgentEvent(key: key, kind: kind, time: now, cwd: cwd, model: model, fromHook: true,
                       transcriptPath: transcriptPath, agentID: agentID, agentType: agentID == nil ? nil : agentType,
                       agentPID: agentPID)
        }
        let tool = string(json, ["tool_name", "toolName"])

        switch name {
        case "sessionstart":
            var result = [make(.sessionStarted)]
            if let prompt = string(json, ["initialPrompt", "initial_prompt"]) {
                result.append(make(.promptSubmitted(prompt)))
            }
            return result
        case "userpromptsubmit", "userpromptsubmitted":
            return [make(.promptSubmitted(string(json, ["prompt"])))]
        case "pretooluse":
            if isQuestionTool(tool) { return [make(.questionAsked(question(json)))] }
            return [make(.toolStarted(tool))]
        case "posttooluse", "posttoolusefailure", "posttoolbatch":
            return [make(.toolFinished(tool))]
        case "permissionrequest":
            // The question dialog is built on the permission prompt, but it is not a permission.
            if isQuestionTool(tool) { return [make(.questionAsked(question(json)))] }
            return [make(.needsPermission(tool.map { "Allow \($0)?" } ?? string(json, ["message"])))]
        case "notification":
            return notification(json).map(make).map { [$0] } ?? []
        case "elicitation":
            return [make(.questionAsked(string(json, ["message"])))]
        case "elicitationresult":
            return [make(.activity)]
        case "stop", "agentstop":
            return [make(.turnFinished(string(json, ["last_assistant_message", "lastAssistantMessage"])))]
        case "stopfailure":
            return [make(.turnFailed(error: string(json, ["error"]),
                                     message: string(json, ["last_assistant_message", "error_details", "message"])))]
        case "erroroccurred":
            return [make(.error(string(json, ["error", "message", "errorMessage"])))]
        case "subagentstart":
            // Without a type it is one of Claude Code's internal agents, not a subagent the session spawned.
            guard let agentID, let agentType else { return [] }
            return [make(.subagentStarted(id: agentID, type: agentType))]
        case "subagentstop":
            guard let agentID else { return [] }
            return [make(.subagentStopped(id: agentID, type: agentType))]
        case "sessionend":
            return [make(.sessionEnded(string(json, ["reason"])))]
        default:
            return []
        }
    }

    static func notification(_ json: [String: Any]) -> AgentEvent.Kind? {
        let type = (string(json, ["notification_type", "notificationType", "type"]) ?? "").lowercased()
        let message = string(json, ["message", "title"])
        let text = (message ?? "").lowercased()
        if type.contains("permission") || type.contains("approval") {
            return text.contains("askuserquestion") ? .questionAsked(message) : .needsPermission(message)
        }
        // `elicitation_response` and `elicitation_complete` say the answer went back; the agent works again.
        if type == "elicitation_response" || type == "elicitation_complete" || type == "quota_auto_resume_fired" {
            return .activity
        }
        if type.contains("elicitation") || type.contains("question") { return .questionAsked(message) }
        if type.contains("idle") || type.contains("input") { return .waitingForInput(message) }
        if type.contains("complete") || type.contains("done") || type.contains("finished") {
            return .turnFinished(message)
        }
        if type.isEmpty || type == "other" {
            if text.contains("permission") || text.contains("approve") { return .needsPermission(message) }
            if text.contains("waiting for your input") || text.contains("waiting for input") { return .waitingForInput(message) }
        }
        return nil
    }

    static func isQuestionTool(_ tool: String?) -> Bool {
        guard let tool = tool?.lowercased() else { return false }
        return tool == "askuserquestion" || tool == "ask_user" || tool == "ask_user_question"
    }

    static func question(_ json: [String: Any]) -> String? {
        let input = (json["tool_input"] ?? json["toolInput"]) as? [String: Any]
        guard let first = (input?["questions"] as? [Any])?.first as? [String: Any] else { return nil }
        return string(first, ["question", "header"])
    }

    static func normalize(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.lowercaseLetters.contains($0) })
    }

    static func string(_ json: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}
