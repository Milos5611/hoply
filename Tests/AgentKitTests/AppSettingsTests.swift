import AgentKit
import Foundation
import XCTest

final class AppSettingsTests: XCTestCase {
    /// The exact shape v1 wrote to UserDefaults under "HoplySettings".
    private let v1JSON = #"{"port":4400,"vllmBaseURL":"http://10.0.0.5:8000","vllmName":"ZGX","claudeLimitsEnabled":true,"notificationsEnabled":false}"#

    func testV1SettingsStillDecode() {
        let settings = AppSettings.decode(Data(v1JSON.utf8))
        XCTAssertEqual(settings.port, 4400)
        XCTAssertEqual(settings.vllmBaseURL, "http://10.0.0.5:8000")
        XCTAssertEqual(settings.vllmName, "ZGX")
        XCTAssertTrue(settings.claudeLimitsEnabled)
        XCTAssertFalse(settings.notificationsEnabled)
    }

    func testMissingKeysKeepDefaults() {
        let settings = AppSettings.decode(Data(#"{"vllmName":"ZGX"}"#.utf8))
        var expected = AppSettings()
        expected.vllmName = "ZGX"
        XCTAssertEqual(settings, expected)
    }

    func testUnknownKeysAndWrongTypesOnlyResetThatField() {
        let json = #"{"port":"not a number","vllmName":"ZGX","futureSetting":{"a":1},"claudeLimitsEnabled":true}"#
        let settings = AppSettings.decode(Data(json.utf8))
        XCTAssertEqual(settings.port, 4318)
        XCTAssertEqual(settings.vllmName, "ZGX")
        XCTAssertTrue(settings.claudeLimitsEnabled)
    }

    func testCopilotHomeDecodesLenientlyAndRoundTrips() {
        XCTAssertEqual(AppSettings.decode(Data(v1JSON.utf8)).copilotHome, "", "older settings mean the default")
        XCTAssertEqual(AppSettings.decode(Data(#"{"copilotHome":42,"vllmName":"ZGX"}"#.utf8)).copilotHome, "")
        XCTAssertEqual(AppSettings.decode(Data(#"{"copilotHome":42,"vllmName":"ZGX"}"#.utf8)).vllmName, "ZGX")
        var settings = AppSettings()
        settings.copilotHome = "~/scratch/copilot"
        XCTAssertEqual(AppSettings.decode(settings.encoded()).copilotHome, "~/scratch/copilot")
    }

    func testGarbageOrMissingDataGivesDefaults() {
        XCTAssertEqual(AppSettings.decode(nil), AppSettings())
        XCTAssertEqual(AppSettings.decode(Data("[1,2".utf8)), AppSettings())
    }

    func testRoundTrip() {
        var settings = AppSettings()
        settings.port = 5000
        settings.vllmBaseURL = "https://zgx.example.com"
        settings.notificationsEnabled = false
        XCTAssertEqual(AppSettings.decode(settings.encoded()), settings)
    }
}
