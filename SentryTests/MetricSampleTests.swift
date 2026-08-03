import XCTest
@testable import SentryKit

/// Covers `MCPPayloads.MetricSample` — one line of `sentryctl watch`'s
/// newline-delimited JSON (plan §21.2.1).
///
/// **Why the JSON shape is worth a test of its own.** This stream is
/// designed to be piped into `jq`, appended to a log, and read back weeks
/// later when someone is asking why a build was slow. Every one of those
/// consumers is a program or a person outside this repository, holding a key
/// name this file decides. That makes the field names a contract in exactly
/// the sense `MetricID`'s raw values are, with the same rule attached: add
/// and deprecate, never rename.
///
/// The substantive assertions are the last two. A metric this Mac cannot
/// read must serialize as an explicit `null` with `available: false`, never
/// as `0` and never by omitting the key — a stream where "unavailable" and
/// "zero" look alike is a stream that cannot be used as evidence, which is
/// the only reason to keep one.
final class MetricSampleTests: XCTestCase {

    private func encode(_ sample: MCPPayloads.MetricSample) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(sample), as: UTF8.self)
    }

    func testAvailableSampleSerializesToTheDocumentedShape() throws {
        let sample = MCPPayloads.MetricSample(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            metric: MetricID.cpuTotalPercent.rawValue,
            unit: MetricUnit.percent.rawValue,
            value: 12.5,
            available: true,
            intervalSeconds: 1
        )
        XCTAssertEqual(
            try encode(sample),
            #"{"available":true,"intervalSeconds":1,"metric":"cpu.total_percent","timestamp":"2023-11-14T22:13:20Z","unit":"percent","value":12.5}"#
        )
    }

    func testTheFirstSampleOmitsIntervalSecondsBecauseItHasNoPredecessor() throws {
        let sample = MCPPayloads.MetricSample(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            metric: MetricID.cpuTotalPercent.rawValue,
            unit: MetricUnit.percent.rawValue,
            value: 3,
            available: true,
            intervalSeconds: nil
        )
        XCTAssertFalse(try encode(sample).contains("intervalSeconds"))
    }

    func testAnUnreadableMetricIsNullAndFlagged__NeverZero() throws {
        let sample = MCPPayloads.MetricSample(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            metric: MetricID.gpuPowerWatts.rawValue,
            unit: MetricUnit.watts.rawValue,
            value: nil,
            available: false,
            intervalSeconds: 2
        )
        let json = try encode(sample)
        XCTAssertTrue(json.contains(#""available":false"#), json)
        XCTAssertTrue(json.contains(#""value":null"#), json)
        XCTAssertFalse(json.contains(#""value":0"#), json)
    }

    func testAvailabilityAgreesWithWhatTheSnapshotCanActuallyAnswer() {
        // This mirrors the exact expression `sentryctl watch` builds each line
        // from. The trap it guards: someone deciding `available` can be
        // derived from `snapshot.gpu != nil` (module present) rather than
        // from `value(for:)` (this *field* present). `cpu.user_percent` is
        // the standing counterexample — the CPU module is fully populated
        // and that particular metric is still unreadable, because
        // `CPUCollector` never splits user from system time.
        let snapshot = SystemSnapshot(
            deviceID: "test-device",
            cpu: CPUStats(totalPercent: 44)
        )

        let readable = snapshot.value(for: .cpuTotalPercent)
        XCTAssertEqual(readable, 44)
        XCTAssertTrue(readable != nil)

        let unreadableDespiteItsModuleBeingPresent = snapshot.value(for: .cpuUserPercent)
        XCTAssertNil(unreadableDespiteItsModuleBeingPresent)

        let absentModule = snapshot.value(for: .gpuPowerWatts)
        XCTAssertNil(absentModule)
    }

    func testEveryStreamableMetricCanNameItsUnit() {
        // `sentryctl watch --list-metrics` prints `id<TAB>unit` for every case,
        // and each emitted line restates the unit. Both would print an empty
        // column if a `MetricUnit` raw value were ever left blank.
        for metric in MetricID.allCases {
            XCTAssertFalse(metric.unit.rawValue.isEmpty, metric.rawValue)
        }
    }
}
