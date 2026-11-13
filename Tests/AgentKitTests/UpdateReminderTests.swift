import AgentKit
import Foundation
import XCTest

final class UpdateReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let available = PendingUpdate(version: "0.1.3", stage: .available)
    private let ready = PendingUpdate(version: "0.1.3", stage: .ready)

    func testNothingPendingShowsNothing() {
        var reminder = UpdateReminder()
        XCTAssertFalse(reminder.showsBadge)
        XCTAssertFalse(reminder.showsCard)
        XCTAssertTrue(reminder.tick(now: now, notify: true).isEmpty)
    }

    func testFoundUpdateShowsBadgeAndCardAndNotifiesOnce() {
        var reminder = UpdateReminder()
        reminder.found(available)
        XCTAssertTrue(reminder.showsBadge)
        XCTAssertTrue(reminder.showsCard)
        let first = reminder.tick(now: now, notify: true)
        XCTAssertEqual(first.post.map(\.id), ["update:0.1.3"])
        XCTAssertEqual(first.post.first?.kind, .update)
        XCTAssertEqual(first.post.first?.title, "Hoply 0.1.3 is available")
        XCTAssertEqual(reminder.notifiedVersion, "0.1.3")
        XCTAssertTrue(reminder.tick(now: now + 5, notify: true).isEmpty)
    }

    func testReadyAfterAvailableKeepsOneNotificationPerVersion() {
        var reminder = UpdateReminder()
        reminder.found(available)
        _ = reminder.tick(now: now, notify: true)
        reminder.found(ready)
        XCTAssertEqual(reminder.pending, ready)
        XCTAssertTrue(reminder.tick(now: now + 5, notify: true).post.isEmpty)
    }

    func testReadyNotificationText() {
        var reminder = UpdateReminder()
        reminder.found(ready)
        let request = reminder.tick(now: now, notify: true).post.first
        XCTAssertEqual(request?.title, "Hoply 0.1.3 is ready to install")
        XCTAssertEqual(request?.body, "Click to restart Hoply now. Otherwise it installs the next time Hoply quits.")
        XCTAssertFalse(request?.playsSound ?? true)
    }

    func testNotifiedVersionSurvivesRelaunch() {
        var reminder = UpdateReminder(notifiedVersion: "0.1.3", runningVersion: "0.1.1")
        reminder.found(ready)
        XCTAssertTrue(reminder.tick(now: now, notify: true).isEmpty)
        reminder.found(PendingUpdate(version: "0.1.4", stage: .available))
        XCTAssertEqual(reminder.tick(now: now + 5, notify: true).post.map(\.id), ["update:0.1.4"])
    }

    func testNotificationWaitsWhileNotAllowed() {
        var reminder = UpdateReminder()
        reminder.found(available)
        XCTAssertTrue(reminder.tick(now: now, notify: false).isEmpty)
        XCTAssertNil(reminder.notifiedVersion)
        XCTAssertEqual(reminder.tick(now: now + 5, notify: true).post.count, 1)
    }

    func testUpdateTheUserAlreadySawIsNotNotified() {
        var reminder = UpdateReminder()
        reminder.found(available, seen: true)
        XCTAssertTrue(reminder.showsCard)
        XCTAssertTrue(reminder.tick(now: now, notify: true).isEmpty)
    }

    func testLaterHidesTheCardUntilItExpiresButKeepsTheBadge() {
        var reminder = UpdateReminder()
        reminder.found(available)
        reminder.later(until: now + 3600)
        XCTAssertFalse(reminder.showsCard)
        XCTAssertTrue(reminder.showsBadge)
        _ = reminder.tick(now: now + 3599, notify: false)
        XCTAssertFalse(reminder.showsCard)
        _ = reminder.tick(now: now + 3600, notify: false)
        XCTAssertTrue(reminder.showsCard)
    }

    func testANewCheckBringsTheCardBack() {
        var reminder = UpdateReminder()
        reminder.found(available)
        reminder.later(until: now + 3600)
        reminder.found(available)
        XCTAssertTrue(reminder.showsCard)
    }

    func testLaterWithoutAnUpdateDoesNothing() {
        var reminder = UpdateReminder()
        reminder.later(until: now + 3600)
        XCTAssertNil(reminder.hiddenUntil)
    }

    func testClearWithdrawsTheNotification() {
        var reminder = UpdateReminder()
        reminder.found(available)
        _ = reminder.tick(now: now, notify: true)
        reminder.clear()
        XCTAssertFalse(reminder.showsBadge)
        XCTAssertFalse(reminder.showsCard)
        XCTAssertEqual(reminder.tick(now: now + 5, notify: true), NotificationActions(withdraw: ["update:0.1.3"]))
        XCTAssertTrue(reminder.tick(now: now + 10, notify: true).isEmpty)
    }

    func testInstalledVersionWithdrawsItsNotificationAtLaunch() {
        var reminder = UpdateReminder(notifiedVersion: "0.1.3", runningVersion: "0.1.3")
        XCTAssertEqual(reminder.tick(now: now, notify: false).withdraw, ["update:0.1.3"])
        XCTAssertTrue(reminder.tick(now: now + 5, notify: false).isEmpty)
        XCTAssertTrue(UpdateReminder(notifiedVersion: "0.1.3", runningVersion: "0.1.1")
            .withdrawalsAreEmpty)
    }
}

private extension UpdateReminder {
    var withdrawalsAreEmpty: Bool {
        var copy = self
        return copy.tick(now: .distantPast, notify: false).withdraw.isEmpty
    }
}
