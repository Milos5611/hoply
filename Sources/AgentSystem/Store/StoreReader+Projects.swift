import AgentKit
import Foundation

extension StoreReader {
    public func projectList() throws -> [ProjectRef] {
        try db.query("""
            SELECT id, root, name, display_name, kind FROM projects WHERE merged_into IS NULL
            ORDER BY COALESCE(last_active, 0) DESC, lower(COALESCE(display_name, name)), id
            """) { Self.project($0, from: 0) }.compactMap { $0 }
    }

    public func pathAssignments() throws -> [PathAssignment] {
        try db.query("""
            SELECT m.cwd, p.id, p.root, p.name, p.display_name, p.kind
            FROM path_map m JOIN projects p ON p.id = m.project_id
            WHERE m.origin = 'user' ORDER BY m.cwd
            """) { row in Self.project(row, from: 1).map { PathAssignment(path: row.text(0), project: $0) } }
            .compactMap { $0 }
    }

    public func mergedProjects() throws -> [MergedProject] {
        try db.query("""
            SELECT a.id, a.root, a.name, a.display_name, a.kind, b.id, b.root, b.name, b.display_name, b.kind
            FROM projects a JOIN projects b ON b.id = a.merged_into
            ORDER BY lower(COALESCE(a.display_name, a.name)), a.id
            """) { row -> MergedProject? in
            guard let project = Self.project(row, from: 0), let into = Self.project(row, from: 5) else { return nil }
            return MergedProject(project: project, into: into)
        }.compactMap { $0 }
    }

    public func sessionAssignments() throws -> [SessionAssignment] {
        try db.query("""
            SELECT s.source, s.id, s.title, p.id, p.root, p.name, p.display_name, p.kind
            FROM sessions s JOIN projects p ON p.id = s.project_id
            WHERE s.project_origin = 'user' ORDER BY s.last_at DESC, s.source, s.id
            """) { row -> SessionAssignment? in
            guard let source = AgentSource(rawValue: row.text(0)), let project = Self.project(row, from: 3) else {
                return nil
            }
            return SessionAssignment(key: SessionKey(source: source, id: row.text(1)), title: row.optionalText(2),
                                     project: project)
        }.compactMap { $0 }
    }
}
