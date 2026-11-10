import AgentKit
import Foundation
import XCTest

final class ModelServerAlertTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_222_000)
    private let zgx = ModelServer(id: ModelServer.legacyID, name: "ZGX", baseURL: "http://192.168.40.141:8888")
    private let ollama = ModelServer(id: "ol1", name: "Ollama", baseURL: "http://localhost:11434")

    private func policy() -> NotificationPolicy {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return NotificationPolicy(preferences: NotificationPreferences(), calendar: calendar)
    }

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testEachServerHasItsOwnWatchAndAlert() {
        var policy = policy()
        for server in [zgx, ollama] {
            XCTAssertTrue(policy.modelServerChecked(server, .online, now: at(0)).isEmpty)
        }
        for second in stride(from: 30.0, to: 120, by: 30) {
            XCTAssertTrue(policy.modelServerChecked(ollama, .offline, now: at(second)).isEmpty)
            XCTAssertTrue(policy.modelServerChecked(zgx, .online, now: at(second)).isEmpty)
        }
        let alert = policy.modelServerChecked(ollama, .offline, now: at(150))
        XCTAssertEqual(alert.post.map(\.id), ["local-model:offline:ol1"])
        XCTAssertEqual(alert.post.first?.title, "Ollama is offline")
        XCTAssertEqual(alert.post.first?.body, "No response from localhost:11434 for 2 min.")
        XCTAssertEqual(alert.post.first?.threadID, NotificationPolicy.localModelThreadID)
        XCTAssertTrue(policy.modelServerChecked(ollama, .offline, now: at(180)).isEmpty, "once per outage")
        XCTAssertTrue(policy.modelServerChecked(zgx, .online, now: at(180)).isEmpty, "the other server is untouched")

        XCTAssertEqual(NotificationPolicy.modelServerOfflineID(ModelServer.legacyID), NotificationPolicy.localModelOfflineID)
        XCTAssertEqual(policy.modelServerChecked(ollama, .online, now: at(210)).withdraw, ["local-model:offline:ol1"])
    }

    func testThePerServerSwitchAndTheGlobalOne() {
        var policy = policy()
        var quiet = ollama
        quiet.offlineAlerts = false
        for server in [zgx, quiet] { _ = policy.modelServerChecked(server, .online, now: at(0)) }
        var posted: [String] = []
        for second in stride(from: 30.0, through: 300, by: 30) {
            posted += policy.modelServerChecked(quiet, .offline, now: at(second)).post.map(\.id)
            posted += policy.modelServerChecked(zgx, .offline, now: at(second)).post.map(\.id)
        }
        XCTAssertEqual(posted, [NotificationPolicy.localModelOfflineID], "only the server whose switch is on")

        var muted = self.policy()
        muted.preferences.localModelAlerts = false
        _ = muted.modelServerChecked(zgx, .online, now: at(0))
        for second in stride(from: 30.0, through: 300, by: 30) {
            XCTAssertTrue(muted.modelServerChecked(zgx, .offline, now: at(second)).isEmpty)
        }
    }

    func testARefusingServerIsNotAnOutage() {
        var policy = policy()
        _ = policy.modelServerChecked(zgx, .online, now: at(0))
        for second in stride(from: 30.0, through: 300, by: 30) {
            XCTAssertTrue(policy.modelServerChecked(zgx, .blocked, now: at(second)).isEmpty, "a 401 means it is up")
        }
        for second in stride(from: 330.0, to: 450, by: 30) { _ = policy.modelServerChecked(zgx, .offline, now: at(second)) }
        XCTAssertEqual(policy.modelServerChecked(zgx, .offline, now: at(450)).post.count, 1)
        XCTAssertEqual(policy.modelServerChecked(zgx, .blocked, now: at(480)).withdraw, [NotificationPolicy.localModelOfflineID])

        var fresh = self.policy()
        for second in stride(from: 0.0, through: 300, by: 30) {
            let state: ModelServerAvailability = second < 60 ? .blocked : .offline
            XCTAssertTrue(fresh.modelServerChecked(ollama, state, now: at(second)).isEmpty, "never seen working, never alerted")
        }
    }

    func testRemovedDisabledAndMovedServersWithdrawTheirAlert() {
        func down(_ policy: inout NotificationPolicy, _ servers: [ModelServer]) {
            for server in servers { _ = policy.modelServerChecked(server, .online, now: at(0)) }
            for second in stride(from: 30.0, through: 150, by: 30) {
                for server in servers { _ = policy.modelServerChecked(server, .offline, now: at(second)) }
            }
        }
        var policy = policy()
        down(&policy, [zgx, ollama])
        XCTAssertTrue(policy.modelServersChanged([zgx, ollama]).isEmpty)
        XCTAssertEqual(policy.modelServersChanged([zgx]).withdraw, ["local-model:offline:ol1"], "removed")
        var disabled = zgx
        disabled.enabled = false
        XCTAssertEqual(policy.modelServersChanged([disabled]).withdraw, [NotificationPolicy.localModelOfflineID])
        XCTAssertTrue(policy.modelServersChanged([]).isEmpty)

        down(&policy, [ollama])
        var moved = ollama
        moved.baseURL = "http://localhost:11435"
        XCTAssertEqual(policy.modelServerChecked(moved, .offline, now: at(180)).withdraw, ["local-model:offline:ol1"],
                       "another address is another outage")
        XCTAssertTrue(policy.modelServerChecked(moved, .offline, now: at(400)).isEmpty, "not seen online at the new address")

        down(&policy, [ollama])
        var silenced = ollama
        silenced.offlineAlerts = false
        XCTAssertEqual(policy.modelServersChanged([silenced]).withdraw, ["local-model:offline:ol1"])
    }
}
