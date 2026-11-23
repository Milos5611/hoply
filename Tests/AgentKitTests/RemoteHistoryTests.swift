import AgentKit
import Foundation
import XCTest

final class RemoteHistoryTests: XCTestCase {
    private typealias Day = RemoteHistoryDay
    private let device = "5B1C0D9E-2F4A-4C61-9E3B-7A8D6F0C1E22"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var day0: Int { RemoteHistoryCalendar.day(of: t0) }

    private func usage(_ offset: TimeInterval, model: String = "claude-opus-5-5", calls: Int = 1,
                       output: Int = 100) -> Day.Usage {
        Day.Usage(model: model, at: t0.addingTimeInterval(offset), last: t0.addingTimeInterval(offset + 30),
                  prompt: 1_000, tokens: TokenCounts(input: 10, output: output, cacheRead: 990), calls: calls)
    }

    private func session(_ id: String, project: String? = "p1", title: String? = "x", usage: [Day.Usage]) -> Day.Session {
        Day.Session(key: "claude-code:\(id)", agent: "claude-code", project: project, title: title,
                    start: usage.first?.at ?? t0, end: usage.last?.last ?? t0, usage: usage)
    }

    private let projects = [
        Day.Project(id: "p1", name: "hoply", origin: "abc", kind: .repo),
        Day.Project(id: "p2", name: "site", kind: .folder),
    ]

    // MARK: - Payload

    func testADayRoundTripsThroughItsRecord() throws {
        let parts = Day.build(device: device, deviceName: "Studio", day: day0,
                              sessions: [session("s1", usage: [usage(0)])], projects: projects, updatedAt: t0)
        XCTAssertEqual(parts.count, 1)
        let record = try RemoteSchema.record(parts[0])
        XCTAssertEqual(record.type, "HistoryDay")
        XCTAssertEqual(record.name, "history-\(device)-20270115-0")
        XCTAssertEqual(record.createdAt, t0)
        XCTAssertEqual(record.version, RemoteSchema.version)
        XCTAssertEqual(RemoteSchema.historyDay(from: record), parts[0])
        XCTAssertEqual(parts[0].version, Day.currentVersion)
        XCTAssertEqual(parts[0].projects.map(\.id), ["p1"], "a part names only the projects its sessions use")

        var renamed = record
        renamed.name = "history-other-20270115-0"
        XCTAssertNil(RemoteSchema.historyDay(from: renamed), "a payload must match its record name")
        var transcript = record
        transcript.type = RemoteSchema.RecordType.transcript
        XCTAssertNil(RemoteSchema.historyDay(from: transcript))
        let text = String(decoding: record.payload, as: UTF8.self)
        XCTAssertFalse(text.contains("/Users/"), "never a path")
    }

    func testRecordNamesParseFromTheEnd() {
        let key = RemoteSchema.historyPart(fromRecordName: "history-\(device)-20270115-12")
        XCTAssertEqual(key, RemoteHistoryPartKey(device: device, day: "2027-01-15", part: 12))
        XCTAssertEqual(key?.recordName, "history-\(device)-20270115-12")
        XCTAssertNil(RemoteSchema.historyPart(fromRecordName: "history--20270115-0"))
        XCTAssertNil(RemoteSchema.historyPart(fromRecordName: "history-mac-2027015-0"))
        XCTAssertNil(RemoteSchema.historyPart(fromRecordName: "history-mac-20270115-x"))
        XCTAssertNil(RemoteSchema.historyPart(fromRecordName: "transcript-mac-20270115-0"))
        XCTAssertEqual(RemoteSchema.historyZoneName, "HoplyHistory")
        XCTAssertNotEqual(RemoteSchema.historyZoneName, RemoteSchema.zoneName, "the phone fetches the whole Hoply zone")
    }

    func testAPayloadFromANewerMacDecodesLeniently() throws {
        let data = try Fixture.data("synthetic_remote_history_day.json")
        let record = RemoteRecord(type: RemoteSchema.RecordType.historyDay, name: "history-\(device)-20270115-0",
                                  kind: nil, createdAt: nil, version: 2, payload: data)
        let day = try XCTUnwrap(RemoteSchema.historyDay(from: record))
        XCTAssertEqual(day.version, 2)
        XCTAssertEqual(day.day, "2027-01-15")
        XCTAssertEqual(day.projects.map(\.kind), [.repo, .unknown], "an unknown kind is .unknown")
        XCTAssertEqual(day.projects[1].kind.local, .folder)
        XCTAssertEqual(day.sessions.count, 2)
        XCTAssertEqual(day.sessions[0].sessionKey, SessionKey(source: .claudeCode, id: "s-1"))
        XCTAssertNil(day.sessions[1].source, "an agent this Mac doesn't know yet")
        XCTAssertEqual(day.sessions[0].usage[1].speed, "fast")
        XCTAssertEqual(day.sessions[1].usage[0].nativeUSD, 0.025)
        XCTAssertEqual(day.updatedAt, Date(timeIntervalSince1970: 1_800_010_000.5))
        XCTAssertNil(day.machine, "a Mac that sends no fingerprint still decodes")
    }

    func testTheMachineFingerprintIsAHashOfTheHardwareID() throws {
        let id = "8F2A11C4-0B3D-4E5F-9A6B-7C8D9E0F1A2B"
        let fingerprint = try XCTUnwrap(RemoteMachine.fingerprint(hardwareID: id))
        XCTAssertEqual(fingerprint.count, 32)
        XCTAssertEqual(RemoteMachine.fingerprint(hardwareID: id.lowercased() + "\n"), fingerprint)
        XCTAssertNotEqual(RemoteMachine.fingerprint(hardwareID: "8F2A11C4-0B3D-4E5F-9A6B-7C8D9E0F1A2C"), fingerprint)
        XCTAssertFalse(fingerprint.uppercased().contains("8F2A11C4"), "the hardware id itself never leaves the Mac")
        XCTAssertNil(RemoteMachine.fingerprint(hardwareID: "  "))

        let parts = Day.build(device: device, deviceName: nil, machine: fingerprint, day: day0,
                              sessions: [session("s1", usage: [usage(0)])], projects: projects, updatedAt: t0)
        XCTAssertEqual(parts.map(\.machine), [fingerprint])
        let record = try RemoteSchema.record(parts[0])
        XCTAssertEqual(RemoteSchema.historyDay(from: record)?.machine, fingerprint)
    }

    func testDaysAreUTC() {
        XCTAssertEqual(RemoteHistoryCalendar.name(of: 0), "1970-01-01")
        XCTAssertEqual(RemoteHistoryCalendar.name(of: day0), "2027-01-15")
        XCTAssertEqual(RemoteHistoryCalendar.name(of: RemoteHistoryCalendar.day(named: "2024-02-29") ?? 0), "2024-02-29")
        XCTAssertEqual(RemoteHistoryCalendar.day(named: "2027-01-15"), day0)
        XCTAssertEqual(RemoteHistoryCalendar.start(of: day0), Date(timeIntervalSince1970: 1_799_971_200))
        XCTAssertEqual(RemoteHistoryCalendar.day(of: Date(timeIntervalSince1970: 1_799_971_199.9)), day0 - 1)
        XCTAssertNil(RemoteHistoryCalendar.day(named: "2023-02-29"))
        XCTAssertNil(RemoteHistoryCalendar.day(named: "2027-1-15"))
        for day in stride(from: -800, through: 30_000, by: 37) {
            XCTAssertEqual(RemoteHistoryCalendar.day(named: RemoteHistoryCalendar.name(of: day)), day)
        }
    }

    func testBuildClipsTitlesSortsAndKeepsDayBounds() {
        let long = String(repeating: "x", count: 500)
        var late = session("b", title: long, usage: [usage(3_600), usage(0)])
        late.start = t0.addingTimeInterval(-3 * 86_400)
        late.end = t0.addingTimeInterval(5 * 86_400)
        let parts = Day.build(device: device, deviceName: nil, day: day0,
                              sessions: [late, session("a", usage: [usage(60, calls: 0)])], projects: projects,
                              updatedAt: t0)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].sessions.map(\.key), ["claude-code:b"], "a session without calls is left out")
        let built = parts[0].sessions[0]
        XCTAssertEqual(built.title?.count, RemoteSchema.titleLimit + 1)
        XCTAssertEqual(built.usage.map(\.at), [t0, t0.addingTimeInterval(3_600)])
        XCTAssertEqual(built.start, t0, "outside this day the session's own times give way to its calls")
        XCTAssertEqual(built.end, t0.addingTimeInterval(3_630))
        XCTAssertEqual(Day.build(device: device, deviceName: nil, day: day0, sessions: [], projects: [],
                                 updatedAt: t0).map(\.sessions), [[]], "an empty day is one empty part")
    }

    func testABigDaySplitsDeterministicallyUnderTheLimit() throws {
        let sessions = (0..<400).map { index in
            session(String(format: "s%04d", index), project: index.isMultiple(of: 2) ? "p1" : "p2",
                    title: String(repeating: "x", count: 200),
                    usage: (0..<12).map { usage(Double($0 * 600 + index), model: "model-\($0 % 3)") })
        }
        let limit = 120_000
        let parts = Day.build(device: device, deviceName: "Studio", day: day0, sessions: sessions.reversed(),
                              projects: projects, updatedAt: t0, byteLimit: limit)
        XCTAssertGreaterThan(parts.count, 2)
        for (index, part) in parts.enumerated() {
            XCTAssertEqual(part.part, index)
            XCTAssertEqual(part.parts, parts.count)
            XCTAssertLessThanOrEqual(try RemoteSchema.encode(part).count, limit)
            XCTAssertEqual(Set(part.projects.map(\.id)), Set(part.sessions.compactMap(\.project)))
        }
        XCTAssertEqual(parts.flatMap(\.sessions).map(\.key), sessions.map(\.key))
        let again = Day.build(device: device, deviceName: "Studio", day: day0, sessions: sessions.shuffled(),
                              projects: projects.reversed(), updatedAt: t0, byteLimit: limit)
        XCTAssertEqual(again, parts, "the same day always splits the same way")
    }

    func testTheRealLimitHoldsADayOfHeavyUse() throws {
        let sessions = (0..<300).map { index in
            session("s\(index)", title: String(repeating: "é", count: 300),
                    usage: (0..<24).map { usage(Double($0 * 3_600 + index), model: "claude-opus-5-5-\($0 % 4)") })
        }
        let parts = Day.build(device: device, deviceName: nil, day: day0, sessions: sessions, projects: projects,
                              updatedAt: t0)
        XCTAssertGreaterThan(parts.count, 1)
        for part in parts {
            XCTAssertLessThanOrEqual(try RemoteSchema.encode(part).count, RemoteHistoryPolicy.byteLimit)
        }
    }

    func testOneHugeSessionSplitsItsCallsAcrossParts() throws {
        let calls = (0..<600).map { usage(Double($0), model: "model-\($0)") }
        let parts = Day.build(device: device, deviceName: nil, day: day0, sessions: [session("big", usage: calls)],
                              projects: projects, updatedAt: t0, byteLimit: 20_000)
        XCTAssertGreaterThan(parts.count, 2)
        XCTAssertEqual(parts.flatMap(\.sessions).flatMap(\.usage), calls)
        XCTAssertTrue(parts.allSatisfy { $0.sessions.map(\.key) == ["claude-code:big"] })
        for part in parts { XCTAssertLessThanOrEqual(try RemoteSchema.encode(part).count, 20_000) }
    }

    func testTheFingerprintIgnoresBuildTimeAndMacName() {
        let sessions = [session("s1", usage: [usage(0)])]
        let first = Day.build(device: device, deviceName: "Studio", day: day0, sessions: sessions, projects: projects,
                              updatedAt: t0)
        let later = Day.build(device: device, deviceName: "Air", day: day0, sessions: sessions, projects: projects,
                              updatedAt: t0.addingTimeInterval(600))
        XCTAssertEqual(Day.fingerprint(first), Day.fingerprint(later))
        let grown = Day.build(device: device, deviceName: "Studio", day: day0,
                              sessions: [session("s1", usage: [usage(0, output: 101)])], projects: projects,
                              updatedAt: t0)
        XCTAssertNotEqual(Day.fingerprint(first), Day.fingerprint(grown))
    }

    // MARK: - Publishing

    func testTheOutboxPublishesNewestDaysFirst() {
        var outbox = RemoteHistoryOutbox()
        XCTAssertTrue(outbox.needsScan, "a new run looks at every day once")
        XCTAssertFalse(outbox.isEmpty)
        outbox.scanned(ledgerDays: [10, 30, 20])
        XCTAssertEqual(outbox.next(limit: 2), [30, 20])
        outbox.done(30)
        outbox.note(.days([5, 20]))
        XCTAssertEqual(outbox.next(limit: 10), [20, 10, 5])
        outbox.note(.all)
        XCTAssertTrue(outbox.needsScan)
        for day in [20, 10, 5] { outbox.done(day) }
        outbox.scanned(ledgerDays: [])
        XCTAssertTrue(outbox.isEmpty)

        var changes = RemoteHistoryChanges.days([1])
        changes.formUnion(.days([2]))
        XCTAssertEqual(changes, .days([1, 2]))
        changes.formUnion(.all)
        XCTAssertEqual(changes, .all)
    }

    func testOnlyChangedDaysAreUploadedAndStaleOnesDeleted() {
        let published = RemoteHistoryPublished(fingerprint: "a", parts: 3, at: t0)
        XCTAssertFalse(RemoteHistoryOutbox.needsPublish("a", published: published))
        XCTAssertTrue(RemoteHistoryOutbox.needsPublish("b", published: published))
        XCTAssertTrue(RemoteHistoryOutbox.needsPublish("a", published: nil))
        var unfinished = published
        unfinished.fingerprint = nil
        XCTAssertTrue(RemoteHistoryOutbox.needsPublish("a", published: unfinished), "a save cut short is redone")

        XCTAssertEqual(RemoteHistoryOutbox.extraParts(device: "m", day: "2027-01-15", previous: published, parts: 1),
                       ["history-m-20270115-1", "history-m-20270115-2"])
        XCTAssertEqual(RemoteHistoryOutbox.extraParts(device: "m", day: "2027-01-15", previous: published, parts: 3), [])
        XCTAssertEqual(RemoteHistoryOutbox.recordNames(device: "m", day: "2027-01-15", published: published).count, 3)

        let days = ["2027-01-15": published, "2027-01-14": published]
        XCTAssertEqual(RemoteHistoryOutbox.stale(days, ledgerDays: [day0], enabled: true), ["2027-01-14"])
        XCTAssertEqual(RemoteHistoryOutbox.stale(days, ledgerDays: nil, enabled: true), [])
        XCTAssertEqual(RemoteHistoryOutbox.stale(days, ledgerDays: [day0], enabled: false), ["2027-01-14", "2027-01-15"],
                       "turned off, every day this Mac wrote goes")

        XCTAssertEqual(RemoteHistoryOutbox.buildTime(now: t0.addingTimeInterval(5), previous: published),
                       t0.addingTimeInterval(5))
        XCTAssertGreaterThan(RemoteHistoryOutbox.buildTime(now: t0.addingTimeInterval(-60), previous: published), t0,
                             "a clock set back never makes a rebuild look older")
    }

    // MARK: - Merging

    private func part(_ device: String, _ day: String = "2027-01-15", part: Int = 0, parts: Int = 1,
                      at offset: TimeInterval) -> Day {
        Day(device: device, day: day, part: part, parts: parts, updatedAt: t0.addingTimeInterval(offset))
    }

    func testANewerSummaryReplacesItsPartAndAShrinkDropsTheRest() {
        let key0 = RemoteHistoryPartKey(device: "b", day: "2027-01-15", part: 0)
        let key1 = RemoteHistoryPartKey(device: "b", day: "2027-01-15", part: 1)
        let other = RemoteHistoryPartKey(device: "b", day: "2027-01-14", part: 1)
        let stored = [key0: RemoteHistoryStoredPart(builtAt: t0, parts: 2),
                      key1: RemoteHistoryStoredPart(builtAt: t0, parts: 2),
                      other: RemoteHistoryStoredPart(builtAt: t0, parts: 2)]
        let newer = part("b", at: 60)
        let plan = RemoteHistoryMerge.plan([newer, part("b", at: 30), part("a", at: 90)], deleted: [], stored: stored,
                                           device: "a")
        XCTAssertEqual(plan.replace, [newer], "the newest build wins and this Mac's own records are ignored")
        XCTAssertEqual(plan.remove, [key1], "parts past the new count go, other days stay")

        let older = RemoteHistoryMerge.plan([part("b", at: -60)], deleted: [], stored: stored, device: "a")
        XCTAssertTrue(older.isEmpty, "an older build never replaces a newer one")
        let same = RemoteHistoryMerge.plan([part("b", parts: 2, at: 0)], deleted: [], stored: stored, device: "a")
        XCTAssertEqual(same.replace.count, 1, "the same build again is applied again, harmlessly")
        XCTAssertEqual(same.remove, [])
        let invalid = RemoteHistoryMerge.plan([part("b", part: 2, parts: 2, at: 90)], deleted: [], stored: [:],
                                              device: "a")
        XCTAssertTrue(invalid.isEmpty)
    }

    func testThisMacsOtherEditionIsNeverMergedIn() {
        var otherEdition = part("b", at: 60)
        otherEdition.machine = "m-1"
        var otherMac = part("c", at: 60)
        otherMac.machine = "m-2"
        let plan = RemoteHistoryMerge.plan([otherEdition, otherMac, part("d", at: 60)], deleted: [], stored: [:],
                                           device: "a", machine: "m-1")
        XCTAssertEqual(plan.replace.map(\.device), ["c", "d"], "same hardware, another device id: this Mac's other edition")
        XCTAssertEqual(RemoteHistoryMerge.plan([otherEdition], deleted: [], stored: [:], device: "a").replace.count, 1,
                       "without a fingerprint of its own a Mac takes every other device")
    }

    func testADeletedRecordRemovesItsPart() {
        let key = RemoteHistoryPartKey(device: "b", day: "2027-01-15", part: 0)
        let own = RemoteHistoryPartKey(device: "a", day: "2027-01-15", part: 0)
        let stored = [key: RemoteHistoryStoredPart(builtAt: t0, parts: 1)]
        XCTAssertEqual(RemoteHistoryMerge.plan([], deleted: [key, own], stored: stored, device: "a").remove, [key])
        XCTAssertTrue(RemoteHistoryMerge.plan([], deleted: [RemoteHistoryPartKey(device: "b", day: "2027-01-16", part: 0)],
                                              stored: stored, device: "a").isEmpty)
        XCTAssertEqual(RemoteHistoryMerge.absent(stored: [key, own], fetched: [own]), [key])
    }

    // MARK: - Projects

    func testProjectsMatchByOriginThenFolderName() {
        let locals = [
            RemoteProjectCandidate(id: 1, name: "hoply", origin: "abc", kind: .repo, lastActive: 10),
            RemoteProjectCandidate(id: 2, name: "hoply-copy", origin: "abc", kind: .repo, lastActive: 20, merged: true),
            RemoteProjectCandidate(id: 3, name: "api", origin: "def", kind: .repo, lastActive: 30),
            RemoteProjectCandidate(id: 4, name: "notes", kind: .folder, lastActive: 5),
            RemoteProjectCandidate(id: 5, name: "Notes", kind: .folder, lastActive: 50),
            RemoteProjectCandidate(id: 6, name: "tmp", kind: .scratch),
        ]
        func match(_ name: String, origin: String? = nil, kind: Day.ProjectKind = .repo) -> Int64? {
            RemoteProjectMatch.match(Day.Project(id: "r", name: name, origin: origin, kind: kind), among: locals)
        }
        XCTAssertEqual(match("renamed", origin: "abc"), 1, "same origin, any folder name; an unmerged project first")
        XCTAssertNil(match("api", origin: "zzz"), "two repos with different origins never match by name")
        XCTAssertEqual(match("api"), 3)
        XCTAssertEqual(match("NOTES", kind: .folder), 5, "folder names ignore case; the most recent wins")
        XCTAssertNil(match("tmp", kind: .scratch))
        XCTAssertNil(match("elsewhere", origin: "zzz"))
    }

    func testOtherMacsCopiesOfAProjectCollapseIntoOne() {
        let locals = [RemoteProjectCandidate(id: 1, name: "notes", kind: .folder),
                      RemoteProjectCandidate(id: 2, name: "api", origin: "def", kind: .repo)]
        let remoteOnly = [
            RemoteProjectCandidate(id: 10, name: "hoply", origin: "abc", kind: .repo),
            RemoteProjectCandidate(id: 11, name: "hoply", origin: "abc", kind: .repo),
            RemoteProjectCandidate(id: 12, name: "site", kind: .folder, merged: true),
            RemoteProjectCandidate(id: 13, name: "site", kind: .folder),
            RemoteProjectCandidate(id: 14, name: "tmp", kind: .scratch),
        ]
        func match(_ name: String, origin: String? = nil, kind: Day.ProjectKind = .repo) -> Int64? {
            RemoteProjectMatch.match(Day.Project(id: "r", name: name, origin: origin, kind: kind), among: locals,
                                     remoteOnly: remoteOnly)
        }
        XCTAssertEqual(match("renamed", origin: "abc"), 10, "the first Mac's copy wins")
        XCTAssertEqual(match("site", kind: .folder), 12, "the order given wins: the caller puts edited groups first")
        XCTAssertEqual(match("api", origin: "def"), 2, "this Mac's own project comes first")
        XCTAssertEqual(match("notes", kind: .folder), 1)
        XCTAssertNil(match("hoply", origin: "zzz"), "different origins never match by name, here either")
        XCTAssertNil(match("tmp", kind: .scratch))
        let originOverName = RemoteProjectMatch.match(Day.Project(id: "r", name: "notes", origin: "abc", kind: .repo),
                                                      among: locals, remoteOnly: remoteOnly)
        XCTAssertEqual(originOverName, 10, "an origin match beats a folder name")

        let taken: Set<Int64> = [2, 10]
        func matchTaken(_ name: String, origin: String? = nil, kind: Day.ProjectKind = .repo) -> Int64? {
            RemoteProjectMatch.match(Day.Project(id: "r", name: name, origin: origin, kind: kind), among: locals,
                                     remoteOnly: remoteOnly, taken: taken)
        }
        XCTAssertEqual(matchTaken("api-2", origin: "def"), 2, "this Mac's project with the same origin, taken or not")
        XCTAssertEqual(matchTaken("hoply", origin: "abc"), 11, "another Mac's copy that Mac already uses is skipped")
        XCTAssertNil(matchTaken("api", kind: .folder), "never joined by folder name once taken")
    }

    func testOnlyAHashOfTheNormalisedOriginLeavesTheMac() throws {
        let ssh = try XCTUnwrap(GitRemote.originHash("git@github.com:Org/Repo.git"))
        XCTAssertEqual(GitRemote.originHash("https://user@github.com/org/repo/"), ssh)
        XCTAssertEqual(GitRemote.originHash("ssh://git@github.com:22/org/repo.git"), ssh)
        XCTAssertNotEqual(GitRemote.originHash("git@github.com:org/other.git"), ssh)
        XCTAssertEqual(ssh.count, 32)
        XCTAssertFalse(ssh.contains("github"))
        XCTAssertNil(GitRemote.originHash("/Users/x/repo.git"), "a local path is never sent, not even hashed")
        XCTAssertNil(GitRemote.originHash("file:///Users/x/repo"))
    }

    // MARK: - Settings and pricing

    func testSharingIsOnByDefaultButOnlyWithTheLink() throws {
        let old = AppSettings.decode(Data(#"{"iCloudLink": true, "port": 4400}"#.utf8))
        XCTAssertTrue(old.iCloudHistory, "settings saved before the field decode with it on")
        XCTAssertTrue(old.sharesHistory)
        XCTAssertEqual(old.port, 4400)
        var settings = AppSettings()
        XCTAssertTrue(settings.iCloudHistory)
        XCTAssertFalse(settings.sharesHistory, "never while the iCloud link is off")
        settings.iCloudLink = true
        settings.iCloudHistory = false
        XCTAssertFalse(settings.sharesHistory)
        let decoded = AppSettings.decode(settings.encoded())
        XCTAssertFalse(decoded.iCloudHistory)
        XCTAssertTrue(AppSettings.decode(Data(#"{"iCloudHistory": "yes"}"#.utf8)).iCloudHistory)
    }

    func testASumOfCallsIsPricedAtOneCallsTier() {
        let pricing = PricingTable.bundled()
        XCTAssertEqual(pricing.contextThresholds, [100_000, 272_000])
        let tokens = TokenCounts(input: 400_000, output: 1_000)
        let summed = pricing.price(model: "gpt-5.5", tokens: tokens, speed: nil)
        let perCall = pricing.price(model: "gpt-5.5", tokens: tokens, speed: nil, promptTokens: 100_000)
        XCTAssertEqual(perCall.costUSD ?? 0, (400_000 * 5 + 1_000 * 30) / 1_000_000, accuracy: 1e-9)
        XCTAssertGreaterThan(summed.costUSD ?? 0, perCall.costUSD ?? 0)
        XCTAssertNil(pricing.price(model: "unknown-model", tokens: tokens, speed: nil, promptTokens: 10).costUSD)
    }
}
