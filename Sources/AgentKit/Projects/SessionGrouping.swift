import Foundation

public struct ProjectGroup: Identifiable, Equatable, Sendable {
    /// The session cwd, or "" for sessions that never reported one.
    public var id: String
    public var name: String
    public var path: String?
    public var sessions: [AgentSession]
    public var lastActivity: Date

    public var isWorking: Bool { sessions.contains { $0.state == .working } }
}

/// Splits sessions for the panel: everything waiting on the user first, the rest grouped by cwd.
/// Until the v2 project resolver lands, a project is simply the session's cwd.
public struct SessionGrouping: Equatable, Sendable {
    public var waiting: [AgentSession]
    public var projects: [ProjectGroup]

    /// `sessions` must already be in `SessionBoard.ordered` order; that order is kept inside each group.
    public init(sessions: [AgentSession]) {
        waiting = sessions.filter { $0.state.needsAttention }
        var groups: [String: ProjectGroup] = [:]
        var order: [String] = []
        for session in sessions where !session.state.needsAttention {
            let path = session.cwd.flatMap { $0.isEmpty ? nil : $0 }
            let id = path ?? ""
            if groups[id] == nil {
                order.append(id)
                groups[id] = ProjectGroup(id: id, name: session.project ?? "Other", path: path,
                                          sessions: [], lastActivity: session.lastEventAt)
            }
            groups[id]?.sessions.append(session)
            if let last = groups[id]?.lastActivity, session.lastEventAt > last {
                groups[id]?.lastActivity = session.lastEventAt
            }
        }
        projects = order.compactMap { groups[$0] }.sorted { a, b in
            if a.isWorking != b.isWorking { return a.isWorking }
            return a.lastActivity > b.lastActivity
        }
    }

    public var oldestWaitSince: Date? { waiting.map(\.stateSince).min() }
}
