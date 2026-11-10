import AgentKit
import Foundation
import XCTest

final class UpdateFeedTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32).base64EncodedString()
    private let feed = "https://github.com/owner/hoply/releases/latest/download/appcast.xml"

    func testReleaseBuildKeys() {
        let update = UpdateFeed(info: ["SUFeedURL": feed, "SUPublicEDKey": key])
        XCTAssertEqual(update?.url.absoluteString, feed)
        XCTAssertEqual(update?.publicKey, key)
    }

    func testSourceBuildHasNoFeed() {
        XCTAssertNil(UpdateFeed(info: ["SUEnableAutomaticChecks": true]))
        XCTAssertNil(UpdateFeed(info: ["SUFeedURL": feed]))
        XCTAssertNil(UpdateFeed(info: ["SUPublicEDKey": key]))
        XCTAssertNil(UpdateFeed(info: ["SUFeedURL": "", "SUPublicEDKey": ""]))
    }

    func testRejectsPlainHTTPAndMalformedKeys() {
        XCTAssertNil(UpdateFeed(info: ["SUFeedURL": "http://example.com/appcast.xml", "SUPublicEDKey": key]))
        XCTAssertNil(UpdateFeed(info: ["SUFeedURL": "https:///appcast.xml", "SUPublicEDKey": key]))
        XCTAssertNil(UpdateFeed(info: ["SUFeedURL": feed, "SUPublicEDKey": "not base64"]))
        XCTAssertNil(UpdateFeed(info: ["SUFeedURL": feed,
                                       "SUPublicEDKey": Data(repeating: 7, count: 64).base64EncodedString()]))
        XCTAssertNil(UpdateFeed(info: ["SUFeedURL": feed, "SUPublicEDKey": 42]))
    }
}
