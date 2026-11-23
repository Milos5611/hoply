import AgentKit
import Foundation

extension Store {
    public func takeHistoryChanges() -> RemoteHistoryChanges {
        let changes = historyChanges
        historyChanges = .none
        return changes
    }

    func noteHistory(_ days: some Sequence<Int>) {
        historyChanges.formUnion(.days(Set(days)))
    }

    func noteHistory(_ batch: LedgerBatch, skipping foreign: Set<SessionKey>) throws {
        var days = Set<Int>()
        for record in batch.usage where !foreign.contains(SessionKey(source: record.source, id: record.sessionID)) {
            days.insert(RemoteHistoryCalendar.day(of: record.timestamp))
        }
        for update in batch.sessions where !foreign.contains(update.key) {
            for date in [update.firstAt, update.lastAt].compactMap({ $0 }) {
                days.insert(RemoteHistoryCalendar.day(of: date))
            }
            if update.title != nil { try noteHistorySpan(of: update.key) }
        }
        noteHistory(days)
    }

    func noteHistorySpan(of key: SessionKey) throws {
        guard let span = try db.queryOne("SELECT first_at, last_at FROM sessions WHERE source = ? AND id = ?",
                                         [key.source.rawValue, key.id], { row in
                                             (row.optionalDouble(0), row.optionalDouble(1))
                                         }) else { return }
        guard let last = (span.1 ?? span.0).map(Date.init(timeIntervalSince1970:)) else { return }
        let end = RemoteHistoryCalendar.day(of: last)
        let start = span.0.map { RemoteHistoryCalendar.day(of: Date(timeIntervalSince1970: $0)) } ?? end
        noteHistory(max(start, end - RemoteHistoryPolicy.titleSpanDays)...end)
    }

    // MARK: - Other Macs' history

    @discardableResult
    public func applyRemoteHistory(_ days: [RemoteHistoryDay], deleted: [RemoteHistoryPartKey] = [],
                                   device: String, machine: String? = nil) throws -> Bool {
        let keys = Set(days.map { "\($0.device)/\($0.day)" } + deleted.map { "\($0.device)/\($0.day)" })
        guard !keys.isEmpty else { return false }
        return try db.transaction {
            let stored = try storedParts("device || '/' || day IN (SELECT value FROM json_each(?))",
                                         [Self.jsonArray(keys.sorted())])
            let plan = RemoteHistoryMerge.plan(days, deleted: deleted, stored: stored, device: device,
                                               machine: machine)
            guard !plan.isEmpty else { return false }
            for key in plan.remove { try removeRemotePart(key) }
            for day in plan.replace { try insertRemotePart(day) }
            try settleRemote()
            return true
        }
    }

    @discardableResult
    public func dropRemoteHistory(keeping fetched: Set<RemoteHistoryPartKey>) throws -> Bool {
        try db.transaction {
            let absent = RemoteHistoryMerge.absent(stored: Set(try storedParts("1", []).keys), fetched: fetched)
            for key in absent { try removeRemotePart(key) }
            if !absent.isEmpty { try settleRemote() }
            return !absent.isEmpty
        }
    }

    @discardableResult
    public func clearRemoteHistory() throws -> Bool {
        try db.transaction {
            let had = try db.queryOne("SELECT EXISTS (SELECT 1 FROM remote_parts) OR EXISTS (SELECT 1 FROM remote_projects)") {
                $0.bool(0)
            } == true
            for table in ["remote_usage", "remote_sessions", "remote_parts", "remote_projects", "remote_session_pins",
                          "remote_devices"] {
                try db.run("DELETE FROM \(table)")
            }
            try db.run("UPDATE projects SET merged_into = NULL WHERE merged_into IN (\(Self.remoteOnlyIDs))")
            try db.run("""
                DELETE FROM projects WHERE \(Self.isRemoteOnlyRoot("root"))
                    AND id NOT IN (SELECT project_id FROM usage WHERE project_id IS NOT NULL)
                    AND id NOT IN (SELECT project_id FROM sessions WHERE project_id IS NOT NULL)
                    AND id NOT IN (SELECT project_id FROM path_map)
                """)
            registry.invalidate()
            knownProjectMax = try projectMax()
            return had
        }
    }

    private func storedParts(_ filter: String,
                             _ values: [any SQLiteBindable]) throws -> [RemoteHistoryPartKey: RemoteHistoryStoredPart] {
        let rows = try db.query("SELECT device, day, part, parts, built_at FROM remote_parts WHERE \(filter)", values) {
            row in
            (RemoteHistoryPartKey(device: row.text(0), day: row.text(1), part: row.int(2)),
             RemoteHistoryStoredPart(builtAt: Date(timeIntervalSince1970: row.double(4)), parts: row.int(3)))
        }
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }

    private func removeRemotePart(_ key: RemoteHistoryPartKey) throws {
        let values: [any SQLiteBindable] = [key.device, key.day, key.part]
        for table in ["remote_usage", "remote_sessions", "remote_parts"] {
            try db.run("DELETE FROM \(table) WHERE device = ? AND day = ? AND part = ?", values)
        }
    }

    private func insertRemotePart(_ day: RemoteHistoryDay) throws {
        try removeRemotePart(day.key)
        let built = day.updatedAt.timeIntervalSince1970
        try db.run("""
            INSERT INTO remote_parts (device, day, part, parts, built_at) VALUES (?, ?, ?, ?, ?)
            """, [day.device, day.day, day.part, day.parts, built])
        try db.run("""
            INSERT INTO remote_devices (device, name, updated_at) VALUES (?1, ?2, ?3)
            ON CONFLICT(device) DO UPDATE SET
                name = CASE WHEN ?2 IS NOT NULL AND ?3 >= COALESCE(remote_devices.updated_at, 0) THEN ?2
                            ELSE COALESCE(remote_devices.name, ?2) END,
                updated_at = max(COALESCE(remote_devices.updated_at, 0), ?3)
            """, [day.device, day.deviceName.flatMap { $0.isEmpty ? nil : $0 }, built])
        for project in day.projects {
            try db.run("""
                INSERT INTO remote_projects (device, remote_id, name, title, origin, kind) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(device, remote_id) DO UPDATE SET
                    name = excluded.name, title = excluded.title, origin = excluded.origin, kind = excluded.kind
                """, [day.device, project.id, project.name, project.title, project.origin, project.kind.rawValue])
        }
        let known = Set(day.projects.map(\.id))
        for session in day.sessions {
            guard !session.key.isEmpty, let colon = session.key.firstIndex(of: ":") else { continue }
            let id = String(session.key[session.key.index(after: colon)...])
            let source = session.agent.isEmpty ? String(session.key[..<colon]) : session.agent
            let sessionProject = session.project.flatMap { known.contains($0) ? $0 : nil }
            try db.run("""
                INSERT INTO remote_sessions (device, day, part, source, id, remote_project, title, first_at, last_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(device, day, part, source, id) DO UPDATE SET
                    first_at = min(remote_sessions.first_at, excluded.first_at),
                    last_at = max(remote_sessions.last_at, excluded.last_at),
                    title = COALESCE(excluded.title, remote_sessions.title)
                """, [day.device, day.day, day.part, source, id, sessionProject, session.title,
                      session.start.timeIntervalSince1970, session.end.timeIntervalSince1970])
            for usage in session.usage where usage.calls > 0 {
                let project = usage.project.flatMap { known.contains($0) ? $0 : nil } ?? sessionProject
                let priced = Self.priceRemote(model: usage.model, tokens: usage.tokens, speed: usage.speed,
                                              prompt: usage.prompt, nativeUSD: usage.nativeUSD, pricing: pricing)
                let revision = usage.nativeUSD != nil ? Self.nativePricingRevision : pricing.revision
                let tokens = usage.tokens
                try db.run("""
                    INSERT INTO remote_usage (device, day, part, source, session_id, remote_project, ts, last_ts, model,
                                              speed, prompt, is_local, input, output, reasoning, cache_read,
                                              cache_write_5m, cache_write_1h, calls, native_usd, native_cost,
                                              premium_requests, cost_usd, api_equiv_usd, pricing_rev)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [day.device, day.day, day.part, source, id, project, usage.at.timeIntervalSince1970,
                          usage.last.timeIntervalSince1970, usage.model, usage.speed, max(usage.prompt, 0),
                          priced.isLocal, tokens.input, tokens.output, tokens.reasoning, tokens.cacheRead,
                          tokens.cacheWrite5m, tokens.cacheWrite1h, usage.calls, usage.nativeUSD, usage.nativeCost,
                          usage.premium ?? 0, priced.costUSD, priced.apiEquivUSD, revision])
            }
        }
    }

    static func priceRemote(model: String?, tokens: TokenCounts, speed: String?, prompt: Int, nativeUSD: Double?,
                            pricing: PricingTable) -> PricedUsage {
        if let nativeUSD { return PricedUsage(costUSD: nativeUSD, apiEquivUSD: nativeUSD, isLocal: false) }
        return pricing.price(model: model, tokens: tokens, speed: speed, promptTokens: prompt > 0 ? prompt : nil)
    }

    static func repriceRemote(_ db: SQLiteConnection, _ pricing: PricingTable) throws -> Int {
        let stale = try db.queryOne("SELECT 1 FROM remote_usage WHERE pricing_rev IS NOT ? AND native_usd IS NULL LIMIT 1",
                                    [pricing.revision]) { _ in true }
        guard stale == true else { return 0 }
        return try db.transaction {
            let rows = try db.query("""
                SELECT id, model, input, output, reasoning, cache_read, cache_write_5m, cache_write_1h, speed, prompt
                FROM remote_usage WHERE pricing_rev IS NOT ? AND native_usd IS NULL
                """, [pricing.revision]) { row in
                (row.int64(0), priceRemote(model: row.optionalText(1),
                                           tokens: TokenCounts(input: row.int(2), output: row.int(3),
                                                               reasoning: row.int(4), cacheRead: row.int(5),
                                                               cacheWrite5m: row.int(6), cacheWrite1h: row.int(7)),
                                           speed: row.optionalText(8), prompt: row.int(9), nativeUSD: nil,
                                           pricing: pricing))
            }
            for (id, priced) in rows {
                try db.run("""
                    UPDATE remote_usage SET cost_usd = ?, api_equiv_usd = ?, is_local = ?, pricing_rev = ? WHERE id = ?
                    """, [priced.costUSD, priced.apiEquivUSD, priced.isLocal, pricing.revision, id])
            }
            return rows.count
        }
    }

    // MARK: - Projects across Macs

    static let remoteOnlyIDs = "SELECT id FROM projects WHERE \(isRemoteOnlyRoot("root"))"

    static func isRemoteOnlyRoot(_ column: String) -> String {
        "substr(\(column), 1, \(ProjectRef.remoteRootPrefix.count)) = '\(ProjectRef.remoteRootPrefix)'"
    }

    func projectMax() throws -> Int64 {
        try db.queryOne("SELECT COALESCE(MAX(id), 0) FROM projects") { $0.int64(0) } ?? 0
    }

    // This Mac's own ingest made a project (it cloned a repo another Mac has): other Macs' rows may now match it.
    func rematchIfProjectsGrew() throws {
        let current = try projectMax()
        guard current > knownProjectMax else { return }
        knownProjectMax = current
        guard try db.queryOne("SELECT 1 FROM remote_projects LIMIT 1", [], { _ in true }) == true else { return }
        try reattributeRemote()
    }

    private func settleRemote() throws {
        try db.run("""
            DELETE FROM remote_projects WHERE
                NOT EXISTS (SELECT 1 FROM remote_sessions s WHERE s.device = remote_projects.device
                            AND s.remote_project = remote_projects.remote_id)
                AND NOT EXISTS (SELECT 1 FROM remote_usage u WHERE u.device = remote_projects.device
                                AND u.remote_project = remote_projects.remote_id)
            """)
        try db.run("DELETE FROM remote_devices WHERE device NOT IN (SELECT device FROM remote_parts)")
        try db.run("""
            DELETE FROM remote_session_pins WHERE NOT EXISTS (SELECT 1 FROM remote_sessions s
                WHERE s.device = remote_session_pins.device AND s.source = remote_session_pins.source
                AND s.id = remote_session_pins.id)
            """)
        try reattributeRemote()
    }

    // Runs inside the caller's transaction: rewrites every remote row's project from its Mac's project, this Mac's
    // merges and the user's session moves, so a manual edit wins over every re-sync.
    func reattributeRemote() throws {
        typealias Row = (device: String, project: RemoteHistoryDay.Project, current: Int64?)
        // Rows with an origin first, so a Mac's repo claims its group before that Mac's same-named plain folder.
        let remotes: [Row] = try db.query("""
            SELECT device, remote_id, name, title, origin, kind, project_id FROM remote_projects
            ORDER BY origin IS NULL, device, remote_id
            """) { row in
            (device: row.text(0),
             project: RemoteHistoryDay.Project(id: row.text(1), name: row.text(2), title: row.optionalText(3),
                                               origin: row.optionalText(4),
                                               kind: RemoteHistoryDay.ProjectKind(rawValue: row.text(5)) ?? .unknown),
             current: row.optionalInt64(6))
        }
        let locals = remotes.isEmpty ? [] : try localProjectCandidates()
        var groupOrigins = Dictionary(locals.compactMap { local in local.origin.map { (local.id, $0) } },
                                      uniquingKeysWith: { first, _ in first })
        let edited = try editedRemoteOnlyProjects()
        for project in edited {
            if let origin = project.origin { groupOrigins[project.id] = groupOrigins[project.id] ?? origin }
        }
        var preferred = edited
        var mapped: [RemoteProjectCandidate] = []
        var targets: [Int: Int64] = [:]
        var claimed: [String: Set<Int64>] = [:]

        func offer(_ row: Row, _ target: Int64, into list: inout [RemoteProjectCandidate]) {
            let origin = groupOrigins[target] ?? row.project.origin
            if let origin { groupOrigins[target] = origin }
            list.append(RemoteProjectCandidate(id: target, name: row.project.name, origin: origin,
                                               kind: row.project.kind.local, device: row.device))
            claimed[row.device, default: []].insert(target)
        }
        // A row whose project the user merged, merged into, or moved a session into keeps it, whoever's project it is.
        for (index, row) in remotes.enumerated() {
            guard let current = row.current, try isEdited(current) else { continue }
            targets[index] = current
            offer(row, current, into: &preferred)
        }
        for (index, row) in remotes.enumerated() where targets[index] == nil {
            let target = try remoteProjectTarget(
                device: row.device, project: row.project, locals: locals,
                mapped: (preferred + mapped).filter { $0.device != row.device }, taken: claimed[row.device] ?? [])
            targets[index] = target
            offer(row, target, into: &mapped)
        }

        for (index, row) in remotes.enumerated() {
            guard let target = targets[index] else { continue }
            if target != row.current {
                try db.run("UPDATE remote_projects SET project_id = ? WHERE device = ? AND remote_id = ?",
                           [target, row.device, row.project.id])
            }
            if let origin = groupOrigins[target] {
                try db.run("""
                    UPDATE projects SET remote_origin = ? WHERE id = ? AND remote_origin IS NULL AND \(Self.isRemoteOnlyRoot("root"))
                    """, [origin, target])
            }
            let resolved = try registry.merged(target, db: db)
            for table in ["remote_usage", "remote_sessions"] {
                try db.run("""
                    UPDATE \(table) SET project_id = ? WHERE device = ? AND remote_project = ? AND project_id IS NOT ?
                    """, [resolved, row.device, row.project.id, resolved])
            }
        }
        for table in ["remote_usage", "remote_sessions"] {
            try db.run("UPDATE \(table) SET project_id = NULL WHERE remote_project IS NULL AND project_id IS NOT NULL")
        }
        let pins = try db.query("SELECT device, source, id, project_id FROM remote_session_pins") { row in
            (row.text(0), row.text(1), row.text(2), row.int64(3))
        }
        for (device, source, id, project) in pins {
            let resolved = try registry.merged(project, db: db)
            try db.run("UPDATE remote_usage SET project_id = ? WHERE device = ? AND source = ? AND session_id = ?",
                       [resolved, device, source, id])
            try db.run("UPDATE remote_sessions SET project_id = ? WHERE device = ? AND source = ? AND id = ?",
                       [resolved, device, source, id])
        }
        try pruneRemoteOnlyProjects()
        knownProjectMax = try projectMax()
    }

    private func isEdited(_ id: Int64) throws -> Bool {
        try db.queryOne("""
            SELECT p.merged_into IS NOT NULL
                OR EXISTS (SELECT 1 FROM projects m WHERE m.merged_into = p.id)
                OR EXISTS (SELECT 1 FROM remote_session_pins n WHERE n.project_id = p.id)
            FROM projects p WHERE p.id = ?
            """, [id]) { $0.bool(0) } ?? false
    }

    // Kept even once every Mac that sent them has left, so a later copy still lands where the user merged it.
    private func editedRemoteOnlyProjects() throws -> [RemoteProjectCandidate] {
        try db.query("""
            SELECT p.id, p.root, p.name, p.remote_origin, p.kind FROM projects p
            WHERE \(Self.isRemoteOnlyRoot("p.root")) AND (p.merged_into IS NOT NULL
                OR EXISTS (SELECT 1 FROM projects m WHERE m.merged_into = p.id)
                OR EXISTS (SELECT 1 FROM remote_session_pins n WHERE n.project_id = p.id))
            ORDER BY p.id
            """) { row in
            let owner = row.text(1).dropFirst(ProjectRef.remoteRootPrefix.count).split(separator: "/").first.map(String.init)
            return RemoteProjectCandidate(id: row.int64(0), name: row.text(2), origin: row.optionalText(3),
                                          kind: ProjectKind(rawValue: row.text(4)) ?? .folder, device: owner)
        }
    }

    private func pruneRemoteOnlyProjects() throws {
        try db.run("""
            DELETE FROM projects WHERE \(Self.isRemoteOnlyRoot("root")) AND merged_into IS NULL
                AND id NOT IN (SELECT project_id FROM remote_projects WHERE project_id IS NOT NULL)
                AND id NOT IN (SELECT project_id FROM remote_usage WHERE project_id IS NOT NULL)
                AND id NOT IN (SELECT project_id FROM remote_sessions WHERE project_id IS NOT NULL)
                AND id NOT IN (SELECT project_id FROM remote_session_pins)
                AND id NOT IN (SELECT merged_into FROM projects WHERE merged_into IS NOT NULL)
                AND id NOT IN (SELECT project_id FROM usage WHERE project_id IS NOT NULL)
                AND id NOT IN (SELECT project_id FROM sessions WHERE project_id IS NOT NULL)
                AND id NOT IN (SELECT project_id FROM path_map)
            """)
        if db.changes > 0 { registry.invalidate() }
    }

    private func remoteProjectTarget(device: String, project: RemoteHistoryDay.Project,
                                     locals: [RemoteProjectCandidate], mapped: [RemoteProjectCandidate],
                                     taken: Set<Int64>) throws -> Int64 {
        let root = ProjectRef.remoteRootPrefix + device + "/" + project.id
        let name = project.name.isEmpty ? "Project" : project.name
        let own = try db.queryOne("SELECT id FROM projects WHERE root = ?", [root]) { $0.int64(0) }
        if let own {
            try db.run("""
                UPDATE projects SET name = ?2, display_name = ?3, kind = ?4
                WHERE id = ?1 AND (name IS NOT ?2 OR display_name IS NOT ?3 OR kind IS NOT ?4)
                """, [own, name, project.title, project.kind.local.rawValue])
        }
        if let match = RemoteProjectMatch.match(project, among: locals, remoteOnly: mapped, taken: taken) { return match }
        if let own { return own }
        return try db.queryOne("""
            INSERT INTO projects (root, name, display_name, kind, remote_origin) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(root) DO UPDATE SET root = excluded.root
            RETURNING id
            """, [root, name, project.title, project.kind.local.rawValue, project.origin]) { $0.int64(0) } ?? 0
    }

    private func localProjectCandidates() throws -> [RemoteProjectCandidate] {
        let rows = try db.query("""
            SELECT id, root, name, kind, COALESCE(last_active, 0), merged_into IS NOT NULL FROM projects
            WHERE NOT \(Self.isRemoteOnlyRoot("root"))
            """) { row in
            (id: row.int64(0), root: row.text(1), name: row.text(2),
             kind: ProjectKind(rawValue: row.text(3)) ?? .folder, lastActive: row.double(4), merged: row.bool(5))
        }
        return rows.map { row in
            RemoteProjectCandidate(id: row.id, name: row.name, origin: localOrigin(id: row.id, root: row.root,
                                                                                    kind: row.kind),
                                   kind: row.kind, lastActive: row.lastActive, merged: row.merged)
        }
    }

    func localOrigin(id: Int64, root: String, kind: ProjectKind) -> String? {
        guard kind == .repo else { return nil }
        if let cached = localOrigins[id] { return cached }
        let origin = GitRemote.originHash(ofRepoAt: root, fileSystem: registry.fileSystem)
        localOrigins[id] = origin
        return origin
    }
}
