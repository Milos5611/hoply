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
    public var agentType: String?
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
        var limits = LimitThinner()
        var subagents: [SubagentInfo] = []
        var activity: [SubagentActivity] = []
        var contextWindow: Int?
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
                let spawn = meta.source?.spawn
                // Older subagent files have no `session_id`; their parent is then the best guess at the session.
                let parent = state.isSubagent ? spawn?.parentThreadID ?? meta.parentThreadID : nil
                state.sessionID = meta.sessionID ?? parent ?? state.threadID
                state.cwd = meta.cwd ?? state.cwd
                state.branch = meta.git?.branch ?? state.branch
                if state.isSubagent {
                    let nickname = nonEmpty(meta.agentNickname ?? spawn?.agentNickname)
                    let role = nonEmpty(meta.agentRole ?? spawn?.agentRole)
                    state.agentType = nickname ?? role ?? nonEmpty(meta.source?.kind)
                    if let type = state.agentType {
                        subagents.append(SubagentInfo(session: SessionKey(source: .codexCLI, id: state.sessionID),
                                                      agentID: state.threadID, agentType: type,
                                                      description: nickname == nil ? nil : role))
                    }
                }
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
                    if let window = payload.modelContextWindow { contextWindow = window }
                    if let time { activity.append(subagentActivity(state, at: time, ended: false)) }
                case "task_complete", "turn_complete", "turn_aborted":
                    if let time { activity.append(subagentActivity(state, at: time, ended: true)) }
                case "user_message":
                    // Older versions write no turn events; newer ones write both, or no `user_message` at all.
                    if !state.hasTurnEvents { turns += 1 }
                case "token_count":
                    if let rateLimits = payload.rateLimits, let time {
                        for sample in rateLimits.samples(at: time) { limits.add(sample) }
                    }
                    if let window = payload.info?.modelContextWindow { contextWindow = window }
                    guard let total = payload.info?.totalTokenUsage?.totals, let time else { continue }
                    if let record = record(after: total, state: &state, at: time) { usage.append(record) }
                default:
                    continue
                }
            default:
                continue
            }
        }
        activity = state.isSubagent ? activity : []
        guard firstAt != nil || !usage.isEmpty || startsAtFileStart else {
            return LedgerBatch(usage: usage, subagents: subagents, limits: limits.samples, activity: activity)
        }
        let session = SessionUpdate(key: SessionKey(source: .codexCLI, id: state.sessionID), firstAt: firstAt,
                                    lastAt: lastAt, cwd: state.cwd, branch: state.branch,
                                    placeIsAuthoritative: !state.isSubagent && state.cwd != nil,
                                    transcriptPath: state.isSubagent ? nil : transcriptPath,
                                    prompts: state.isSubagent ? 0 : turns,
                                    resetsTurns: startsAtFileStart && !state.isSubagent,
                                    contextWindow: state.isSubagent ? nil : contextWindow)
        return LedgerBatch(usage: usage, sessions: [session], subagents: subagents, limits: limits.samples,
                           activity: activity)
    }

    private static func subagentActivity(_ state: CodexRolloutState, at time: Date, ended: Bool) -> SubagentActivity {
        SubagentActivity(session: SessionKey(source: .codexCLI, id: state.sessionID), agentID: state.threadID,
                         type: state.agentType, time: time, ended: ended)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    // Each kind's last reading is kept too: it dates the newest reading for `LimitSample.current`.
    struct LimitThinner {
        private var kept: [LimitSample] = []
        private var lastKept: [LimitKind: LimitSample] = [:]
        private var lastSeen: [LimitKind: LimitSample] = [:]

        mutating func add(_ sample: LimitSample) {
            lastSeen[sample.kind] = sample
            if let previous = lastKept[sample.kind], previous.isSameReading(as: sample),
               sample.ts.timeIntervalSince(previous.ts) < LimitSample.repeatInterval {
                return
            }
            kept.append(sample)
            lastKept[sample.kind] = sample
        }

        var samples: [LimitSample] {
            let tails = lastSeen.values.filter { lastKept[$0.kind] != $0 }
            return (kept + tails).sorted { ($0.ts, $0.kind) < ($1.ts, $1.kind) }
        }
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
        var parentThreadID: String?
        var cwd: String?
        var model: String?
        var source: Source?
        var agentNickname: String?
        var agentRole: String?
        var git: Git?
        var info: Info?
        var rateLimits: RateLimits?
        var modelContextWindow: Int?

        enum CodingKeys: String, CodingKey {
            case type, id, cwd, model, source, git, info
            case sessionID = "session_id"
            case parentThreadID = "parent_thread_id"
            case agentNickname = "agent_nickname"
            case agentRole = "agent_role"
            case agentType = "agent_type"
            case rateLimits = "rate_limits"
            case modelContextWindow = "model_context_window"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            sessionID = try? container.decodeIfPresent(String.self, forKey: .sessionID)
            parentThreadID = try? container.decodeIfPresent(String.self, forKey: .parentThreadID)
            cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
            model = try? container.decodeIfPresent(String.self, forKey: .model)
            source = try? container.decodeIfPresent(Source.self, forKey: .source)
            agentNickname = try? container.decodeIfPresent(String.self, forKey: .agentNickname)
            agentRole = (try? container.decodeIfPresent(String.self, forKey: .agentRole))
                ?? (try? container.decodeIfPresent(String.self, forKey: .agentType))
            git = try? container.decodeIfPresent(Git.self, forKey: .git)
            info = try? container.decodeIfPresent(Info.self, forKey: .info)
            rateLimits = try? container.decodeIfPresent(RateLimits.self, forKey: .rateLimits)
            modelContextWindow = try? container.decodeIfPresent(Int.self, forKey: .modelContextWindow)
        }
    }

    // `"cli"` / `"exec"` for a session; a subagent thread is `{"subagent": "review"}` (also `compact`,
    // `memory_consolidation`), `{"subagent": {"thread_spawn": {...}}}` or `{"subagent": {"other": "<name>"}}`.
    struct Source: Decodable {
        var isSubagent = false
        var kind: String?
        var spawn: Spawn?

        init(from decoder: any Decoder) throws {
            guard let object = try? decoder.container(keyedBy: AnyKey.self),
                  let key = object.allKeys.first(where: { $0.stringValue == "subagent" }) else { return }
            isSubagent = true
            if let name = try? object.decode(String.self, forKey: key) {
                kind = name
            } else if let variant = try? object.nestedContainer(keyedBy: AnyKey.self, forKey: key) {
                for inner in variant.allKeys {
                    switch inner.stringValue {
                    case "thread_spawn": spawn = try? variant.decode(Spawn.self, forKey: inner)
                    case "other": kind = try? variant.decode(String.self, forKey: inner)
                    default: kind = kind ?? inner.stringValue
                    }
                }
            }
        }
    }

    struct Spawn: Decodable {
        var parentThreadID: String?
        var agentNickname: String?
        var agentRole: String?

        enum CodingKeys: String, CodingKey {
            case parentThreadID = "parent_thread_id"
            case agentNickname = "agent_nickname"
            case agentRole = "agent_role"
            case agentType = "agent_type"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            parentThreadID = try? container.decodeIfPresent(String.self, forKey: .parentThreadID)
            agentNickname = try? container.decodeIfPresent(String.self, forKey: .agentNickname)
            agentRole = (try? container.decodeIfPresent(String.self, forKey: .agentRole))
                ?? (try? container.decodeIfPresent(String.self, forKey: .agentType))
        }
    }

    struct RateLimits: Decodable {
        var limitID: String?
        var primary: Window?
        var secondary: Window?
        var planType: String?

        enum CodingKeys: String, CodingKey {
            case primary, secondary
            case limitID = "limit_id"
            case planType = "plan_type"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            limitID = try? container.decodeIfPresent(String.self, forKey: .limitID)
            primary = try? container.decodeIfPresent(Window.self, forKey: .primary)
            secondary = try? container.decodeIfPresent(Window.self, forKey: .secondary)
            planType = try? container.decodeIfPresent(String.self, forKey: .planType)
        }

        func samples(at time: Date) -> [LimitSample] {
            [primary, secondary].compactMap { window in
                guard let window, let minutes = window.windowMinutes, let used = window.usedPercent, used.isFinite,
                      let kind = LimitKind.codex(windowMinutes: minutes, limitID: limitID) else { return nil }
                return LimitSample(kind: kind, ts: time, utilization: min(max(used, 0), 100),
                                   resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) },
                                   plan: planType.flatMap { $0.isEmpty ? nil : $0 })
            }
        }
    }

    struct Window: Decodable {
        var usedPercent: Double?
        var windowMinutes: Int?
        var resetsAt: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = try? container.decodeIfPresent(Double.self, forKey: .usedPercent)
            windowMinutes = try? container.decodeIfPresent(Int.self, forKey: .windowMinutes)
            resetsAt = try? container.decodeIfPresent(TimeInterval.self, forKey: .resetsAt)
        }
    }

    struct Git: Decodable {
        var branch: String?
    }

    struct Info: Decodable {
        var totalTokenUsage: Usage?
        var modelContextWindow: Int?

        enum CodingKeys: String, CodingKey {
            case totalTokenUsage = "total_token_usage"
            case modelContextWindow = "model_context_window"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            totalTokenUsage = try container.decodeIfPresent(Usage.self, forKey: .totalTokenUsage)
            modelContextWindow = try? container.decodeIfPresent(Int.self, forKey: .modelContextWindow)
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
