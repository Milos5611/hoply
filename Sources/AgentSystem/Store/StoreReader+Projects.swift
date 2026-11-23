import AgentKit
import Foundation

extension StoreReader {
    public func projectList() throws -> [ProjectRef] {
        try db.query("""
            SELECT id, root, name, display_name, kind FROM projects WHERE merged_into IS NULL
                AND (substr(root, 1, \(ProjectRef.remoteRootPrefix.count)) <> '\(ProjectRef.remoteRootPrefix)'
                     OR EXISTS (SELECT 1 FROM remote_usage u WHERE u.project_id = projects.id)
                     OR EXISTS (SELECT 1 FROM remote_sessions s WHERE s.project_id = projects.id))
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
            WHERE substr(a.root, 1, \(ProjectRef.remoteRootPrefix.count)) <> '\(ProjectRef.remoteRootPrefix)'
                OR EXISTS (SELECT 1 FROM remote_projects rp WHERE rp.project_id = a.id)
            ORDER BY lower(COALESCE(a.display_name, a.name)), a.id
            """) { row -> MergedProject? in
            guard let project = Self.project(row, from: 0), let into = Self.project(row, from: 5) else { return nil }
            return MergedProject(project: project, into: into)
        }.compactMap { $0 }
    }

    public func sessionAssignments() throws -> [SessionAssignment] {
        let local = try db.query("""
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
        let remote = try db.query("""
            SELECT n.source, n.id, n.device,
                   (SELECT t.title FROM remote_sessions t WHERE t.device = n.device AND t.source = n.source
                        AND t.id = n.id AND t.title IS NOT NULL ORDER BY t.day DESC, t.part LIMIT 1),
                   p.id, p.root, p.name, p.display_name, p.kind,
                   (SELECT MAX(t.last_at) FROM remote_sessions t WHERE t.device = n.device AND t.source = n.source
                        AND t.id = n.id)
            FROM remote_session_pins n JOIN projects p ON p.id = n.project_id
            ORDER BY 10 DESC, n.device, n.source, n.id
            """) { row -> SessionAssignment? in
            guard let source = AgentSource(rawValue: row.text(0)), let project = Self.project(row, from: 4) else {
                return nil
            }
            return SessionAssignment(key: SessionKey(source: source, id: row.text(1)), title: row.optionalText(3),
                                     project: project, device: row.text(2))
        }.compactMap { $0 }
        return local + remote
    }
}
