import AgentKit
import Foundation
import SQLite3

public enum CopilotStoreError: Error, Equatable, CustomStringConvertible {
    case notFound
    case unsupported(String)
    case changedWhileReading

    public var description: String {
        switch self {
        case .notFound: return "No Copilot CLI session store"
        case .unsupported(let detail): return "Unsupported Copilot schema: \(detail)"
        case .changedWhileReading: return "The Copilot session store changed while it was read"
        }
    }
}

public struct CopilotStoreIngester: Sendable {
    public static let databaseName = "session-store.db"
    public static let knownSchemaVersion = 7

    static let requiredEventColumns: Set<String> = ["id", "session_id", "model", "input_tokens", "output_tokens",
                                                    "cache_read_tokens", "cache_write_tokens", "created_at"]
    static let optionalEventColumns = ["turn_index", "agent_id", "reasoning_tokens", "total_nano_aiu",
                                       "request_multiplier", "token_details_json"]
    static let optionalSessionColumns = ["cwd", "branch", "summary", "created_at", "updated_at"]

    public struct Signature: Sendable, Equatable {
        public var database: FileStat?
        public var wal: FileStat?
    }

    public let home: String

    public static var defaultHome: String {
        if let configured = ProcessInfo.processInfo.environment["COPILOT_HOME"], !configured.isEmpty {
            return (configured as NSString).expandingTildeInPath
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".copilot").path
    }

    public init(home: String = CopilotStoreIngester.defaultHome) {
        self.home = URL(fileURLWithPath: home).standardizedFileURL.path
    }

    public var databasePath: String { home + "/" + Self.databaseName }

    public func signature() -> Signature {
        Signature(database: FileTailer.status(of: databasePath), wal: FileTailer.status(of: databasePath + "-wal"))
    }

    public func open() throws -> CopilotStoreConnection {
        var before = signature()
        guard before.database != nil else { throw CopilotStoreError.notFound }
        if before.wal != nil {
            do {
                let db = try SQLiteConnection(path: "file:\(Self.uriPath(databasePath))?mode=ro", readOnly: true)
                try db.execute("PRAGMA query_only = 1")
                try db.execute("PRAGMA busy_timeout = 1000")
                return try CopilotStoreConnection(db: db)
            } catch let error as SQLiteError where error.code == SQLITE_CANTOPEN {
                // Copilot closed and removed its WAL between the stat and the open.
                before = signature()
                guard before.database != nil, before.wal == nil else { throw error }
            }
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: databasePath), options: .mappedIfSafe)
        guard signature() == before else { throw CopilotStoreError.changedWhileReading }
        return try CopilotStoreConnection(db: SQLiteConnection(snapshot: data))
    }

    static func uriPath(_ path: String) -> String {
        path.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "?", with: "%3F")
            .replacingOccurrences(of: "#", with: "%23")
    }
}

public final class CopilotStoreConnection {
    public let schemaVersion: Int?
    private let db: SQLiteConnection
    private let eventSelect: String
    private let sessionSelect: String

    init(db: SQLiteConnection) throws {
        self.db = db
        func columns(_ table: String) throws -> Set<String> {
            Set(try db.query("SELECT name FROM pragma_table_info(?)", [table]) { $0.text(0) })
        }
        let events = try columns("assistant_usage_events")
        let sessions = try columns("sessions")
        let hasTurns = try columns("turns").contains("session_id")
        schemaVersion = try columns("schema_version").contains("version")
            ? try db.queryOne("SELECT MAX(version) FROM schema_version") { $0.optionalInt(0) } ?? nil
            : nil
        let versionNote = schemaVersion.map { "schema_version \($0)" } ?? "no schema_version"
        if events.isEmpty { throw CopilotStoreError.unsupported("no assistant_usage_events table (\(versionNote))") }
        let missing = CopilotStoreIngester.requiredEventColumns.subtracting(events).sorted()
        if !missing.isEmpty {
            throw CopilotStoreError.unsupported("assistant_usage_events lacks \(missing.joined(separator: ", ")) (\(versionNote))")
        }
        if !sessions.contains("id") { throw CopilotStoreError.unsupported("no sessions table (\(versionNote))") }

        func optional(_ name: String, in table: Set<String>, alias: String) -> String {
            table.contains(name) ? "\(alias).\(name)" : "NULL"
        }
        let eventOptional = CopilotStoreIngester.optionalEventColumns.map { optional($0, in: events, alias: "e") }
        eventSelect = """
            SELECT e.id, e.session_id, e.model, e.input_tokens, e.output_tokens, e.cache_read_tokens,
                   e.cache_write_tokens, e.created_at, \(eventOptional.joined(separator: ", "))
            FROM assistant_usage_events e
            """
        let sessionOptional = CopilotStoreIngester.optionalSessionColumns.map { optional($0, in: sessions, alias: "s") }
        let turns = hasTurns ? "(SELECT COUNT(*) FROM turns t WHERE t.session_id = s.id)" : "0"
        sessionSelect = "SELECT s.id, \(sessionOptional.joined(separator: ", ")), \(turns) FROM sessions s"
    }

    public func maxEventID() throws -> Int64 {
        try db.queryOne("SELECT COALESCE(MAX(id), 0) FROM assistant_usage_events") { $0.int64(0) } ?? 0
    }

    public func events(after id: Int64, limit: Int) throws -> [CopilotUsageEvent] {
        try db.query("\(eventSelect) WHERE e.id > ? ORDER BY e.id LIMIT ?", [id, limit]) { row in
            CopilotUsageEvent(id: row.int64(0), sessionID: row.text(1), turnIndex: row.optionalInt(8),
                              agentID: row.optionalText(9), model: row.optionalText(2), inputTokens: row.int(3),
                              outputTokens: row.int(4), cacheReadTokens: row.int(5), cacheWriteTokens: row.int(6),
                              reasoningTokens: row.int(10), totalNanoAIU: row.optionalInt64(11),
                              requestMultiplier: row.optionalDouble(12), tokenDetailsJSON: row.optionalText(13),
                              createdAt: row.optionalText(7))
        }
    }

    public func sessions(ids: [String]? = nil) throws -> [String: CopilotSession] {
        let rows: [CopilotSession]
        let map = { (row: SQLiteRow) in
            CopilotSession(id: row.text(0), cwd: row.optionalText(1), branch: row.optionalText(2),
                           summary: row.optionalText(3), createdAt: row.optionalText(4), updatedAt: row.optionalText(5),
                           turns: row.int(6))
        }
        if let ids {
            let json = String(decoding: (try? JSONSerialization.data(withJSONObject: ids)) ?? Data("[]".utf8), as: UTF8.self)
            rows = try db.query("\(sessionSelect) WHERE s.id IN (SELECT value FROM json_each(?))", [json], map)
        } else {
            rows = try db.query("""
                \(sessionSelect) WHERE EXISTS (SELECT 1 FROM assistant_usage_events e WHERE e.session_id = s.id)
                """, [], map)
        }
        return Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
