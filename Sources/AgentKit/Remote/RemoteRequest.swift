import Foundation

public struct RemoteRequest: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case approval
        case reply
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var id: String
    public var kind: Kind
    public var device: String
    public var session: String
    public var agent: String
    public var project: String?
    public var title: String?
    public var tool: String?
    public var detail: String?
    public var message: String?
    public var createdAt: Date
    public var expiresAt: Date

    public init(id: String, kind: Kind, device: String, session: String, agent: String, project: String? = nil,
                title: String? = nil, tool: String? = nil, detail: String? = nil, message: String? = nil,
                createdAt: Date, expiresAt: Date) {
        self.id = id
        self.kind = kind
        self.device = device
        self.session = session
        self.agent = agent
        self.project = project
        self.title = title
        self.tool = tool
        self.detail = detail
        self.message = message
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public var source: AgentSource? { AgentSource(rawValue: agent) }

    public static func approval(_ approval: ApprovalRequest, session: AgentSession?,
                                projects: [String: ProjectRef] = [:], device: String) -> RemoteRequest {
        RemoteRequest(id: approval.id, kind: .approval, device: device, session: RemoteSchema.sessionKey(approval.key),
                      agent: approval.key.source.rawValue,
                      project: RemoteSnapshot.projectName(session, projects: projects),
                      title: RemoteSchema.title(session?.title),
                      tool: approval.tool, detail: approval.detail, createdAt: approval.received,
                      expiresAt: approval.received.addingTimeInterval(PermissionApproval.holdLimit))
    }

    public static func reply(_ reply: TurnReplyRequest, session: AgentSession?, projects: [String: ProjectRef] = [:],
                             device: String) -> RemoteRequest {
        RemoteRequest(id: reply.id, kind: .reply, device: device, session: RemoteSchema.sessionKey(reply.key),
                      agent: reply.key.source.rawValue,
                      project: RemoteSnapshot.projectName(session, projects: projects),
                      title: RemoteSchema.title(session?.title),
                      message: reply.message, createdAt: reply.received,
                      expiresAt: reply.received.addingTimeInterval(TurnReply.holdLimit))
    }
}
