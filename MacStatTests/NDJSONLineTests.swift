import XCTest
@testable import MacStatKit

/// Coverage for `NDJSONLine` (`MacStatKit/CLI/NDJSONLine.swift`), the
/// framing guarantee behind `macstat watch`'s "one JSON object per line"
/// contract. Three behaviors matter: the common compact payload passes
/// through byte-identical (no reparse, no field loss), a pretty-printed
/// payload gets flattened to one line without losing fields the local
/// model types might not know about, and an unparseable multi-line payload
/// yields nil rather than a malformed line — on a data interface, no
/// output beats wrong output.
final class NDJSONLineTests: XCTestCase {

    func testCompactPayloadPassesThroughByteIdentical() {
        // Today's app path: JSONEncoder without .prettyPrinted. Must be
        // returned as-is — same bytes, not merely equivalent JSON — so the
        // fast path provably does no reserialization that could reorder
        // keys or reformat numbers.
        let payload = Data(#"{"cpu":{"totalPercent":42.5},"deviceID":"mac-1"}"#.utf8)
        XCTAssertEqual(NDJSONLine.make(from: payload), payload)
    }

    func testEscapedNewlinesInsideStringsAreNotFormattingWhitespace() {
        // JSON mandates escaping literal newlines inside strings, so the
        // two-character sequence \n must not trigger the slow path — it's
        // data, and the payload is already one line.
        let payload = Data(#"{"note":"line one\nline two"}"#.utf8)
        XCTAssertEqual(NDJSONLine.make(from: payload), payload)
    }

    func testPrettyPrintedPayloadFlattensToOneLineKeepingAllFields() {
        // The defensive path: a future app version turning on
        // .prettyPrinted must degrade to a reserialize, not corrupt every
        // consumer's line-based reader. Field survival matters more than
        // key order (JSONSerialization does not promise order), so assert
        // on parse-equality and the single-line invariant.
        let pretty = Data("""
        {
          "deviceID" : "mac-1",
          "futureFieldThisCLIDoesNotModel" : true,
          "cpu" : {
            "totalPercent" : 42.5
          }
        }
        """.utf8)
        guard let line = NDJSONLine.make(from: pretty) else {
            return XCTFail("pretty-printed JSON should flatten, not fail")
        }
        XCTAssertFalse(line.contains(0x0A))
        XCTAssertFalse(line.contains(0x0D))
        let original = try? JSONSerialization.jsonObject(with: pretty) as? NSDictionary
        let flattened = try? JSONSerialization.jsonObject(with: line) as? NSDictionary
        XCTAssertNotNil(original)
        XCTAssertEqual(original, flattened)
        // The whole reason the fallback is JSONSerialization and not a
        // decode-reencode through SystemSnapshot: unknown fields survive.
        XCTAssertEqual(flattened?["futureFieldThisCLIDoesNotModel"] as? Bool, true)
    }

    func testCarriageReturnsAloneAlsoTriggerFlattening() {
        let payload = Data("{\r\"a\":1\r}".utf8)
        guard let line = NDJSONLine.make(from: payload) else {
            return XCTFail("CR-formatted JSON should flatten, not fail")
        }
        XCTAssertFalse(line.contains(0x0D))
    }

    func testMultiLineGarbageYieldsNilNotAMalformedLine() {
        XCTAssertNil(NDJSONLine.make(from: Data("not\njson".utf8)))
    }
}
