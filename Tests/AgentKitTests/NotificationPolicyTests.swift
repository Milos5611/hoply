import AgentKit
import Foundation
import XCTest

final class NotificationPolicyTests: XCTestCase {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// 2026-11-09 12:00 UTC.
    private let t0 = NotificationPolicyTests.utc.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!
    private let fiba = ProjectRef(id: 7, root: "/r/fiba", name: "fiba", displayName: "FIBA", kind: .repo)
    private var board = SessionBoard()
    private var policy = NotificationPolicy(calendar: NotificationPolicyTests.utc)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func local(hour: Int, minute: Int = 0, day: Int = 9) -> Date {
        Self.utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @discardableResult
    private func send(_ id: String, _ kind: AgentEvent.Kind, at time: Date, cwd: String? = "/r/fiba/src",
                      project: ProjectRef? = nil) -> NotificationActions {
        let event = AgentEvent(key: SessionKey(source: .claudeCode, id: id), kind: kind, time: time, cwd: cwd,
                               fromHook: true)
        guard let change = board.apply(event) else { return NotificationActions() }
        return policy.sessionChanged(change, project: project, now: time)
    }

    @discardableResult
    private func send(_ id: String, _ kind: AgentEvent.Kind, at seconds: TimeInterval, cwd: String? = "/r/fiba/src",
                      project: ProjectRef? = nil) -> NotificationActions {
        send(id, kind, at: at(seconds), cwd: cwd, project: project)
    }

    private func id(_ session: String) -> String {
        NotificationPolicy.notificationID(for: SessionKey(source: .claudeCode, id: session))
    }

    // MARK: - Sessions

    func testPermissionIsActiveAndNamedAfterTheResolvedProject() throws {
        XCTAssertTrue(send("a", .promptSubmitted("Fix the login bug"), at: 0, project: fiba).isEmpty)
        let actions = send("a", .needsPermission("Bash"), at: 5, project: fiba)
        let request = try XCTUnwrap(actions.post.first)
        XCTAssertEqual(actions.post.count, 1)
        XCTAssertEqual(request.id, "session:claude-code:a")
        XCTAssertEqual(request.kind, .permission)
        XCTAssertEqual(request.interruption, .active)
        XCTAssertTrue(request.playsSound)
        XCTAssertEqual(request.title, "Claude Code needs permission")
        XCTAssertEqual(request.body, "Fix the login bug · FIBA")
        XCTAssertEqual(request.threadID, "/r/fiba", "threads per project root")
        XCTAssertEqual(request.session, SessionKey(source: .claudeCode, id: "a"))
    }

    func testYourTurnIsPassiveAndOnlyAfterRealWork() throws {
        send("a", .promptSubmitted("Quick one"), at: 0)
        XCTAssertTrue(send("a", .turnFinished(nil), at: 29).post.isEmpty, "under 30 s of work")
        send("a", .promptSubmitted("Longer"), at: 40)
        let actions = send("a", .turnFinished(nil), at: 75)
        let request = try XCTUnwrap(actions.post.first)
        XCTAssertEqual(request.kind, .yourTurn)
        XCTAssertEqual(request.interruption, .passive)
        XCTAssertFalse(request.playsSound)
        XCTAssertEqual(request.title, "Claude Code is waiting for you")
        XCTAssertEqual(request.body, "Quick one · src", "unresolved: the cwd's folder name")
        XCTAssertEqual(request.threadID, "/r/fiba/src", "unresolved: threads per cwd")

        send("b", .promptSubmitted("x"), at: 0)
        send("b", .needsPermission(nil), at: 50)
        XCTAssertTrue(send("b", .turnFinished(nil), at: 100).post.isEmpty, "your-turn only follows work")
    }

    func testLeavingAWaitingStateWithdrawsItsNotification() {
        send("a", .promptSubmitted("x"), at: 0)
        XCTAssertEqual(send("a", .needsPermission(nil), at: 5).post.count, 1)
        XCTAssertEqual(send("a", .toolStarted("Bash"), at: 10), NotificationActions(withdraw: [id("a")]))
        XCTAssertTrue(send("a", .toolFinished("Bash"), at: 11).isEmpty)
        send("a", .turnFinished(nil), at: 60)
        XCTAssertEqual(send("a", .sessionEnded(nil), at: 70).withdraw, [id("a")])

        send("b", .promptSubmitted("x"), at: 0)
        send("b", .turnFinished(nil), at: 40)
        XCTAssertTrue(send("b", .needsPermission(nil), at: 45).withdraw.isEmpty, "still waiting: replaced, not removed")
        XCTAssertEqual(policy.sessionDismissed(SessionKey(source: .claudeCode, id: "b")).withdraw, [id("b")])
    }

    func testCooldownIsPerSessionAndPerKind() {
        send("a", .promptSubmitted("x"), at: 0)
        XCTAssertEqual(send("a", .needsPermission(nil), at: 5).post.count, 1)
        send("a", .toolStarted(nil), at: 10)
        XCTAssertTrue(send("a", .needsPermission(nil), at: 60).post.isEmpty, "a second permission within 2 min")
        send("b", .promptSubmitted("x"), at: 0)
        XCTAssertEqual(send("b", .needsPermission(nil), at: 61).post.count, 1, "another session")
        send("a", .toolStarted(nil), at: 70)
        XCTAssertEqual(send("a", .turnFinished(nil), at: 110).post.map(\.kind), [.yourTurn], "another kind")
        send("a", .promptSubmitted("y"), at: 115)
        XCTAssertEqual(send("a", .needsPermission(nil), at: 126).post.count, 1, "2 min after the last permission")
    }

    func testMasterSwitchSilencesPostsButStillWithdraws() {
        policy.preferences.enabled = false
        send("a", .promptSubmitted("x"), at: 0)
        XCTAssertTrue(send("a", .needsPermission(nil), at: 5).post.isEmpty)
        XCTAssertEqual(send("a", .toolStarted(nil), at: 10).withdraw, [id("a")])
    }

    func testQuietHoursWrapMidnight() {
        let night = QuietHours(start: 22 * 60, end: 8 * 60)
        XCTAssertTrue(night.contains(local(hour: 22), calendar: Self.utc))
        XCTAssertTrue(night.contains(local(hour: 23, minute: 30), calendar: Self.utc))
        XCTAssertTrue(night.contains(local(hour: 0), calendar: Self.utc))
        XCTAssertTrue(night.contains(local(hour: 7, minute: 59), calendar: Self.utc))
        XCTAssertFalse(night.contains(local(hour: 8), calendar: Self.utc))
        XCTAssertFalse(night.contains(local(hour: 21, minute: 59), calendar: Self.utc))

        let lunch = QuietHours(start: 13 * 60, end: 14 * 60)
        XCTAssertTrue(lunch.contains(local(hour: 13, minute: 30), calendar: Self.utc))
        XCTAssertFalse(lunch.contains(local(hour: 14), calendar: Self.utc))
        XCTAssertFalse(lunch.contains(local(hour: 12, minute: 59), calendar: Self.utc))
        XCTAssertFalse(QuietHours(start: 600, end: 600).contains(local(hour: 10), calendar: Self.utc))
        XCTAssertEqual(QuietHours(start: -60, end: 1500), QuietHours(start: 23 * 60, end: 60))
    }

    func testQuietHoursSilenceSessionsInTheCalendarsTimeZone() throws {
        var belgrade = Calendar(identifier: .gregorian)
        belgrade.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Belgrade"))
        policy = NotificationPolicy(preferences: NotificationPreferences(quietHours: QuietHours(start: 22 * 60, end: 8 * 60)),
                                    calendar: belgrade)
        send("a", .promptSubmitted("x"), at: local(hour: 21, minute: 20))
        XCTAssertTrue(send("a", .needsPermission(nil), at: local(hour: 21, minute: 30)).post.isEmpty,
                      "21:30 UTC is 22:30 in Belgrade")
        send("a", .promptSubmitted("y"), at: local(hour: 7, minute: 0, day: 10))
        XCTAssertEqual(send("a", .needsPermission(nil), at: local(hour: 7, minute: 5, day: 10)).post.count, 1,
                       "08:05 in Belgrade")
        XCTAssertFalse(policy.isQuiet(at: local(hour: 7, minute: 5, day: 10)))
    }

    func testMutedRootsSilenceSessionsOnly() {
        policy.preferences.mutedProjectRoots = ["/r/fiba", "/r/api/"]
        send("a", .promptSubmitted("x"), at: 0, project: fiba)
        XCTAssertTrue(send("a", .needsPermission(nil), at: 5, project: fiba).post.isEmpty, "muted project root")
        send("b", .promptSubmitted("x"), at: 0, cwd: "/r/api")
        XCTAssertTrue(send("b", .needsPermission(nil), at: 5, cwd: "/r/api").post.isEmpty, "unresolved: muted cwd")
        send("c", .promptSubmitted("x"), at: 0)
        XCTAssertEqual(send("c", .needsPermission(nil), at: 5).post.count, 1,
                       "an unresolved subfolder is not its root")
        let limit = policy.limitsUpdated([sample(85, at: 0)], previous: [:], now: at(0))
        XCTAssertEqual(limit.post.count, 1, "mute leaves limit alerts alone")
    }

    // MARK: - Limits

    private func sample(_ utilization: Double, _ kind: LimitKind = .fiveHour, at seconds: TimeInterval,
                        resets: TimeInterval? = 3 * 3600) -> LimitSample {
        LimitSample(kind: kind, ts: at(seconds), utilization: utilization, resetsAt: resets.map { at($0) })
    }

    private func limits(_ samples: LimitSample..., previous: [LimitKind: LimitSample]? = nil,
                        at seconds: TimeInterval? = nil) -> [NotificationRequest] {
        let now = seconds.map { at($0) } ?? samples.map(\.ts).max() ?? t0
        return policy.limitsUpdated(samples, previous: previous, now: now).post
    }

    func testLimitThresholdsAlertOnceWhenCrossedInsideAWindow() throws {
        XCTAssertTrue(limits(sample(70, at: -180)).isEmpty)
        let eighty = try XCTUnwrap(limits(sample(82, at: 0)).first)
        XCTAssertEqual(eighty.kind, .limit)
        XCTAssertEqual(eighty.interruption, .passive)
        XCTAssertEqual(eighty.title, "Claude 5-hour limit at 82%")
        XCTAssertEqual(eighty.body, "Resets in 3 h.")
        XCTAssertEqual(eighty.threadID, NotificationPolicy.limitsThreadID)
        XCTAssertNil(eighty.session)
        XCTAssertEqual(eighty.id, NotificationPolicy.limitID(sample(82, at: 0), threshold: 80))
        XCTAssertTrue(limits(sample(90, at: 180)).isEmpty)
        let ninetyFive = try XCTUnwrap(limits(sample(96, at: 360)).first)
        XCTAssertEqual(ninetyFive.interruption, .active)
        XCTAssertTrue(ninetyFive.id.hasSuffix(":95"))
        XCTAssertTrue(limits(sample(99, at: 540)).isEmpty)
    }

    func testOnlyTheHighestCrossedThresholdPosts() {
        let posted = limits(sample(96, at: 0), previous: [.fiveHour: sample(70, at: -180)])
        XCTAssertEqual(posted.map(\.id), [NotificationPolicy.limitID(sample(96, at: 0), threshold: 95)])
        XCTAssertTrue(limits(sample(97, at: 180)).isEmpty, "80 never posts afterwards")
    }

    func testRestartComparesWithTheLastStoredSample() {
        let stored = sample(85, at: -600, resets: 3 * 3600 + 40)
        XCTAssertTrue(limits(sample(86, at: 0), previous: [.fiveHour: stored]).isEmpty, "jittered reset, same window")

        policy = NotificationPolicy(calendar: Self.utc)
        XCTAssertEqual(limits(sample(86, at: 0), previous: [.fiveHour: sample(79, at: -600)]).count, 1)

        policy = NotificationPolicy(calendar: Self.utc)
        XCTAssertTrue(limits(sample(86, at: 0), previous: [.fiveHour: sample(86, at: 0)]).isEmpty,
                      "a stored copy of the same fetch never alerts")
    }

    func testANewWindowThatStartsAboveAThresholdAlerts() {
        let oldWindow = sample(97, at: -3600, resets: -600)
        XCTAssertEqual(limits(sample(85, at: 0, resets: 5 * 3600), previous: [.fiveHour: oldWindow]).map(\.title),
                       ["Claude 5-hour limit at 85%"])
        policy = NotificationPolicy(calendar: Self.utc)
        XCTAssertTrue(limits(sample(10, at: 0, resets: 5 * 3600), previous: [.fiveHour: oldWindow]).isEmpty)
        policy = NotificationPolicy(calendar: Self.utc)
        XCTAssertEqual(limits(sample(85, at: 0), previous: [:]).count, 1, "no history at all counts as a new window")
    }

    func testADipAndReRiseInOneWindowDoesNotRepost() {
        XCTAssertEqual(limits(sample(81, at: 0), previous: [.fiveHour: sample(70, at: -180)]).count, 1)
        XCTAssertTrue(limits(sample(78, at: 180, resets: 3 * 3600 + 30)).isEmpty)
        XCTAssertTrue(limits(sample(82, at: 360, resets: 3 * 3600 - 20)).isEmpty)
        XCTAssertEqual(NotificationPolicy.limitID(sample(1, at: 0, resets: 3 * 3600 + 30), threshold: 80),
                       NotificationPolicy.limitID(sample(1, at: 0, resets: 3 * 3600 - 20), threshold: 80))
    }

    func testLimitAlertsFollowPreferencesAndNameTheWindow() {
        policy.preferences.limitAlerts = false
        XCTAssertTrue(limits(sample(85, at: 0), previous: [:]).isEmpty)
        policy.preferences.limitAlerts = true
        XCTAssertTrue(limits(sample(86, at: 180)).isEmpty, "a crossing missed while off is not replayed")

        policy.preferences.quietHours = QuietHours(start: 11 * 60, end: 13 * 60)
        XCTAssertTrue(limits(sample(96, at: 360)).isEmpty)
        policy.preferences.quietHours = nil

        let weekly = limits(sample(81, .sevenDayOpus, at: 0, resets: 2 * 86_400 + 3 * 3600),
                            previous: [.sevenDayOpus: sample(60, .sevenDayOpus, at: -180, resets: 2 * 86_400 + 3 * 3600)])
        XCTAssertEqual(weekly.map(\.title), ["Claude weekly Opus limit at 81%"])
        XCTAssertEqual(weekly.map(\.body), ["Resets in 2 d 3 h."])
    }

    // MARK: - Local model

    private let server = "http://192.168.40.141:8888"

    private func check(_ online: Bool, at seconds: TimeInterval, server: String? = nil) -> NotificationActions {
        policy.localModelChecked(server: server ?? self.server, name: "ZGX", online: online, now: at(seconds))
    }

    func testLaunchingWithTheServerOffNeverAlerts() {
        for second in stride(from: 0.0, through: 900, by: 5) {
            XCTAssertTrue(check(false, at: second).isEmpty)
        }
    }

    func testOfflineAlertsOnceAfterTwoMinutesAndRearmsWhenBack() throws {
        XCTAssertTrue(check(true, at: 0).isEmpty)
        XCTAssertTrue(check(false, at: 5).isEmpty)
        XCTAssertTrue(check(false, at: 124).isEmpty)
        let actions = check(false, at: 125)
        let request = try XCTUnwrap(actions.post.first)
        XCTAssertEqual(request.id, NotificationPolicy.localModelOfflineID)
        XCTAssertEqual(request.kind, .localModelOffline)
        XCTAssertEqual(request.interruption, .active)
        XCTAssertEqual(request.title, "ZGX is offline")
        XCTAssertEqual(request.body, "No response from 192.168.40.141:8888 for 2 min.")
        XCTAssertEqual(request.threadID, NotificationPolicy.localModelThreadID)
        XCTAssertTrue(check(false, at: 130).isEmpty)
        XCTAssertTrue(check(false, at: 3600).isEmpty, "once per outage")
        XCTAssertEqual(check(true, at: 3605), NotificationActions(withdraw: [NotificationPolicy.localModelOfflineID]))
        XCTAssertTrue(check(false, at: 3610).isEmpty)
        XCTAssertEqual(check(false, at: 3730).post.count, 1, "re-armed")
    }

    func testNoServerOrANewServerNeverAlertsUntilSeenOnline() {
        XCTAssertTrue(policy.localModelChecked(server: nil, online: true, now: at(0)).isEmpty)
        XCTAssertTrue(policy.localModelChecked(server: "  ", online: false, now: at(600)).isEmpty)

        _ = check(true, at: 0)
        XCTAssertTrue(check(false, at: 5, server: "http://10.0.0.9:8000").isEmpty)
        XCTAssertTrue(check(false, at: 900, server: "http://10.0.0.9:8000").isEmpty, "the new server was never online")

        _ = check(true, at: 1000)
        _ = check(false, at: 1005)
        XCTAssertEqual(check(false, at: 1200).post.count, 1)
        XCTAssertEqual(policy.localModelChecked(server: "", online: false, now: at(1205)).withdraw,
                       [NotificationPolicy.localModelOfflineID], "clearing the URL removes the alert")
    }

    func testOfflineAlertHeldByQuietHoursPostsWhenTheyEnd() {
        policy.preferences.quietHours = QuietHours(start: 22 * 60, end: 8 * 60)
        func poll(_ online: Bool, _ date: Date) -> NotificationActions {
            policy.localModelChecked(server: server, online: online, now: date)
        }
        XCTAssertTrue(poll(true, local(hour: 21, minute: 50)).isEmpty)
        XCTAssertTrue(poll(false, local(hour: 21, minute: 55)).isEmpty)
        XCTAssertTrue(poll(false, local(hour: 22, minute: 30)).isEmpty)
        let morning = poll(false, local(hour: 8, day: 10))
        XCTAssertEqual(morning.post.map(\.title), ["Local model is offline"])
        XCTAssertEqual(morning.post.map(\.body), ["No response from 192.168.40.141:8888 for 10 h 5 min."])
        XCTAssertTrue(poll(false, local(hour: 8, minute: 5, day: 10)).isEmpty)
    }

    func testPreferencesFromSettings() {
        var settings = AppSettings()
        XCTAssertEqual(NotificationPreferences(settings: settings), NotificationPreferences())
        settings.notificationsEnabled = false
        settings.quietHoursEnabled = true
        settings.quietHoursStart = 23 * 60
        settings.quietHoursEnd = 7 * 60
        settings.mutedProjectRoots = ["/r/fiba"]
        settings.limitAlertsEnabled = false
        settings.localModelAlertsEnabled = false
        XCTAssertEqual(NotificationPreferences(settings: settings),
                       NotificationPreferences(enabled: false, quietHours: QuietHours(start: 23 * 60, end: 7 * 60),
                                               mutedProjectRoots: ["/r/fiba"], limitAlerts: false,
                                               localModelAlerts: false))
    }
}
