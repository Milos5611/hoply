import Foundation

/// Turns hook payloads from Claude Code and Copilot CLI into `AgentEvent`s.
///
/// Claude Code sends snake_case JSON with `hook_event_name`. Copilot CLI sends camelCase JSON
/// without an event name, so the setup scripts put the event name in the URL path
/// (`/hooks/copilot-cli/sessionStart`); the path name wins when both are present.
public enum HookMapper {
    public static func events(source: AgentSource, eventName pathEventName: String?,
                              json: [String: Any], now: Date = Date()) -> [AgentEvent] {
        let rawName = pathEventName ?? string(json, ["hook_event_name", "hookEventName", "event"]) ?? ""
        let name = normalize(rawName)
        let sessionID = string(json, ["session_id", "sessionId"]) ?? "unknown"
        let key = SessionKey(source: source, id: sessionID)
        let cwd = string(json, ["cwd"])
        let model = string(json, ["model"])
        let transcriptPath = string(json, ["transcript_path", "transcriptPath"])

        func make(_ kind: AgentEvent.Kind) -> AgentEvent {
            AgentEvent(key: key, kind: kind, time: now, cwd: cwd, model: model, fromHook: true,
                       transcriptPath: transcriptPath)
        }

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
            return [make(.toolStarted(string(json, ["tool_name", "toolName"])))]
        case "posttooluse", "posttoolusefailure", "posttoolbatch":
            return [make(.toolFinished(string(json, ["tool_name", "toolName"])))]
        case "permissionrequest":
            let tool = string(json, ["tool_name", "toolName"])
            return [make(.needsPermission(tool.map { "Allow \($0)?" } ?? string(json, ["message"])))]
        case "notification":
            return notification(json).map(make).map { [$0] } ?? []
        case "stop", "agentstop":
            return [make(.turnFinished(string(json, ["last_assistant_message", "lastAssistantMessage"])))]
        case "stopfailure", "erroroccurred":
            return [make(.error(string(json, ["error", "message", "errorMessage"])))]
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
        if type.contains("permission") || type.contains("approval") { return .needsPermission(message) }
        if type.contains("idle") || type.contains("input") || type.contains("elicitation") || type.contains("question") {
            return .waitingForInput(message)
        }
        if type.contains("complete") || type.contains("done") || type.contains("finished") {
            return .turnFinished(message)
        }
        if type.isEmpty || type == "other" {
            if text.contains("permission") || text.contains("approve") { return .needsPermission(message) }
            if text.contains("waiting for your input") || text.contains("waiting for input") { return .waitingForInput(message) }
        }
        return nil
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
