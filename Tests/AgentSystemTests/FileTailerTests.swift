import AgentSystem
import Foundation
import XCTest

final class FileTailerTests: XCTestCase {
    private func lines(_ chunk: TailChunk?) -> [String] {
        (chunk?.lines ?? []).map { String(decoding: $0, as: UTF8.self) }
    }

    func testAppendReadsOnlyCompleteLines() throws {
        let directory = try TempDirectory()
        let path = try directory.write("t.jsonl", "one\ntw")
        let first = try XCTUnwrap(FileTailer.read(path: path, from: nil))
        XCTAssertEqual(lines(first), ["one"])
        XCTAssertEqual(first.cursor.offset, 4)
        XCTAssertEqual(first.startOffset, 0)
        XCTAssertTrue(first.atEnd)

        let unchanged = try XCTUnwrap(FileTailer.read(path: path, from: first.cursor))
        XCTAssertEqual(lines(unchanged), [])
        XCTAssertEqual(unchanged.cursor, first.cursor)

        try directory.append("t.jsonl", "o\r\nthree\n\n")
        let second = try XCTUnwrap(FileTailer.read(path: path, from: first.cursor))
        XCTAssertEqual(lines(second), ["two", "three"])
        XCTAssertEqual(second.startOffset, 4)
        XCTAssertFalse(second.didReset)
        XCTAssertEqual(second.cursor.offset, Int64("one\ntwo\r\nthree\n\n".utf8.count))
    }

    func testTruncationRereadsFromTheStart() throws {
        let directory = try TempDirectory()
        let path = try directory.write("t.jsonl", "aaaa\nbbbb\ncccc\n")
        let first = try XCTUnwrap(FileTailer.read(path: path, from: nil))
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try handle.truncate(atOffset: 5)
        try handle.close()
        let after = try XCTUnwrap(FileTailer.read(path: path, from: first.cursor))
        XCTAssertTrue(after.didReset)
        XCTAssertEqual(after.startOffset, 0)
        XCTAssertEqual(lines(after), ["aaaa"])
    }

    func testRotationRereadsFromTheStart() throws {
        let directory = try TempDirectory()
        let path = try directory.write("t.jsonl", "old line\n")
        let first = try XCTUnwrap(FileTailer.read(path: path, from: nil))
        let replacement = try directory.write("next.jsonl", "old line\nnew line\n")
        XCTAssertEqual(rename(replacement, path), 0)
        let after = try XCTUnwrap(FileTailer.read(path: path, from: first.cursor))
        XCTAssertNotEqual(after.cursor.inode, first.cursor.inode)
        XCTAssertTrue(after.didReset)
        XCTAssertEqual(lines(after), ["old line", "new line"])
    }

    func testRewrittenHeadRereadsFromTheStart() throws {
        let directory = try TempDirectory()
        let path = try directory.write("t.jsonl", "first\n")
        let first = try XCTUnwrap(FileTailer.read(path: path, from: nil))
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try handle.write(contentsOf: Data("FIRST\nsecond\n".utf8))
        try handle.close()
        let after = try XCTUnwrap(FileTailer.read(path: path, from: first.cursor))
        XCTAssertEqual(after.cursor.inode, first.cursor.inode)
        XCTAssertTrue(after.didReset)
        XCTAssertEqual(lines(after), ["FIRST", "second"])
    }

    func testChunksAndLinesLongerThanTheChunk() throws {
        let directory = try TempDirectory()
        let long = String(repeating: "x", count: 20)
        let longer = String(repeating: "y", count: 50)
        let path = try directory.write("t.jsonl", "\(long)\n\(longer)\nz\n")
        let first = try XCTUnwrap(FileTailer.read(path: path, from: nil, maxBytes: 8))
        XCTAssertEqual(lines(first), [long], "the read grows until one line fits, then stops")
        XCTAssertFalse(first.atEnd)
        let second = try XCTUnwrap(FileTailer.read(path: path, from: first.cursor, maxBytes: 8))
        XCTAssertEqual(lines(second), [longer, "z"])
        XCTAssertTrue(second.atEnd)
        XCTAssertEqual(second.cursor.offset, 74)
    }

    func testMissingFilesAndDirectories() throws {
        let directory = try TempDirectory()
        XCTAssertNil(try FileTailer.read(path: directory.path("missing.jsonl"), from: nil))
        XCTAssertNil(FileTailer.status(of: directory.url.path))
        try directory.write("a.jsonl", "x\n")
        XCTAssertEqual(FileTailer.status(of: directory.path("a.jsonl"))?.size, 2)
    }
}
