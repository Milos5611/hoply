import Foundation

public struct PathRules: Sendable, Equatable {
    public struct Rule: Sendable, Equatable {
        public var path: String
        public var projectID: Int64

        public init(path: String, projectID: Int64) {
            self.path = PathRules.standardized(path)
            self.projectID = projectID
        }
    }

    public private(set) var rules: [Rule]
    public var exactOnly: Set<String>

    public init(_ rules: [Rule] = [], exactOnly: Set<String> = []) {
        self.rules = rules.sorted { ($0.path.count, $0.path) > ($1.path.count, $1.path) }
        self.exactOnly = Set(exactOnly.map(PathRules.standardized))
    }

    public var isEmpty: Bool { rules.isEmpty }

    public func projectID(forRealPath path: String, repoAnchor: String? = nil) -> Int64? {
        let path = Self.standardized(path)
        for rule in rules {
            if rule.path == path { return rule.projectID }
            guard !exactOnly.contains(rule.path), Self.contains(rule.path, path) else { continue }
            // A repository or worktree that starts below the assigned folder keeps its own project.
            if let anchor = repoAnchor.map(Self.standardized), anchor != rule.path, Self.contains(rule.path, anchor) {
                return nil
            }
            return rule.projectID
        }
        return nil
    }

    public static func standardized(_ path: String) -> String {
        ProjectResolver.standardize(path)
    }

    public static func contains(_ root: String, _ path: String) -> Bool {
        PathScope.contains(root, path)
    }

    public static func isAssignable(_ path: String) -> Bool {
        path.hasPrefix("/") && standardized(path) != "/" && !path.utf8.contains(0)
    }
}

public struct PathAssignment: Sendable, Equatable, Identifiable {
    public var path: String
    public var project: ProjectRef

    public init(path: String, project: ProjectRef) {
        self.path = path
        self.project = project
    }

    public var id: String { path }
}

public struct MergedProject: Sendable, Equatable, Identifiable {
    public var project: ProjectRef
    public var into: ProjectRef

    public init(project: ProjectRef, into: ProjectRef) {
        self.project = project
        self.into = into
    }

    public var id: Int64 { project.id }
}

public struct SessionAssignment: Sendable, Equatable, Identifiable {
    public var key: SessionKey
    public var title: String?
    public var project: ProjectRef

    public init(key: SessionKey, title: String? = nil, project: ProjectRef) {
        self.key = key
        self.title = title
        self.project = project
    }

    public var id: String { "\(key.source.rawValue):\(key.id)" }
}

public enum ProjectEditError: Error, Equatable, Sendable {
    case unknownProject(Int64)
    case unknownSession
    case invalidPath(String)
    case sameProject
    case notMerged
}
