import AgentKit
import Foundation
import XCTest

final class AppSettingsTests: XCTestCase {
    /// The exact shape v1 wrote to UserDefaults under "HoplySettings".
    private let v1JSON = #"{"port":4400,"vllmBaseURL":"http://10.0.0.5:8000","vllmName":"ZGX","claudeLimitsEnabled":true,"notificationsEnabled":false}"#

    func testTurnNotificationDelayDecodesLeniently() {
        XCTAssertEqual(AppSettings.decode(Data(v1JSON.utf8)).turnNotificationDelay, 10, "older settings mean the default")
        XCTAssertEqual(AppSettings.decode(Data(#"{"turnNotificationDelay":0}"#.utf8)).turnNotificationDelay, 0)
        XCTAssertEqual(AppSettings.decode(Data(#"{"turnNotificationDelay":120}"#.utf8)).turnNotificationDelay, 120)
        XCTAssertEqual(AppSettings.decode(Data(#"{"turnNotificationDelay":45}"#.utf8)).turnNotificationDelay, 10)
        XCTAssertEqual(AppSettings.decode(Data(#"{"turnNotificationDelay":-1}"#.utf8)).turnNotificationDelay, 10)
        let wrong = AppSettings.decode(Data(#"{"turnNotificationDelay":"30","port":4400}"#.utf8))
        XCTAssertEqual(wrong.turnNotificationDelay, 10)
        XCTAssertEqual(wrong.port, 4400)
        XCTAssertEqual(AppSettings.turnNotificationDelays, [0, 10, 30, 60, 120])
        var settings = AppSettings()
        settings.turnNotificationDelay = 30
        XCTAssertEqual(AppSettings.decode(settings.encoded()).turnNotificationDelay, 30)
    }

    func testV1SettingsStillDecode() {
        let settings = AppSettings.decode(Data(v1JSON.utf8))
        XCTAssertEqual(settings.port, 4400)
        XCTAssertEqual(settings.legacyModelServer?.baseURL, "http://10.0.0.5:8000")
        XCTAssertEqual(settings.legacyModelServer?.name, "ZGX")
        XCTAssertTrue(settings.claudeLimitsEnabled)
        XCTAssertFalse(settings.notificationsEnabled)
    }

    func testMissingKeysKeepDefaults() {
        let settings = AppSettings.decode(Data(#"{"vllmName":"ZGX"}"#.utf8))
        var expected = AppSettings()
        expected.modelServers = [ModelServer(id: ModelServer.legacyID, name: "ZGX")]
        XCTAssertEqual(settings, expected)
    }

    func testUnknownKeysAndWrongTypesOnlyResetThatField() {
        let json = #"{"port":"not a number","vllmName":"ZGX","futureSetting":{"a":1},"claudeLimitsEnabled":true}"#
        let settings = AppSettings.decode(Data(json.utf8))
        XCTAssertEqual(settings.port, 4318)
        XCTAssertEqual(settings.legacyModelServer?.name, "ZGX")
        XCTAssertTrue(settings.claudeLimitsEnabled)
    }

    func testCopilotHomeDecodesLenientlyAndRoundTrips() {
        XCTAssertEqual(AppSettings.decode(Data(v1JSON.utf8)).copilotHome, "", "older settings mean the default")
        XCTAssertEqual(AppSettings.decode(Data(#"{"copilotHome":42,"vllmName":"ZGX"}"#.utf8)).copilotHome, "")
        XCTAssertEqual(AppSettings.decode(Data(#"{"copilotHome":42,"vllmName":"ZGX"}"#.utf8)).legacyModelServer?.name, "ZGX")
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

        let wrong = #"{"quietHoursEnabled":"yes","quietHoursStart":"22:00","mutedProjectRoots":"/r/corestory","limitAlertsEnabled":1.5,"copilotMonthlyAllowance":"1500","copilotUSDPerPremiumRequest":"cheap","quietHoursEnd":420,"vllmName":"ZGX"}"#
        let settings = AppSettings.decode(Data(wrong.utf8))
        XCTAssertFalse(settings.quietHoursEnabled)
        XCTAssertEqual(settings.quietHoursStart, 1320)
        XCTAssertEqual(settings.quietHoursEnd, 420)
        XCTAssertEqual(settings.mutedProjectRoots, [])
        XCTAssertTrue(settings.limitAlertsEnabled)
        XCTAssertEqual(settings.copilotMonthlyAllowance, 300)
        XCTAssertEqual(settings.copilotUSDPerPremiumRequest, 0.04)
        XCTAssertEqual(settings.legacyModelServer?.name, "ZGX")
        XCTAssertEqual(AppSettings.decode(Data(#"{"copilotUSDPerPremiumRequest":1}"#.utf8)).copilotUSDPerPremiumRequest, 1,
                       "a whole-number price is still a price")

        var changed = AppSettings()
        changed.quietHoursEnabled = true
        changed.quietHoursStart = 23 * 60
        changed.quietHoursEnd = 6 * 60 + 30
        changed.mutedProjectRoots = ["/r/corestory", "/r/api"]
        changed.limitAlertsEnabled = false
        changed.localModelAlertsEnabled = false
        changed.copilotMonthlyAllowance = 0
        changed.copilotUSDPerPremiumRequest = 0.1
        XCTAssertEqual(AppSettings.decode(changed.encoded()), changed)
    }

    func testDroppedSparkDashKeysStillDecodeAndAreNotWritten() throws {
        let saved = #"{"port":4400,"sparkDashURL":"http://192.168.40.141:5555","sparkDashName":"zgx-ff24","energyPricePerKWh":0.31,"vllmName":"ZGX","notificationsEnabled":false}"#
        let settings = AppSettings.decode(Data(saved.utf8))
        XCTAssertEqual(settings.port, 4400)
        XCTAssertFalse(settings.notificationsEnabled)
        XCTAssertEqual(settings.legacyModelServer?.name, "ZGX")

        let wrong = #"{"sparkDashURL":5555,"sparkDashName":["zgx"],"energyPricePerKWh":"0.30","port":4400}"#
        XCTAssertEqual(AppSettings.decode(Data(wrong.utf8)).port, 4400)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(settings.encoded())) as? [String: Any])
        for key in ["sparkDashURL", "sparkDashName", "energyPricePerKWh"] { XCTAssertNil(json[key], key) }
        XCTAssertEqual(AppSettings.decode(settings.encoded()), settings)
    }

    func testGarbageOrMissingDataGivesDefaults() {
        XCTAssertEqual(AppSettings.decode(nil), AppSettings())
        XCTAssertEqual(AppSettings.decode(Data("[1,2".utf8)), AppSettings())
    }

    func testRoundTrip() {
        var settings = AppSettings()
        settings.port = 5000
        settings.modelServers = [ModelServer(id: ModelServer.legacyID, baseURL: "https://zgx.example.com"),
                                 ModelServer(id: "a1", name: "Ollama", baseURL: "http://localhost:11434")]
        settings.notificationsEnabled = false
        XCTAssertEqual(AppSettings.decode(settings.encoded()), settings)
    }

    func testPriceAliasesDecodeLeniently() throws {
        var settings = AppSettings()
        settings.priceAliases = ["claude-opus-4-5": "claude-opus-4-6"]
        XCTAssertEqual(AppSettings.decode(settings.encoded()).priceAliases, ["claude-opus-4-5": "claude-opus-4-6"])
        XCTAssertEqual(AppSettings.decode(Data(#"{"port": 5000}"#.utf8)).priceAliases, [:])
        let wrong = AppSettings.decode(Data(#"{"port": 5000, "priceAliases": ["a", "b"]}"#.utf8))
        XCTAssertEqual(wrong.priceAliases, [:])
        XCTAssertEqual(wrong.port, 5000)
    }

    func testCustomPricesDecodeLeniently() throws {
        var settings = AppSettings()
        XCTAssertEqual(settings.customPrices, [:])
        settings.customPrices = ["claude-nova-1": CustomModelPrice(input: 2, output: 8)]
        XCTAssertEqual(AppSettings.decode(settings.encoded()).customPrices, settings.customPrices)
        XCTAssertEqual(AppSettings.decode(Data(#"{"port": 5000}"#.utf8)).customPrices, [:])
        let json = #"""
            {"port": 5000, "customPrices": {
              " Nova-1 ": {"input": 2, "output": 8}, "zero": {"input": 0, "output": 8}, "negative": {"input": 1, "output": -2},
              "text": {"input": "x", "output": 8}, "missing": {"input": 1}, "list": [1, 2], " ": {"input": 1, "output": 1}}}
            """#
        let decoded = AppSettings.decode(Data(json.utf8))
        XCTAssertEqual(decoded.customPrices, ["nova-1": CustomModelPrice(input: 2, output: 8)],
                       "keys are trimmed and lowercased, a bad entry never costs the rest")
        XCTAssertEqual(decoded.port, 5000)
        let wrong = AppSettings.decode(Data(#"{"port": 5000, "customPrices": ["a", "b"]}"#.utf8))
        XCTAssertEqual(wrong.customPrices, [:])
        XCTAssertEqual(wrong.port, 5000)
    }

    func testAwayModeIsOffByDefaultAndDecodesLeniently() {
        XCTAssertFalse(AppSettings().awayMode)
        let older = AppSettings.decode(Data(v1JSON.utf8))
        XCTAssertFalse(older.awayMode, "settings saved before Away mode")
        XCTAssertEqual(older.port, 4400)
        let wrong = AppSettings.decode(Data(#"{"port": 5000, "awayMode": "on", "approveFromHoply": true}"#.utf8))
        XCTAssertFalse(wrong.awayMode)
        XCTAssertTrue(wrong.approveFromHoply)
        XCTAssertEqual(wrong.port, 5000)
        XCTAssertTrue(AppSettings.decode(Data(#"{"awayMode": true}"#.utf8)).awayMode)
        var settings = AppSettings()
        settings.awayMode = true
        XCTAssertEqual(AppSettings.decode(settings.encoded()), settings)
    }

    func testICloudLinkIsOffByDefaultAndDecodesLeniently() {
        XCTAssertFalse(AppSettings().iCloudLink)
        let older = AppSettings.decode(Data(v1JSON.utf8))
        XCTAssertFalse(older.iCloudLink, "settings saved before the iCloud link")
        XCTAssertEqual(older.port, 4400)
        let wrong = AppSettings.decode(Data(#"{"port": 5000, "iCloudLink": 1, "awayMode": true}"#.utf8))
        XCTAssertFalse(wrong.iCloudLink)
        XCTAssertTrue(wrong.awayMode)
        XCTAssertEqual(wrong.port, 5000)
        XCTAssertTrue(AppSettings.decode(Data(#"{"iCloudLink": true}"#.utf8)).iCloudLink)
        var settings = AppSettings()
        settings.iCloudLink = true
        XCTAssertEqual(AppSettings.decode(settings.encoded()), settings)
    }

    func testIPhoneLaunchIsOffByDefaultAndDecodesLeniently() {
        XCTAssertFalse(AppSettings().iPhoneLaunch)
        let older = AppSettings.decode(Data(v1JSON.utf8))
        XCTAssertFalse(older.iPhoneLaunch, "settings saved before launching from the iPhone")
        XCTAssertEqual(older.port, 4400)
        let wrong = AppSettings.decode(Data(#"{"port": 5000, "iPhoneLaunch": "yes", "iCloudLink": true}"#.utf8))
        XCTAssertFalse(wrong.iPhoneLaunch)
        XCTAssertTrue(wrong.iCloudLink)
        XCTAssertEqual(wrong.port, 5000)
        XCTAssertTrue(AppSettings.decode(Data(#"{"iPhoneLaunch": true}"#.utf8)).iPhoneLaunch)
        var settings = AppSettings()
        settings.iPhoneLaunch = true
        XCTAssertEqual(AppSettings.decode(settings.encoded()), settings)
    }

    func testIPhoneConversationsAreOnByDefaultAndDecodeLeniently() {
        XCTAssertTrue(AppSettings().iPhoneConversations)
        let older = AppSettings.decode(Data(v1JSON.utf8))
        XCTAssertTrue(older.iPhoneConversations, "settings saved before conversations on the iPhone")
        XCTAssertEqual(older.port, 4400)
        let wrong = AppSettings.decode(Data(#"{"port": 5000, "iPhoneConversations": "no", "iCloudLink": true}"#.utf8))
        XCTAssertTrue(wrong.iPhoneConversations)
        XCTAssertTrue(wrong.iCloudLink)
        XCTAssertEqual(wrong.port, 5000)
        XCTAssertFalse(AppSettings.decode(Data(#"{"iPhoneConversations": false}"#.utf8)).iPhoneConversations)
        var settings = AppSettings()
        settings.iPhoneConversations = false
        XCTAssertEqual(AppSettings.decode(settings.encoded()), settings)
    }

    func testSettingsSavedWithTheRemovedCleanupKeyStillDecode() {
        let json = #"{"port": 5000, "cleanupIncludesNodeModules": true, "paletteEnabled": false}"#
        let settings = AppSettings.decode(Data(json.utf8))
        XCTAssertEqual(settings.port, 5000)
        XCTAssertFalse(settings.paletteEnabled)
    }

    func testPaletteKeysDecodeLeniently() throws {
        let older = AppSettings.decode(Data(v1JSON.utf8))
        XCTAssertTrue(older.paletteEnabled)
        XCTAssertEqual(older.paletteHotKey, .optionSpace)
        XCTAssertEqual(older.port, 4400, "older keys survive")

        for wrong in [#""paletteHotKey":"⌥Space""#, #""paletteHotKey":{"keyCode":49}"#,
                      #""paletteHotKey":{"keyCode":49,"modifiers":0}"#, #""paletteHotKey":{"keyCode":"49","modifiers":2048}"#,
                      #""paletteHotKey":{"keyCode":900,"modifiers":2048}"#] {
            let settings = AppSettings.decode(Data("{\(wrong),\"paletteEnabled\":\"no\",\"vllmName\":\"ZGX\"}".utf8))
            XCTAssertEqual(settings.paletteHotKey, .optionSpace, wrong)
            XCTAssertTrue(settings.paletteEnabled)
            XCTAssertEqual(settings.legacyModelServer?.name, "ZGX")
        }

        var changed = AppSettings()
        changed.paletteEnabled = false
        changed.paletteHotKey = .controlOptionSpace
        XCTAssertEqual(AppSettings.decode(changed.encoded()), changed)

        let object = { (settings: AppSettings) -> [String: Any] in
            try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(settings.encoded())) as? [String: Any])
        }
        let (base, edited) = (try object(AppSettings()), try object(changed))
        XCTAssertEqual(base["paletteHotKey"] as? NSDictionary, ["keyCode": 49, "modifiers": 2048])
        XCTAssertNotEqual(base["paletteHotKey"] as? NSDictionary, edited["paletteHotKey"] as? NSDictionary)
        XCTAssertEqual(try object(AppSettings())["paletteHotKey"] as? NSDictionary, base["paletteHotKey"] as? NSDictionary)
        var merged = base
        merged["paletteHotKey"] = edited["paletteHotKey"]
        let result = AppSettings.decode(try JSONSerialization.data(withJSONObject: merged))
        XCTAssertEqual(result.paletteHotKey, .controlOptionSpace)
        XCTAssertTrue(result.paletteEnabled)
    }
}
