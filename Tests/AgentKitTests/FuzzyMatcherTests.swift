import AgentKit
import Foundation
import XCTest

final class FuzzyMatcherTests: XCTestCase {
    private func score(_ query: String, _ text: String) -> Int? {
        FuzzyMatcher.match(query, in: text)?.score
    }

    private func highlighted(_ query: String, _ text: String) -> [String]? {
        FuzzyMatcher.match(query, in: text).map { match in match.stringRanges(in: text).map { String(text[$0]) } }
    }

    func testSubsequenceMatchesAndReturnsRanges() throws {
        let match = try XCTUnwrap(FuzzyMatcher.match("hpl", in: "Hoply"))
        XCTAssertEqual(match.ranges, [0..<1, 2..<4])
        XCTAssertEqual(highlighted("hpl", "Hoply"), ["H", "pl"])
        XCTAssertEqual(FuzzyMatcher.match("hoply", in: "Hoply")?.ranges, [0..<5])
        XCTAssertEqual(highlighted("dash", "Open Dashboard"), ["Dash"])
    }

    func testNoMatch() {
        XCTAssertNil(FuzzyMatcher.match("xyz", in: "Hoply"))
        XCTAssertNil(FuzzyMatcher.match("ylp", in: "Hoply"), "order matters inside a term")
        XCTAssertNil(FuzzyMatcher.match("hoplyy", in: "Hoply"))
        XCTAssertNil(FuzzyMatcher.match("a", in: ""))
    }

    func testEmptyQueryMatchesEverythingWithScoreZero() {
        XCTAssertEqual(FuzzyMatcher.match("", in: "Hoply"), FuzzyMatch(score: 0, ranges: []))
        XCTAssertEqual(FuzzyMatcher.match("  \t", in: ""), FuzzyMatch(score: 0, ranges: []))
        XCTAssertTrue(FuzzyQuery("   ").isEmpty)
    }

    func testCaseAndDiacriticsAreIgnoredBothWays() throws {
        XCTAssertEqual(highlighted("milos", "Miloš Nikolić"), ["Miloš"])
        XCTAssertEqual(highlighted("NIKOLIĆ", "milos nikolic"), ["nikolic"])
        XCTAssertEqual(score("cafe", "Café"), score("cafe", "cafe"))
        let decomposed = "Cafe\u{301} menu"
        XCTAssertEqual(highlighted("menu", decomposed), ["menu"], "offsets count characters, not scalars")
        XCTAssertEqual(highlighted("café", decomposed), ["Cafe\u{301}"])
    }

    func testWordStartsBeatMidWordHits() throws {
        XCTAssertEqual(highlighted("sb", "SessionBoard"), ["S", "B"], "camelCase humps")
        XCTAssertEqual(highlighted("ds", "old-dev_server"), ["d", "s"])
        XCTAssertEqual(highlighted("fl", "refill/fix-login"), ["f", "l"], "word starts win over the earlier mid-word hits")
        let wordStart = try XCTUnwrap(score("ds", "dev server"))
        let midWord = try XCTUnwrap(score("ds", "adds"))
        XCTAssertGreaterThan(wordStart, midWord)
        XCTAssertGreaterThan(try XCTUnwrap(score("log", "Logs")), try XCTUnwrap(score("log", "Catalog")))
        XCTAssertGreaterThan(try XCTUnwrap(score("log", "api/logs")), try XCTUnwrap(score("log", "catalog")))
    }

    func testConsecutiveRunsPrefixAndGaps() throws {
        XCTAssertGreaterThan(try XCTUnwrap(score("set", "Settings")), try XCTUnwrap(score("set", "Sessions tab")))
        XCTAssertGreaterThan(try XCTUnwrap(score("set", "Settings")), try XCTUnwrap(score("set", "Open Settings")),
                             "a prefix beats a late start")
        XCTAssertGreaterThan(try XCTUnwrap(score("abc", "abc")), try XCTUnwrap(score("abc", "a b c")))
        XCTAssertGreaterThan(try XCTUnwrap(score("ac", "abc")), try XCTUnwrap(score("ac", "abbbbc")))
        XCTAssertEqual(FuzzyMatcher.match("test", in: "attest test")?.ranges, [7..<11], "the best alignment, not the leftmost")
    }

    func testEveryTermMustMatchInAnyOrder() throws {
        XCTAssertEqual(highlighted("board session", "SessionBoard tests"), ["SessionBoard"])
        XCTAssertEqual(highlighted("tests sess", "SessionBoard tests"), ["Sess", "tests"])
        XCTAssertNil(FuzzyMatcher.match("session zebra", in: "SessionBoard tests"))
        XCTAssertEqual(score("board session", "SessionBoard"), score("session board", "SessionBoard"))
        XCTAssertGreaterThan(try XCTUnwrap(score("session board", "SessionBoard")),
                             try XCTUnwrap(score("session", "SessionBoard")))
    }

    func testLongTextIsCutNotScanned() {
        let long = String(repeating: "a", count: FuzzyText.maxLength) + "needle"
        XCTAssertNil(FuzzyMatcher.match("needle", in: long))
        XCTAssertNotNil(FuzzyMatcher.match("aaa", in: long))
    }

    func testAFewThousandItemsPerKeystroke() {
        let words = ["hoply", "SessionBoard", "fix-login", "api/server", "Dashboard", "refactor_parser", "vite", "Überblick"]
        let texts = (0..<4000).map { index in
            FuzzyText("\(words[index % 8]) \(words[(index / 8) % 8])/\(words[(index / 64) % 8]) \(index)")
        }
        let query = FuzzyQuery("sess dash")
        let started = Date()
        let hits = texts.reduce(0) { $0 + (FuzzyMatcher.match(query, in: $1) == nil ? 0 : 1) }
        XCTAssertGreaterThan(hits, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "a debug build stays far below a second")
    }
}
