import AgentKit
import Foundation
import XCTest

final class RemoteTranscriptTests: XCTestCase {
    private typealias Message = RemoteTranscript.Message
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000.5)

    private func build(_ messages: [Message], earlierOmitted: Bool = false) -> RemoteTranscript {
        RemoteTranscript.build(device: "mac-1", session: "claude-code:s1", agent: "claude-code", answerID: "a-1",
                               messages: messages, earlierOmitted: earlierOmitted, now: t0)
    }

    func testRecordRoundTripsUnderAStableName() throws {
        let transcript = RemoteTranscript(device: "mac-1", session: "claude-code:s1", agent: "claude-code",
                                          answerID: "a-1", updatedAt: t0,
                                          messages: [Message(role: .user, text: "Fix it", at: t0),
                                                     Message(role: .tool, text: "Bash swift test"),
                                                     Message(role: .assistant, text: "Done.", at: t0 + 5)],
                                          truncated: true)
        let record = try RemoteSchema.record(transcript)
        XCTAssertEqual(record.type, "Transcript")
        XCTAssertEqual(record.name, "transcript-mac-1-1f54a97aee48097b")
        XCTAssertNil(record.kind)
        XCTAssertEqual(record.createdAt, t0)
        XCTAssertEqual(record.version, RemoteSchema.version)
        XCTAssertEqual(RemoteSchema.transcript(from: record), transcript)
        XCTAssertNil(RemoteSchema.snapshot(from: record))
        XCTAssertNil(RemoteSchema.transcript(from: try RemoteSchema.record(RemoteSnapshot(device: "mac-1", away: false,
                                                                                         updatedAt: t0))))
        XCTAssertEqual(RemoteSchema.transcriptZoneName, "HoplyTranscripts")
        XCTAssertNotEqual(RemoteSchema.transcriptZoneName, RemoteSchema.zoneName,
                          "the phone fetches the whole Hoply zone and must not download conversations")
    }

    func testRecordNamesAreTheSameOnEveryLaunchAndDevice() {
        let sessions = ["claude-code:s1", "codex-cli:019c0000-0000-7000-8000-000000000003", "copilot-cli:é ü 🎉", ""]
        for session in sessions {
            XCTAssertEqual(RemoteSchema.sessionHash(session), FNV1a.hex64(session.utf8), session)
            XCTAssertEqual(RemoteSchema.sessionHash(session).count, 16)
        }
        XCTAssertEqual(RemoteSchema.sessionHash("claude-code:s1"), "1f54a97aee48097b")
        XCTAssertNotEqual(RemoteSchema.transcriptRecordName(device: "mac-1", session: "claude-code:s1"),
                          RemoteSchema.transcriptRecordName(device: "mac-2", session: "claude-code:s1"))
    }

    func testNewerValuesDecodeAsUnknown() throws {
        let json = #"{"device":"m","session":"s","agent":"cursor","updatedAt":1800000000,"truncated":false,"#
            + #""problem":"busy","messages":[{"role":"system","text":"x"}],"later":1}"#
        let decoded = try RemoteSchema.decode(RemoteTranscript.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.problem, .unknown)
        XCTAssertEqual(decoded.messages.first?.role, .unknown)
        XCTAssertNil(decoded.messages.first?.at)
        XCTAssertNil(decoded.source)
        XCTAssertNil(decoded.answerID)
    }

    func testSmallConversationsGoAsTheyAre() {
        let messages = [Message(role: .user, text: "Hi", at: t0), Message(role: .assistant, text: "Hello")]
        let transcript = build(messages)
        XCTAssertEqual(transcript.messages, messages)
        XCTAssertFalse(transcript.truncated)
        XCTAssertNil(transcript.problem)
        XCTAssertEqual(transcript.answerID, "a-1")
        XCTAssertEqual(transcript.updatedAt, t0)
        XCTAssertTrue(build(messages, earlierOmitted: true).truncated, "the file had more before the part read")
    }

    func testOnlyTheNewestMessagesAndTheirTextUpToTheLimits() {
        let many = (0..<250).map { Message(role: .user, text: "m\($0)") }
        let capped = build(many)
        XCTAssertEqual(capped.messages.count, RemoteTranscriptPolicy.maxMessages)
        XCTAssertEqual(capped.messages.first?.text, "m50")
        XCTAssertEqual(capped.messages.last?.text, "m249")
        XCTAssertTrue(capped.truncated)

        let text = String(repeating: "a", count: RemoteTranscriptPolicy.textLimit)
        let tool = String(repeating: "b", count: RemoteTranscriptPolicy.toolLimit)
        let clipped = build([Message(role: .assistant, text: text + "z"), Message(role: .user, text: text),
                             Message(role: .tool, text: tool + "z"), Message(role: .tool, text: tool)])
        XCTAssertEqual(clipped.messages.map(\.text), [text + "…", text, tool + "…", tool])
        XCTAssertFalse(clipped.truncated, "clipping a message is not leaving one out")
    }

    func testTheRecordStaysUnderCloudKitsLimitWithTheWidestText() throws {
        let kiss = "🧑🏼‍❤️‍💋‍🧑🏾"
        XCTAssertEqual(kiss.utf8.count, 35)
        let wide = String(repeating: kiss, count: RemoteTranscriptPolicy.textLimit + 5)
        let messages = (0..<6).map { Message(role: .assistant, text: wide + "\($0)", at: t0) }
        let transcript = build(messages)
        let payload = try RemoteSchema.record(transcript).payload.count
        XCTAssertLessThanOrEqual(payload, RemoteTranscriptPolicy.byteLimit)
        XCTAssertLessThan(payload, 1_000_000, "CloudKit refuses a record over 1 MB")
        XCTAssertTrue(transcript.truncated)
        XCTAssertEqual(transcript.messages.count, 1, "two of these would pass the byte limit")
        XCTAssertEqual(transcript.messages.last?.text.count, RemoteTranscriptPolicy.textLimit + 1, "the newest one")

        let marks = "a" + String(repeating: "\u{0301}", count: 400_000)
        XCTAssertEqual(marks.count, 1, "one character")
        let zalgo = build([Message(role: .user, text: "before"), Message(role: .user, text: marks)])
        XCTAssertLessThanOrEqual(try RemoteSchema.record(zalgo).payload.count, RemoteTranscriptPolicy.byteLimit)
        XCTAssertEqual(zalgo.messages.last?.text.hasSuffix("…"), true)
        XCTAssertGreaterThan(zalgo.messages.last?.text.utf8.count ?? 0, 600_000, "cut only as far as needed")

        let controls = String(repeating: "\u{0001}", count: RemoteTranscriptPolicy.textLimit)
        let escaped = build((0..<200).map { _ in Message(role: .user, text: controls) })
        XCTAssertLessThanOrEqual(try RemoteSchema.record(escaped).payload.count, RemoteTranscriptPolicy.byteLimit,
                                 "measured as encoded JSON, where one control character takes six bytes")
        XCTAssertGreaterThan(escaped.messages.count, 5)
    }

    func testAProblemCarriesNoMessages() throws {
        let failed = RemoteTranscript.failed(.unknownSession, device: "mac-1", session: "claude-code:nope",
                                             agent: "claude-code", answerID: "a-2", now: t0)
        XCTAssertEqual(failed.problem, .unknownSession)
        XCTAssertEqual(failed.messages, [])
        XCTAssertFalse(failed.truncated)
        XCTAssertEqual(RemoteSchema.transcript(from: try RemoteSchema.record(failed)), failed)
    }

    func testSessionKeysParseBackFromTheirRecordForm() {
        let key = SessionKey(source: .codexCLI, id: "019c:with:colons")
        XCTAssertEqual(RemoteSchema.sessionKey(from: RemoteSchema.sessionKey(key)), key)
        XCTAssertNil(RemoteSchema.sessionKey(from: "cursor:abc"))
        XCTAssertNil(RemoteSchema.sessionKey(from: "claude-code:"))
        XCTAssertNil(RemoteSchema.sessionKey(from: "claude-code"))
    }

    func testSameContentIgnoresOnlyTheTime() {
        let one = build([Message(role: .user, text: "a")])
        var later = one
        later.updatedAt = t0 + 60
        XCTAssertTrue(later.sameContent(as: one))
        later.answerID = "a-2"
        XCTAssertFalse(later.sameContent(as: one), "a newer request needs the record to name it")
    }
}

final class RemoteTranscriptAnswerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let device = "mac-1"

    private func resolve(_ answers: [RemoteAnswer], conversations: Bool = true, handled: Set<String> = [],
                         now: Date? = nil) -> RemoteResolution {
        RemoteAnswers.resolve(answers, approvals: [], replies: [], device: device, handled: handled,
                              conversations: conversations, now: now ?? t0 + 5)
    }

    func testATranscriptAnswerBecomesAnOrder() throws {
        let answer = RemoteAnswer.transcript(session: "claude-code:s1", device: device, at: t0)
        XCTAssertEqual(answer.kind, .transcript)
        XCTAssertEqual(answer.session, "claude-code:s1")
        XCTAssertEqual(answer.device, device)
        XCTAssertEqual(RemoteSchema.answer(from: try RemoteSchema.record(answer)), answer)
        XCTAssertEqual(try RemoteSchema.record(answer).kind, "transcript")
        let result = resolve([answer])
        XCTAssertEqual(result.transcripts, [RemoteTranscriptOrder(answerID: answer.id, session: "claude-code:s1",
                                                                  createdAt: t0)])
        XCTAssertEqual(result.acknowledged, [answer.id])
        XCTAssertEqual(result.actions, [])
        XCTAssertEqual(result.launches, [])
    }

    func testRefusedTranscriptAnswersAreStillDeleted() {
        let off = RemoteAnswer.transcript(session: "claude-code:s1", device: device, at: t0)
        XCTAssertEqual(resolve([off], conversations: false).transcripts, [])
        XCTAssertEqual(resolve([off], conversations: false).acknowledged, [off.id])
        XCTAssertEqual(RemoteAnswers.resolve([off], approvals: [], replies: [], device: device, now: t0).transcripts, [],
                       "off unless the caller says conversations are on")

        let noDevice = RemoteAnswer(device: nil, kind: .transcript, session: "claude-code:s1", createdAt: t0)
        let noSession = RemoteAnswer(device: device, kind: .transcript, session: "", createdAt: t0)
        let missing = RemoteAnswer(device: device, kind: .transcript, createdAt: t0)
        let result = resolve([noDevice, noSession, missing])
        XCTAssertEqual(result.transcripts, [])
        XCTAssertEqual(result.acknowledged, [noDevice.id, noSession.id, missing.id])
    }

    func testOnlyRecentRequestsCount() {
        let limit = RemoteTranscriptPolicy.watchFor + RemoteAnswers.clockTolerance
        let old = RemoteAnswer.transcript(session: "claude-code:old", device: device, at: t0)
        let edge = RemoteAnswer.transcript(session: "claude-code:edge", device: device, at: t0 + 1)
        let result = resolve([old, edge], now: t0 + 1 + limit)
        XCTAssertEqual(result.transcripts.map(\.session), ["claude-code:edge"])
        XCTAssertEqual(result.acknowledged, [old.id, edge.id])
    }

    func testAnotherMacsTranscriptAnswersAreLeftForIt() {
        let foreign = RemoteAnswer.transcript(session: "claude-code:s1", device: "mac-2", at: t0)
        XCTAssertEqual(resolve([foreign]).transcripts, [])
        XCTAssertEqual(resolve([foreign]).acknowledged, [])
        let handled = RemoteAnswer.transcript(session: "claude-code:s1", device: device, at: t0)
        XCTAssertEqual(resolve([handled], handled: [handled.id]).transcripts, [])
        XCTAssertEqual(resolve([handled], handled: [handled.id]).acknowledged, [handled.id])
    }

    func testTheSnapshotSaysWhichAgentsTheMacCanServe() throws {
        func snapshot(_ agents: [AgentSource]?) -> RemoteSnapshot {
            RemoteSnapshot.build(device: device, away: false, sessions: [], today: nil, transcriptAgents: agents, now: t0)
        }
        XCTAssertNil(snapshot(nil).transcriptAgents)
        XCTAssertFalse(String(decoding: try RemoteSchema.encode(snapshot(nil)), as: UTF8.self).contains("transcript"),
                       "a Mac without conversations writes the snapshot exactly as before")
        XCTAssertEqual(snapshot([]).transcriptAgents, [], "turned off on the Mac")
        XCTAssertEqual(snapshot([.copilotCLI, .claudeCode]).transcriptAgents, ["claude-code", "copilot-cli"])
        let decoded = try RemoteSchema.decode(RemoteSnapshot.self,
                                              from: Data(#"{"device":"m","away":false,"updatedAt":1,"sessions":[],"spend":{"byAgent":[]}}"#.utf8))
        XCTAssertNil(decoded.transcriptAgents, "an older Mac's snapshot")

        let on = snapshot([.claudeCode])
        XCTAssertTrue(RemoteLinkPolicy.shouldPublish(snapshot([]), last: on, at: t0, now: t0 + 1),
                      "turning conversations off reaches the phone at once")
        XCTAssertFalse(RemoteLinkPolicy.shouldPublish(on, last: on, at: t0, now: t0 + 1))
    }
}

final class TranscriptWatchesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let session = "claude-code:s1"
    private let refresh = RemoteTranscriptPolicy.refreshEvery
    private let watchFor = RemoteTranscriptPolicy.watchFor

    private func order(_ id: String, _ session: String? = nil, at seconds: TimeInterval) -> RemoteTranscriptOrder {
        RemoteTranscriptOrder(answerID: id, session: session ?? self.session, createdAt: t0 + seconds)
    }

    private func signal(_ size: Int64) -> TranscriptSignal {
        TranscriptSignal(path: "/x/s1.jsonl", size: size, modified: t0)
    }

    private func transcript(_ answerID: String, _ text: String = "a") -> RemoteTranscript {
        RemoteTranscript(device: "mac-1", session: session, agent: "claude-code", answerID: answerID, updatedAt: t0,
                         messages: [RemoteTranscript.Message(role: .user, text: text)])
    }

    func testTheNewestRequestNamesTheWatchAndExtendsIt() {
        var watches = TranscriptWatches()
        watches.add([order("a-2", at: 30), order("a-1", at: 0)], now: t0 + 40)
        XCTAssertEqual(watches.sessions, [session])
        XCTAssertEqual(watches.watch(session)?.answerID, "a-2")
        XCTAssertEqual(watches.watch(session)?.until, t0 + 30 + watchFor)
        watches.add([order("a-0", at: -10)], now: t0 + 50)
        XCTAssertEqual(watches.watch(session)?.answerID, "a-2", "a late copy of an older request")
        watches.add([order("a-3", at: 5_000)], now: t0 + 60)
        XCTAssertEqual(watches.watch(session)?.answerID, "a-3")
        XCTAssertEqual(watches.watch(session)?.until, t0 + 60 + watchFor, "a phone clock ahead counts from now")
    }

    func testBuildsAreDueForNewRequestsAndChangedFilesAtMostEveryRefresh() {
        var watches = TranscriptWatches()
        watches.add([order("a-1", at: 0)], now: t0)
        XCTAssertEqual(watches.due([:], now: t0).map(\.answerID), ["a-1"], "never built")
        XCTAssertTrue(watches.built(transcript("a-1"), signal: signal(10), at: t0))
        XCTAssertEqual(watches.due([session: signal(10)], now: t0 + 1).count, 1, "built but not yet on the phone")
        watches.published(transcript("a-1"))
        XCTAssertEqual(watches.due([session: signal(10)], now: t0 + 100), [], "nothing changed")
        XCTAssertEqual(watches.due([session: signal(20)], now: t0 + refresh - 1), [], "changed too soon")
        XCTAssertEqual(watches.due([session: signal(20)], now: t0 + refresh).map(\.session), [session])
        XCTAssertEqual(watches.due([:], now: t0 + refresh).count, 1, "the file went away")

        XCTAssertFalse(watches.built(transcript("a-1"), signal: signal(20), at: t0 + refresh),
                       "same content: nothing to save")
        XCTAssertEqual(watches.due([session: signal(20)], now: t0 + 100), [])

        watches.add([order("a-2", at: 120)], now: t0 + 121)
        XCTAssertEqual(watches.due([session: signal(20)], now: t0 + 121).map(\.answerID), ["a-2"],
                       "a renewed request is answered at once")
        XCTAssertTrue(watches.built(transcript("a-2"), signal: signal(20), at: t0 + 121))
    }

    func testAFailedSaveIsRebuiltLater() {
        var watches = TranscriptWatches()
        watches.add([order("a-1", at: 0)], now: t0)
        XCTAssertTrue(watches.built(transcript("a-1"), signal: signal(10), at: t0))
        watches.published(transcript("a-1"))
        XCTAssertTrue(watches.built(transcript("a-1", "b"), signal: signal(20), at: t0 + refresh))
        XCTAssertEqual(watches.due([session: signal(20)], now: t0 + 2 * refresh).count, 1,
                       "the grown file was never seen by the phone")
        watches.published(transcript("a-1", "b"))
        XCTAssertEqual(watches.due([session: signal(20)], now: t0 + 3 * refresh), [])
    }

    func testWatchesEndAfterTheirTimeOnceServed() {
        var watches = TranscriptWatches()
        watches.add([order("a-1", at: 0), order("b-1", "codex-cli:c", at: 0)], now: t0)
        _ = watches.built(transcript("a-1"), signal: nil, at: t0)
        watches.published(transcript("a-1"))
        XCTAssertEqual(watches.expire(now: t0 + watchFor - 1), [])
        XCTAssertEqual(watches.due([:], now: t0 + watchFor).map(\.session), ["codex-cli:c"],
                       "an expired watch builds no more, an unserved one still answers")
        XCTAssertEqual(watches.expire(now: t0 + watchFor), [session])
        XCTAssertEqual(watches.sessions, ["codex-cli:c"])
        XCTAssertEqual(watches.expire(now: t0 + 2 * watchFor), ["codex-cli:c"])
        XCTAssertTrue(watches.isEmpty)
        XCTAssertFalse(watches.built(transcript("a-1"), signal: nil, at: t0), "a build for a dropped watch")
    }

    func testOldAndSurplusRecordsAreDeletedButNeverAWatchedOne() {
        var watches = TranscriptWatches()
        watches.add([order("a-1", at: 0)], now: t0)
        let watched = RemoteSchema.transcriptRecordName(device: "mac-1", session: session)
        var records: [String: Date] = [watched: t0 - 2 * RemoteTranscriptPolicy.recordLifetime]
        for index in 0..<(RemoteTranscriptPolicy.maxRecords + 2) {
            records["transcript-mac-1-\(index)"] = t0 - TimeInterval(index * 60)
        }
        records["transcript-mac-1-old"] = t0 - RemoteTranscriptPolicy.recordLifetime - 1
        let stale = watches.stale(records, device: "mac-1", now: t0)
        XCTAssertFalse(stale.contains(watched))
        XCTAssertEqual(Set(stale), ["transcript-mac-1-old", "transcript-mac-1-11", "transcript-mac-1-12",
                                    "transcript-mac-1-13"],
                       "the least recently requested go; the watched one counts toward the cap")
        XCTAssertEqual(records.count - stale.count, RemoteTranscriptPolicy.maxRecords)
        XCTAssertEqual(TranscriptWatches().stale(["a": t0], device: "mac-1", now: t0), [])
        XCTAssertEqual(watches.stale(records, device: "mac-1", enabled: false, now: t0), records.keys.sorted(),
                       "turned off: every record this Mac wrote goes")
    }
}
