import Foundation
import SQLite3

public struct SQLiteError: Error, Equatable, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public var description: String { "SQLite \(code): \(message)" }
}

/// One SQLite handle. Not thread-safe: an owning actor serializes access.
public final class SQLiteConnection {
    private var handle: OpaquePointer?

    public init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI
        let status = sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK else {
            let error = SQLiteError(code: status, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
            sqlite3_close_v2(handle)
            handle = nil
            throw error
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    public func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &message)
        guard status == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(message)
            throw SQLiteError(code: status, message: text)
        }
    }

    public func userVersion() throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil)
        guard status == SQLITE_OK else { throw SQLiteError(code: status, message: lastErrorMessage) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    private var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
    }
}
