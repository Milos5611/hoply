import AgentKit
import Foundation
import XCTest

final class RemoteRetryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testBackoffDoublesFromFiveSecondsUpToFiveMinutes() {
        XCTAssertEqual(RemoteRetry.backoff(after: 0), 5)
        XCTAssertEqual(RemoteRetry.backoff(after: 1), 5)
        XCTAssertEqual(RemoteRetry.backoff(after: 2), 10)
        XCTAssertEqual(RemoteRetry.backoff(after: 3), 20)
        XCTAssertEqual(RemoteRetry.backoff(after: 6), 160)
        XCTAssertEqual(RemoteRetry.backoff(after: 7), 300)
        XCTAssertEqual(RemoteRetry.backoff(after: 50), 300)
    }

    func testFailuresWaitLongerUntilASuccessResets() {
        var retry = RemoteRetry()
        XCTAssertFalse(retry.isWaiting(at: t0))
        retry.failed(now: t0)
        XCTAssertEqual(retry.retryAt, t0 + 5)
        XCTAssertTrue(retry.isWaiting(at: t0 + 4.9))
        XCTAssertFalse(retry.isWaiting(at: t0 + 5))
        retry.failed(now: t0 + 5)
        XCTAssertEqual(retry.retryAt, t0 + 15)
        XCTAssertEqual(retry.failures, 2)
        retry.succeeded()
        XCTAssertEqual(retry, RemoteRetry())
        retry.failed(now: t0 + 20)
        XCTAssertEqual(retry.retryAt, t0 + 25)
    }

    func testRetryAfterIsHonouredButNeverShortensTheBackoff() {
        var retry = RemoteRetry()
        retry.failed(retryAfter: 42, now: t0)
        XCTAssertEqual(retry.retryAt, t0 + 42)
        retry.failed(retryAfter: 1, now: t0 + 42)
        XCTAssertEqual(retry.retryAt, t0 + 52)
    }

    func testWatchingPollsFastOnlyWhileTranscriptsAreNotBackingOff() {
        var retry = RemoteRetry()
        let poll = RemoteTranscriptPolicy.pollInterval
        XCTAssertEqual(poll(0, false, retry, t0), RemoteLinkPolicy.pollIdle)
        XCTAssertEqual(poll(0, true, retry, t0), RemoteLinkPolicy.pollWhileOpen)
        retry.failed(now: t0)
        XCTAssertEqual(poll(0, true, retry, t0 + 1), RemoteLinkPolicy.pollIdle)
        XCTAssertEqual(poll(2, true, retry, t0 + 1), RemoteLinkPolicy.pollWhileOpen)
        XCTAssertEqual(poll(0, true, retry, t0 + 5), RemoteLinkPolicy.pollWhileOpen)
    }

    func testWaitWakesForRefreshesButNotBeforeTheTranscriptRetry() {
        var retry = RemoteRetry()
        let wait = RemoteTranscriptPolicy.wait
        XCTAssertEqual(wait(55, false, retry, t0), 55)
        XCTAssertEqual(wait(55, true, retry, t0), RemoteTranscriptPolicy.refreshEvery)
        XCTAssertEqual(wait(3, true, retry, t0), 3)
        for _ in 0..<4 { retry.failed(now: t0) }
        XCTAssertEqual(retry.retryAt, t0 + 40)
        XCTAssertEqual(wait(55, true, retry, t0), 40)
        XCTAssertEqual(wait(30, true, retry, t0), 30)
        XCTAssertEqual(wait(3, true, retry, t0), 3)
        XCTAssertEqual(wait(55, true, retry, t0 + 40), RemoteTranscriptPolicy.refreshEvery)
    }
}
