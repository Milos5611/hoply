import AgentKit
import Foundation

public struct CleanupInventory: Sendable, Equatable {
    public struct Worktree: Sendable, Equatable {
        public var path: String
        public var lastActive: Date?

        public init(path: String, lastActive: Date? = nil) {
            self.path = path
            self.lastActive = lastActive
        }
    }

    public struct Project: Sendable, Equatable {
        public var ref: ProjectRef
        public var lastActive: Date?
        public var worktrees: [Worktree]

        public init(ref: ProjectRef, lastActive: Date? = nil, worktrees: [Worktree] = []) {
            self.ref = ref
            self.lastActive = lastActive
            self.worktrees = worktrees
        }

        public var latestActivity: Date? {
            ([lastActive] + worktrees.map(\.lastActive)).compactMap { $0 }.max()
        }
    }

    public struct TranscriptSession: Sendable, Equatable {
        public var title: String?
        public var project: ProjectRef?

        public init(title: String? = nil, project: ProjectRef? = nil) {
            self.title = title
            self.project = project
        }
    }

    public var projects: [Project]
    public var transcriptsDirectory: String
    public var transcriptCursors: [String: FileCursor]
    public var transcriptSessions: [String: TranscriptSession]

    public init(projects: [Project] = [], transcriptsDirectory: String, transcriptCursors: [String: FileCursor] = [:],
                transcriptSessions: [String: TranscriptSession] = [:]) {
        self.projects = projects
        self.transcriptsDirectory = transcriptsDirectory
        self.transcriptCursors = transcriptCursors
        self.transcriptSessions = transcriptSessions
    }

    public func project(_ id: Int64) -> Project? {
        projects.first { $0.ref.id == id }
    }
}
