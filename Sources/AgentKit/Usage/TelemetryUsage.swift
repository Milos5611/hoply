import Foundation

/// Ledger rows from OTLP, for the sources whose ledger is telemetry (Copilot IDE, Qwen Code). Claude Code and
/// Copilot CLI telemetry is never persisted: their transcripts and session store are the history.
public enum TelemetryUsage {
    /// Resource attribute users set through `OTEL_RESOURCE_ATTRIBUTES=hoply.cwd=…` to name the project.
    public static let cwdKey = "hoply.cwd"
    static let genAICacheWriteKeys = ["gen_ai.usage.cache_creation.input_tokens", "gen_ai.usage.cache_creation_input_tokens"]
    static let genAIReasoningKeys = ["gen_ai.usage.reasoning.output_tokens", "gen_ai.usage.reasoning_tokens"]

    public static func records(from records: [TelemetryRecord]) -> [UsageRecord] {
        records.compactMap(record)
    }

    /// Nil for records that are not a model call, come from a source with another ledger, or lack a stable
    /// identity (a re-sent batch must map to the same dedupe keys).
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
        let cwd = record.resource[cwdKey]?.string ?? record[cwdKey]?.string
        let pid = record.resource["process.pid"]?.int.flatMap { Int32(exactly: $0) }
        return UsageRecord(dedupeKey: dedupeKey, source: source, sessionID: sessionID, timestamp: time,
                           model: record.first(TelemetryMapper.modelKeys)?.string, tokens: tokens,
                           cwd: cwd.flatMap { $0.isEmpty ? nil : $0 }, processID: pid.flatMap { $0 > 0 ? $0 : nil })
    }

    /// One session update per session in `usage`: first/last activity and the cwd, if any record carried one.
    public static func ledgerBatch(_ usage: [UsageRecord]) -> LedgerBatch {
        let bySession = Dictionary(grouping: usage) { SessionKey(source: $0.source, id: $0.sessionID) }
        let updates = bySession.keys.sorted { ($0.source.rawValue, $0.id) < ($1.source.rawValue, $1.id) }.map { key in
            let records = bySession[key] ?? []
            let cwd = records.lazy.compactMap(\.cwd).first
            return SessionUpdate(key: key, firstAt: records.map(\.timestamp).min(),
                                 lastAt: records.map(\.timestamp).max(), cwd: cwd,
                                 placeIsAuthoritative: cwd != nil)
        }
        return LedgerBatch(usage: usage, sessions: updates)
    }

    /// Spans are identified by trace and span id. A log record (or a span) without them falls back to its
    /// session and exact timestamp.
    static func otelKey(_ record: TelemetryRecord, source: AgentSource, session: String) -> String? {
        if let trace = record.traceID, let span = record.spanID { return "otel:\(trace):\(span)" }
        guard let nanos = record.timeUnixNano else { return nil }
        return "otel:\(source.rawValue):\(session):\(nanos)"
    }

    /// Qwen Code (a Gemini CLI fork) reports the prompt including cached tokens.
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

    /// GenAI semantic conventions: `input_tokens` includes cache reads and writes; reasoning is part of the output.
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
