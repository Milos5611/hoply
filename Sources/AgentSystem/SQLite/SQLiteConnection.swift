import Foundation
import SQLite3

public struct SQLiteError: Error, Equatable, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public var description: String { "SQLite \(code): \(message)" }
}

public enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
}

public protocol SQLiteBindable {
    var sqliteValue: SQLiteValue { get }
}

extension SQLiteValue: SQLiteBindable {
    public var sqliteValue: SQLiteValue { self }
}

extension Int: SQLiteBindable {
    public var sqliteValue: SQLiteValue { .integer(Int64(self)) }
}

extension Int64: SQLiteBindable {
    public var sqliteValue: SQLiteValue { .integer(self) }
}

extension Double: SQLiteBindable {
    public var sqliteValue: SQLiteValue { .real(self) }
}

extension String: SQLiteBindable {
    public var sqliteValue: SQLiteValue { .text(self) }
}

extension Bool: SQLiteBindable {
    public var sqliteValue: SQLiteValue { .integer(self ? 1 : 0) }
}

extension Optional: SQLiteBindable where Wrapped: SQLiteBindable {
    public var sqliteValue: SQLiteValue { self?.sqliteValue ?? .null }
}

public struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    public func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    public func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    public func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
    public func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    public func bool(_ column: Int32) -> Bool { sqlite3_column_int64(statement, column) != 0 }

    public func text(_ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    public func optionalText(_ column: Int32) -> String? { isNull(column) ? nil : text(column) }
    public func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : double(column) }
    public func optionalInt(_ column: Int32) -> Int? { isNull(column) ? nil : int(column) }
    public func optionalInt64(_ column: Int32) -> Int64? { isNull(column) ? nil : int64(column) }
}

public final class SQLiteConnection {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

    public convenience init(snapshot data: Data) throws {
        try self.init(path: ":memory:")
        var bytes = [UInt8](data)
        if bytes.count >= 100, bytes[18] == 2, bytes[19] == 2 {
            bytes[18] = 1
            bytes[19] = 1
        }
        guard let buffer = sqlite3_malloc64(sqlite3_uint64(max(bytes.count, 1))) else {
            throw SQLiteError(code: SQLITE_NOMEM, message: "out of memory")
        }
        bytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress { buffer.copyMemory(from: base, byteCount: raw.count) }
        }
        let status = sqlite3_deserialize(handle, "main", buffer.assumingMemoryBound(to: UInt8.self),
                                         sqlite3_int64(bytes.count), sqlite3_int64(bytes.count),
                                         UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_READONLY))
        guard status == SQLITE_OK else { throw SQLiteError(code: status, message: lastErrorMessage) }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
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

    public func run(_ sql: String, _ values: [any SQLiteBindable] = []) throws {
        try withStatement(sql, values) { statement in
            while try step(statement) {}
        }
    }

    public func query<T>(_ sql: String, _ values: [any SQLiteBindable] = [], _ row: (SQLiteRow) throws -> T) throws -> [T] {
        try withStatement(sql, values) { statement in
            var result: [T] = []
            while try step(statement) { result.append(try row(SQLiteRow(statement: statement))) }
            return result
        }
    }

    public func queryOne<T>(_ sql: String, _ values: [any SQLiteBindable] = [], _ row: (SQLiteRow) throws -> T) throws -> T? {
        try withStatement(sql, values) { statement in
            try step(statement) ? try row(SQLiteRow(statement: statement)) : nil
        }
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func userVersion() throws -> Int {
        try queryOne("PRAGMA user_version") { $0.int(0) } ?? 0
    }

    public func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }

    private func withStatement<T>(_ sql: String, _ values: [any SQLiteBindable], _ body: (OpaquePointer) throws -> T) throws -> T {
        let statement = try prepared(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value.sqliteValue {
            case .null: status = sqlite3_bind_null(statement, index)
            case .integer(let number): status = sqlite3_bind_int64(statement, index, number)
            case .real(let number): status = sqlite3_bind_double(statement, index, number)
            case .text(let text): status = sqlite3_bind_text(statement, index, text, -1, Self.transient)
            }
            guard status == SQLITE_OK else { throw SQLiteError(code: status, message: lastErrorMessage) }
        }
        return try body(statement)
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] { return cached }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw SQLiteError(code: status, message: lastErrorMessage)
        }
        statements[sql] = statement
        return statement
    }

    private func step(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        case let status: throw SQLiteError(code: status, message: lastErrorMessage)
        }
    }

    private var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
    }
}
