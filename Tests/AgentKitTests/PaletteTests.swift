import AgentKit
import Foundation
import XCTest

final class PaletteRankerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_200_000)
    private let day: TimeInterval = 86_400

    private func item(_ id: String, _ kind: PaletteItem.Kind, _ title: String, subtitle: String? = nil,
                      keywords: [String] = [], daysAgo: Double? = nil, attention: PaletteItem.Attention = .none) -> PaletteItem {
        PaletteItem(id: id, kind: kind, title: title, subtitle: subtitle, keywords: keywords,
                    lastActive: daysAgo.map { now.addingTimeInterval(-$0 * day) }, attention: attention)
    }

    private func frecency(_ uses: [String: Int], daysAgo: Double = 0) -> Frecency {
        var frecency = Frecency()
        for (id, count) in uses.sorted(by: { $0.key < $1.key }) {
            for _ in 0..<count { frecency.record(id, at: now.addingTimeInterval(-daysAgo * day)) }
        }
        return frecency
    }

    private var catalogue: [PaletteItem] {
        [item("action:reindex", .action, "Reindex history", keywords: ["rebuild", "ledger"]),
         item("action:settings", .action, "Open Settings", keywords: ["preferences"]),
         item("page:sessions", .page, "Sessions"),
         item("page:spending", .page, "Spending"),
         item("project:1", .project, "hoply", subtitle: "~/Project/hoply", daysAgo: 1),
         item("project:2", .project, "settings-service", subtitle: "~/Project/settings-service", daysAgo: 30),
         item("session:claude-code:a", .session, "Fix the login flow", subtitle: "hoply · main", daysAgo: 2),
         item("session:claude-code:b", .session, "Palette ranking", subtitle: "hoply · m8", daysAgo: 0.1, attention: .live),
         item("session:claude-code:c", .session, "Review migrations", subtitle: "api · main", daysAgo: 0.5,
              attention: .needsUser),
         item("devserver:1", .devServer, "vite :5173", subtitle: "hoply", daysAgo: 0.01, attention: .live)]
    }

    func testQueryParsing() {
        XCTAssertEqual(PaletteQuery("  > re index "), PaletteQuery(">re index"))
        XCTAssertTrue(PaletteQuery(">").actionsOnly)
        XCTAssertTrue(PaletteQuery(">").isEmpty)
        XCTAssertEqual(PaletteQuery("> set").text, "set")
        XCTAssertFalse(PaletteQuery("a > b").actionsOnly)
        XCTAssertEqual(PaletteQuery("a > b").text, "a > b")
    }

    func testAnglePrefixShowsActionsOnly() {
        let ranker = PaletteRanker()
        XCTAssertEqual(ranker.rank(catalogue, query: ">", now: now).map(\.id), ["action:settings", "action:reindex"])
        XCTAssertEqual(ranker.rank(catalogue, query: "> set", now: now).map(\.id), ["action:settings"])
        XCTAssertEqual(ranker.rank(catalogue, query: ">sess", now: now).map(\.id), [])
        let all = ranker.rank(catalogue, query: "set", now: now).map(\.id)
        XCTAssertTrue(all.contains("project:2"))
        XCTAssertTrue(all.contains("action:settings"))
    }

    func testTitleOutranksSubtitleAndKeywords() throws {
        let ranker = PaletteRanker()
        let results = ranker.rank(catalogue, query: "hoply", now: now)
        XCTAssertEqual(results.first?.id, "project:1")
        XCTAssertEqual(results.first?.titleRanges, [0..<5])
        XCTAssertEqual(Set(results.map(\.id)),
                       ["project:1", "session:claude-code:a", "session:claude-code:b", "devserver:1"])
        XCTAssertEqual(results.first { $0.id == "devserver:1" }?.titleRanges, [], "a subtitle hit highlights nothing in the title")

        let keyword = ranker.rank(catalogue, query: "preferences", now: now)
        XCTAssertEqual(keyword.map(\.id), ["action:settings"])
        let title = try XCTUnwrap(ranker.rank([item("a", .action, "preferences")], query: "preferences", now: now).first)
        XCTAssertEqual(try XCTUnwrap(keyword.first).score, title.score * PaletteRanker.keywordWeight, accuracy: 0.001)
    }

    func testTermsMayMatchDifferentFields() throws {
        let results = PaletteRanker().rank(catalogue, query: "login hoply", now: now)
        XCTAssertEqual(results.map(\.id), ["session:claude-code:a"])
        let first = try XCTUnwrap(results.first)
        XCTAssertEqual(first.titleStringRanges.map { String(first.item.title[$0]) }, ["login"])
        XCTAssertEqual(PaletteRanker().rank(catalogue, query: "login zebra", now: now), [])
    }

    func testFrecencyLiftsANearTieButNotAClearlyWorseMatch() {
        let items = [item("page:sessions", .page, "Sessions"), item("action:settings", .action, "All settings"),
                     item("project:9", .project, "asset-pipeline")]
        XCTAssertEqual(PaletteRanker().rank(items, query: "se", now: now).map(\.id),
                       ["page:sessions", "action:settings", "project:9"])

        let used = PaletteRanker(frecency: frecency(["action:settings": 10, "project:9": 40]))
        XCTAssertEqual(used.rank(items, query: "se", now: now).map(\.id), ["action:settings", "page:sessions", "project:9"],
                       "a word-start match used often passes the prefix match; a mid-word match never does")

        let stale = PaletteRanker(frecency: frecency(["action:settings": 10], daysAgo: 120))
        XCTAssertEqual(stale.rank(items, query: "se", now: now).first?.id, "page:sessions", "old use has decayed away")
    }

    func testRecencyAndAttentionBreakEqualTextScores() {
        let items = [item("session:claude-code:old", .session, "Fix parser", daysAgo: 20),
                     item("session:claude-code:new", .session, "Fix parser", daysAgo: 0.1),
                     item("session:claude-code:waiting", .session, "Fix parser", daysAgo: 3, attention: .needsUser)]
        XCTAssertEqual(PaletteRanker().rank(items, query: "fix", now: now).map(\.id),
                       ["session:claude-code:waiting", "session:claude-code:new", "session:claude-code:old"])
    }

    func testEmptyQueryOrder() {
        let ranker = PaletteRanker(frecency: frecency(["page:spending": 3, "project:2": 1]))
        XCTAssertEqual(ranker.rank(catalogue, query: "", now: now).map(\.id), [
            "session:claude-code:c",
            "page:spending", "project:2",
            "devserver:1", "session:claude-code:b",
            "project:1", "session:claude-code:a",
            "page:sessions", "action:settings", "action:reindex",
        ])
        XCTAssertEqual(ranker.rank(catalogue, query: "   ", now: now, limit: 3).map(\.id),
                       ["session:claude-code:c", "page:spending", "project:2"])
        XCTAssertEqual(ranker.rank(catalogue, query: "", now: now, limit: 0), [])
    }

    func testOrderDoesNotDependOnInputOrder() {
        let ranker = PaletteRanker(frecency: frecency(["page:spending": 3]))
        let twins = catalogue + [item("page:sessions-2", .page, "Sessions"), item("action:sessions", .action, "Sessions")]
        for query in ["", "s", "se", "hoply", ">", "> re"] {
            let expected = ranker.rank(twins, query: query, now: now)
            XCTAssertEqual(ranker.rank(twins.reversed(), query: query, now: now), expected, query)
            XCTAssertEqual(ranker.rank(twins.sorted { $0.title > $1.title }, query: query, now: now), expected, query)
        }
        XCTAssertEqual(ranker.rank(twins, query: "sessions", now: now).prefix(3).map(\.id),
                       ["page:sessions", "page:sessions-2", "action:sessions"], "equal scores: kind, then id")
    }

    func testItemIDs() {
        let key = SessionKey(source: .copilotCLI, id: "ab:cd")
        XCTAssertEqual(PaletteItem.sessionID(key), "session:copilot-cli:ab:cd")
        XCTAssertEqual(PaletteItem.sessionKey(fromID: "session:copilot-cli:ab:cd"), key)
        XCTAssertNil(PaletteItem.sessionKey(fromID: "session:nobody:x"))
        XCTAssertNil(PaletteItem.sessionKey(fromID: "session:claude-code:"))
        XCTAssertNil(PaletteItem.sessionKey(fromID: "project:3"))
        XCTAssertEqual(PaletteItem.projectID(fromID: PaletteItem.projectID(42)), 42)
        XCTAssertNil(PaletteItem.projectID(fromID: "project:x"))
        XCTAssertEqual(PaletteItem.payload(of: PaletteItem.pageID("limits"), prefix: "page:"), "limits")
        XCTAssertEqual(PaletteItem.devServerID("501:1"), "devserver:501:1")
        XCTAssertEqual(PaletteItem.actionID("reindex"), "action:reindex")
    }
}

final class FrecencyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_200_000)
    private let day: TimeInterval = 86_400

    func testRecordAndDecay() {
        var frecency = Frecency(halfLife: 10 * day)
        XCTAssertEqual(frecency.score("a", at: now), 0)
        frecency.record("a", at: now)
        XCTAssertEqual(frecency.score("a", at: now), 1)
        XCTAssertEqual(frecency.score("a", at: now.addingTimeInterval(10 * day)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(frecency.score("a", at: now.addingTimeInterval(20 * day)), 0.25, accuracy: 1e-9)
        frecency.record("a", at: now.addingTimeInterval(10 * day))
        XCTAssertEqual(frecency.score("a", at: now.addingTimeInterval(10 * day)), 1.5, accuracy: 1e-9)
        XCTAssertEqual(frecency.entries["a"]?.uses, 2)
        XCTAssertEqual(frecency.score("a", at: now.addingTimeInterval(-5 * day)), 1.5, accuracy: 1e-9,
                       "a clock that moved back never raises the score")
        frecency.record("a", at: now)
        XCTAssertEqual(frecency.entries["a"]?.lastUsed, now.addingTimeInterval(10 * day))
        XCTAssertEqual(frecency.score("a", at: now.addingTimeInterval(10 * day)), 2.5, accuracy: 1e-9)
    }

    func testManyOldUsesLoseToAFewRecentOnes() {
        var frecency = Frecency()
        for _ in 0..<10 { frecency.record("old", at: now.addingTimeInterval(-90 * day)) }
        for _ in 0..<2 { frecency.record("new", at: now.addingTimeInterval(-day)) }
        XCTAssertGreaterThan(frecency.score("new", at: now), frecency.score("old", at: now))
    }

    func testPruningKeepsTheStrongestEntries() {
        var frecency = Frecency(maxEntries: 3)
        frecency.record("stale", at: now.addingTimeInterval(-60 * day))
        for _ in 0..<3 { frecency.record("often", at: now.addingTimeInterval(-2 * day)) }
        frecency.record("b", at: now.addingTimeInterval(-day))
        frecency.record("a", at: now.addingTimeInterval(-day))
        XCTAssertEqual(Set(frecency.entries.keys), ["often", "a", "b"])
        frecency.record("fresh", at: now)
        XCTAssertEqual(Set(frecency.entries.keys), ["often", "fresh", "a"], "equal scores: the lower id stays")
        frecency.forget("often")
        XCTAssertEqual(frecency.score("often", at: now), 0)
    }

    func testRoundTripAndLenientDecode() throws {
        var frecency = Frecency()
        frecency.record("page:limits", at: now)
        frecency.record("page:limits", at: now.addingTimeInterval(day))
        frecency.record("action:reindex", at: now)
        let decoded = Frecency.decode(frecency.encoded())
        XCTAssertEqual(decoded, frecency)
        XCTAssertEqual(decoded.score("page:limits", at: now.addingTimeInterval(day)),
                       frecency.score("page:limits", at: now.addingTimeInterval(day)))

        XCTAssertTrue(Frecency.decode(nil).isEmpty)
        XCTAssertTrue(Frecency.decode(Data("[1,2".utf8)).isEmpty)
        XCTAssertTrue(Frecency.decode(Data(#"{"entries":"none"}"#.utf8)).isEmpty)
        XCTAssertTrue(Frecency.decode(Data(#"{"other":1}"#.utf8)).isEmpty)

        let mixed = #"""
            {"entries":{"good":{"uses":2,"weight":1.5,"lastUsed":1794200000},"text":"x","negative":{"uses":1,"weight":-4,"lastUsed":1},
            "partial":{"uses":1},"zero":{"uses":0,"weight":1,"lastUsed":1}},"future":true}
            """#
        let kept = Frecency.decode(Data(mixed.utf8))
        XCTAssertEqual(kept.entries, ["good": Frecency.Entry(uses: 2, weight: 1.5, lastUsed: now)])
    }

    func testAnOversizedBlobIsCutOnDecode() throws {
        let entries = (0..<500).map { #""id\#($0)":{"uses":1,"weight":1,"lastUsed":\#(1_794_200_000 + $0)}"# }
        let decoded = Frecency.decode(Data("{\"entries\":{\(entries.joined(separator: ","))}}".utf8))
        XCTAssertEqual(decoded.entries.count, Frecency.defaultMaxEntries)
        XCTAssertNotNil(decoded.entries["id499"])
        XCTAssertNil(decoded.entries["id0"])
    }
}

final class ResumeScriptTests: XCTestCase {
    private let id = "0b6f6c1e-8a57-4f0e-9d0c-2f6a4a1f3b77"

    func testClaudeScript() throws {
        let script = try XCTUnwrap(ResumeScript.script(source: .claudeCode, sessionID: id, cwd: "/Users/dev/Project/hoply"))
        XCTAssertEqual(script, """
            #!/bin/zsh
            cd -- '/Users/dev/Project/hoply' || { print -r -- "Hoply: cannot open" '/Users/dev/Project/hoply'; exit 1; }
            if command -v 'claude' >/dev/null 2>&1; then
              exec 'claude' '--resume' '\(id)'
            fi
            exec /bin/zsh -ilc 'exec "$0" "$@"' 'claude' '--resume' '\(id)'

            """)
    }

    func testQuoting() throws {
        XCTAssertEqual(ResumeScript.shellQuoted("plain"), "'plain'")
        XCTAssertEqual(ResumeScript.shellQuoted("it's"), #"'it'\''s'"#)
        XCTAssertEqual(ResumeScript.shellQuoted(""), "''")
        XCTAssertEqual(ResumeScript.shellQuoted("$HOME `id` \"x\" \\"), "'$HOME `id` \"x\" \\'")
        XCTAssertEqual(ResumeScript.shellQuoted("''"), #"''\'''\'''"#)

        let cwd = "/Users/dev/My Project's $HOME `x`; rm -rf \"y\""
        let script = try XCTUnwrap(ResumeScript.script(source: .claudeCode, sessionID: id, cwd: cwd))
        XCTAssertTrue(script.contains(#"cd -- '/Users/dev/My Project'\''s $HOME `x`; rm -rf "y"' || "#), script)
    }

    func testImplausibleSessionIDsAreRejected() {
        for bad in ["", "-rf", "--dangerously-skip-permissions", "a b", "a;b", "a'b", "$(id)", "a/b", "../x", "a\nb", "é1",
                    String(repeating: "a", count: 129)] {
            XCTAssertFalse(ResumeScript.isPlausibleSessionID(bad), bad)
            XCTAssertNil(ResumeScript.script(source: .claudeCode, sessionID: bad, cwd: "/tmp"), bad)
            XCTAssertNil(ResumeScript.fileName(source: .claudeCode, sessionID: bad), bad)
        }
        for good in [id, "sim-1", "a", "session_42", String(repeating: "a", count: 128)] {
            XCTAssertTrue(ResumeScript.isPlausibleSessionID(good), good)
        }
    }

    func testMissingOrOddFoldersGiveNoScript() {
        XCTAssertNil(ResumeScript.script(source: .claudeCode, sessionID: id, cwd: nil))
        XCTAssertNil(ResumeScript.script(source: .claudeCode, sessionID: id, cwd: ""))
        XCTAssertNil(ResumeScript.script(source: .claudeCode, sessionID: id, cwd: "relative/path"))
        XCTAssertNil(ResumeScript.script(source: .claudeCode, sessionID: id, cwd: "/a\nb"))
        XCTAssertNotNil(ResumeScript.script(source: .claudeCode, sessionID: id, cwd: "/"))
    }

    func testCopilotCLIAndQwenScripts() throws {
        for (source, binary, resume) in [(AgentSource.copilotCLI, "copilot", "'--resume=\(id)'"),
                                         (.qwenCode, "qwen", "'--resume' '\(id)'")] {
            XCTAssertTrue(ResumeScript.isSupported(source))
            let script = try XCTUnwrap(ResumeScript.script(source: source, sessionID: id, cwd: "/Users/dev/My Project"))
            XCTAssertEqual(script, """
                #!/bin/zsh
                cd -- '/Users/dev/My Project' || { print -r -- "Hoply: cannot open" '/Users/dev/My Project'; exit 1; }
                if command -v '\(binary)' >/dev/null 2>&1; then
                  exec '\(binary)' \(resume)
                fi
                exec /bin/zsh -ilc 'exec "$0" "$@"' '\(binary)' \(resume)

                """)
            XCTAssertEqual(ResumeScript.fileName(source: source, sessionID: id),
                           "hoply-resume-\(source.rawValue)-\(id).command")
            XCTAssertNil(ResumeScript.script(source: source, sessionID: "--allow-all-tools", cwd: "/tmp"))
            XCTAssertNil(ResumeScript.script(source: source, sessionID: "a;b", cwd: "/tmp"))
            XCTAssertNil(ResumeScript.script(source: source, sessionID: id, cwd: nil))
        }
    }

    func testCopilotIDEIsNotSupported() {
        XCTAssertTrue(ResumeScript.isSupported(.claudeCode))
        XCTAssertFalse(ResumeScript.isSupported(.copilotIDE))
        XCTAssertNil(ResumeScript.script(source: .copilotIDE, sessionID: id, cwd: "/tmp"))
        XCTAssertNil(ResumeScript.fileName(source: .copilotIDE, sessionID: id))
    }

    func testStaleScriptsAreOnlyHoplysOwnOldOnes() {
        let now = Date(timeIntervalSince1970: 1_794_300_000)
        func file(_ name: String, days: Double) -> (name: String, modified: Date) {
            (name, now.addingTimeInterval(-days * 86_400))
        }
        let files = [
            file("hoply-resume-claude-code-\(id).command", days: 8),
            file("hoply-resume-qwen-code-sim-1.command", days: 30),
            file("hoply-resume-copilot-cli-abc.command", days: 6.9),
            file("hoply-resume-claude-code-fresh.command", days: 0),
            file("hoply-resume-copilot-ide-abc.command", days: 30),
            file("hoply-resume-claude-code-.command", days: 30),
            file("hoply-resume-claude-code-a b.command", days: 30),
            file("hoply-resume-claude-code-abc.command.bak", days: 30),
            file("hoply-resume-other-abc.command", days: 30),
            file("notes.command", days: 30),
            file(".DS_Store", days: 30),
        ]
        XCTAssertEqual(ResumeScript.staleFileNames(files, now: now),
                       ["hoply-resume-claude-code-\(id).command", "hoply-resume-qwen-code-sim-1.command"])
        XCTAssertEqual(ResumeScript.staleFileNames(files, now: now, olderThan: 86_400).count, 3)
        XCTAssertEqual(ResumeScript.staleFileNames([], now: now), [])
    }

    func testFileName() {
        XCTAssertEqual(ResumeScript.fileName(source: .claudeCode, sessionID: id), "hoply-resume-claude-code-\(id).command")
    }
}

final class HotKeyComboTests: XCTestCase {
    func testDisplayStrings() {
        XCTAssertEqual(HotKeyCombo.optionSpace.displayString, "⌥Space")
        XCTAssertEqual(HotKeyCombo.controlOptionSpace.displayString, "⌃⌥Space")
        XCTAssertEqual(HotKeyCombo(keyCode: 40, modifiers: [.command, .shift, .option, .control]).displayString, "⌃⌥⇧⌘K")
        XCTAssertEqual(HotKeyCombo(keyCode: 122, modifiers: .command).displayString, "⌘F1")
        XCTAssertEqual(HotKeyCombo(keyCode: 10, modifiers: .control).displayString, "⌃Key 10")
    }

    func testCarbonValues() {
        XCTAssertEqual(HotKeyCombo.optionSpace.keyCode, 49)
        XCTAssertEqual(HotKeyCombo.optionSpace.modifiers.rawValue, 2048)
        XCTAssertEqual(HotKeyCombo.controlOptionSpace.modifiers.rawValue, 4096 + 2048)
        XCTAssertEqual(HotKeyModifiers.command.rawValue, 256)
        XCTAssertEqual(HotKeyModifiers.shift.rawValue, 512)
    }

    func testValidity() {
        XCTAssertTrue(HotKeyCombo.optionSpace.isValid)
        XCTAssertTrue(HotKeyCombo.controlOptionSpace.isValid)
        XCTAssertTrue(HotKeyCombo(keyCode: 0, modifiers: [.shift, .command]).isValid)
        XCTAssertFalse(HotKeyCombo(keyCode: 49, modifiers: []).isValid)
        XCTAssertFalse(HotKeyCombo(keyCode: 49, modifiers: .shift).isValid, "⇧Space alone would swallow typing")
        XCTAssertFalse(HotKeyCombo(keyCode: -1, modifiers: .option).isValid)
        XCTAssertFalse(HotKeyCombo(keyCode: 300, modifiers: .option).isValid)
        XCTAssertFalse(HotKeyCombo(keyCode: 49, modifiers: HotKeyModifiers(rawValue: 2048 | 1)).isValid)
    }
}
