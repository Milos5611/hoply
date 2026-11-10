import Foundation

public enum Schema {
    public static let migrations: [String] = [v1, v2, v3]

    static let v1 = """
    CREATE TABLE projects (
        id INTEGER PRIMARY KEY,
        root TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        display_name TEXT,
        kind TEXT NOT NULL,
        pinned INTEGER NOT NULL DEFAULT 0,
        hidden INTEGER NOT NULL DEFAULT 0,
        last_active REAL
    );
    CREATE TABLE path_map (
        cwd TEXT PRIMARY KEY,
        project_id INTEGER NOT NULL REFERENCES projects(id),
        worktree TEXT,
        origin TEXT NOT NULL DEFAULT 'auto'
    );
    CREATE TABLE sessions (
        source TEXT NOT NULL,
        id TEXT NOT NULL,
        project_id INTEGER REFERENCES projects(id),
        cwd TEXT,
        branch TEXT,
        worktree TEXT,
        title TEXT,
        title_rank INTEGER NOT NULL DEFAULT 0,
        pr_url TEXT,
        first_at REAL,
        last_at REAL,
        ended_at REAL,
        turns INTEGER NOT NULL DEFAULT 0,
        native_cost REAL,
        lines_added INTEGER,
        lines_removed INTEGER,
        transcript_path TEXT,
        PRIMARY KEY (source, id)
    );
    CREATE INDEX sessions_last_at ON sessions(last_at);
    CREATE INDEX sessions_project ON sessions(project_id);
    CREATE TABLE usage (
        id INTEGER PRIMARY KEY,
        dedupe_key TEXT NOT NULL UNIQUE,
        source TEXT NOT NULL,
        session_id TEXT NOT NULL,
        project_id INTEGER REFERENCES projects(id),
        ts REAL NOT NULL,
        model TEXT,
        is_local INTEGER NOT NULL DEFAULT 0,
        sidechain INTEGER NOT NULL DEFAULT 0,
        agent_id TEXT,
        input INTEGER NOT NULL DEFAULT 0,
        output INTEGER NOT NULL DEFAULT 0,
        reasoning INTEGER NOT NULL DEFAULT 0,
        cache_read INTEGER NOT NULL DEFAULT 0,
        cache_write_5m INTEGER NOT NULL DEFAULT 0,
        cache_write_1h INTEGER NOT NULL DEFAULT 0,
        speed TEXT,
        cost_usd REAL,
        api_equiv_usd REAL,
        native_cost REAL,
        request_multiplier REAL,
        turn_index INTEGER,
        pricing_rev TEXT
    );
    CREATE INDEX usage_ts ON usage(ts);
    CREATE INDEX usage_session ON usage(source, session_id);
    CREATE INDEX usage_project_ts ON usage(project_id, ts);
    CREATE TABLE ingest_cursors (
        source TEXT NOT NULL,
        path TEXT NOT NULL,
        inode INTEGER,
        size INTEGER,
        offset INTEGER NOT NULL DEFAULT 0,
        head_hash INTEGER,
        PRIMARY KEY (source, path)
    );
    CREATE TABLE samples (
        series TEXT NOT NULL,
        res INTEGER NOT NULL,
        bucket INTEGER NOT NULL,
        n INTEGER NOT NULL,
        sum REAL NOT NULL,
        min REAL,
        max REAL,
        PRIMARY KEY (series, res, bucket)
    );
    CREATE TABLE limit_samples (
        kind TEXT NOT NULL,
        ts REAL NOT NULL,
        utilization REAL NOT NULL,
        resets_at REAL,
        PRIMARY KEY (kind, ts)
    );
    CREATE TABLE state_spans (
        id INTEGER PRIMARY KEY,
        source TEXT NOT NULL,
        session_id TEXT NOT NULL,
        state TEXT NOT NULL,
        start_at REAL NOT NULL,
        end_at REAL
    );
    CREATE INDEX state_spans_session ON state_spans(source, session_id, start_at);
    CREATE TABLE cleanup_log (
        id INTEGER PRIMARY KEY,
        ts REAL NOT NULL,
        kind TEXT NOT NULL,
        path TEXT NOT NULL,
        bytes INTEGER,
        project_id INTEGER,
        detail TEXT
    );
    """

    static let v2 = """
    ALTER TABLE usage ADD COLUMN native_usd REAL;
    ALTER TABLE usage ADD COLUMN premium_requests REAL NOT NULL DEFAULT 0;
    CREATE INDEX usage_turn ON usage(source, session_id, turn_index) WHERE request_multiplier IS NOT NULL;
    """

    static let v3 = """
    CREATE TABLE subagents (
        source TEXT NOT NULL,
        session_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        agent_type TEXT,
        description TEXT,
        PRIMARY KEY (source, session_id, agent_id)
    );
    """

    public static func configure(_ db: SQLiteConnection, readOnly: Bool = false) throws {
        try db.execute("PRAGMA busy_timeout = 2000")
        if readOnly {
            try db.execute("PRAGMA query_only = 1")
        } else {
            try db.execute("PRAGMA journal_mode = WAL")
            try db.execute("PRAGMA synchronous = NORMAL")
        }
    }

    public static func migrate(_ db: SQLiteConnection, databasePath: String, migrations: [String] = migrations,
                               backupsToKeep: Int = 2) throws {
        let current = try db.userVersion()
        guard current < migrations.count else { return }
        if current > 0 {
            try Backups.rotate(db, databasePath: databasePath, keep: backupsToKeep)
        }
        for version in current..<migrations.count {
            try db.transaction {
                try db.execute(migrations[version])
                try db.setUserVersion(version + 1)
            }
        }
    }
}

public enum Backups {
    public static func slot(_ index: Int, databasePath: String) -> URL {
        URL(fileURLWithPath: "\(databasePath).\(index).bak")
    }

    public static func isPersistent(_ databasePath: String) -> Bool {
        !databasePath.isEmpty && databasePath != ":memory:" && !databasePath.hasPrefix("file::memory:")
    }

    public static func rotate(_ db: SQLiteConnection, databasePath: String, keep: Int) throws {
        guard keep > 0, isPersistent(databasePath) else { return }
        let fileManager = FileManager.default
        let temporary = URL(fileURLWithPath: "\(databasePath).\(UUID().uuidString).tmp")
        try db.execute("VACUUM INTO '\(temporary.path.replacingOccurrences(of: "'", with: "''"))'")
        for index in stride(from: keep - 1, through: 1, by: -1) {
            let from = slot(index, databasePath: databasePath)
            guard fileManager.fileExists(atPath: from.path) else { continue }
            try place(from, at: slot(index + 1, databasePath: databasePath))
        }
        try place(temporary, at: slot(1, databasePath: databasePath))
    }

    public static func rotateIfDue(_ db: SQLiteConnection, databasePath: String, keep: Int,
                                   interval: TimeInterval, now: Date = Date()) throws {
        guard isPersistent(databasePath) else { return }
        let newest = slot(1, databasePath: databasePath).path
        let modified = (try? FileManager.default.attributesOfItem(atPath: newest))?[.modificationDate] as? Date
        if let modified, now.timeIntervalSince(modified) < interval { return }
        try rotate(db, databasePath: databasePath, keep: keep)
    }

    private static func place(_ source: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: source)
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
    }
}
