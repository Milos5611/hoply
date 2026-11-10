import AgentKit
import Foundation

extension Store {
    @discardableResult
    public func assign(path: String, toProject projectID: Int64) throws -> Set<SessionKey> {
        guard PathRules.isAssignable(path) else { throw ProjectEditError.invalidPath(path) }
        let real = registry.realPath(path)
        guard PathRules.isAssignable(real) else { throw ProjectEditError.invalidPath(path) }
        return try edit {
            let target = try existingProject(projectID)
            try db.run("""
                INSERT INTO path_map (cwd, project_id, worktree, origin) VALUES (?, ?, NULL, 'user')
                ON CONFLICT(cwd) DO UPDATE SET project_id = excluded.project_id, worktree = NULL, origin = 'user'
                """, [real, target])
            registry.invalidate()
            return try reattribute(sessionsUnder: real)
        }
    }

    @discardableResult
    public func unassign(path: String) throws -> Set<SessionKey> {
        let real = registry.realPath(path)
        return try edit {
            try db.run("DELETE FROM path_map WHERE origin = 'user' AND cwd IN (?, ?)", [real, path])
            registry.invalidate()
            return try reattribute(sessionsUnder: real)
        }
    }

    @discardableResult
    public func mergeProject(_ sourceID: Int64, into targetID: Int64) throws -> Set<SessionKey> {
        try edit {
            guard try projectExists(sourceID) else { throw ProjectEditError.unknownProject(sourceID) }
            let target = try existingProject(targetID)
            guard target != sourceID else { throw ProjectEditError.sameProject }
            let moved = try sessionKeys("project_id = ?", [sourceID])
            try db.run("UPDATE projects SET merged_into = ? WHERE id = ?", [target, sourceID])
            try db.run("UPDATE usage SET project_id = ? WHERE project_id = ?", [target, sourceID])
            try db.run("UPDATE sessions SET project_id = ? WHERE project_id = ?", [target, sourceID])
            try db.run("""
                UPDATE projects SET last_active = max(COALESCE(last_active, 0),
                                                      COALESCE((SELECT last_active FROM projects WHERE id = ?), 0))
                WHERE id = ?
                """, [sourceID, target])
            registry.invalidate()
            return moved
        }
    }

    @discardableResult
    public func unmergeProject(_ projectID: Int64) throws -> Set<SessionKey> {
        try edit {
            guard try projectExists(projectID) else { throw ProjectEditError.unknownProject(projectID) }
            guard try db.queryOne("SELECT merged_into FROM projects WHERE id = ?", [projectID], { $0.optionalInt64(0) })
                    .flatMap({ $0 }) != nil else { throw ProjectEditError.notMerged }
            let holder = try registry.merged(projectID, db: db)
            try db.run("UPDATE projects SET merged_into = NULL WHERE id = ?", [projectID])
            registry.invalidate()
            return try reattribute(sessionsWhere: "project_id = ?", [holder])
        }
    }

    @discardableResult
    public func assign(session key: SessionKey, toProject projectID: Int64) throws -> Set<SessionKey> {
        try edit {
            let target = try existingProject(projectID)
            guard try sessionExists(key) else { throw ProjectEditError.unknownSession }
            try db.run("UPDATE sessions SET project_id = ?, project_origin = 'user' WHERE source = ? AND id = ?",
                       [target, key.source.rawValue, key.id])
            try db.run("UPDATE usage SET project_id = ? WHERE source = ? AND session_id = ?",
                       [target, key.source.rawValue, key.id])
            registry.invalidate()
            return [key]
        }
    }

    @discardableResult
    public func unassign(session key: SessionKey) throws -> Set<SessionKey> {
        try edit {
            guard let cwd = try db.queryOne("""
                SELECT cwd FROM sessions WHERE source = ? AND id = ? AND project_origin = 'user'
                """, [key.source.rawValue, key.id], { $0.optionalText(0) }) else { return [] }
            try db.run("UPDATE sessions SET project_origin = 'auto' WHERE source = ? AND id = ?",
                       [key.source.rawValue, key.id])
            registry.invalidate()
            let automatic = try cwd.flatMap { $0.isEmpty ? nil : $0 }.map { try registry.entry(for: $0, db: db).projectID }
            try db.run("UPDATE sessions SET project_id = ? WHERE source = ? AND id = ?",
                       [automatic, key.source.rawValue, key.id])
            try db.run("UPDATE usage SET project_id = ? WHERE source = ? AND session_id = ?",
                       [automatic, key.source.rawValue, key.id])
            return [key]
        }
    }

    public func mergeSuggestions() throws -> [MergeSuggestion] {
        let projects = try db.query("""
            SELECT id, root, name, display_name, kind FROM projects
            WHERE merged_into IS NULL AND kind = 'repo' ORDER BY COALESCE(last_active, 0) DESC, id
            """) { StoreReader.project($0, from: 0) }.compactMap { $0 }
        let dismissed = Set(try db.query("SELECT key FROM dismissed_suggestions") { $0.text(0) })
        let fileSystem = registry.fileSystem
        let remotes = projects.compactMap { project in
            GitRemote.originURL(ofRepoAt: project.root, fileSystem: fileSystem).map { (project: project, originURL: $0) }
        }
        return MergeSuggestion.clones(remotes, dismissed: dismissed)
    }

    public func dismissSuggestion(_ id: String, at time: Date = Date()) throws {
        try db.run("INSERT INTO dismissed_suggestions (key, dismissed_at) VALUES (?, ?) ON CONFLICT(key) DO NOTHING",
                   [id, time.timeIntervalSince1970])
    }

    public func restoreSuggestions() throws {
        try db.run("DELETE FROM dismissed_suggestions")
    }

    func record(_ prompts: [PromptRecord], touched: inout Set<SessionKey>) throws {
        guard !prompts.isEmpty else { return }
        for prompt in prompts {
            try db.run("""
                INSERT INTO session_prompts (dedupe_key, source, session_id, ts) VALUES (?, ?, ?, ?)
                ON CONFLICT(dedupe_key) DO NOTHING
                """, [prompt.dedupeKey, prompt.source.rawValue, prompt.sessionID, prompt.timestamp.timeIntervalSince1970])
        }
        for key in Set(prompts.map(\.session)) {
            try db.run("""
                UPDATE sessions SET turns = (SELECT COUNT(*) FROM session_prompts WHERE source = ?1 AND session_id = ?2)
                WHERE source = ?1 AND id = ?2
                """, [key.source.rawValue, key.id])
            touched.insert(key)
        }
    }

    // A failed edit may leave the registry holding rules that were rolled back.
    private func edit<T>(_ body: () throws -> T) throws -> T {
        do {
            return try db.transaction(body)
        } catch {
            registry.invalidate()
            throw error
        }
    }

    private func projectExists(_ id: Int64) throws -> Bool {
        try db.queryOne("SELECT 1 FROM projects WHERE id = ?", [id]) { _ in true } == true
    }

    private func existingProject(_ id: Int64) throws -> Int64 {
        guard try projectExists(id) else { throw ProjectEditError.unknownProject(id) }
        return try registry.merged(id, db: db)
    }

    private func sessionExists(_ key: SessionKey) throws -> Bool {
        try db.queryOne("SELECT 1 FROM sessions WHERE source = ? AND id = ?", [key.source.rawValue, key.id]) { _ in true }
            == true
    }

    private func sessionKeys(_ filter: String, _ values: [any SQLiteBindable]) throws -> Set<SessionKey> {
        Set(try db.query("SELECT source, id FROM sessions WHERE \(filter)", values) { row in
            AgentSource(rawValue: row.text(0)).map { SessionKey(source: $0, id: row.text(1)) }
        }.compactMap { $0 })
    }

    private func reattribute(sessionsUnder root: String) throws -> Set<SessionKey> {
        let cwds = try db.query("""
            SELECT DISTINCT cwd FROM sessions WHERE project_origin = 'auto' AND cwd IS NOT NULL AND cwd != ''
            """) { $0.text(0) }
        let inside = cwds.filter { PathRules.contains(root, registry.realPath($0)) }
        guard !inside.isEmpty else { return [] }
        return try reattribute(sessionsWhere: "cwd IN (SELECT value FROM json_each(?))", [Self.jsonArray(inside)])
    }

    private func reattribute(sessionsWhere filter: String, _ values: [any SQLiteBindable]) throws -> Set<SessionKey> {
        let rows = try db.query("""
            SELECT source, id, cwd, project_id FROM sessions
            WHERE project_origin = 'auto' AND cwd IS NOT NULL AND cwd != '' AND \(filter)
            """, values) { row in (row.text(0), row.text(1), row.text(2), row.optionalInt64(3)) }
        var moved = Set<SessionKey>()
        for (source, id, cwd, current) in rows {
            let resolved = try registry.entry(for: cwd, db: db).projectID
            guard resolved != current else { continue }
            try db.run("UPDATE sessions SET project_id = ? WHERE source = ? AND id = ?", [resolved, source, id])
            // Only the rows filed with the session move; a call made from another project's folder stays there.
            try db.run("UPDATE usage SET project_id = ? WHERE source = ? AND session_id = ? AND project_id IS ?",
                       [resolved, source, id, current])
            if let agent = AgentSource(rawValue: source) { moved.insert(SessionKey(source: agent, id: id)) }
        }
        return moved
    }

    static func jsonArray(_ values: [String]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: values)) ?? Data("[]".utf8), as: UTF8.self)
    }
}
