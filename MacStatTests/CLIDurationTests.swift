import XCTest
@testable import MacStatKit

/// Covers `CLIDuration`, which parses `--interval 1s` / `--for 30s` style
/// arguments for the `macstat` CLI (plan §21.2.1).
///
/// The failure this suite is built around is not a crash — it is a
/// *plausible wrong answer*. `Double("500ms")` returns nil, `Double("1s")`
/// returns nil, and a parser that fell back to a default on nil would give a
/// user who typed `--interval 500ms` a stream at some other cadence with no
/// indication anything was ignored. Everything below therefore checks two
/// things at once: that valid input produces the right number of seconds,
/// and that invalid input produces `nil` rather than a number that merely
/// looks reasonable.
final class CLIDurationTests: XCTestCase {

    func testBareNumbersAreSeconds() {
        XCTAssertEqual(CLIDuration.seconds("1"), 1)
        XCTAssertEqual(CLIDuration.seconds("2.5"), 2.5)
        XCTAssertEqual(CLIDuration.seconds("0"), 0)
    }

    func testSuffixedFormsFromThePlan() {
        XCTAssertEqual(CLIDuration.seconds("1s"), 1)
        XCTAssertEqual(CLIDuration.seconds("30s"), 30)
        XCTAssertEqual(CLIDuration.seconds("2m"), 120)
        XCTAssertEqual(CLIDuration.seconds("1h"), 3600)
    }

    func testMillisecondsAreNotParsedAsMinutes() {
        // The ordering bug this rules out: testing the "m" suffix before
        // "ms" makes "500ms" fail to parse as a number ("500m"), and testing
        // "s" first makes it 500 *seconds* if the leftover "m" is tolerated.
        // Either way a user asking for half a second gets something between
        // 500x and 30000x too slow.
        XCTAssertEqual(CLIDuration.seconds("500ms"), 0.5)
        XCTAssertEqual(CLIDuration.seconds("250ms"), 0.25)
        XCTAssertNotEqual(CLIDuration.seconds("500ms"), 500)
        XCTAssertNotEqual(CLIDuration.seconds("500ms"), 30000)
    }

    func testWhitespaceAndCaseAreForgiven() {
        XCTAssertEqual(CLIDuration.seconds("  2S "), 2)
        XCTAssertEqual(CLIDuration.seconds("500MS"), 0.5)
    }

    func testGarbageIsRejectedRatherThanPartiallyParsed() {
        for input in ["", "   ", "s", "ms", "abc", "1x", "--interval", "1 s", "1,5s"] {
            XCTAssertNil(CLIDuration.seconds(input), "`\(input)` should not parse")
        }
    }

    func testCompoundDurationsAreRejectedRatherThanSilentlyTruncated() {
        // "1h30m" reading as one hour would be the worst possible outcome:
        // a wait that returns thirty minutes early, with nothing to suggest
        // the argument was misunderstood.
        XCTAssertNil(CLIDuration.seconds("1h30m"))
        XCTAssertNil(CLIDuration.seconds("2m30s"))
    }

    func testNegativeAndNonFiniteValuesAreRejected() {
        // These parse fine as numbers and are not durations. A negative
        // interval would make `Task.sleep`'s `UInt64` conversion trap.
        XCTAssertNil(CLIDuration.seconds("-1"))
        XCTAssertNil(CLIDuration.seconds("-5s"))
        XCTAssertNil(CLIDuration.seconds("inf"))
        XCTAssertNil(CLIDuration.seconds("nan"))
    }

    func testTheErrorMessageDescribesFormsTheParserActuallyAccepts() {
        // A usage string listing a syntax the parser rejects is worse than
        // no usage string, so the two are asserted against each other.
        let description = CLIDuration.acceptedFormsDescription
        for example in ["1.5", "500ms", "1s", "2m", "1h"] {
            XCTAssertTrue(description.contains(example), "`\(example)` is advertised but untested")
            XCTAssertNotNil(CLIDuration.seconds(example), "`\(example)` is advertised but rejected")
        }
    }
}
