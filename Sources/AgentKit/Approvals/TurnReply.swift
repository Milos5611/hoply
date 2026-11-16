import Foundation

public struct TurnReplyRequest: Sendable, Equatable, Identifiable {
    public let id: String
    public let key: SessionKey
    public var message: String?
    public let received: Date
    public let transcriptPath: String?

    public init(id: String = UUID().uuidString, key: SessionKey, message: String?, received: Date,
                transcriptPath: String? = nil) {
        self.id = id
        self.key = key
        self.message = message
        self.received = received
        self.transcriptPath = transcriptPath
    }
}

public enum TurnReply {
    public static let header = "x-hoply-reply"
    // Hold limit < the hook's curl -m < the agent's hook timeout; all three derive from this one number.
    public static let hookTimeout = 1800
    public static let curlTimeout = hookTimeout - 10
    public static let holdLimit = TimeInterval(hookTimeout - 30)
    public static let reasonPrefix = "Message from the user, sent from Hoply: "
    public static let messageLimit = 1000
    public static let sources = AgentSource.allCases.filter { event(for: $0) != nil }

    static func event(for source: AgentSource) -> String? {
        switch source {
        case .claudeCode: "stop"
        case .copilotCLI: "agentstop"
        default: nil
        }
    }

    public static func request(source: AgentSource, eventName: String?, json: [String: Any],
                               headers: [String: String], now: Date = Date()) -> TurnReplyRequest? {
        guard headers[header] == "1", let event = event(for: source) else { return nil }
        let name = HookMapper.normalize(eventName ?? HookMapper.string(json, ["hook_event_name"]) ?? "")
        guard name == event else { return nil }
        let session = HookMapper.string(json, ["session_id", "sessionId"]) ?? "unknown"
        let transcript = source == .copilotCLI ? HookMapper.string(json, ["transcriptPath"]) : nil
        return TurnReplyRequest(key: SessionKey(source: source, id: session),
                                message: message(HookMapper.string(json, ["last_assistant_message"])), received: now,
                                transcriptPath: transcript)
    }

    static func message(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed.count > messageLimit ? String(trimmed.prefix(messageLimit)) + "…" : trimmed
    }

    public static func response(_ text: String?) -> HTTPResponse {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return .json() }
        let output = ["decision": "block", "reason": reasonPrefix + text]
        guard let data = try? JSONSerialization.data(withJSONObject: output,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return .json()
        }
        return .json(String(decoding: data, as: UTF8.self))
    }

    public static func answered(_ pending: [TurnReplyRequest], by events: [AgentEvent]) -> [String] {
        pending.filter { reply in
            events.contains { event in
                guard event.key == reply.key, event.fromHook, event.time >= reply.received else { return false }
                switch event.kind {
                case .sessionStarted, .sessionEnded, .promptSubmitted:
                    return true
                case .turnFinished, .turnFailed:
                    // The request's own Stop arrives with it, stamped `received`; only a later turn end answers it.
                    return event.time > reply.received && event.agentID.flatMap { $0.isEmpty ? nil : $0 } == nil
                default:
                    return false
                }
            }
        }.map(\.id)
    }
}
