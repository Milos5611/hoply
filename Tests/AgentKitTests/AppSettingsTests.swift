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

    func testNotificationAndAllowanceKeysDecodeLeniently() {
        let older = AppSettings.decode(Data(v1JSON.utf8))
        XCTAssertFalse(older.quietHoursEnabled)
        XCTAssertEqual(older.quietHoursStart, 1320)
        XCTAssertEqual(older.quietHoursEnd, 480)
        XCTAssertEqual(older.mutedProjectRoots, [])
        XCTAssertTrue(older.limitAlertsEnabled)
        XCTAssertTrue(older.localModelAlertsEnabled)
        XCTAssertEqual(older.copilotMonthlyAllowance, 300)
        XCTAssertEqual(older.copilotUSDPerPremiumRequest, 0.04)
        XCTAssertEqual(older.port, 4400, "older keys survive")

        let wrong = #"{"quietHoursEnabled":"yes","quietHoursStart":"22:00","mutedProjectRoots":"/r/fiba","limitAlertsEnabled":1.5,"copilotMonthlyAllowance":"1500","copilotUSDPerPremiumRequest":"cheap","quietHoursEnd":420,"vllmName":"ZGX"}"#
        let settings = AppSettings.decode(Data(wrong.utf8))
        XCTAssertFalse(settings.quietHoursEnabled)
        XCTAssertEqual(settings.quietHoursStart, 1320)
        XCTAssertEqual(settings.quietHoursEnd, 420)
        XCTAssertEqual(settings.mutedProjectRoots, [])
        XCTAssertTrue(settings.limitAlertsEnabled)
        XCTAssertEqual(settings.copilotMonthlyAllowance, 300)
        XCTAssertEqual(settings.copilotUSDPerPremiumRequest, 0.04)
        XCTAssertEqual(settings.vllmName, "ZGX")
        XCTAssertEqual(AppSettings.decode(Data(#"{"copilotUSDPerPremiumRequest":1}"#.utf8)).copilotUSDPerPremiumRequest, 1,
                       "a whole-number price is still a price")

        var changed = AppSettings()
        changed.quietHoursEnabled = true
        changed.quietHoursStart = 23 * 60
        changed.quietHoursEnd = 6 * 60 + 30
        changed.mutedProjectRoots = ["/r/fiba", "/r/api"]
        changed.limitAlertsEnabled = false
        changed.localModelAlertsEnabled = false
        changed.copilotMonthlyAllowance = 0
        changed.copilotUSDPerPremiumRequest = 0.1
        XCTAssertEqual(AppSettings.decode(changed.encoded()), changed)
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
