import AgentSystem
import Foundation
import XCTest

final class SQLiteConnectionTests: XCTestCase {
    func testInMemoryExecuteAndUserVersion() throws {
        let db = try SQLiteConnection(path: ":memory:")
        XCTAssertEqual(try db.userVersion(), 0)
        try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t (name) VALUES ('a');")
        try db.setUserVersion(3)
        XCTAssertEqual(try db.userVersion(), 3)
    }

    func testInvalidSQLThrows() throws {
        let db = try SQLiteConnection(path: ":memory:")
        XCTAssertThrowsError(try db.execute("SELEKT 1")) { error in
            XCTAssertEqual((error as? SQLiteError)?.code, 1)
        }
    }

    func testReadOnlyOpenOfMissingFileFails() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoply-missing-\(UUID().uuidString).sqlite").path
        XCTAssertThrowsError(try SQLiteConnection(path: path, readOnly: true))
    }
}
