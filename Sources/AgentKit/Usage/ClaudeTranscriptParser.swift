import Foundation

public enum ClaudeTitleKind: Int, Sendable, Comparable {
    case agentName = 1
    case ai = 2
    case custom = 3

    public static func < (lhs: ClaudeTitleKind, rhs: ClaudeTitleKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Claude Code's own running cost for a session (`cost-state` lines). Used as calibration ground truth.
public struct ClaudeCostState: Sendable, Equatable {
    public struct Model: Sendable, Equatable {
        public var tokens: TokenCounts
        public var costUSD: Double
        public var webSearchRequests: Int
        /// False when part of the cache write total has no 5m/1h split (older versions, or calls Claude Code
        /// never split); `tokens` then books that part at 5 minutes.
        public var cacheSplitKnown: Bool
    }

    public var sessionID: String
    public var totalCostUSD: Double
    public var linesAdded: Int
    public var linesRemoved: Int
    public var hasUnknownModelCost: Bool
    public var models: [String: Model]
}

public enum ClaudeTranscriptItem: Sendable, Equatable {
    case usage(UsageRecord)
    /// A typed user prompt. The text is never kept, only that it happened.
    case userPrompt(sessionID: String, at: Date, cwd: String?, gitBranch: String?)
    case title(sessionID: String, title: String, kind: ClaudeTitleKind)
    case prLink(sessionID: String, url: String)
    case costState(ClaudeCostState)
}

/// Parses Claude Code transcript lines (`~/.claude/projects/<dashed-cwd>/<session>.jsonl`), one line at a time.
/// Unknown or malformed lines are skipped, never fatal.
public enum ClaudeTranscriptParser {
    public static func item(from line: Data) -> ClaudeTranscriptItem? {
        if let type = leadingType(line), isSkipped(type) { return nil }
        guard let decoded = try? decoder.decode(Line.self, from: line) else { return nil }
        return decoded.item
    }

    public static func batch<Lines: Sequence>(from lines: Lines) -> ClaudeTranscriptBatch where Lines.Element == Data {
        var batch = ClaudeTranscriptBatch()
        for line in lines {
            if let item = item(from: line) { batch.add(item) }
        }
        return batch
    }

    /// Known line types that carry nothing for the ledger. Unknown types are decoded and ignored, so a new
    /// Claude Code version that reorders keys can never hide usage lines.
    static func isSkipped(_ type: String) -> Bool {
        skippedTypes.contains(type) || skippedTypePrefixes.contains { type.hasPrefix($0) }
    }

    private static let skippedTypes: Set<String> = [
        "attachment", "last-prompt", "mode", "permission-mode", "atis-latch", "session-owner", "queue-operation",
        "tools-used", "system", "frame-link", "continued-in",
    ]
    private static let skippedTypePrefixes = ["api-request", "file-history-", "artifact-"]
    private static let decoder = JSONDecoder()
    private static let typePrefix = Array(#"{"type":""#.utf8)

    /// Metadata lines start with `{"type":"…"`, so their kind is known without decoding. That skips the bulky
    /// `api-request-blob`, `api-request` and `file-history-*` lines, and `last-prompt` (which holds prompt text).
    /// Message lines start with `{"parentUuid"` and return nil here.
    static func leadingType(_ line: Data) -> String? {
        guard line.starts(with: typePrefix) else { return nil }
        let start = line.startIndex + typePrefix.count
        let limit = min(line.endIndex, start + 64)
        guard let end = line[start..<limit].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: line[start..<end], as: UTF8.self)
    }
}

/// Everything learned from a run of transcript lines: usage deduped by call, plus per-session facts.
public struct ClaudeTranscriptBatch: Sendable, Equatable {
    public struct Session: Sendable, Equatable {
        public var firstAt: Date?
        public var lastAt: Date?
        public var cwd: String?
        public var gitBranch: String?
        public var title: String?
        public var titleKind: ClaudeTitleKind?
        public var prURL: String?
        public var costState: ClaudeCostState?
        public var prompts = 0
        var sidechainCwd: String?
        var sidechainBranch: String?

        public var effectiveCwd: String? { cwd ?? sidechainCwd }
        public var effectiveBranch: String? { gitBranch ?? sidechainBranch }

        mutating func touch(_ time: Date) {
            firstAt = min(firstAt ?? time, time)
            lastAt = max(lastAt ?? time, time)
        }

        mutating func place(cwd newCwd: String?, branch: String?, sidechain: Bool) {
            if sidechain {
                if let newCwd { sidechainCwd = newCwd }
                if let branch { sidechainBranch = branch }
            } else {
                if let newCwd { cwd = newCwd }
                if let branch { gitBranch = branch }
            }
        }
    }

    public private(set) var usage: [UsageRecord] = []
    public private(set) var sessions: [String: Session] = [:]
    private var usageIndex: [String: Int] = [:]

    public init() {}

    public var isEmpty: Bool { usage.isEmpty && sessions.isEmpty }

    public mutating func add(_ item: ClaudeTranscriptItem) {
        switch item {
        case .usage(let record):
            if let index = usageIndex[record.dedupeKey] {
                usage[index] = usage[index].merged(with: record)
            } else {
                usageIndex[record.dedupeKey] = usage.count
                usage.append(record)
            }
            sessions[record.sessionID, default: Session()].touch(record.timestamp)
            sessions[record.sessionID]?.place(cwd: record.cwd, branch: record.gitBranch, sidechain: record.isSidechain)
        case .userPrompt(let sessionID, let at, let cwd, let branch):
            sessions[sessionID, default: Session()].touch(at)
            sessions[sessionID]?.prompts += 1
            sessions[sessionID]?.place(cwd: cwd, branch: branch, sidechain: false)
        case .title(let sessionID, let title, let kind):
            var session = sessions[sessionID] ?? Session()
            if kind >= (session.titleKind ?? .agentName) {
                session.title = title
                session.titleKind = kind
            }
            sessions[sessionID] = session
        case .prLink(let sessionID, let url):
            sessions[sessionID, default: Session()].prURL = url
        case .costState(let state):
            sessions[state.sessionID, default: Session()].costState = state
        }
    }
}

// MARK: - Line decoding

private struct Line: Decodable {
    var type: String?
    var sessionId: String?
    var timestamp: String?
    var isSidechain = false
    var agentId: String?
    var requestId: String?
    var cwd: String?
    var gitBranch: String?
    var isMeta = false
    var isCompactSummary = false
    var hasToolUseResult = false
    var originKind: String?
    var message: Message?
    var aiTitle: String?
    var customTitle: String?
    var agentName: String?
    var prUrl: String?
    var totalCostUSD: Double?
    var totalLinesAdded: Int?
    var totalLinesRemoved: Int?
    var hasUnknownModelCost = false
    var modelUsage: [String: ModelUsage]?

    enum CodingKeys: String, CodingKey {
        case type, sessionId, timestamp, isSidechain, agentId, requestId, cwd, gitBranch, isMeta, isCompactSummary
        case toolUseResult, origin, message, aiTitle, customTitle, agentName, prUrl, totalCostUSD
        case totalLinesAdded, totalLinesRemoved, hasUnknownModelCost, modelUsage
    }

    struct Origin: Decodable { var kind: String? }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        sessionId = c.lenient(String.self, .sessionId)
        timestamp = c.lenient(String.self, .timestamp)
        isSidechain = c.lenient(Bool.self, .isSidechain) ?? false
        agentId = c.lenient(String.self, .agentId)
        requestId = c.lenient(String.self, .requestId)
        cwd = c.lenient(String.self, .cwd)
        gitBranch = c.lenient(String.self, .gitBranch)
        isMeta = c.lenient(Bool.self, .isMeta) ?? false
        isCompactSummary = c.lenient(Bool.self, .isCompactSummary) ?? false
        hasToolUseResult = c.contains(.toolUseResult) && !((try? c.decodeNil(forKey: .toolUseResult)) ?? true)
        originKind = c.lenient(Origin.self, .origin)?.kind
        message = c.lenient(Message.self, .message)
        aiTitle = c.lenient(String.self, .aiTitle)
        customTitle = c.lenient(String.self, .customTitle)
        agentName = c.lenient(String.self, .agentName)
        prUrl = c.lenient(String.self, .prUrl)
        totalCostUSD = c.lenient(Double.self, .totalCostUSD)
        totalLinesAdded = c.lenient(Int.self, .totalLinesAdded)
        totalLinesRemoved = c.lenient(Int.self, .totalLinesRemoved)
        hasUnknownModelCost = c.lenient(Bool.self, .hasUnknownModelCost) ?? false
        modelUsage = c.lenient([String: ModelUsage].self, .modelUsage)
    }

    var item: ClaudeTranscriptItem? {
        guard let sessionId, !sessionId.isEmpty else { return nil }
        switch type {
        case "assistant": return usageItem(sessionId)
        case "user": return promptItem(sessionId)
        case "ai-title": return aiTitle.flatMap(nonEmpty).map { .title(sessionID: sessionId, title: $0, kind: .ai) }
        case "custom-title": return customTitle.flatMap(nonEmpty).map { .title(sessionID: sessionId, title: $0, kind: .custom) }
        case "agent-name": return agentName.flatMap(nonEmpty).map { .title(sessionID: sessionId, title: $0, kind: .agentName) }
        case "pr-link": return prUrl.flatMap(nonEmpty).map { .prLink(sessionID: sessionId, url: $0) }
        case "cost-state": return costStateItem(sessionId)
        default: return nil
        }
    }

    private func usageItem(_ sessionID: String) -> ClaudeTranscriptItem? {
        guard let message, let usage = message.usage, let id = message.id, !id.isEmpty,
              let model = message.model, model != "<synthetic>",
              let timestamp, let time = Timestamps.parse(timestamp) else { return nil }
        let created = usage.cacheCreationInputTokens ?? 0
        var write5m = usage.cacheCreation?.ephemeral5m ?? 0
        let write1h = usage.cacheCreation?.ephemeral1h ?? 0
        // Older transcripts have no 5m/1h split; anything unaccounted for was written at the default 5 minute TTL.
        if created > write5m + write1h { write5m = created - write1h }
        let tokens = TokenCounts(input: usage.inputTokens ?? 0, output: usage.outputTokens ?? 0,
                                 reasoning: usage.thinkingTokens ?? 0, cacheRead: usage.cacheReadInputTokens ?? 0,
                                 cacheWrite5m: write5m, cacheWrite1h: write1h)
        return .usage(UsageRecord(dedupeKey: "cc:\(id):\(requestId ?? "")", source: .claudeCode, sessionID: sessionID,
                                  timestamp: time, model: model, isSidechain: isSidechain, agentID: agentId,
                                  tokens: tokens, speed: usage.speed, cwd: cwd.flatMap(nonEmpty),
                                  gitBranch: gitBranch.flatMap(nonEmpty)))
    }

    /// Only prompts a person typed: no tool results, meta lines, compaction summaries, subagent prompts
    /// or system-originated turns (task notifications, peers). Older versions have no `origin`, where
    /// command echoes and local command output start with `<`.
    private func promptItem(_ sessionID: String) -> ClaudeTranscriptItem? {
        guard !isSidechain, !isMeta, !isCompactSummary, !hasToolUseResult,
              let content = message?.content, !content.hasToolResult,
              let timestamp, let time = Timestamps.parse(timestamp) else { return nil }
        let text = content.leadingText
        guard !text.isEmpty else { return nil }
        if let originKind {
            guard originKind == "human" else { return nil }
        } else if text.hasPrefix("<") {
            return nil
        }
        return .userPrompt(sessionID: sessionID, at: time, cwd: cwd.flatMap(nonEmpty), gitBranch: gitBranch.flatMap(nonEmpty))
    }

    private func costStateItem(_ sessionID: String) -> ClaudeTranscriptItem? {
        guard let totalCostUSD else { return nil }
        var models: [String: ClaudeCostState.Model] = [:]
        for (name, usage) in modelUsage ?? [:] {
            let created = usage.cacheCreationInputTokens ?? 0
            let write1h = usage.cacheCreationEphemeral1hInputTokens ?? 0
            let unsplit = max(created - write1h - (usage.cacheCreationEphemeral5mInputTokens ?? 0), 0)
            let write5m = (usage.cacheCreationEphemeral5mInputTokens ?? 0) + unsplit
            models[name] = .init(tokens: TokenCounts(input: usage.inputTokens ?? 0, output: usage.outputTokens ?? 0,
                                                     reasoning: usage.thinkingTokens ?? 0,
                                                     cacheRead: usage.cacheReadInputTokens ?? 0,
                                                     cacheWrite5m: write5m, cacheWrite1h: write1h),
                                 costUSD: usage.costUSD ?? 0, webSearchRequests: usage.webSearchRequests ?? 0,
                                 cacheSplitKnown: unsplit == 0)
        }
        return .costState(ClaudeCostState(sessionID: sessionID, totalCostUSD: totalCostUSD,
                                          linesAdded: totalLinesAdded ?? 0, linesRemoved: totalLinesRemoved ?? 0,
                                          hasUnknownModelCost: hasUnknownModelCost, models: models))
    }

    private func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct Message: Decodable {
    var id: String?
    var model: String?
    var usage: Usage?
    var content: Content?

    enum CodingKeys: String, CodingKey { case id, model, usage, content }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id)
        model = c.lenient(String.self, .model)
        usage = c.lenient(Usage.self, .usage)
        content = c.lenient(Content.self, .content)
    }
}

private struct Usage: Decodable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadInputTokens: Int?
    var cacheCreationInputTokens: Int?
    var cacheCreation: CacheCreation?
    var thinkingTokens: Int?
    var speed: String?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheCreation = "cache_creation"
        case outputTokensDetails = "output_tokens_details"
        case speed
    }

    struct CacheCreation: Decodable {
        var ephemeral5m: Int?
        var ephemeral1h: Int?

        enum CodingKeys: String, CodingKey {
            case ephemeral5m = "ephemeral_5m_input_tokens"
            case ephemeral1h = "ephemeral_1h_input_tokens"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ephemeral5m = c.lenient(Int.self, .ephemeral5m)
            ephemeral1h = c.lenient(Int.self, .ephemeral1h)
        }
    }

    struct OutputDetails: Decodable {
        var thinkingTokens: Int?
        enum CodingKeys: String, CodingKey { case thinkingTokens = "thinking_tokens" }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = c.lenient(Int.self, .inputTokens)
        outputTokens = c.lenient(Int.self, .outputTokens)
        cacheReadInputTokens = c.lenient(Int.self, .cacheReadInputTokens)
        cacheCreationInputTokens = c.lenient(Int.self, .cacheCreationInputTokens)
        cacheCreation = c.lenient(CacheCreation.self, .cacheCreation)
        thinkingTokens = c.lenient(OutputDetails.self, .outputTokensDetails)?.thinkingTokens
        speed = c.lenient(String.self, .speed)
    }
}

private struct ModelUsage: Decodable {
    var inputTokens: Int?
    var outputTokens: Int?
    var thinkingTokens: Int?
    var cacheReadInputTokens: Int?
    var cacheCreationInputTokens: Int?
    var cacheCreationEphemeral5mInputTokens: Int?
    var cacheCreationEphemeral1hInputTokens: Int?
    var webSearchRequests: Int?
    var costUSD: Double?

    enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, thinkingTokens, cacheReadInputTokens, cacheCreationInputTokens
        case cacheCreationEphemeral5mInputTokens, cacheCreationEphemeral1hInputTokens, webSearchRequests, costUSD
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = c.lenient(Int.self, .inputTokens)
        outputTokens = c.lenient(Int.self, .outputTokens)
        thinkingTokens = c.lenient(Int.self, .thinkingTokens)
        cacheReadInputTokens = c.lenient(Int.self, .cacheReadInputTokens)
        cacheCreationInputTokens = c.lenient(Int.self, .cacheCreationInputTokens)
        cacheCreationEphemeral5mInputTokens = c.lenient(Int.self, .cacheCreationEphemeral5mInputTokens)
        cacheCreationEphemeral1hInputTokens = c.lenient(Int.self, .cacheCreationEphemeral1hInputTokens)
        webSearchRequests = c.lenient(Int.self, .webSearchRequests)
        costUSD = c.lenient(Double.self, .costUSD)
    }
}

/// Message content is either a string or an array of blocks. Only block types and text are read.
private enum Content: Decodable {
    case text(String)
    case blocks([Block])

    struct Block: Decodable {
        var type: String?
        var text: String?

        enum CodingKeys: String, CodingKey { case type, text }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.lenient(String.self, .type)
            text = c.lenient(String.self, .text)
        }
    }

    init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let text = try? single.decode(String.self) {
            self = .text(text)
        } else {
            self = .blocks((try? single.decode([Block].self)) ?? [])
        }
    }

    var hasToolResult: Bool {
        if case .blocks(let blocks) = self { return blocks.contains { $0.type == "tool_result" } }
        return false
    }

    var leadingText: String {
        switch self {
        case .text(let text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .blocks(let blocks):
            let first = blocks.first { $0.type == "text" && !($0.text ?? "").isEmpty }?.text ?? ""
            return first.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
