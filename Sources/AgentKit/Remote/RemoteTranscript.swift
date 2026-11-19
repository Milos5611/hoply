import Foundation

public struct RemoteTranscript: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
        case tool
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public enum Problem: String, Codable, Sendable {
        case unknownSession
        case unsupportedAgent
        case unreadable
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public struct Message: Codable, Sendable, Equatable {
        public var role: Role
        public var text: String
        public var at: Date?

        public init(role: Role, text: String, at: Date? = nil) {
            self.role = role
            self.text = text
            self.at = at
        }
    }

    public var device: String
    public var session: String
    public var agent: String
    public var answerID: String?
    public var updatedAt: Date
    public var messages: [Message]
    public var truncated: Bool
    public var problem: Problem?

    public init(device: String, session: String, agent: String, answerID: String? = nil, updatedAt: Date,
                messages: [Message] = [], truncated: Bool = false, problem: Problem? = nil) {
        self.device = device
        self.session = session
        self.agent = agent
        self.answerID = answerID
        self.updatedAt = updatedAt
        self.messages = messages
        self.truncated = truncated
        self.problem = problem
    }

    public var source: AgentSource? { AgentSource(rawValue: agent) }

    public func sameContent(as other: RemoteTranscript) -> Bool {
        var mine = self
        mine.updatedAt = other.updatedAt
        return mine == other
    }
}

public enum RemoteTranscriptPolicy {
    public static let watchFor: TimeInterval = 600
    public static let renewEvery: TimeInterval = 240
    public static let refreshEvery: TimeInterval = 10
    public static let phonePoll: TimeInterval = 5
    public static let maxMessages = 200
    public static let textLimit = 10_000
    public static let toolLimit = 300
    public static let byteLimit = 700_000
    public static let maxRecords = 12
    public static let recordLifetime: TimeInterval = 24 * 3600
}
