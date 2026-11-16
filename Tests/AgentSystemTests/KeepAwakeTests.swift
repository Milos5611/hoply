import AgentSystem
import Foundation
import IOKit.pwr_mgt
import XCTest

final class KeepAwakeTests: XCTestCase {
    private func assertionNames() -> [String] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let mine = all[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []
        return mine.compactMap { $0[kIOPMAssertionNameKey] as? String }
    }

    func testBeginAndEndAreIdempotent() {
        let reason = "Hoply test \(UUID().uuidString)"
        let awake = KeepAwake(reason: reason)
        XCTAssertFalse(awake.isActive)
        XCTAssertTrue(awake.begin())
        XCTAssertTrue(awake.begin())
        XCTAssertTrue(awake.isActive)
        XCTAssertEqual(assertionNames().filter { $0 == reason }.count, 1)
        awake.end()
        awake.end()
        XCTAssertFalse(awake.isActive)
        XCTAssertEqual(assertionNames().filter { $0 == reason }, [])
    }

    func testReleasedWhenDropped() {
        let reason = "Hoply test \(UUID().uuidString)"
        var awake: KeepAwake? = KeepAwake(reason: reason)
        awake?.begin()
        XCTAssertEqual(assertionNames().filter { $0 == reason }.count, 1)
        awake = nil
        XCTAssertEqual(assertionNames().filter { $0 == reason }, [])
        XCTAssertEqual(KeepAwake().reason, "Hoply Away mode")
    }
}
