import Foundation

public struct CodexTokenTotals: Sendable, Equatable, Codable {
    public var input: Int
    public var cached: Int
    public var output: Int
    public var reasoning: Int
    public var cacheWrite: Int
    public var total: Int

    public init(input: Int = 0, cached: Int = 0, output: Int = 0, reasoning: Int = 0, cacheWrite: Int = 0, total: Int = 0) {
        self.input = input
        self.cached = cached
        self.output = output
        self.reasoning = reasoning
        self.cacheWrite = cacheWrite
        self.total = total
    }

    var fields: [Int] { [input, cached, output, reasoning, cacheWrite, total] }
}

public struct CodexRolloutState: Sendable, Equatable {
    public var threadID: String
    public var sessionID: String
    public var isSubagent = false
    public var hasMeta = false
    public var hasTurnEvents = false
    public var cwd: String?
    public var branch: String?
    public var model: String?
    public var total: CodexTokenTotals?

    public init(path: String) {
        let id = Self.threadID(fromPath: path) ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        threadID = id
        sessionID = id
    }

    // `rollout-<local time>-<uuid>.jsonl`; a reverted thread appends `_<rollout id>` to the uuid.
    public static func threadID(fromPath path: String) -> String? {
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("rollout-") else { return nil }
        let base = stem.split(separator: "_").first.map(String.init) ?? stem
        guard base.count >= 36 else { return nil }
        let candidate = String(base.suffix(36))
        return UUID(uuidString: candidate) == nil ? nil : candidate.lowercased()
    }
}

public enum CodexRolloutParser {
    public static func batch<Lines: Sequence>(lines: Lines, state: inout CodexRolloutState, transcriptPath: String,
                                              startsAtFileStart: Bool) -> LedgerBatch where Lines.Element == Data {
        var usage: [UsageRecord] = []
        var firstAt: Date?
        var lastAt: Date?
        var turns = 0
        for line in lines {
            if let type = leadingType(line), skippedTypes.contains(type) { continue }
            guard let decoded = try? decoder.decode(Line.self, from: line) else { continue }
            let time = decoded.timestamp.flatMap(Timestamps.parse)
            if let time {
                firstAt = min(firstAt ?? time, time)
                lastAt = max(lastAt ?? time, time)
            }
            switch decoded.type {
            case "session_meta":
                // A forked thread copies its parent's lines, `session_meta` included; the first one is this file's.
                guard !state.hasMeta, let meta = decoded.payload else { continue }
                state.hasMeta = true
                if let id = meta.id { state.threadID = id }
                state.isSubagent = meta.source?.isSubagent ?? false
                state.sessionID = meta.sessionID ?? state.threadID
                state.cwd = meta.cwd ?? state.cwd
                state.branch = meta.git?.branch ?? state.branch
            case "turn_context":
                guard let context = decoded.payload else { continue }
                if let model = context.model { state.model = model }
                if state.cwd == nil { state.cwd = context.cwd }
            case "event_msg":
                guard let payload = decoded.payload else { continue }
                switch payload.type {
                case "task_started", "turn_started":
                    state.hasTurnEvents = true
                    turns += 1
                case "user_message":
                    // Older versions write no turn events; newer ones write both, or no `user_message` at all.
                    if !state.hasTurnEvents { turns += 1 }
                case "token_count":
                    guard let total = payload.info?.totalTokenUsage?.totals, let time else { continue }
                    if let record = record(after: total, state: &state, at: time) { usage.append(record) }
                default:
                    continue
                }
            default:
                continue
            }
        }
        guard firstAt != nil || !usage.isEmpty || startsAtFileStart else { return LedgerBatch(usage: usage) }
        let session = SessionUpdate(key: SessionKey(source: .codexCLI, id: state.sessionID), firstAt: firstAt,
                                    lastAt: lastAt, cwd: state.cwd, branch: state.branch,
                                    placeIsAuthoritative: !state.isSubagent && state.cwd != nil,
                                    transcriptPath: state.isSubagent ? nil : transcriptPath,
                                    prompts: state.isSubagent ? 0 : turns,
                                    resetsTurns: startsAtFileStart && !state.isSubagent)
        return LedgerBatch(usage: usage, sessions: [session])
    }

    // A call's usage is the growth of the thread's running total: `last_token_usage` repeats on rate-limit
    // updates and is overwritten by local estimates, and a total that drops (context-window reset) is a new base.
    static func record(after total: CodexTokenTotals, state: inout CodexRolloutState, at time: Date) -> UsageRecord? {
        let previous = state.total ?? CodexTokenTotals()
        state.total = total
        let deltas = zip(total.fields, previous.fields).map { $0 - $1 }
        guard deltas.allSatisfy({ $0 >= 0 }), deltas.contains(where: { $0 > 0 }) else { return nil }
        let cached = total.cached - previous.cached
        let cacheWrite = total.cacheWrite - previous.cacheWrite
        let input = total.input - previous.input
        let tokens = TokenCounts(input: max(input - cached - cacheWrite, 0), output: total.output - previous.output,
                                 reasoning: total.reasoning - previous.reasoning, cacheRead: cached,
                                 cacheWrite5m: cacheWrite)
        // Keyed on the running total alone, so a fork's copy of its parent's lines lands on the parent's rows.
        let key = "cx:" + total.fields.map(String.init).joined(separator: ":")
        return UsageRecord(dedupeKey: key, source: .codexCLI, sessionID: state.sessionID, timestamp: time,
                           model: state.model, isSidechain: state.isSubagent,
                           agentID: state.isSubagent ? state.threadID : nil, tokens: tokens, cwd: state.cwd,
                           gitBranch: state.branch)
    }

    static let skippedTypes: Set<String> = ["response_item", "world_state", "compacted"]

    static func leadingType(_ line: Data) -> String? {
        let head = line.prefix(96)
        let marker = Data(#""type":""#.utf8)
        guard let range = head.range(of: marker) else { return nil }
        let rest = head[range.upperBound...]
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: rest[..<end], as: UTF8.self)
    }

    private static let decoder = JSONDecoder()

    struct Line: Decodable {
        var timestamp: String?
        var type: String
        var payload: Payload?
    }

    struct Payload: Decodable {
        var type: String?
        var id: String?
        var sessionID: String?
        var cwd: String?
        var model: String?
        var source: Source?
        var git: Git?
        var info: Info?

        enum CodingKeys: String, CodingKey {
            case type, id, cwd, model, source, git, info
            case sessionID = "session_id"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            sessionID = try? container.decodeIfPresent(String.self, forKey: .sessionID)
            cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
            model = try? container.decodeIfPresent(String.self, forKey: .model)
            source = try? container.decodeIfPresent(Source.self, forKey: .source)
            git = try? container.decodeIfPresent(Git.self, forKey: .git)
            info = try? container.decodeIfPresent(Info.self, forKey: .info)
        }
    }

    // `"cli"` / `"exec"` for a session, `{"subagent": {...}}` for a spawned agent's thread.
    struct Source: Decodable {
        var isSubagent: Bool

        init(from decoder: any Decoder) throws {
            if let object = try? decoder.container(keyedBy: AnyKey.self) {
                isSubagent = object.allKeys.contains { $0.stringValue == "subagent" }
            } else {
                isSubagent = false
            }
        }
    }

    struct Git: Decodable {
        var branch: String?
    }

    struct Info: Decodable {
        var totalTokenUsage: Usage?

        enum CodingKeys: String, CodingKey {
            case totalTokenUsage = "total_token_usage"
        }
    }

    struct Usage: Decodable {
        var inputTokens: Int?
        var cachedInputTokens: Int?
        var outputTokens: Int?
        var reasoningOutputTokens: Int?
        var cacheWriteInputTokens: Int?
        var totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case outputTokens = "output_tokens"
            case reasoningOutputTokens = "reasoning_output_tokens"
            case cacheWriteInputTokens = "cache_write_input_tokens"
            case totalTokens = "total_tokens"
        }

        var totals: CodexTokenTotals {
            CodexTokenTotals(input: inputTokens ?? 0, cached: cachedInputTokens ?? 0, output: outputTokens ?? 0,
                             reasoning: reasoningOutputTokens ?? 0, cacheWrite: cacheWriteInputTokens ?? 0,
                             total: totalTokens ?? 0)
        }
    }
}
