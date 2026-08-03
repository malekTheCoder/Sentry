import XCTest
@testable import Sentry
@testable import SentryKit

/// Coverage for the menu-bar layout truncation logic in
/// `StatusItemView.rebuildLayout()` (Sentry/MenuBar/StatusItemView.swift):
/// when a user's `MenuBarLayout.maxWidth` is smaller than what all enabled
/// modules need, trailing modules are dropped and an ellipsis is drawn
/// rather than overflowing the status bar or vanishing entirely.
///
/// `rebuildLayout()` itself is private, so these tests drive it indirectly
/// through the internal, testable surface (`init`, `update(_:)`,
/// `apply(layout:)`, `intrinsicContentSize`, `accessibilitySummary`) exactly
/// as `StatusItemContainer` does in production.
final class StatusItemViewTruncationTests: XCTestCase {

    private func makeSnapshot(cpu: Double = 42, memoryUsed: UInt64 = 8_000_000_000) -> SystemSnapshot {
        var snapshot = SystemSnapshot(deviceID: "test-device")
        snapshot.cpu = CPUStats(totalPercent: cpu)
        snapshot.memory = MemoryStats(
            usedBytes: memoryUsed,
            appMemoryBytes: memoryUsed / 2,
            wiredBytes: 1_000_000_000,
            compressedBytes: 0,
            cachedBytes: 0,
            totalBytes: 16_000_000_000
        )
        snapshot.gpu = GPUStats(utilizationPercent: 12)
        snapshot.network = NetworkStats(
            rxBytesPerSec: 500_000,
            txBytesPerSec: 100_000,
            rxSessionTotalBytes: 0,
            txSessionTotalBytes: 0
        )
        return snapshot
    }

    private func manyModulesLayout(maxWidth: Double?) -> MenuBarLayout {
        MenuBarLayout(
            modules: [
                BarModule(metric: .cpuTotalPercent, displayMode: .valueOnly, showLabel: true),
                BarModule(metric: .memoryUsedBytes, displayMode: .valueOnly, showLabel: true),
                BarModule(metric: .gpuUtilizationPercent, displayMode: .valueOnly, showLabel: true),
                BarModule(metric: .networkRxBytesPerSec, displayMode: .valueOnly, showLabel: true),
                BarModule(metric: .networkTxBytesPerSec, displayMode: .valueOnly, showLabel: true)
            ],
            spacing: 6,
            separatorStyle: .space,
            maxWidth: maxWidth
        )
    }

    // MARK: - No budget: nothing is truncated

    func testNilMaxWidthKeepsAllModulesAndAccessibilitySummary() {
        let view = StatusItemView(layout: manyModulesLayout(maxWidth: nil), theme: .slate)
        view.update(makeSnapshot())

        // With no width budget, every configured module's label should show
        // up in the VoiceOver summary — none silently dropped.
        for label in ["CPU", "Mem", "GPU"] {
            XCTAssertTrue(
                view.accessibilitySummary.contains(label),
                "expected '\(label)' in summary, got: \(view.accessibilitySummary)"
            )
        }
        XCTAssertFalse(view.accessibilitySummary.isEmpty)
    }

    // MARK: - A tight budget forces truncation

    func testVeryNarrowBudgetStillKeepsFirstModule() {
        // R8: the first module is always kept even if it alone busts the
        // budget — a vanished bar item reads as a crashed app.
        let view = StatusItemView(layout: manyModulesLayout(maxWidth: 1), theme: .slate)
        view.update(makeSnapshot())

        XCTAssertTrue(
            view.accessibilitySummary.contains("CPU"),
            "first module must survive even a near-zero budget, got: \(view.accessibilitySummary)"
        )
    }

    func testNarrowBudgetDropsTrailingModulesComparedToUnlimited() {
        let unlimited = StatusItemView(layout: manyModulesLayout(maxWidth: nil), theme: .slate)
        unlimited.update(makeSnapshot())

        let narrow = StatusItemView(layout: manyModulesLayout(maxWidth: 60), theme: .slate)
        narrow.update(makeSnapshot())

        // A budget far smaller than five labeled modules need must render a
        // narrower (or equal, never wider) item than the unlimited layout.
        XCTAssertLessThanOrEqual(narrow.intrinsicContentSize.width, unlimited.intrinsicContentSize.width)
    }

    func testNarrowBudgetProducesFewerAccessibilityPartsThanUnlimited() {
        let unlimited = StatusItemView(layout: manyModulesLayout(maxWidth: nil), theme: .slate)
        unlimited.update(makeSnapshot())
        let unlimitedParts = unlimited.accessibilitySummary.components(separatedBy: ", ").count

        let narrow = StatusItemView(layout: manyModulesLayout(maxWidth: 60), theme: .slate)
        narrow.update(makeSnapshot())
        let narrowParts = narrow.accessibilitySummary.components(separatedBy: ", ").count

        XCTAssertLessThan(narrowParts, unlimitedParts)
    }

    // MARK: - Growing the budget back never truncates more than a smaller one

    func testWidthNeverDecreasesWhenBudgetGrows() {
        let layoutNarrow = manyModulesLayout(maxWidth: 80)
        let layoutWide = manyModulesLayout(maxWidth: 400)

        let view = StatusItemView(layout: layoutNarrow, theme: .slate)
        view.update(makeSnapshot())
        let narrowWidth = view.intrinsicContentSize.width

        view.apply(layout: layoutWide)
        let wideWidth = view.intrinsicContentSize.width

        XCTAssertGreaterThanOrEqual(wideWidth, narrowWidth)
    }

    // MARK: - Empty layout falls back to the glyph rather than a blank item

    func testEmptyModulesFallsBackToNonZeroWidth() {
        let view = StatusItemView(layout: MenuBarLayout(modules: [], maxWidth: nil), theme: .slate)
        view.update(makeSnapshot())

        XCTAssertGreaterThan(view.intrinsicContentSize.width, 0)
        XCTAssertEqual(view.accessibilitySummary, "Sentry")
    }

    // MARK: - A single module always fits regardless of a tiny budget

    func testSingleModuleLayoutIsNeverEmptyEvenWithTinyBudget() {
        let layout = MenuBarLayout(
            modules: [BarModule(metric: .cpuTotalPercent, displayMode: .valueOnly)],
            maxWidth: 1
        )
        let view = StatusItemView(layout: layout, theme: .slate)
        view.update(makeSnapshot())

        XCTAssertFalse(view.accessibilitySummary.isEmpty)
        XCTAssertNotEqual(view.accessibilitySummary, "Sentry")
        XCTAssertGreaterThan(view.intrinsicContentSize.width, 0)
    }
}
