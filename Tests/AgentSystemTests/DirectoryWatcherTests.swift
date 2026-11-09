import AgentSystem
import Foundation
import XCTest

final class DirectoryWatcherTests: XCTestCase {
    func testReportsChangedFiles() async throws {
        let directory = try TempDirectory()
        try directory.mkdir("projects/-a")
        let root = URL(fileURLWithPath: directory.path("projects")).resolvingSymlinksInPath().path
        let seen = Locked<[String]>([])
        let watcher = DirectoryWatcher(paths: [root], latency: 0.1) { paths in seen.mutate { $0 += paths } }
        XCTAssertTrue(watcher.start())
        try await Task.sleep(for: .milliseconds(200))
        try directory.write("projects/-a/s.jsonl", "x\n")
        for _ in 0..<100 where !seen.value.contains(where: { $0.hasSuffix(".jsonl") }) { try await Task.sleep(for: .milliseconds(50)) }
        print("FSEvents paths:", seen.value)
        watcher.stop()
        XCTAssertTrue(seen.value.contains { $0.hasSuffix("/projects/-a/s.jsonl") })
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}
