@testable import AgentKit
import XCTest

final class PriceInputTests: XCTestCase {
    func testParseAcceptsAPositivePrice() {
        XCTAssertEqual(PriceInput.parse("2"), 2)
        XCTAssertEqual(PriceInput.parse("0.25"), 0.25)
        XCTAssertEqual(PriceInput.parse("  8.5 "), 8.5)
        XCTAssertEqual(PriceInput.parse("$2.50"), 2.5)
    }

    func testParseTakesACommaAsTheDecimalSeparator() {
        XCTAssertEqual(PriceInput.parse("2,5"), 2.5)
        XCTAssertEqual(PriceInput.parse("1,000"), 1, "a comma is a decimal point, never a thousands separator")
        XCTAssertNil(PriceInput.parse("1,000,5"))
    }

    func testParseRejectsWhatIsNotAPrice() {
        XCTAssertNil(PriceInput.parse(""))
        XCTAssertNil(PriceInput.parse("   "))
        XCTAssertNil(PriceInput.parse("$"))
        XCTAssertNil(PriceInput.parse("$ 3"), "a space after the dollar sign is not trimmed")
        XCTAssertNil(PriceInput.parse("0"))
        XCTAssertNil(PriceInput.parse("0.0"))
        XCTAssertNil(PriceInput.parse("-1"))
        XCTAssertNil(PriceInput.parse("abc"))
        XCTAssertNil(PriceInput.parse("2 dollars"))
        XCTAssertNil(PriceInput.parse("nan"))
        XCTAssertNil(PriceInput.parse("inf"))
    }

    func testFormatDropsAWholeNumbersFraction() {
        XCTAssertEqual(PriceInput.format(8), "8")
        XCTAssertEqual(PriceInput.format(0.25), "0.25")
        XCTAssertEqual(PriceInput.format(2.5), "2.5")
    }

    func testFormatRoundTripsWhatParseAccepts() throws {
        for text in ["2", "0.1", "$2.50", "12,75", " 40 ", "0.0625"] {
            let value = try XCTUnwrap(PriceInput.parse(text), text)
            XCTAssertEqual(PriceInput.parse(PriceInput.format(value)), value, text)
        }
        XCTAssertEqual(PriceInput.format(try XCTUnwrap(PriceInput.parse("$2.50"))), "2.5")
    }
}
