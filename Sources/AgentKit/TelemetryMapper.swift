import Foundation

/// Turns OTLP log records and spans from Claude Code, Qwen Code and Copilot into `AgentEvent`s.
public enum TelemetryMapper {
    static let sessionKeys = [
        "session.id", "session_id", "gen_ai.conversation.id",
        "github.copilot.session.id", "copilot_chat.session_id", "conversation.id",
    ]
    static let modelKeys = ["model", "gen_ai.response.model", "gen_ai.request.model"]

    public static func events(from records: [TelemetryRecord], now: Date = Date()) -> [AgentEvent] {
        records.compactMap { event(from: $0, now: now) }
    }

    public static func source(of record: TelemetryRecord) -> AgentSource? {
        let service = record.resource["service.name"]?.string?.lowercased() ?? ""
        let name = record.name.lowercased()
        if service.contains("claude") || name.hasPrefix("claude_code") { return .claudeCode }
        if service.contains("qwen") || name.hasPrefix("qwen-code") || name.hasPrefix("qwen_code") { return .qwenCode }
        if service.contains("copilot") || name.contains("copilot") {
            return service.contains("cli") ? .copilotCLI : .copilotIDE
        }
        return nil
    }

    static func sessionID(of record: TelemetryRecord, source: AgentSource) -> String {
        record.first(sessionKeys)?.string
            ?? record.resource["service.instance.id"]?.string
            ?? record.resource["service.name"]?.string
            ?? source.rawValue
    }

    static func event(from record: TelemetryRecord, now: Date) -> AgentEvent? {
        guard let source = source(of: record) else { return nil }
        let key = SessionKey(source: source, id: sessionID(of: record, source: source))
        let model = record.first(modelKeys)?.string
        let time = record.time ?? now
        let kind: AgentEvent.Kind

        switch source {
        case .claudeCode: kind = claudeKind(record)
        case .qwenCode: kind = qwenKind(record)
        case .copilotCLI, .copilotIDE: kind = genAIKind(record)
        }
        return AgentEvent(key: key, kind: kind, time: time, model: model, fromHook: false)
    }

    /// Claude Code log events: claude_code.user_prompt, api_request, tool_result, api_error, …
    static func claudeKind(_ record: TelemetryRecord) -> AgentEvent.Kind {
        let name = record.name.lowercased()
        if name.hasSuffix("api_request") {
            let cache = (record["cache_read_tokens"]?.int ?? 0) + (record["cache_creation_tokens"]?.int ?? 0)
            return .usage(.init(inputTokens: record["input_tokens"]?.int ?? 0,
                                outputTokens: record["output_tokens"]?.int ?? 0,
                                cacheTokens: cache,
                                costUSD: record["cost_usd"]?.double ?? 0))
        }
        if name.hasSuffix("user_prompt") {
            return .promptSubmitted(record["prompt"]?.string)
        }
        if name.hasSuffix("tool_result") {
            return .toolFinished(record["tool_name"]?.string)
        }
        if name.hasSuffix("api_error") {
            return .error(record["error"]?.string)
        }
        return .activity
    }

    /// Qwen Code log events: qwen-code.api_request, api_response, user_prompt, tool_call, api_error.
    static func qwenKind(_ record: TelemetryRecord) -> AgentEvent.Kind {
        let name = record.name.lowercased()
        if name.hasSuffix("api_response") {
            return .usage(.init(inputTokens: record["input_token_count"]?.int ?? 0,
                                outputTokens: record["output_token_count"]?.int ?? 0,
                                cacheTokens: record["cached_content_token_count"]?.int ?? 0))
        }
        if name.hasSuffix("user_prompt") {
            return .promptSubmitted(record["prompt"]?.string)
        }
        if name.hasSuffix("tool_call") {
            return .toolFinished(record["function_name"]?.string ?? record["tool_name"]?.string)
        }
        if name.hasSuffix("api_error") {
            return .error(record["error"]?.string ?? record["error.message"]?.string)
        }
        return .activity
    }

    /// Copilot (CLI, VS Code, JetBrains) emits OpenTelemetry GenAI semantic conventions.
    static func genAIKind(_ record: TelemetryRecord) -> AgentEvent.Kind {
        if isGenAIModelCall(record) {
            let cache = record.first(genAICacheReadKeys)?.int ?? 0
            return .usage(.init(inputTokens: record["gen_ai.usage.input_tokens"]?.int ?? 0,
                                outputTokens: record["gen_ai.usage.output_tokens"]?.int ?? 0, cacheTokens: cache))
        }
        if let tool = record["gen_ai.tool.name"]?.string {
            return .toolFinished(tool)
        }
        if record.name.lowercased().hasPrefix("execute_tool") {
            let tool = record.name.split(separator: " ").dropFirst().joined(separator: " ")
            return .toolFinished(tool.isEmpty ? nil : tool)
        }
        return .activity
    }

    static let genAICacheReadKeys = ["gen_ai.usage.cache_read.input_tokens", "gen_ai.usage.cache_read_input_tokens"]

    /// Only model calls carry usage worth counting; agent and turn spans can repeat the same totals.
    static func isGenAIModelCall(_ record: TelemetryRecord) -> Bool {
        let operation = record["gen_ai.operation.name"]?.string?.lowercased()
        guard record["gen_ai.usage.input_tokens"] != nil || record["gen_ai.usage.output_tokens"] != nil else { return false }
        return operation == nil || operation == "chat" || operation == "text_completion"
    }
}
