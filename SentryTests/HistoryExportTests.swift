import XCTest
@testable import SentryKit

/// Exact-output coverage for `HistoryExport` — the Dashboard's "Export…"
/// action has no other automated coverage (it ends in an `NSSavePanel`,
/// which these tests deliberately never touch), so the formatting itself is
/// what's asserted here: the CSV/JSON text a fabricated sample array
/// produces, byte for byte, including the edge cases (missing values,
/// missing units, an empty sample array, and non-finite doubles) `Sample`'s
/// own doc comment says this file is responsible for handling honestly.
final class HistoryExportTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z

    // MARK: - CSV

    func testCSVHeaderAndOneRowPerSample() {
        let samples = [
            HistoryExport.Sample(timestamp: referenceDate, value: 42.5),
            HistoryExport.Sample(timestamp: referenceDate.addingTimeInterval(60), value: 51.0)
        ]
        let csv = HistoryExport.csv(metricID: "cpu.total_percent", unit: .percent, samples: samples)
        XCTAssertEqual(csv, """
        timestamp,value,unit
        2023-11-14T22:13:20Z,42.5,percent
        2023-11-14T22:14:20Z,51.0,percent

        """)
    }

    func testCSVWithNoSamplesIsJustTheHeader() {
        let csv = HistoryExport.csv(metricID: "cpu.total_percent", unit: .percent, samples: [])
        XCTAssertEqual(csv, "timestamp,value,unit\n")
    }

    /// A `nil` value renders as an empty field, never a fabricated `0` —
    /// same P5 discipline `VitalDetail`/`MetricFormatting` already apply
    /// everywhere else a reading can be genuinely absent.
    func testCSVMissingValueIsAnEmptyField() {
        let csv = HistoryExport.csv(
            metricID: "cpu.total_percent",
            unit: .percent,
            samples: [HistoryExport.Sample(timestamp: referenceDate, value: nil)]
        )
        XCTAssertEqual(csv, "timestamp,value,unit\n2023-11-14T22:13:20Z,,percent\n")
    }

    /// A `nil` unit renders as an empty field too, independently of `value`.
    func testCSVMissingUnitIsAnEmptyField() {
        let csv = HistoryExport.csv(
            metricID: "cpu.total_percent",
            unit: nil,
            samples: [HistoryExport.Sample(timestamp: referenceDate, value: 42.5)]
        )
        XCTAssertEqual(csv, "timestamp,value,unit\n2023-11-14T22:13:20Z,42.5,\n")
    }

    /// Non-finite doubles collapse to the same empty field a `nil` value
    /// produces, rather than writing text ("nan", "inf") a numeric-column
    /// parser would choke on.
    func testCSVNonFiniteValueIsAnEmptyField() {
        let csv = HistoryExport.csv(
            metricID: "cpu.total_percent",
            unit: .percent,
            samples: [
                HistoryExport.Sample(timestamp: referenceDate, value: .nan),
                HistoryExport.Sample(timestamp: referenceDate, value: .infinity)
            ]
        )
        XCTAssertEqual(csv, """
        timestamp,value,unit
        2023-11-14T22:13:20Z,,percent
        2023-11-14T22:13:20Z,,percent

        """)
    }

    // MARK: - JSON

    func testJSONIsAnArrayOfObjectsWithTheSameFields() throws {
        let samples = [HistoryExport.Sample(timestamp: referenceDate, value: 42.5)]
        let data = HistoryExport.json(metricID: "cpu.total_percent", unit: .percent, samples: samples)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        let rows = try XCTUnwrap(decoded)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["timestamp"] as? String, "2023-11-14T22:13:20Z")
        XCTAssertEqual(rows[0]["value"] as? Double, 42.5)
        XCTAssertEqual(rows[0]["unit"] as? String, "percent")
    }

    func testJSONWithNoSamplesIsAnEmptyArray() throws {
        let data = HistoryExport.json(metricID: "cpu.total_percent", unit: .percent, samples: [])
        let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertEqual(try XCTUnwrap(decoded).count, 0)
    }

    /// `nil`/non-finite values encode as JSON `null`, not a sentinel number
    /// or the literal string `"null"` — the same "no reading, honestly
    /// stated" contract the CSV path applies via an empty field.
    func testJSONMissingOrNonFiniteValueEncodesAsNull() throws {
        let samples = [
            HistoryExport.Sample(timestamp: referenceDate, value: nil),
            HistoryExport.Sample(timestamp: referenceDate, value: .nan)
        ]
        let data = HistoryExport.json(metricID: "cpu.total_percent", unit: nil, samples: samples)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        let rows = try XCTUnwrap(decoded)
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertTrue(row["value"] is NSNull)
            XCTAssertTrue(row["unit"] is NSNull)
            XCTAssertNotNil(row["timestamp"] as? String)
        }
    }
}
