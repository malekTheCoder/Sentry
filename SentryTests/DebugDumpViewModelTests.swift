import XCTest
@testable import Sentry
import SentryKit

/// Regression coverage for gating `DebugDumpViewModel`'s expensive `Mirror`
/// reflection walk on window visibility. An earlier version ran
/// `SnapshotDebugFormatter.sections(for:)` on every ingested snapshot
/// unconditionally — every install, every ~3s tick, forever, whether or not
/// the debug window had ever been opened — which a review correctly flagged
/// against plan R9 ("does this app use noticeable CPU/battery").
@MainActor
final class DebugDumpViewModelTests: XCTestCase {

    private func makeSnapshot(deviceID: String) -> SystemSnapshot {
        SystemSnapshot(deviceID: deviceID, cpu: CPUStats(totalPercent: 10))
    }

    func testIngestDoesNotPopulateSectionsWhileWindowIsNotVisible() {
        let model = DebugDumpViewModel()
        XCTAssertFalse(model.isWindowVisible)

        model.ingest(makeSnapshot(deviceID: "a"))

        // `lastUpdated` is cheap bookkeeping and always kept current...
        XCTAssertNotNil(model.lastUpdated)
        // ...but the expensive reflection dump must not have run.
        XCTAssertTrue(model.sections.isEmpty)
    }

    func testBecomingVisibleBackfillsSectionsFromTheLastIngestedSnapshot() {
        let model = DebugDumpViewModel()
        model.ingest(makeSnapshot(deviceID: "backfill-me"))
        XCTAssertTrue(model.sections.isEmpty, "sanity check: still gated before becoming visible")

        model.isWindowVisible = true

        XCTAssertFalse(model.sections.isEmpty)
        let meta = model.sections.first { $0.name == "Snapshot" }
        XCTAssertEqual(meta?.fields.first { $0.name == "deviceID" }?.value, "backfill-me")
    }

    func testIngestPopulatesSectionsWhileWindowIsVisible() {
        let model = DebugDumpViewModel()
        model.isWindowVisible = true

        model.ingest(makeSnapshot(deviceID: "live"))

        let meta = model.sections.first { $0.name == "Snapshot" }
        XCTAssertEqual(meta?.fields.first { $0.name == "deviceID" }?.value, "live")
    }

    func testBecomingInvisibleStopsFurtherReflectionButKeepsLastSections() {
        let model = DebugDumpViewModel()
        model.isWindowVisible = true
        model.ingest(makeSnapshot(deviceID: "first"))
        XCTAssertFalse(model.sections.isEmpty)

        model.isWindowVisible = false
        model.ingest(makeSnapshot(deviceID: "second"))

        // Stale content left on screen is fine — the window isn't visible to
        // see it — but confirms the second ingest's reflection was skipped
        // rather than silently updating `sections` in the background.
        let meta = model.sections.first { $0.name == "Snapshot" }
        XCTAssertEqual(meta?.fields.first { $0.name == "deviceID" }?.value, "first")
    }

    func testPlainTextDumpWorksRegardlessOfVisibility() {
        // The Copy button must reflect the true latest snapshot even though
        // `sections` itself is gated — it re-renders on demand rather than
        // reading the (possibly stale/empty) published `sections` array.
        let model = DebugDumpViewModel()
        model.ingest(makeSnapshot(deviceID: "copy-target"))

        XCTAssertTrue(model.plainTextDump.contains("copy-target"))
    }
}
