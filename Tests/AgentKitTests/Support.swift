import Foundation
import XCTest

enum Fixture {
    static func data(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
                                "Missing fixture \(name)", file: file, line: line)
        return try Data(contentsOf: url)
    }

    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }

    static func object(_ name: String) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: try data(name))
        return try XCTUnwrap(value as? [String: Any])
    }

    /// A fixture file holding a dictionary of named hook payloads.
    static func hookPayloads(_ name: String) throws -> [String: [String: Any]] {
        let root = try object(name)
        var result: [String: [String: Any]] = [:]
        for (key, value) in root {
            result[key] = value as? [String: Any]
        }
        return result
    }
}
