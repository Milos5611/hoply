import AgentKit
import Foundation
import XCTest

final class RemoteSnapshotTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func key(_ id: String, _ source: AgentSource = .claudeCode) -> SessionKey {
        SessionKey(source: source, id: id)
    }

    private func board() -> SessionBoard {
        var board = SessionBoard()
        let events: [(SessionKey, String?, AgentEvent.Kind, TimeInterval, Bool)] = [
            (key("a"), "/r/api", .promptSubmitted("Fix the login"), 0, true),
            (key("a"), nil, .needsPermission("Bash"), 10, true),
            (key("b"), "/r/web", .promptSubmitted("Ship it"), 20, true),
            (key("b"), nil, .turnFinished("Done."), 30, true),
            (key("c", .copilotCLI), "/r/web/sub", .promptSubmitted("Tidy"), 40, true),
            (key("d", .codexCLI), nil, .sessionStarted, 50, true),
            (key("e", .qwenCode), "/r/q", .usage(AgentEvent.Usage(inputTokens: 900, outputTokens: 100)), 60, false),
        ]
        for (key, cwd, kind, seconds, hook) in events {
            board.apply(AgentEvent(key: key, kind: kind, time: t0.addingTimeInterval(seconds), cwd: cwd,
                                   fromHook: hook))
        }
        return board
    }

    private func build(today: [AgentSource: LedgerTotals]? = [:], week: LedgerTotals? = nil,
                       totals: [SessionKey: LedgerTotals] = [:], approvals: [ApprovalRequest] = [],
                       replies: [TurnReplyRequest] = [], limitedUntil: [SessionKey: Date] = [:]) -> RemoteSnapshot {
        let web = ProjectRef(id: 7, root: "/r/web", name: "web", displayName: "Website", kind: .repo)
        return RemoteSnapshot.build(device: "mac-1", deviceName: "Studio", away: true, sessions: board().ordered,
                                    projects: ["/r/web": web, "/r/web/sub": web], sessionTotals: totals,
                                    limitedUntil: limitedUntil, approvals: approvals, replies: replies, today: today,
                                    week: week, now: t0.addingTimeInterval(100))
    }

    func testSessionsCarryStateProjectAndTitle() throws {
        let snapshot = build()
        XCTAssertEqual(snapshot.device, "mac-1")
        XCTAssertEqual(snapshot.deviceName, "Studio")
        XCTAssertTrue(snapshot.away)
        XCTAssertEqual(snapshot.updatedAt, t0.addingTimeInterval(100))
        let byKey = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.key, $0) })
        let a = try XCTUnwrap(byKey["claude-code:a"])
        XCTAssertEqual(a.agent, "claude-code")
        XCTAssertEqual(a.source, .claudeCode)
        XCTAssertEqual(a.state, .permission)
        XCTAssertEqual(a.title, "Fix the login")
        XCTAssertEqual(a.project, "api", "no resolved project: the folder name, as in the panel")
        XCTAssertEqual(a.since, t0.addingTimeInterval(10))
        XCTAssertEqual(byKey["claude-code:b"]?.state, .yourTurn)
        XCTAssertEqual(byKey["claude-code:b"]?.project, "Website", "the resolved project's title wins")
        XCTAssertEqual(byKey["copilot-cli:c"]?.project, "Website")
        XCTAssertEqual(byKey["copilot-cli:c"]?.state, .working)
        XCTAssertNil(byKey["codex-cli:d"]?.project)
        XCTAssertEqual(byKey["codex-cli:d"]?.state, .idle)
        XCTAssertNil(a.waiting)
        XCTAssertNil(a.cost)
    }

    func testUnpricedStaysNilNeverZero() throws {
        let unpriced = LedgerTotals(costUSD: 0, apiEquivUSD: 0, tokens: TokenCounts(input: 500, output: 20), calls: 2,
                                    hasUnpriced: true)
        let partial = LedgerTotals(costUSD: 1.5, apiEquivUSD: 2.5, tokens: TokenCounts(input: 100), calls: 3,
                                   hasUnpriced: true)
        let priced = LedgerTotals(costUSD: 0.4, apiEquivUSD: 0.75, tokens: TokenCounts(input: 40, output: 10), calls: 1)
        let snapshot = build(today: [.claudeCode: priced, .qwenCode: unpriced, .copilotCLI: partial],
                             week: unpriced, totals: [key("a"): unpriced, key("b"): partial, key("c", .copilotCLI): priced])
        let byKey = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.key, $0) })

        XCTAssertEqual(byKey["claude-code:a"]?.cost, RemoteCost(usd: nil, hasUnpriced: true, tokens: 520))
        XCTAssertEqual(byKey["claude-code:b"]?.cost, RemoteCost(usd: 2.5, hasUnpriced: true, tokens: 100),
                       "partly priced: a lower bound, like the panel's $x+")
        XCTAssertEqual(byKey["copilot-cli:c"]?.cost, RemoteCost(usd: 0.75, tokens: 50), "the API-equivalent figure")
        XCTAssertNil(byKey["codex-cli:d"]?.cost, "no usage at all")
        XCTAssertEqual(byKey["qwen-code:e"]?.cost, RemoteCost(usd: nil, tokens: 1000),
                       "live telemetry without a cost has tokens and no price")

        XCTAssertEqual(snapshot.spend.today, RemoteCost(usd: 3.25, hasUnpriced: true, tokens: 670))
        XCTAssertEqual(snapshot.spend.week, RemoteCost(usd: nil, hasUnpriced: true, tokens: 520))
        XCTAssertEqual(snapshot.spend.byAgent.map(\.agent), ["claude-code", "copilot-cli", "qwen-code"],
                       "the panel's agent order, only agents with usage today")
        XCTAssertEqual(snapshot.spend.byAgent.map(\.today.usd), [0.75, 2.5, nil])
        XCTAssertEqual(snapshot.spend.byAgent.last?.source, .qwenCode)
    }

    func testSpendWithoutHistoryIsUnknownNotZero() {
        let closed = build(today: nil)
        XCTAssertNil(closed.spend.today, "history not open yet: unknown")
        XCTAssertNil(closed.spend.week)
        XCTAssertEqual(closed.spend.byAgent, [])
        XCTAssertEqual(build(today: [:]).spend.today, RemoteCost(usd: 0), "an open ledger with no usage today is $0")
    }

    func testWaitingSessionsComeFirstWithTheirKind() {
        let approval = ApprovalRequest(key: key("a"), tool: "Bash", detail: "ls", received: t0)
        let reply = TurnReplyRequest(key: key("b"), message: "Done.", received: t0)
        let both = TurnReplyRequest(key: key("a"), message: nil, received: t0)
        let snapshot = build(approvals: [approval], replies: [reply, both])
        XCTAssertEqual(snapshot.sessions.prefix(2).map(\.key), ["claude-code:a", "claude-code:b"])
        XCTAssertEqual(snapshot.sessions.prefix(2).map(\.waiting), [.approval, .reply], "an approval outranks a reply")
        XCTAssertEqual(snapshot.sessions.dropFirst(2).compactMap(\.waiting), [])
        XCTAssertEqual(Set(snapshot.sessions.map(\.key)).count, 5)
    }

    func testLimitedSessionKeepsItsResetTime() throws {
        let until = t0.addingTimeInterval(3600)
        let snapshot = build(limitedUntil: [key("b"): until])
        let b = try XCTUnwrap(snapshot.sessions.first { $0.key == "claude-code:b" })
        XCTAssertEqual(b.state, .limited)
        XCTAssertEqual(b.limitedUntil, until)
    }

    func testLongTitlesAreClipped() throws {
        var board = SessionBoard()
        let long = String(repeating: "x", count: RemoteSchema.titleLimit + 50)
        let key = key("long")
        board.apply(AgentEvent(key: key, kind: .promptSubmitted("p"), time: t0, fromHook: true))
        board.noteTitles([key: long])
        let snapshot = RemoteSnapshot.build(device: "m", away: false, sessions: board.ordered, today: nil, now: t0)
        let title = try XCTUnwrap(snapshot.sessions.first?.title)
        XCTAssertEqual(title.count, RemoteSchema.titleLimit + 1)
        XCTAssertTrue(title.hasSuffix("…"))
        let approval = ApprovalRequest(key: key, tool: "Bash", detail: nil, received: t0)
        XCTAssertEqual(RemoteRequest.approval(approval, session: board.sessions[key], device: "m").title, title)
    }

    func testSessionCountIsCappedKeepingWaitingOnes() {
        var board = SessionBoard()
        for index in 0..<(RemoteSnapshot.maxSessions + 10) {
            board.apply(AgentEvent(key: key("s\(index)"), kind: .promptSubmitted("p"),
                                   time: t0.addingTimeInterval(Double(index)), fromHook: true))
        }
        let waiting = TurnReplyRequest(key: key("s0"), message: nil, received: t0)
        let snapshot = RemoteSnapshot.build(device: "m", away: false, sessions: board.ordered, replies: [waiting],
                                            today: nil, now: t0)
        XCTAssertEqual(snapshot.sessions.count, RemoteSnapshot.maxSessions)
        XCTAssertEqual(snapshot.sessions.first?.key, "claude-code:s0", "the oldest session is kept: it waits")
    }

    func testPublishingWaitsOnlyForCostChanges() {
        var snapshot = build()
        let start = t0.addingTimeInterval(100)
        XCTAssertTrue(RemoteLinkPolicy.shouldPublish(snapshot, last: nil, at: nil, now: start))
        var later = snapshot
        later.updatedAt = start.addingTimeInterval(5)
        XCTAssertFalse(RemoteLinkPolicy.shouldPublish(later, last: snapshot, at: start, now: start.addingTimeInterval(5)))
        XCTAssertTrue(RemoteLinkPolicy.shouldPublish(later, last: snapshot, at: start,
                                                     now: start.addingTimeInterval(RemoteLinkPolicy.heartbeat)),
                      "a heartbeat tells the phone the Mac is still there")

        later.sessions[0].cost = RemoteCost(usd: 1)
        XCTAssertFalse(RemoteLinkPolicy.shouldPublish(later, last: snapshot, at: start, now: start.addingTimeInterval(5)))
        XCTAssertTrue(RemoteLinkPolicy.shouldPublish(later, last: snapshot, at: start,
                                                     now: start.addingTimeInterval(RemoteLinkPolicy.publishInterval)))

        var urgent = snapshot
        urgent.away = false
        XCTAssertTrue(RemoteLinkPolicy.shouldPublish(urgent, last: snapshot, at: start, now: start.addingTimeInterval(1)))
        urgent = snapshot
        urgent.sessions[1].state = .working
        XCTAssertTrue(RemoteLinkPolicy.shouldPublish(urgent, last: snapshot, at: start, now: start.addingTimeInterval(1)))
        urgent = snapshot
        urgent.sessions[1].waiting = .reply
        XCTAssertTrue(RemoteLinkPolicy.shouldPublish(urgent, last: snapshot, at: start, now: start.addingTimeInterval(1)))
        snapshot.sessions.removeLast()
        XCTAssertTrue(RemoteLinkPolicy.shouldPublish(snapshot, last: later, at: start, now: start.addingTimeInterval(1)))

        XCTAssertEqual(RemoteLinkPolicy.pollInterval(openRequests: 1), RemoteLinkPolicy.pollWhileOpen)
        XCTAssertEqual(RemoteLinkPolicy.pollInterval(openRequests: 0), RemoteLinkPolicy.pollIdle)
        XCTAssertLessThan(RemoteLinkPolicy.pollWhileOpen, RemoteLinkPolicy.pollIdle)
    }
}

final class RemoteRequestTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ key: SessionKey, cwd: String, prompt: String) -> AgentSession? {
        var board = SessionBoard()
        board.apply(AgentEvent(key: key, kind: .promptSubmitted(prompt), time: t0, cwd: cwd, fromHook: true))
        return board.sessions[key]
    }

    func testApprovalExpiresAtTheHoldLimit() {
        let key = SessionKey(source: .claudeCode, id: "s1")
        let approval = ApprovalRequest(id: "ap-1", key: key, tool: "Bash", detail: "rm -rf build", received: t0)
        let api = ProjectRef(id: 1, root: "/r/api", name: "api", displayName: "API", kind: .repo)
        let request = RemoteRequest.approval(approval, session: session(key, cwd: "/r/api", prompt: "Clean up"),
                                             projects: ["/r/api": api], device: "mac-1")
        XCTAssertEqual(request, RemoteRequest(id: "ap-1", kind: .approval, device: "mac-1", session: "claude-code:s1",
                                              agent: "claude-code", project: "API", title: "Clean up", tool: "Bash",
                                              detail: "rm -rf build", createdAt: t0,
                                              expiresAt: t0.addingTimeInterval(PermissionApproval.holdLimit)))
        XCTAssertEqual(request.source, .claudeCode)
        let bare = RemoteRequest.approval(approval, session: nil, device: "mac-1")
        XCTAssertNil(bare.project)
        XCTAssertNil(bare.title)
    }

    func testReplyExpiresAtTheHoldLimit() {
        let key = SessionKey(source: .copilotCLI, id: "cp-9")
        let reply = TurnReplyRequest(id: "re-1", key: key, message: "All tests pass.", received: t0,
                                     transcriptPath: "/Users/x/.copilot/session-state/cp-9/events.jsonl")
        let request = RemoteRequest.reply(reply, session: session(key, cwd: "/r/web", prompt: "Run tests"),
                                          device: "mac-1")
        XCTAssertEqual(request, RemoteRequest(id: "re-1", kind: .reply, device: "mac-1", session: "copilot-cli:cp-9",
                                              agent: "copilot-cli", project: "web", title: "Run tests",
                                              message: "All tests pass.", createdAt: t0,
                                              expiresAt: t0.addingTimeInterval(TurnReply.holdLimit)))
        XCTAssertGreaterThan(TurnReply.holdLimit, PermissionApproval.holdLimit)
    }

    func testReplyCarriesTheWholeMessageUpToTheCap() throws {
        var stop = try XCTUnwrap(try Fixture.hookPayloads("claude_hooks.json")["Stop"])
        func remote(_ text: String) throws -> RemoteRequest {
            stop["last_assistant_message"] = text
            let reply = try XCTUnwrap(TurnReply.request(source: .claudeCode, eventName: nil, json: stop,
                                                        headers: [TurnReply.header: "1"], now: t0))
            return RemoteRequest.reply(reply, session: nil, device: "mac-1")
        }
        let limit = TurnReply.messageLimit
        let paragraph = "The refresh path now awaits the token; 214 tests pass.\n\n"
        let whole = String(String(repeating: paragraph, count: limit / paragraph.count + 1).prefix(limit - 1)) + "."
        XCTAssertEqual(whole.count, limit)
        XCTAssertEqual(try remote(whole).message, whole, "the phone gets the whole message")
        XCTAssertEqual(try remote(String(whole.prefix(1500))).message?.count, 1500)

        let longer = whole + String(repeating: "y", count: 5000)
        XCTAssertEqual(try remote(longer).message, whole + "…")
        let direct = TurnReplyRequest(id: "re-2", key: SessionKey(source: .claudeCode, id: "s1"), message: longer,
                                      received: t0)
        XCTAssertEqual(RemoteRequest.reply(direct, session: nil, device: "mac-1").message, whole + "…",
                       "the record caps whatever it is given")

        let kiss = "🧑🏼‍❤️‍💋‍🧑🏾"
        XCTAssertEqual(kiss.count, 1)
        XCTAssertEqual(kiss.utf8.count, 35)
        let widest = TurnReplyRequest(id: "re-3", key: SessionKey(source: .claudeCode, id: "s1"),
                                      message: String(repeating: kiss, count: limit + 10), received: t0)
        let request = RemoteRequest.reply(widest, session: nil, device: "mac-1")
        XCTAssertEqual(request.message?.count, limit + 1)
        XCTAssertLessThan(try RemoteSchema.record(request).payload.count, 1_000_000,
                          "CloudKit refuses a record over 1 MB")
    }
}

final class RemoteAnswerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let device = "mac-1"
    private lazy var approval = ApprovalRequest(id: "ap", key: SessionKey(source: .claudeCode, id: "s1"), tool: "Bash",
                                                detail: "ls", received: t0)
    private lazy var reply = TurnReplyRequest(id: "re", key: SessionKey(source: .claudeCode, id: "s2"), message: nil,
                                              received: t0)
    private lazy var approvalRequest = RemoteRequest.approval(approval, session: nil, device: device)
    private lazy var replyRequest = RemoteRequest.reply(reply, session: nil, device: device)

    private func resolve(_ answers: [RemoteAnswer], handled: Set<String> = [], awaySetAt: Date? = nil,
                         now: Date? = nil) -> RemoteResolution {
        RemoteAnswers.resolve(answers, approvals: [approval], replies: [reply], device: device, handled: handled,
                              awaySetAt: awaySetAt, now: now ?? t0.addingTimeInterval(120))
    }

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testEachKindBecomesItsAction() {
        let allow = RemoteAnswer.decide(.allow, to: approvalRequest, at: at(5))
        let text = RemoteAnswer.reply("  run the tests again \n", to: replyRequest, at: at(6))
        let away = RemoteAnswer.away(false, device: device, at: at(7))
        let result = resolve([allow, text, away])
        XCTAssertEqual(result.actions, [.decide(id: "ap", .allow), .reply(id: "re", text: "run the tests again"),
                                        .setAway(false)])
        XCTAssertEqual(result.acknowledged, [allow.id, text.id, away.id])
        XCTAssertEqual(resolve([RemoteAnswer.decide(.deny, to: approvalRequest, at: at(5))]).actions,
                       [.decide(id: "ap", .deny)])
        XCTAssertEqual(resolve([RemoteAnswer.done(replyRequest, at: at(5))]).actions, [.finish(id: "re")])
        XCTAssertEqual(resolve([RemoteAnswer.away(true, device: nil, at: at(5))]).actions, [.setAway(true)],
                       "an away answer without a device is for every Mac")
    }

    func testAnswersForUnknownOrClosedRequestsAreIgnoredAndDeleted() {
        var stray = RemoteAnswer.decide(.allow, to: approvalRequest, at: at(5))
        stray.requestID = "gone"
        let first = RemoteAnswer.decide(.deny, to: approvalRequest, at: at(5))
        let second = RemoteAnswer.decide(.allow, to: approvalRequest, at: at(6))
        let done = RemoteAnswer.done(replyRequest, at: at(7))
        let lateText = RemoteAnswer.reply("more", to: replyRequest, at: at(8))
        let result = resolve([stray, first, second, done, lateText])
        XCTAssertEqual(result.actions, [.decide(id: "ap", .deny), .finish(id: "re")],
                       "the first answer closes a request; a double tap on the phone does nothing")
        XCTAssertEqual(result.acknowledged, [stray.id, first.id, second.id, done.id, lateText.id])
    }

    func testAnswersOlderThanTheirRequestAreIgnored() {
        let stale = RemoteAnswer.decide(.allow, to: approvalRequest, at: at(-RemoteAnswers.clockTolerance - 1))
        let skewed = RemoteAnswer.reply("go", to: replyRequest, at: at(-RemoteAnswers.clockTolerance + 1))
        let result = resolve([stale, skewed])
        XCTAssertEqual(result.actions, [.reply(id: "re", text: "go")], "a phone clock a little behind still counts")
        XCTAssertEqual(result.acknowledged, [stale.id, skewed.id])
    }

    func testBlankReplyTextIsNotADone() {
        let blank = RemoteAnswer.reply(" \n ", to: replyRequest, at: at(5))
        var missing = RemoteAnswer.reply("x", to: replyRequest, at: at(6))
        missing.text = nil
        let result = resolve([blank, missing])
        XCTAssertEqual(result.actions, [])
        XCTAssertEqual(result.acknowledged, [blank.id, missing.id])
        XCTAssertEqual(resolve([blank, RemoteAnswer.done(replyRequest, at: at(7))]).actions, [.finish(id: "re")],
                       "the request stays open for a real answer")
    }

    func testKindMismatchesAndUnreadableAnswersAreIgnored() {
        var decideReply = RemoteAnswer.decide(.allow, to: replyRequest, at: at(5))
        decideReply.device = device
        let replyApproval = RemoteAnswer.reply("yes", to: approvalRequest, at: at(6))
        let doneApproval = RemoteAnswer.done(approvalRequest, at: at(7))
        var noDecision = RemoteAnswer.decide(.allow, to: approvalRequest, at: at(8))
        noDecision.decision = .unknown
        let unknown = RemoteAnswer(device: device, kind: .unknown, createdAt: at(9))
        let noFlag = RemoteAnswer(device: device, kind: .away, createdAt: at(10))
        let result = resolve([decideReply, replyApproval, doneApproval, noDecision, unknown, noFlag])
        XCTAssertEqual(result.actions, [])
        XCTAssertEqual(result.acknowledged.count, 6)
    }

    func testDuplicatesApplyOnce() {
        let allow = RemoteAnswer.decide(.allow, to: approvalRequest, at: at(5))
        let again = resolve([allow, allow])
        XCTAssertEqual(again.actions, [.decide(id: "ap", .allow)])
        XCTAssertEqual(again.acknowledged, [allow.id])
        let refetched = resolve([allow], handled: [allow.id])
        XCTAssertEqual(refetched.actions, [], "already applied in an earlier fetch")
        XCTAssertEqual(refetched.acknowledged, [allow.id], "its delete is retried")
    }

    func testOrderFollowsCreationTimeThenInput() {
        let on = RemoteAnswer.away(true, device: device, at: at(10))
        let off = RemoteAnswer.away(false, device: device, at: at(20))
        let tie = RemoteAnswer.away(true, device: device, at: at(20))
        XCTAssertEqual(resolve([off, on]).actions, [.setAway(true), .setAway(false)])
        XCTAssertEqual(resolve([on, off, tie]).actions, [.setAway(true), .setAway(false), .setAway(true)])
        XCTAssertEqual(resolve([off, on, tie]).acknowledged, [on.id, off.id, tie.id])
    }

    func testLeavingAwayClosesReplies() {
        let off = RemoteAnswer.away(false, device: device, at: at(5))
        let text = RemoteAnswer.reply("continue", to: replyRequest, at: at(6))
        let allow = RemoteAnswer.decide(.allow, to: approvalRequest, at: at(7))
        XCTAssertEqual(resolve([off, text, allow]).actions, [.setAway(false), .decide(id: "ap", .allow)],
                       "leaving Away releases held turn ends; approvals follow their own setting")
        let laterOff = RemoteAnswer.away(false, device: device, at: at(8))
        XCTAssertEqual(resolve([laterOff, text]).actions, [.reply(id: "re", text: "continue"), .setAway(false)])
    }

    func testAwayAnswersOlderThanTheLastLocalChangeAreIgnored() {
        let off = RemoteAnswer.away(false, device: device, at: at(5))
        XCTAssertEqual(resolve([off], awaySetAt: at(10)).actions, [])
        XCTAssertEqual(resolve([off], awaySetAt: at(10)).acknowledged, [off.id])
        XCTAssertEqual(resolve([off], awaySetAt: at(5)).actions, [.setAway(false)])
    }

    func testAnotherMacsAnswersAreLeftForIt() {
        var foreign = RemoteAnswer.decide(.allow, to: approvalRequest, at: at(5))
        foreign.device = "mac-2"
        let otherAway = RemoteAnswer.away(true, device: "mac-2", at: at(6))
        let result = resolve([foreign, otherAway])
        XCTAssertEqual(result.actions, [])
        XCTAssertEqual(result.acknowledged, [])
        let old = resolve([foreign], now: at(5 + RemoteAnswers.foreignLifetime + 1))
        XCTAssertEqual(old.actions, [])
        XCTAssertEqual(old.acknowledged, [foreign.id], "a day later nobody will apply it")
    }
}

final class RemoteSchemaTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000.25)

    func testRecordsRoundTripThroughTheirPayload() throws {
        let snapshot = RemoteSnapshot(
            device: "mac-1", deviceName: "Studio", away: true, updatedAt: t0,
            sessions: [RemoteSnapshot.Session(key: "claude-code:s1", agent: "claude-code", project: "API", title: "Fix",
                                              state: .permission, since: t0, cost: RemoteCost(usd: nil, hasUnpriced: true,
                                                                                              tokens: 12),
                                              waiting: .approval)],
            spend: RemoteSnapshot.Spend(today: RemoteCost(usd: 1.25, tokens: 900), week: nil,
                                        byAgent: [RemoteSnapshot.AgentSpend(agent: "claude-code",
                                                                            today: RemoteCost(usd: 1.25, tokens: 900))]))
        let snapshotRecord = try RemoteSchema.record(snapshot)
        XCTAssertEqual(snapshotRecord.type, RemoteSchema.RecordType.snapshot)
        XCTAssertEqual(snapshotRecord.name, "snapshot-mac-1")
        XCTAssertNil(snapshotRecord.kind)
        XCTAssertEqual(snapshotRecord.createdAt, t0)
        XCTAssertEqual(snapshotRecord.version, RemoteSchema.version)
        XCTAssertEqual(RemoteSchema.snapshot(from: snapshotRecord), snapshot)

        let request = RemoteRequest(id: "ap-1", kind: .approval, device: "mac-1", session: "claude-code:s1",
                                    agent: "claude-code", project: "API", title: "Fix", tool: "Bash", detail: "ls",
                                    createdAt: t0, expiresAt: t0.addingTimeInterval(570))
        let requestRecord = try RemoteSchema.record(request)
        XCTAssertEqual(requestRecord.type, RemoteSchema.RecordType.request)
        XCTAssertEqual(requestRecord.name, "ap-1")
        XCTAssertEqual(requestRecord.kind, "approval")
        XCTAssertEqual(RemoteSchema.request(from: requestRecord), request)

        let answer = RemoteAnswer.reply("go on", to: request, at: t0)
        let answerRecord = try RemoteSchema.record(answer)
        XCTAssertEqual(answerRecord.type, RemoteSchema.RecordType.answer)
        XCTAssertEqual(answerRecord.name, answer.id)
        XCTAssertEqual(answerRecord.kind, "reply")
        XCTAssertEqual(RemoteSchema.answer(from: answerRecord), answer)

        XCTAssertNil(RemoteSchema.request(from: snapshotRecord))
        XCTAssertNil(RemoteSchema.answer(from: requestRecord))
        XCTAssertNil(RemoteSchema.snapshot(from: answerRecord))
    }

    func testContentStaysInTheEncryptedPayload() throws {
        XCTAssertEqual(RemoteSchema.Field.encrypted, [RemoteSchema.Field.payload])
        let request = RemoteRequest(id: "re-1", kind: .reply, device: "mac-1", session: "claude-code:s1",
                                    agent: "claude-code", message: "secret plan", createdAt: t0, expiresAt: t0)
        let record = try RemoteSchema.record(request)
        XCTAssertEqual(record.kind, "reply")
        XCTAssertEqual(String(decoding: record.payload, as: UTF8.self).contains("secret plan"), true)
        XCTAssertEqual(RemoteSchema.containerID, "iCloud.com.coolcraftcoders.hoply")
        XCTAssertEqual(RemoteSchema.zoneName, "Hoply")
    }

    func testRecordNamesWinOverPayloadIDs() throws {
        let answer = RemoteAnswer.away(true, device: nil, at: t0)
        var record = try RemoteSchema.record(answer)
        record.name = "renamed"
        XCTAssertEqual(RemoteSchema.answer(from: record)?.id, "renamed")
    }

    func testUnreadableAnswersStillComeBackToBeDeleted() {
        let record = RemoteRecord(type: RemoteSchema.RecordType.answer, name: "a-1", kind: "decide", createdAt: t0,
                                  payload: Data("not json".utf8))
        XCTAssertEqual(RemoteSchema.answer(from: record), RemoteAnswer(id: "a-1", kind: .unknown, createdAt: t0))
        let undated = RemoteRecord(type: RemoteSchema.RecordType.answer, name: "a-2", kind: nil, createdAt: nil,
                                   payload: Data())
        XCTAssertEqual(RemoteSchema.answer(from: undated)?.kind, .unknown)
    }

    func testNewerValuesDecodeAsUnknown() throws {
        let answer = #"{"id":"a","kind":"snooze","decision":"maybe","createdAt":1800000000,"later":1}"#
        let decoded = try RemoteSchema.decode(RemoteAnswer.self, from: Data(answer.utf8))
        XCTAssertEqual(decoded.kind, .unknown)
        XCTAssertEqual(decoded.decision, .unknown)
        let session = #"{"key":"k","agent":"cursor","state":"sleeping","since":1800000000,"waiting":"call"}"#
        let row = try RemoteSchema.decode(RemoteSnapshot.Session.self, from: Data(session.utf8))
        XCTAssertEqual(row.state, .unknown)
        XCTAssertEqual(row.waiting, .unknown)
        XCTAssertNil(row.source, "an agent this build doesn't know")
        XCTAssertNil(row.cost)
    }

    func testDatesKeepSubsecondPrecision() throws {
        let answer = RemoteAnswer(id: "a", kind: .done, createdAt: t0)
        let decoded = try RemoteSchema.decode(RemoteAnswer.self, from: RemoteSchema.encode(answer))
        XCTAssertEqual(decoded.createdAt, t0)
    }
}
