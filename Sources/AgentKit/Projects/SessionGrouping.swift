import Foundation

public struct ProjectGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var path: String?
    public var project: ProjectRef?
    public var sessions: [AgentSession]
    public var lastActivity: Date

    public var isWorking: Bool { sessions.contains { $0.state == .working } }
}

public struct SessionGrouping: Equatable, Sendable {
    public var waiting: [AgentSession]
    public var projects: [ProjectGroup]
    public var limitedUntil: [SessionKey: Date]

    public init(sessions: [AgentSession], projects resolved: [String: ProjectRef] = [:], limits: [LimitSample] = [],
                localModelPatterns: [String] = [], now: Date = Date()) {
        var limited: [SessionKey: Date] = [:]
        if !limits.isEmpty {
            for session in sessions {
                limited[session.key] = LimitedSessions.limitedUntil(session, limits: limits,
                                                                    localModelPatterns: localModelPatterns, now: now)
            }
        }
        limitedUntil = limited
        waiting = sessions.enumerated()
            .filter { $0.element.state.needsAttention }
            .sorted { a, b in
                let left = SessionStatus(a.element, limitedUntil: limited[a.element.key]).priority
                let right = SessionStatus(b.element, limitedUntil: limited[b.element.key]).priority
                return (left, a.offset) < (right, b.offset)
            }
            .map(\.element)
        var groups: [String: ProjectGroup] = [:]
        var order: [String] = []
        for session in sessions where !session.state.needsAttention {
            let cwd = session.cwd.flatMap { $0.isEmpty ? nil : $0 }
            let project = cwd.flatMap { resolved[$0] }
            let id = project.map { "project:\($0.id)" } ?? cwd ?? ""
            if groups[id] == nil {
                order.append(id)
                groups[id] = ProjectGroup(id: id, name: project?.title ?? session.project ?? "Other",
                                          path: project?.root ?? cwd, project: project, sessions: [],
                                          lastActivity: session.lastEventAt)
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

    public func status(of session: AgentSession) -> SessionStatus {
        SessionStatus(session, limitedUntil: limitedUntil[session.key])
    }
}
