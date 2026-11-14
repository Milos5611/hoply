import AgentKit
import Foundation
import XCTest

final class UpdateFeedHealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let domain = "SUSparkleErrorDomain"

    private func sparkle(_ code: Int, _ description: String = "", cause: NSError? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: description]
        if let cause { info[NSUnderlyingErrorKey] = cause }
        return NSError(domain: domain, code: code, userInfo: info)
    }

    private func feedDownload(cause: NSError) -> NSError {
        sparkle(2001, "An error occurred in retrieving update information. Please try again later.",
                cause: sparkle(2001, "An error occurred while downloading the update. Please try again later.", cause: cause))
    }

    private var notFound: NSError {
        feedDownload(cause: sparkle(2001, "A network error occurred while downloading https://hoply.dev/appcast.xml. not found (404)"))
    }

    private func transport(_ code: URLError.Code = .notConnectedToInternet) -> NSError {
        feedDownload(cause: sparkle(2001, "Failed to download temporary data.",
                                    cause: NSError(domain: NSURLErrorDomain, code: code.rawValue)))
    }

    private var badSignature: NSError {
        sparkle(1000, "The update feed is improperly signed and could not be validated.",
                cause: sparkle(3002, "EdDSA and DSA verification for the appcast has failed"))
    }

    func testFeedLevelErrorsAreProblems() {
        XCTAssertEqual(UpdateFeedHealth.problem(for: notFound), .unavailable)
        XCTAssertEqual(UpdateFeedHealth.problem(for: badSignature), .badSignature)
        XCTAssertEqual(UpdateFeedHealth.problem(for: sparkle(1000, "An error occurred while parsing the update feed.",
                                                            cause: NSError(domain: XMLParser.errorDomain, code: 4))),
                       .unreadable)
        XCTAssertEqual(UpdateFeedHealth.problem(for: sparkle(1000)), .unreadable)
        XCTAssertEqual(UpdateFeedHealth.problem(for: sparkle(4, "Sparkle cannot form a valid feed URL.")), .misconfigured)
        XCTAssertEqual(UpdateFeedHealth.problem(for: transport(.httpTooManyRedirects)), .unavailable)
    }

    func testNoUpdateNetworkAndInstallErrorsAreNot() {
        XCTAssertNil(UpdateFeedHealth.problem(for: sparkle(1001, "You're up to date!")))
        XCTAssertNil(UpdateFeedHealth.problem(for: transport()))
        XCTAssertNil(UpdateFeedHealth.problem(for: transport(.timedOut)))
        XCTAssertNil(UpdateFeedHealth.problem(for: transport(.cannotFindHost)))
        XCTAssertNil(UpdateFeedHealth.problem(for: transport(.serverCertificateUntrusted)))
        XCTAssertNil(UpdateFeedHealth.problem(for: sparkle(4007)))
        XCTAssertNil(UpdateFeedHealth.problem(for: sparkle(3001)))
        XCTAssertNil(UpdateFeedHealth.problem(for: NSError(domain: NSURLErrorDomain, code: 404)))
    }

    func testStreakStartsAtFirstFailureAndClearsOnLoadedFeed() {
        var health = UpdateFeedHealth()
        health.checkFailed(notFound, at: now)
        health.cycleEnded()
        XCTAssertEqual(health.failure?.problem, .unavailable)
        XCTAssertEqual(health.failure?.since, now)
        XCTAssertEqual(health.failure?.detail,
                       "A network error occurred while downloading https://hoply.dev/appcast.xml. not found (404)")

        health.checkFailed(transport(), at: now + 1_800)
        health.cycleEnded()
        health.checkFailed(badSignature, at: now + 3_600)
        health.cycleEnded()
        XCTAssertEqual(health.failure?.problem, .badSignature)
        XCTAssertEqual(health.failure?.since, now)
        XCTAssertEqual(health.failure?.last, now + 3_600)

        health.appcastLoaded(verified: true)
        health.cycleEnded()
        XCTAssertNil(health.failure)
        health.checkFailed(notFound, at: now + 7_200)
        XCTAssertEqual(health.failure?.since, now + 7_200)
    }

    func testNetworkFailureNeverStartsAStreak() {
        var health = UpdateFeedHealth()
        health.checkFailed(transport(), at: now)
        health.checkFailed(sparkle(1001), at: now)
        XCTAssertNil(health.failure)
    }

    func testDownloadErrorAfterTheFeedLoadedIsTheArchive() {
        var health = UpdateFeedHealth()
        health.appcastLoaded(verified: true)
        health.checkFailed(feedDownload(cause: sparkle(2001, "not found (404)")), at: now)
        XCTAssertNil(health.failure)
        health.cycleEnded()
        health.checkFailed(notFound, at: now + 3_600)
        XCTAssertEqual(health.failure?.since, now + 3_600)
    }

    func testUnverifiedFeedInSafeModeKeepsTheStreak() {
        var health = UpdateFeedHealth(failure: UpdateFeedFailure(problem: .badSignature, since: now, last: now,
                                                                detail: ""))
        health.appcastLoaded(verified: false)
        health.checkFailed(badSignature, at: now + 86_400 * 20)
        XCTAssertEqual(health.failure?.since, now)
        XCTAssertEqual(health.failure?.last, now + 86_400 * 20)
    }

    func testSavedFailureDecodesTolerantly() throws {
        let failure = UpdateFeedFailure(problem: .unavailable, since: now, last: now + 60, detail: "404")
        XCTAssertEqual(UpdateFeedFailure.decoded(failure.encoded()), failure)

        let since = now.timeIntervalSinceReferenceDate
        let minimal = try XCTUnwrap(#"{"problem":"badSignature","since":\#(since),"last":"x"}"#.data(using: .utf8))
        XCTAssertEqual(UpdateFeedFailure.decoded(minimal),
                       UpdateFeedFailure(problem: .badSignature, since: now, last: now, detail: ""))

        XCTAssertNil(UpdateFeedFailure.decoded(#"{"problem":"later","since":0}"#.data(using: .utf8)))
        XCTAssertNil(UpdateFeedFailure.decoded(Data("garbage".utf8)))
        XCTAssertNil(UpdateFeedFailure.decoded(nil))
    }
}
