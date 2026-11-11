import Foundation

public struct CopilotWorkspace: Sendable, Equatable {
    public var id: String?
    public var cwd: String?
    public var gitRoot: String?
    public var branch: String?
    public var clientName: String?
    public var name: String?
    public var createdAt: String?
    public var updatedAt: String?

    public init(id: String? = nil, cwd: String? = nil, gitRoot: String? = nil, branch: String? = nil,
                clientName: String? = nil, name: String? = nil, createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id
        self.cwd = cwd
        self.gitRoot = gitRoot
        self.branch = branch
        self.clientName = clientName
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(yaml: String) {
        var values: [String: String] = [:]
        for line in yaml.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon]
            guard !key.isEmpty, key.allSatisfy({ ("a"..."z").contains($0) || $0 == "_" }),
                  let value = Self.scalar(line[line.index(after: colon)...]) else { continue }
            values[String(key)] = value
        }
        self.init(id: values["id"], cwd: values["cwd"], gitRoot: values["git_root"], branch: values["branch"],
                  clientName: values["client_name"], name: values["name"], createdAt: values["created_at"],
                  updatedAt: values["updated_at"])
    }

    static func scalar(_ raw: Substring) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !["|", "|-", "|+", ">", ">-", ">+", "~", "null"].contains(text) else { return nil }
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            return (try? JSONDecoder().decode(String.self, from: Data(text.utf8))) ?? String(text.dropFirst().dropLast())
        }
        if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
            return text.dropFirst().dropLast().replacingOccurrences(of: "''", with: "'")
        }
        return text
    }
}

public struct CopilotEventsState: Sendable, Equatable {
    public var sessionID: String
    public var turns = 0
    public var model: String?
    public var cwd: String?
    public var branch: String?
    public var hasUsage = false

    public init(path: String) {
        sessionID = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
    }
}

public enum CopilotEventsParser {
    public static let keyPrefix = "cpe:"

    public static func batch<Lines: Sequence>(lines: Lines, state: inout CopilotEventsState,
                                              workspace: CopilotWorkspace? = nil) -> LedgerBatch
    where Lines.Element == Data {
        if state.cwd == nil { state.cwd = nonEmpty(workspace?.cwd) }
        if state.branch == nil { state.branch = nonEmpty(workspace?.branch) }
        var usage: [UsageRecord] = []
        var firstAt: Date?
        var lastAt: Date?
        for line in lines {
            if let type = leadingType(line), !readTypes.contains(type) { continue }
            guard let decoded = try? decoder.decode(Line.self, from: line), readTypes.contains(decoded.type) else {
                continue
            }
            let time = decoded.timestamp.flatMap(Timestamps.parse)
            if let time {
                firstAt = min(firstAt ?? time, time)
                lastAt = max(lastAt ?? time, time)
            }
            let subagent = nonEmpty(decoded.agentId)
            switch decoded.type {
            case "session.start":
                state.cwd = nonEmpty(decoded.data?.context?.cwd) ?? state.cwd
                state.branch = nonEmpty(decoded.data?.context?.branch) ?? state.branch
                select(decoded.data?.selectedModel, state: &state)
            case "session.model_change":
                select(decoded.data?.newModel, state: &state)
            case "user.message":
                // A subagent's task arrives as its own user message; only the user's prompts are turns.
                if subagent == nil { state.turns += 1 }
            case "session.usage_record":
                guard let call = decoded.data?.usage, let time,
                      let record = record(call, subagent: subagent, lineID: decoded.id, state: &state, at: time)
                else { continue }
                usage.append(record)
            default:
                continue
            }
        }
        guard state.hasUsage else { return LedgerBatch(usage: usage, origin: keyPrefix) }
        let first = ([firstAt, CopilotUsageMapper.date(workspace?.createdAt)].compactMap { $0 }).min()
        let last = ([lastAt, CopilotUsageMapper.date(workspace?.updatedAt)].compactMap { $0 }).max()
        let title = CopilotUsageMapper.title(workspace?.name)
        let session = SessionUpdate(key: SessionKey(source: .copilotCLI, id: state.sessionID), firstAt: first,
                                    lastAt: last, cwd: state.cwd, branch: state.branch,
                                    placeIsAuthoritative: state.cwd != nil, title: title,
                                    titleRank: title == nil ? 0 : CopilotUsageMapper.titleRank, prompts: state.turns,
                                    resetsTurns: true)
        return LedgerBatch(usage: usage, sessions: [session], origin: keyPrefix)
    }

    // `cost` is the premium-request multiplier, not money.
    static func record(_ call: Call, subagent: String?, lineID: String?, state: inout CopilotEventsState,
                       at time: Date) -> UsageRecord? {
        let key: String
        // Hashed (the id runs to ~520 characters) and session-free, so a copy of the call in another session's file
        // lands on the same row.
        if let callID = nonEmpty(call.apiCallId) ?? nonEmpty(call.accounting?.usageId) {
            key = keyPrefix + FNV1a.hex64(callID.utf8)
        } else if let lineID = nonEmpty(lineID) {
            key = keyPrefix + state.sessionID + ":" + lineID
        } else {
            return nil
        }
        var details: [String: Int] = [:]
        for detail in call.copilotUsage?.tokenDetails ?? [] {
            if let type = detail.tokenType { details[type, default: 0] += detail.tokenCount ?? 0 }
        }
        let tokens = CopilotUsageMapper.tokens(input: call.inputTokens ?? 0, output: call.outputTokens ?? 0,
                                               cacheRead: call.cacheReadTokens ?? 0,
                                               cacheWrite: call.cacheWriteTokens ?? 0,
                                               reasoning: call.reasoningTokens ?? 0, details: details)
        // Models without AI credits carry no (or zero) `totalNanoAiu`: the price table decides, never a native $0.
        let nano = call.copilotUsage?.totalNanoAiu.flatMap { $0 > 0 ? $0 : nil }
        let model = nonEmpty(call.model)
        state.hasUsage = true
        if subagent == nil, let model { state.model = model }
        return UsageRecord(dedupeKey: key, source: .copilotCLI, sessionID: state.sessionID, timestamp: time,
                           model: model, isSidechain: subagent != nil, agentID: subagent, tokens: tokens,
                           nativeCost: nano.map { $0 / CopilotUsageMapper.nanoAIUPerAIU },
                           nativeUSD: nano.map { $0 / CopilotUsageMapper.nanoAIUPerAIU * CopilotUsageMapper.usdPerAIU },
                           requestMultiplier: call.cost, turnIndex: max(state.turns - 1, 0), cwd: state.cwd,
                           gitBranch: state.branch)
    }

    private static func select(_ model: String?, state: inout CopilotEventsState) {
        guard let model = nonEmpty(model), model.lowercased() != "auto" else { return }
        state.model = model
    }

    static let readTypes: Set<String> = ["session.start", "session.model_change", "user.message",
                                         "session.usage_record", "session.shutdown"]

    static func leadingType(_ line: Data) -> String? {
        let marker = Data(#"{"type":""#.utf8)
        guard line.starts(with: marker) else { return nil }
        let rest = line.dropFirst(marker.count).prefix(64)
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: rest[..<end], as: UTF8.self)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static let decoder = JSONDecoder()

    struct Line: Decodable {
        var type: String
        var id: String?
        var timestamp: String?
        var agentId: String?
        var data: Payload?

        enum CodingKeys: String, CodingKey {
            case type, id, timestamp, agentId, data
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            timestamp = try? container.decodeIfPresent(String.self, forKey: .timestamp)
            agentId = try? container.decodeIfPresent(String.self, forKey: .agentId)
            data = try? container.decodeIfPresent(Payload.self, forKey: .data)
        }
    }

    struct Payload: Decodable {
        var selectedModel: String?
        var newModel: String?
        var context: Context?
        var usage: Call?

        enum CodingKeys: String, CodingKey {
            case selectedModel, newModel, context, usage
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            selectedModel = try? container.decodeIfPresent(String.self, forKey: .selectedModel)
            newModel = try? container.decodeIfPresent(String.self, forKey: .newModel)
            context = try? container.decodeIfPresent(Context.self, forKey: .context)
            usage = try? container.decodeIfPresent(Call.self, forKey: .usage)
        }
    }

    struct Context: Decodable {
        var cwd: String?
        var branch: String?
    }

    struct Call: Decodable {
        var model: String?
        var apiCallId: String?
        var inputTokens: Int?
        var outputTokens: Int?
        var cacheReadTokens: Int?
        var cacheWriteTokens: Int?
        var reasoningTokens: Int?
        var cost: Double?
        var accounting: Accounting?
        var copilotUsage: CopilotUsage?

        enum CodingKeys: String, CodingKey {
            case model, apiCallId, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, reasoningTokens, cost
            case accounting, copilotUsage
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            model = try? container.decodeIfPresent(String.self, forKey: .model)
            apiCallId = try? container.decodeIfPresent(String.self, forKey: .apiCallId)
            inputTokens = container.count(.inputTokens)
            outputTokens = container.count(.outputTokens)
            cacheReadTokens = container.count(.cacheReadTokens)
            cacheWriteTokens = container.count(.cacheWriteTokens)
            reasoningTokens = container.count(.reasoningTokens)
            cost = try? container.decodeIfPresent(Double.self, forKey: .cost)
            accounting = try? container.decodeIfPresent(Accounting.self, forKey: .accounting)
            copilotUsage = try? container.decodeIfPresent(CopilotUsage.self, forKey: .copilotUsage)
        }
    }

    struct Accounting: Decodable {
        var usageId: String?
    }

    struct CopilotUsage: Decodable {
        var tokenDetails: [TokenDetail]?
        var totalNanoAiu: Double?

        enum CodingKeys: String, CodingKey {
            case tokenDetails, totalNanoAiu
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tokenDetails = try? container.decodeIfPresent([TokenDetail].self, forKey: .tokenDetails)
            totalNanoAiu = try? container.decodeIfPresent(Double.self, forKey: .totalNanoAiu)
        }
    }

    struct TokenDetail: Decodable {
        var tokenType: String?
        var tokenCount: Int?

        enum CodingKeys: String, CodingKey {
            case tokenType, tokenCount
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tokenType = try? container.decodeIfPresent(String.self, forKey: .tokenType)
            tokenCount = container.count(.tokenCount)
        }
    }
}

private extension KeyedDecodingContainer {
    func count(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        return (try? decodeIfPresent(Double.self, forKey: key)).flatMap { $0.isFinite ? Int($0) : nil }
    }
}
