import AgentKit
import Foundation
import XCTest

final class HistorySyncHealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func cloudKit(_ code: Int) -> NSError {
        NSError(domain: "CKErrorDomain", code: code)
    }

    private func partial(_ codes: [Int]) -> NSError {
        var items: [AnyHashable: Any] = [:]
        for (index, code) in codes.enumerated() { items["r\(index)"] = cloudKit(code) }
        return NSError(domain: "CKErrorDomain", code: 2, userInfo: ["CKPartialErrors": items])
    }

    func testRejectedRequestsAreTheirOwnCategory() {
        for code in [10, 11, 12, 15] {
            XCTAssertEqual(HistorySyncHealth.problem(for: cloudKit(code)), .rejected, "CKError \(code)")
        }
        XCTAssertEqual(HistorySyncHealth.problem(for: partial([22, 15, 22])), .rejected,
                       "batchRequestFailed only points at the record the server rejected")
    }

    func testOtherFailuresCount() {
        XCTAssertEqual(HistorySyncHealth.problem(for: cloudKit(1)), .other, "internalError")
        XCTAssertEqual(HistorySyncHealth.problem(for: cloudKit(14)), .other, "serverRecordChanged")
        XCTAssertEqual(HistorySyncHealth.problem(for: partial([22])), .other)
        XCTAssertEqual(HistorySyncHealth.problem(for: partial([1, 15])), .rejected)
        XCTAssertEqual(HistorySyncHealth.problem(for: NSError(domain: NSCocoaErrorDomain, code: 513)), .other,
                       "a ledger or file error stops history too")
    }

    func testErrorsTheLinkShowsOrConnectivityNeverCount() {
        let never = [3, 4, 34, 5, 8, 6, 7, 23, 9, 32, 36, 25]
        for code in never {
            XCTAssertNil(HistorySyncHealth.problem(for: cloudKit(code)), "CKError \(code)")
        }
        XCTAssertNil(HistorySyncHealth.problem(for: partial([22, 25])), "a full iCloud inside a batch")
        XCTAssertNil(HistorySyncHealth.problem(for: partial([15, 4])), "the link's error outranks the rejection")
        XCTAssertNil(HistorySyncHealth.problem(for: NSError(domain: NSURLErrorDomain,
                                                            code: URLError.notConnectedToInternet.rawValue)))

        var health = HistorySyncHealth()
        for code in never { health.failed(.publish, error: cloudKit(code), at: now) }
        XCTAssertNil(health.failure)
    }

    func testTheFirstFailureOfTheRunStaysUntilASuccess() {
        var health = HistorySyncHealth()
        XCTAssertNil(health.failure)
        XCTAssertEqual(health.failed(.publish, error: cloudKit(15), at: now), .rejected)
        XCTAssertEqual(health.failure, HistorySyncFailure(operation: .publish, problem: .rejected, since: now, last: now))

        health.failed(.publish, error: cloudKit(4), at: now + 60)
        XCTAssertEqual(health.failure?.last, now, "a network error neither counts nor clears")
        health.failed(.publish, error: cloudKit(1), at: now + 120)
        XCTAssertEqual(health.failure, HistorySyncFailure(operation: .publish, problem: .other, since: now,
                                                          last: now + 120))

        health.succeeded(.publish)
        XCTAssertNil(health.failure)
        health.failed(.publish, error: cloudKit(15), at: now + 600)
        XCTAssertEqual(health.failure?.since, now + 600)
    }

    func testPublishAndFetchAreTrackedApart() {
        var health = HistorySyncHealth()
        health.failed(.fetch, error: cloudKit(11), at: now)
        health.failed(.publish, error: cloudKit(15), at: now + 30)
        XCTAssertEqual(health.failure?.operation, .fetch, "the older failure is the one shown")
        XCTAssertEqual(health.failure(of: .publish)?.since, now + 30)

        health.succeeded(.publish)
        XCTAssertNil(health.publish)
        XCTAssertEqual(health.fetch, HistorySyncFailure(operation: .fetch, problem: .rejected, since: now, last: now))

        health.failed(.publish, error: cloudKit(15), at: now + 60)
        health.succeeded(.fetch)
        XCTAssertEqual(health.failure?.operation, .publish)
        XCTAssertEqual(health.failure?.since, now + 60)
    }
}
