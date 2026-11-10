import Foundation

public enum TelemetryUsage {
    public static let cwdKey = "hoply.cwd"
    static let genAICacheWriteKeys = ["gen_ai.usage.cache_creation.input_tokens", "gen_ai.usage.cache_creation_input_tokens"]
    static let genAIReasoningKeys = ["gen_ai.usage.reasoning.output_tokens", "gen_ai.usage.reasoning_tokens"]

    public static func records(from records: [TelemetryRecord]) -> [UsageRecord] {
        records.compactMap(record)
    }

    public static func record(_ record: TelemetryRecord) -> UsageRecord? {
        guard let source = TelemetryMapper.source(of: record), UsageAuthority.persistsTelemetry(from: source),
              let time = record.time else { return nil }
        let sessionID = TelemetryMapper.sessionID(of: record, source: source)
        let tokens: TokenCounts
        let dedupeKey: String
        switch source {
        case .qwenCode:
            guard record.name.lowercased().hasSuffix("api_response"), let nanos = record.timeUnixNano else { return nil }
            tokens = qwenTokens(record)
            dedupeKey = "qw:\(sessionID):\(record["prompt_id"]?.string ?? ""):\(nanos)"
        case .copilotIDE:
            guard TelemetryMapper.isGenAIModelCall(record), let key = otelKey(record, source: source, session: sessionID) else {
                return nil
            }
            tokens = genAITokens(record)
            dedupeKey = key
        case .claudeCode, .copilotCLI:
            return nil
        }
        let place = place(of: record)
        return UsageRecord(dedupeKey: dedupeKey, source: source, sessionID: sessionID, timestamp: time,
                           model: record.first(TelemetryMapper.modelKeys)?.string, tokens: tokens,
                           cwd: place.cwd, processID: place.processID)
    }

    public static func ledgerBatch(_ usage: [UsageRecord], prompts: [PromptRecord] = []) -> LedgerBatch {
        var seen: [SessionKey: (times: [Date], cwd: String?)] = [:]
        for record in usage {
            let key = SessionKey(source: record.source, id: record.sessionID)
            seen[key, default: ([], nil)].times.append(record.timestamp)
            if seen[key]?.cwd == nil { seen[key]?.cwd = record.cwd }
        }
        for prompt in prompts {
            seen[prompt.session, default: ([], nil)].times.append(prompt.timestamp)
            if seen[prompt.session]?.cwd == nil { seen[prompt.session]?.cwd = prompt.cwd }
        }
        let updates = seen.keys.sorted { ($0.source.rawValue, $0.id) < ($1.source.rawValue, $1.id) }.map { key in
            let facts = seen[key] ?? ([], nil)
            return SessionUpdate(key: key, firstAt: facts.times.min(), lastAt: facts.times.max(), cwd: facts.cwd,
                                 placeIsAuthoritative: facts.cwd != nil)
        }
        return LedgerBatch(usage: usage, sessions: updates, prompts: prompts)
    }

    static func otelKey(_ record: TelemetryRecord, source: AgentSource, session: String) -> String? {
        if let trace = record.traceID, let span = record.spanID { return "otel:\(trace):\(span)" }
        guard let nanos = record.timeUnixNano else { return nil }
        return "otel:\(source.rawValue):\(session):\(nanos)"
    }

    static func qwenTokens(_ record: TelemetryRecord) -> TokenCounts {
        let prompt = record["input_token_count"]?.int ?? 0
        let cached = record["cached_content_token_count"]?.int ?? 0
        var output = record["output_token_count"]?.int ?? 0
        let thoughts = record["thoughts_token_count"]?.int ?? 0
        // Gemini-style totals count thoughts on top of the output; OpenAI-style completions already include them.
        if thoughts > 0, let total = record["total_token_count"]?.int, total >= prompt + output + thoughts {
            output += thoughts
        }
        return TokenCounts(input: max(0, prompt - cached), output: output, reasoning: min(thoughts, output),
                           cacheRead: cached)
    }

    static func genAITokens(_ record: TelemetryRecord) -> TokenCounts {
        let prompt = record["gen_ai.usage.input_tokens"]?.int ?? 0
        let output = record["gen_ai.usage.output_tokens"]?.int ?? 0
        let cacheRead = record.first(TelemetryMapper.genAICacheReadKeys)?.int ?? 0
        let cacheWrite = record.first(genAICacheWriteKeys)?.int ?? 0
        let reasoning = record.first(genAIReasoningKeys)?.int ?? 0
        return TokenCounts(input: max(0, prompt - cacheRead - cacheWrite), output: output,
                           reasoning: min(reasoning, output), cacheRead: cacheRead, cacheWrite5m: cacheWrite)
    }
}
