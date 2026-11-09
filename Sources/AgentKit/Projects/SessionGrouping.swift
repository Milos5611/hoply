import Foundation

public struct ProjectGroup: Identifiable, Equatable, Sendable {
    /// `project:<id>` for a resolved project, else the session cwd, or "" for sessions that never reported one.
    public var id: String
    public var name: String
    /// The project root, or the raw cwd while it is unresolved.
    public var path: String?
    public var project: ProjectRef?
    public var sessions: [AgentSession]
    public var lastActivity: Date

    public var isWorking: Bool { sessions.contains { $0.state == .working } }
}

/// Splits sessions for the panel: everything waiting on the user first, the rest grouped by project.
public struct SessionGrouping: Equatable, Sendable {
    public var waiting: [AgentSession]
    public var projects: [ProjectGroup]

    /// `sessions` must already be in `SessionBoard.ordered` order; that order is kept inside each group.
    /// `projects` maps a session's cwd to its resolved project (`Ledger.resolveProjects`), so worktrees and
    /// subfolders of one repo share a group. A cwd missing from it groups on its own until it resolves, so the
    /// panel never waits for the ledger.
    public init(sessions: [AgentSession], projects resolved: [String: ProjectRef] = [:]) {
        waiting = sessions.filter { $0.state.needsAttention }
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
}
