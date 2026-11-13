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
    private let corestory = ProjectRef(id: 7, root: "/r/corestory", name: "corestory", displayName: "CoreStory", kind: .repo)
    private var board = SessionBoard()
    private var policy = NotificationPolicy(calendar: NotificationPolicyTests.utc)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func local(hour: Int, minute: Int = 0, day: Int = 9) -> Date {
        Self.utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @discardableResult
    private func send(_ id: String, _ kind: AgentEvent.Kind, at time: Date, cwd: String? = "/r/corestory/src",
                      project: ProjectRef? = nil) -> NotificationActions {
        let event = AgentEvent(key: SessionKey(source: .claudeCode, id: id), kind: kind, time: time, cwd: cwd,
                               fromHook: true)
        guard let change = board.apply(event) else { return NotificationActions() }
        return policy.sessionChanged(change, project: project, now: time)
    }

    @discardableResult
    private func send(_ id: String, _ kind: AgentEvent.Kind, at seconds: TimeInterval, cwd: String? = "/r/corestory/src",
                      project: ProjectRef? = nil) -> NotificationActions {
        send(id, kind, at: at(seconds), cwd: cwd, project: project)
    }

    private func id(_ session: String) -> String {
        NotificationPolicy.notificationID(for: SessionKey(source: .claudeCode, id: session))
    }

    // MARK: - Sessions

    func testPermissionIsActiveAndNamedAfterTheResolvedProject() throws {
        XCTAssertTrue(send("a", .promptSubmitted("Fix the login bug"), at: 0, project: corestory).isEmpty)
        let actions = send("a", .needsPermission("Bash"), at: 5, project: corestory)
        let request = try XCTUnwrap(actions.post.first)
        XCTAssertEqual(actions.post.count, 1)
        XCTAssertEqual(request.id, "session:claude-code:a")
        XCTAssertEqual(request.kind, .permission)
        XCTAssertEqual(request.interruption, .active)
        XCTAssertTrue(request.playsSound)
        XCTAssertEqual(request.title, "Claude Code needs permission")
        XCTAssertEqual(request.body, "Fix the login bug · CoreStory")
        XCTAssertEqual(request.threadID, "/r/corestory", "threads per project root")
        XCTAssertEqual(request.session, SessionKey(source: .claudeCode, id: "a"))
    }

    func testYourTurnIsPassiveAndOnlyAfterRealWork() throws {
        send("a", .promptSubmitted("Quick one"), at: 0)
        XCTAssertTrue(send("a", .turnFinished(nil), at: 9).post.isEmpty, "under the 10 s default")
        send("a", .promptSubmitted("Longer"), at: 40)
        let actions = send("a", .turnFinished(nil), at: 75)
        let request = try XCTUnwrap(actions.post.first)
        XCTAssertEqual(request.kind, .yourTurn)
        XCTAssertEqual(request.interruption, .passive)
        XCTAssertFalse(request.playsSound)
        XCTAssertEqual(request.title, "Claude Code is waiting for you")
        XCTAssertEqual(request.body, "Quick one · src", "unresolved: the cwd's folder name")
        XCTAssertEqual(request.threadID, "/r/corestory/src", "unresolved: threads per cwd")

        send("b", .promptSubmitted("x"), at: 0)
        send("b", .needsPermission(nil), at: 50)
        XCTAssertTrue(send("b", .turnFinished(nil), at: 100).post.isEmpty, "your-turn only follows work")
    }

    func testTurnDelayComesFromTheSettings() {
        XCTAssertEqual(NotificationPreferences().turnNotificationDelay, 10)
        var settings = AppSettings()
        settings.turnNotificationDelay = 60
        policy.preferences = NotificationPreferences(settings: settings)
        send("a", .promptSubmitted("x"), at: 0)
        XCTAssertTrue(send("a", .turnFinished(nil), at: 59).post.isEmpty)
        send("b", .promptSubmitted("x"), at: 0)
        XCTAssertEqual(send("b", .turnFinished(nil), at: 60).post.first?.cause, .yourTurn)
    }

    func testDelayZeroAlwaysNotifies() {
        policy.preferences.turnNotificationDelay = 0
        send("a", .promptSubmitted("x"), at: 0)
        XCTAssertEqual(send("a", .turnFinished(nil), at: 1).post.first?.cause, .yourTurn)
    }

    func testAPromptMidTurnDoesNotRestartTheTurnClock() {
        policy.preferences.turnNotificationDelay = 30
        send("a", .promptSubmitted("x"), at: 0)
        XCTAssertEqual(send("a", .needsPermission("Allow Bash?"), at: 3).post.first?.cause, .permission)
        send("a", .toolFinished("Bash"), at: 25)
        XCTAssertEqual(send("a", .turnFinished(nil), at: 40).post.first?.cause, .yourTurn,
                       "40 s since the prompt, though only 15 s since the permission prompt")

        policy.preferences.turnNotificationDelay = 10
        send("b", .promptSubmitted("x"), at: 0)
        XCTAssertEqual(send("b", .questionAsked("Which file?"), at: 3).post.first?.cause, .input)
        send("b", .toolFinished("AskUserQuestion"), at: 8)
        XCTAssertEqual(send("b", .turnFinished(nil), at: 15).post.first?.cause, .yourTurn,
                       "answering a question continues the turn")

        send("c", .promptSubmitted("x"), at: 0)
        send("c", .needsPermission(nil), at: 3)
        send("c", .toolFinished("Bash"), at: 4)
        XCTAssertTrue(send("c", .turnFinished(nil), at: 9).post.filter { $0.cause == .yourTurn }.isEmpty)
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
        policy.preferences.mutedProjectRoots = ["/r/corestory", "/r/api/"]
        send("a", .promptSubmitted("x"), at: 0, project: corestory)
        XCTAssertTrue(send("a", .needsPermission(nil), at: 5, project: corestory).post.isEmpty, "muted project root")
        send("b", .promptSubmitted("x"), at: 0, cwd: "/r/api")
        XCTAssertTrue(send("b", .needsPermission(nil), at: 5, cwd: "/r/api").post.isEmpty, "unresolved: muted cwd")
        send("c", .promptSubmitted("x"), at: 0)
        XCTAssertTrue(send("c", .needsPermission(nil), at: 5).post.isEmpty,
                      "unresolved: a cwd under a muted root is muted until the project resolves")
        send("d", .promptSubmitted("x"), at: 0, cwd: "/r/corestorybar/src")
        XCTAssertEqual(send("d", .needsPermission(nil), at: 5, cwd: "/r/corestorybar/src").post.count, 1,
                       "path components, not a string prefix")
        let limit = policy.limitsUpdated([sample(85, at: 0)], previous: [:], now: at(0))
        XCTAssertEqual(limit.post.count, 1, "mute leaves limit alerts alone")
    }

    func testAResolvedProjectIsMutedByItsExactRootOnly() {
        policy.preferences.mutedProjectRoots = ["/r", "/r/corestory/src"]
        send("a", .promptSubmitted("x"), at: 0, project: corestory)
        XCTAssertEqual(send("a", .needsPermission(nil), at: 5, project: corestory).post.count, 1,
                       "neither a muted parent nor the muted cwd mutes a resolved repo")
        policy.preferences.mutedProjectRoots = ["/"]
        send("b", .promptSubmitted("x"), at: 200, cwd: "/tmp/x")
        XCTAssertTrue(send("b", .needsPermission(nil), at: 205, cwd: "/tmp/x").post.isEmpty)
    }

    func testSessionsDroppedByTheBoardAreReported() {
        send("a", .promptSubmitted("x"), at: 0)
        XCTAssertEqual(send("a", .needsPermission(nil), at: 5).post.count, 1)
        send("b", .sessionEnded(nil), at: 5)
        XCTAssertEqual(board.sweep(now: at(600)), SessionBoard.Sweep())
        let ended = board.sweep(now: at(606))
        XCTAssertEqual(ended.dropped.map(\.key.id), ["b"], "ended over 10 minutes ago")
        XCTAssertTrue(ended.changes.isEmpty)
        let stale = board.sweep(now: at(4 * 3600 + 6))
        XCTAssertEqual(stale.dropped.map(\.key.id), ["a"])
        XCTAssertEqual(stale.dropped.first?.state, .needsPermission)
        XCTAssertEqual(stale.dropped.map { policy.sessionDismissed($0.key) },
                       [NotificationActions(withdraw: [id("a")])])
        XCTAssertTrue(board.sessions.isEmpty)
        XCTAssertEqual(board.sweep(now: at(5 * 3600)), SessionBoard.Sweep())
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

    func testCodexLimitsAreNamedAfterCodexAndTheirWindow() throws {
        let fiveHour = try XCTUnwrap(LimitKind.codex(windowMinutes: 300))
        let month = try XCTUnwrap(LimitKind.codex(windowMinutes: 43_200))
        XCTAssertEqual(limits(sample(82, fiveHour, at: 0), previous: [:]).map(\.title), ["Codex 5-hour limit at 82%"])
        let monthly = limits(sample(96, month, at: 10, resets: 20 * 86_400), previous: [:])
        XCTAssertEqual(monthly.map(\.title), ["Codex 30-day limit at 96%"])
        XCTAssertEqual(monthly.map(\.interruption), [.active])
        XCTAssertTrue(limits(sample(85, fiveHour, at: 20), previous: [:]).isEmpty, "remembered per kind")
        XCTAssertEqual(limits(sample(85, at: 20), previous: [:]).map(\.title), ["Claude 5-hour limit at 85%"],
                       "Claude's window is its own")
    }

    func testOldReadingsRaiseTheFloorButNeverAlert() throws {
        let fiveHour = try XCTUnwrap(LimitKind.codex(windowMinutes: 300))
        let backfilled = [sample(70, fiveHour, at: -7200), sample(88, fiveHour, at: -3600)]
        XCTAssertTrue(policy.limitsUpdated(backfilled, previous: [:], now: at(0)).post.isEmpty)
        XCTAssertTrue(limits(sample(90, fiveHour, at: 0)).isEmpty, "80 was crossed in a reading nobody saw live")
        XCTAssertEqual(limits(sample(95, fiveHour, at: 60)).map(\.title), ["Codex 5-hour limit at 95%"])
        let edge = sample(81, .sevenDay, at: -NotificationPolicy.limitAlertFreshness, resets: 2 * 86_400)
        XCTAssertEqual(policy.limitsUpdated([edge], previous: [:], now: at(0)).post.count, 1, "ten minutes is still news")
    }

    func testOneUpdateWithSeveralReadingsAlertsOnceInTimeOrder() throws {
        let fiveHour = try XCTUnwrap(LimitKind.codex(windowMinutes: 300))
        let posted = policy.limitsUpdated([sample(86, fiveHour, at: 30), sample(81, fiveHour, at: 0)],
                                          previous: [fiveHour: sample(60, fiveHour, at: -300)], now: at(40))
        XCTAssertEqual(posted.post.map(\.title), ["Codex 5-hour limit at 81%"])
    }

    // MARK: - Local model

    private let server = "http://192.168.40.141:8888"

    private func check(_ online: Bool, at seconds: TimeInterval, server: String? = nil) -> NotificationActions {
        legacy(server ?? self.server, name: "ZGX", online, now: at(seconds))
    }

    private func legacy(_ url: String, name: String = "", _ online: Bool, now: Date) -> NotificationActions {
        policy.modelServerChecked(ModelServer(id: ModelServer.legacyID, name: name, baseURL: url),
                                  online ? .online : .offline, now: now)
    }

    /// Polls every 5 s over `seconds`, as the app does, and returns every action in order.
    private func poll(_ online: Bool, _ seconds: ClosedRange<Int>) -> [NotificationActions] {
        stride(from: seconds.lowerBound, through: seconds.upperBound, by: 5)
            .map { check(online, at: TimeInterval($0)) }.filter { !$0.isEmpty }
    }

    func testAGapBetweenChecksRestartsTheOutageClock() {
        XCTAssertTrue(check(true, at: 0).isEmpty)
        XCTAssertTrue(check(false, at: 5).isEmpty)
        let wake: TimeInterval = 8 * 3600
        XCTAssertTrue(check(false, at: wake).isEmpty, "asleep for 8 h: not an 8 h outage")
        XCTAssertTrue(check(false, at: wake + 30).isEmpty)
        XCTAssertTrue(check(false, at: wake + 60).isEmpty)
        XCTAssertTrue(check(false, at: wake + 90).isEmpty)
        XCTAssertEqual(check(false, at: wake + 120).post.map(\.body),
                       ["No response from 192.168.40.141:8888 for 2 min."])
    }

    func testLaunchingWithTheServerOffNeverAlerts() {
        for second in stride(from: 0.0, through: 900, by: 5) {
            XCTAssertTrue(check(false, at: second).isEmpty)
        }
    }

    func testOfflineAlertsOnceAfterTwoMinutesAndRearmsWhenBack() throws {
        XCTAssertTrue(check(true, at: 0).isEmpty)
        XCTAssertTrue(poll(false, 5...120).isEmpty)
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
        XCTAssertTrue(poll(false, 3610...3725).isEmpty)
        XCTAssertEqual(check(false, at: 3730).post.count, 1, "re-armed")
    }

    func testNoServerOrANewServerNeverAlertsUntilSeenOnline() {
        XCTAssertTrue(legacy("", true, now: at(0)).isEmpty)
        XCTAssertTrue(legacy("  ", false, now: at(600)).isEmpty)

        _ = check(true, at: 0)
        XCTAssertTrue(check(false, at: 5, server: "http://10.0.0.9:8000").isEmpty)
        XCTAssertTrue(check(false, at: 900, server: "http://10.0.0.9:8000").isEmpty, "the new server was never online")

        _ = check(true, at: 1000)
        XCTAssertEqual(poll(false, 1005...1200).map(\.post.count), [1])
        XCTAssertEqual(legacy("", false, now: at(1205)).withdraw,
                       [NotificationPolicy.localModelOfflineID], "clearing the URL removes the alert")
    }

    func testOfflineAlertHeldByQuietHoursPostsWhenTheyEnd() {
        policy.preferences.quietHours = QuietHours(start: 22 * 60, end: 8 * 60)
        func poll(_ online: Bool, _ date: Date) -> NotificationActions {
            legacy(server, online, now: date)
        }
        XCTAssertTrue(poll(true, local(hour: 21, minute: 50)).isEmpty)
        let down = local(hour: 21, minute: 59)
        let night = stride(from: 0.0, to: 10 * 3600 + 60, by: 30).map { poll(false, down.addingTimeInterval($0)) }
        XCTAssertTrue(night.allSatisfy(\.isEmpty))
        let morning = poll(false, local(hour: 8, day: 10))
        XCTAssertEqual(morning.post.map(\.title), ["Local model is offline"])
        XCTAssertEqual(morning.post.map(\.body), ["No response from 192.168.40.141:8888 for 10 h 1 min."])
        XCTAssertTrue(poll(false, local(hour: 8, minute: 5, day: 10)).isEmpty)
    }

    func testPreferencesFromSettings() {
        var settings = AppSettings()
        XCTAssertEqual(NotificationPreferences(settings: settings), NotificationPreferences())
        settings.notificationsEnabled = false
        settings.quietHoursEnabled = true
        settings.quietHoursStart = 23 * 60
        settings.quietHoursEnd = 7 * 60
        settings.mutedProjectRoots = ["/r/corestory"]
        settings.limitAlertsEnabled = false
        settings.localModelAlertsEnabled = false
        XCTAssertEqual(NotificationPreferences(settings: settings),
                       NotificationPreferences(enabled: false, quietHours: QuietHours(start: 23 * 60, end: 7 * 60),
                                               mutedProjectRoots: ["/r/corestory"], limitAlerts: false,
                                               localModelAlerts: false))
    }

    // MARK: - Input and limited sessions

    func testAQuestionPostsItsOwnActiveNotificationAtOnce() throws {
        send("s1", .promptSubmitted("Fix it"), at: 0)
        let asked = send("s1", .questionAsked("Which framework?"), at: 3, project: corestory)
        let request = try XCTUnwrap(asked.post.first)
        XCTAssertEqual(request.cause, .input)
        XCTAssertEqual(request.kind, .permission, "routed like a session notification")
        XCTAssertEqual(request.interruption, .active)
        XCTAssertEqual(request.title, "Claude Code has a question")
        XCTAssertEqual(request.body, "Fix it · CoreStory")
        XCTAssertEqual(request.session, SessionKey(source: .claudeCode, id: "s1"))

        XCTAssertEqual(send("s1", .toolFinished("AskUserQuestion"), at: 20).withdraw, [id("s1")])
        XCTAssertTrue(send("s1", .questionAsked("Again?"), at: 30).post.isEmpty, "cooldown per session and cause")
        send("s1", .toolFinished("AskUserQuestion"), at: 35)
        XCTAssertEqual(send("s1", .needsPermission("Allow Bash?"), at: 40).post.first?.cause, .permission)
        send("s1", .toolFinished("Bash"), at: 45)
        XCTAssertEqual(send("s1", .turnFinished("Done"), at: 100).post.first?.cause, .yourTurn)
    }

    private func full(_ kind: LimitKind = .fiveHour, at seconds: TimeInterval = 0, resetsAt: TimeInterval = 3600,
                      utilization: Double = 100) -> LimitSample {
        LimitSample(kind: kind, ts: at(seconds), utilization: utilization, resetsAt: at(resetsAt))
    }

    private var live: [AgentSession] { board.ordered }

    func testOneNotificationWhenTheWindowHoldingSessionsUpResets() throws {
        send("s1", .promptSubmitted("Fix it"), at: 0)
        send("s1", .turnFailed(error: "rate_limit", message: "API Error: Rate limit reached"), at: 10)
        send("s2", .promptSubmitted("Other"), at: 0)
        send("s2", .turnFinished(nil), at: 12)
        for seconds in stride(from: 15.0, to: 3600, by: 300) {
            XCTAssertTrue(policy.limitedSessionsChecked(live, limits: [full()], now: at(seconds)).isEmpty)
        }
        let reset = policy.limitedSessionsChecked(live, limits: [full()], now: at(3601))
        let request = try XCTUnwrap(reset.post.first)
        XCTAssertEqual(reset.post.count, 1)
        XCTAssertEqual(request.cause, .limitReset)
        XCTAssertEqual(request.kind, .limit)
        XCTAssertEqual(request.title, "Claude 5-hour limit reset")
        XCTAssertEqual(request.body, "2 sessions can continue.")
        XCTAssertEqual(request.threadID, NotificationPolicy.limitsThreadID)
        XCTAssertEqual(request.id, NotificationPolicy.limitResetID(.fiveHour, resetsAt: at(3600)))

        XCTAssertTrue(policy.limitedSessionsChecked(live, limits: [full()], now: at(3606)).isEmpty)
        let next = full(at: 3700, resetsAt: 21_600, utilization: 2)
        XCTAssertTrue(policy.limitedSessionsChecked(live, limits: [next], now: at(3700)).isEmpty)
    }

    func testNoResetNotificationForSessionsThatMovedOn() {
        send("s1", .promptSubmitted("Fix it"), at: 0)
        send("s1", .turnFinished(nil), at: 10)
        XCTAssertTrue(policy.limitedSessionsChecked(live, limits: [full()], now: at(20)).isEmpty)
        send("s1", .sessionEnded(nil), at: 30)
        XCTAssertTrue(policy.limitedSessionsChecked(live, limits: [full()], now: at(35)).isEmpty)
        XCTAssertTrue(policy.limitedSessionsChecked(live, limits: [full()], now: at(3601)).isEmpty)

        send("s3", .promptSubmitted("Work"), at: 3700)
        XCTAssertTrue(policy.limitedSessionsChecked(live, limits: [full(at: 3700, resetsAt: 7200)], now: at(3700)).isEmpty,
                      "a working session is not limited")
    }

    func testAnEarlierReadingWithRoomAlsoCountsAsReset() throws {
        send("s1", .promptSubmitted("Fix it"), at: 0)
        send("s1", .turnFinished(nil), at: 10)
        _ = policy.limitedSessionsChecked(live, limits: [full()], now: at(20))
        XCTAssertTrue(policy.limitedSessionsChecked(live, limits: [], now: at(100)).isEmpty,
                      "no reading is not a reset")
        let lifted = policy.limitedSessionsChecked(live, limits: [full(at: 200, utilization: 60)], now: at(200))
        XCTAssertEqual(lifted.post.first?.body, "Fix it can continue.")
        XCTAssertEqual(lifted.post.first?.session, SessionKey(source: .claudeCode, id: "s1"))
    }

    func testEachProviderGetsItsOwnResetNotification() throws {
        let codexKind = try XCTUnwrap(LimitKind.codex(windowMinutes: 10_080))
        send("s1", .promptSubmitted("Fix it"), at: 0)
        send("s1", .turnFinished(nil), at: 10)
        let codex = SessionKey(source: .codexCLI, id: "c1")
        board.apply(AgentEvent(key: codex, kind: .promptSubmitted("Port it"), time: at(0), fromHook: true))
        board.apply(AgentEvent(key: codex, kind: .turnFinished(nil), time: at(12), fromHook: true))
        let held = [full(), full(codexKind, resetsAt: 7200)]
        XCTAssertTrue(policy.limitedSessionsChecked(live, limits: held, now: at(20)).isEmpty)

        let claudeReset = policy.limitedSessionsChecked(live, limits: held, now: at(3601))
        XCTAssertEqual(claudeReset.post.map(\.title), ["Claude 5-hour limit reset"])
        XCTAssertEqual(claudeReset.post.first?.session, SessionKey(source: .claudeCode, id: "s1"))
        XCTAssertTrue(policy.limitedSessionsChecked(live, limits: held, now: at(3700)).isEmpty)
        let codexReset = policy.limitedSessionsChecked(live, limits: held, now: at(7201))
        XCTAssertEqual(codexReset.post.map(\.title), ["Codex weekly limit reset"])
        XCTAssertEqual(codexReset.post.first?.body, "Port it can continue.")
        XCTAssertEqual(codexReset.post.first?.id, NotificationPolicy.limitResetID(codexKind, resetsAt: at(7200)))
    }

    func testResetNotificationRespectsPreferencesAndQuietHours() {
        send("s1", .promptSubmitted("Fix it"), at: 0)
        send("s1", .turnFinished(nil), at: 10)
        policy.preferences.limitAlerts = false
        _ = policy.limitedSessionsChecked(live, limits: [full()], now: at(20))
        XCTAssertTrue(policy.limitedSessionsChecked(live, limits: [full()], now: at(3601)).isEmpty)

        policy.preferences.limitAlerts = true
        policy.preferences.quietHours = QuietHours(start: 12 * 60, end: 20 * 60)
        _ = policy.limitedSessionsChecked(live, limits: [full(at: 3700, resetsAt: 7200)], now: at(3700))
        XCTAssertTrue(policy.limitedSessionsChecked(live, limits: [], now: at(7201)).isEmpty)
        policy.preferences.quietHours = nil
        XCTAssertTrue(policy.limitedSessionsChecked(live, limits: [], now: at(7300)).isEmpty, "not posted late")
    }
}
