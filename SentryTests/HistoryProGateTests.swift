import XCTest
@testable import Sentry
import SentryKit

/// The Pro gate for history export + extended retention
/// (`ProFeature.historyExport`), pinned at its pure seams — the
/// `HistoryProGate` clamp the composition root applies before
/// `RollupJob.setRetention`, the Advanced pane's slider bounds, and the
/// locked export menu's copy. Same shape as `FanControlServiceTests`' "Pro
/// gate" section: what locked withholds, and — just as load-bearing — what
/// it must never withhold (the shipped defaults, and lowering retention).
///
/// What's deliberately *not* here: `DashboardChart.export(_:format:)`'s own
/// locked guard ends in an `NSSavePanel`, which this suite never touches
/// for the same reason `HistoryExportTests`' header gives — the testable
/// half of that path is the `ExportContext.isUnlocked` flag both the menu
/// and the action read, and the flag's sources are pinned below.
final class HistoryProGateTests: XCTestCase {

    // MARK: - The clamp (HistoryProGate.clampedRetention)

    func testLockedClampsAboveDefaultRetentionToTheFreeCaps() {
        let clamped = HistoryProGate.clampedRetention(isUnlocked: false, rawHours: 168, hourlyDays: 365)
        XCTAssertEqual(clamped.rawHours, HistoryProGate.freeRawRetentionCapHours)
        XCTAssertEqual(clamped.hourlyDays, HistoryProGate.freeHourlyRetentionCapDays)
    }

    func testLockedLeavesTheShippedDefaultsUntouched() {
        // The free caps equal the defaults, so a free user who never touched
        // the sliders must see no change at all when the gate arrives.
        let clamped = HistoryProGate.clampedRetention(isUnlocked: false, rawHours: 48, hourlyDays: 90)
        XCTAssertEqual(clamped.rawHours, 48)
        XCTAssertEqual(clamped.hourlyDays, 90)
    }

    func testLockedNeverTouchesLoweredRetention() {
        // Shrinking retention is data minimization and is never gated —
        // both the slider minimums and anything between them and the caps.
        for (raw, hourly) in [(6, 7), (24, 30), (47, 89)] {
            let clamped = HistoryProGate.clampedRetention(isUnlocked: false, rawHours: raw, hourlyDays: hourly)
            XCTAssertEqual(clamped.rawHours, raw)
            XCTAssertEqual(clamped.hourlyDays, hourly)
        }
    }

    func testClampNeverRaisesAValue() {
        // No floor is supplied here on purpose — `RollupJob.setRetention`
        // guards its own lower bound, and a clamp that silently raised a
        // hand-edited value would be a second, hidden writer of policy.
        let clamped = HistoryProGate.clampedRetention(isUnlocked: false, rawHours: 1, hourlyDays: 1)
        XCTAssertEqual(clamped.rawHours, 1)
        XCTAssertEqual(clamped.hourlyDays, 1)
    }

    func testUnlockedPassesEverythingThroughUntouched() {
        for (raw, hourly) in [(168, 365), (48, 90), (6, 7)] {
            let clamped = HistoryProGate.clampedRetention(isUnlocked: true, rawHours: raw, hourlyDays: hourly)
            XCTAssertEqual(clamped.rawHours, raw)
            XCTAssertEqual(clamped.hourlyDays, hourly)
        }
    }

    /// The lapse story in one assertion: a license that lapses with
    /// retention still set above the caps pins the *effective* window at
    /// the free caps while the stored preference (the inputs here — a pure
    /// function mutates nothing) survives, so re-unlocking restores the
    /// user's choice verbatim.
    func testLapsePinsEffectiveRetentionAndReUnlockRestoresTheStoredChoice() {
        let stored = (rawHours: 168, hourlyDays: 365)

        let lapsed = HistoryProGate.clampedRetention(
            isUnlocked: false, rawHours: stored.rawHours, hourlyDays: stored.hourlyDays
        )
        XCTAssertEqual(lapsed.rawHours, HistoryProGate.freeRawRetentionCapHours)
        XCTAssertEqual(lapsed.hourlyDays, HistoryProGate.freeHourlyRetentionCapDays)

        let restored = HistoryProGate.clampedRetention(
            isUnlocked: true, rawHours: stored.rawHours, hourlyDays: stored.hourlyDays
        )
        XCTAssertEqual(restored.rawHours, stored.rawHours)
        XCTAssertEqual(restored.hourlyDays, stored.hourlyDays)
    }

    func testFreeCapsEqualTheShippedDefaults() {
        // `HistoryProGate`'s caps promise to track `AppSettings.init`'s
        // defaults — this is the assertion that makes drifting apart a test
        // failure instead of a silent free-tier change.
        let defaults = AppSettings()
        XCTAssertEqual(HistoryProGate.freeRawRetentionCapHours, defaults.rawRetentionHours)
        XCTAssertEqual(HistoryProGate.freeHourlyRetentionCapDays, defaults.hourlyRetentionDays)
    }

    // MARK: - Entitlement source (ProFeature.historyExport)

    /// A throwaway-URL `SettingsStore` with a debounce long enough that no
    /// test races a disk write — same helper shape as
    /// `LicenseProEntitlementTests.makeSettingsStore`.
    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-gate-tests-\(UUID().uuidString)")
            .appendingPathComponent("settings.json")
        return SettingsStore(fileURL: url, debounceInterval: 3600)
    }

    /// The flip-live contract at the entitlement level: `.historyExport`
    /// answers locked → unlocked → locked as the override toggles, through
    /// the same `applySettings` push the composition root uses. (Full
    /// every-feature/every-source parity lives in
    /// `LicenseProEntitlementTests`; this pins the one case this gate
    /// consumes.)
    @MainActor
    func testHistoryExportEntitlementFlipsWithTheOverride() {
        let settingsStore = makeSettingsStore()
        let store = ProEntitlementStore(settingsStore: settingsStore)
        XCTAssertFalse(store.isUnlocked(.historyExport))

        var settings = settingsStore.settings
        settings.proUnlockOverrideEnabled = true
        store.applySettings(settings)
        XCTAssertTrue(store.isUnlocked(.historyExport))

        settings.proUnlockOverrideEnabled = false
        store.applySettings(settings)
        XCTAssertFalse(store.isUnlocked(.historyExport))
    }

    // MARK: - UI seams (defaults locked, capped ranges, honest copy)

    /// Both consumers of the composition-root push default locked — a view
    /// model or grid nobody seeded must not offer export, same doctrine as
    /// `FanControlService.isProUnlocked`.
    @MainActor
    func testDashboardViewModelDefaultsLocked() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryProGateTests-\(UUID().uuidString).sqlite")
        let model = DashboardViewModel(historyStore: HistoryStore(databaseURL: url))
        XCTAssertFalse(model.isProUnlocked)
    }

    func testLockedSliderRangesCapAtTheFreeWindowAndUnlockRestoresTheFullSpan() {
        XCTAssertEqual(AdvancedPane.rawRetentionSliderRange(isProUnlocked: false), 6...48)
        XCTAssertEqual(AdvancedPane.hourlyRetentionSliderRange(isProUnlocked: false), 7...90)
        XCTAssertEqual(AdvancedPane.rawRetentionSliderRange(isProUnlocked: true), 6...168)
        XCTAssertEqual(AdvancedPane.hourlyRetentionSliderRange(isProUnlocked: true), 7...365)
    }

    func testSliderLowerBoundsNeverMoveWithEntitlement() {
        // The free tier's freedom to shrink retention must not depend on
        // the paywall in either direction.
        XCTAssertEqual(
            AdvancedPane.rawRetentionSliderRange(isProUnlocked: false).lowerBound,
            AdvancedPane.rawRetentionSliderRange(isProUnlocked: true).lowerBound
        )
        XCTAssertEqual(
            AdvancedPane.hourlyRetentionSliderRange(isProUnlocked: false).lowerBound,
            AdvancedPane.hourlyRetentionSliderRange(isProUnlocked: true).lowerBound
        )
    }

    func testLockedExportMenuCopyNamesTheTierAndSellsNothing() {
        // Mirrors `testRequiresProCopyNamesTheLicenseNotTheHardware`: the
        // locked item names the feature and the tier, and offers no
        // purchase it can't deliver (checkout doesn't exist — see
        // `ProUpsellCard.unavailableNotice`).
        let copy = DashboardChart.lockedExportMenuTitle
        XCTAssertTrue(copy.contains("Export"))
        XCTAssertTrue(copy.contains("Sentry Pro"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("buy"))
    }
}
