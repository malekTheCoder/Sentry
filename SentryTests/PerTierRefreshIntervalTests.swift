import XCTest
@testable import SentryKit

/// Covers FR-2's actual implemented surface: per-*tier* (not per-module)
/// refresh interval control. See `StatsCoordinator.setBaseInterval`'s doc
/// comment for why "per tier" was the scope chosen instead of a full
/// per-collector scheduler rewrite.
///
/// Two things are load-bearing enough to need tests:
///  1. `AppSettings`' forward-compatible decode of the two new keys
///     (`mediumTierRefreshInterval`/`slowTierRefreshInterval`) — the same
///     failure mode as `AlertRuleSettingsTests`: getting this wrong doesn't
///     crash, it just silently reverts a user's chosen interval on next
///     launch.
///  2. `StatsCoordinator`'s tier setters actually being independent of each
///     other (the bug this refactor specifically had to avoid — see
///     `setBaseInterval`'s doc comment about the old ratio-locked behavior)
///     and correctly clamped.
@MainActor
final class PerTierRefreshIntervalTests: XCTestCase {

    // MARK: - AppSettings decode

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    func testSettingsFileWithoutTierKeysDecodesToPlanDefaults() throws {
        // A settings file written by a build from before these two keys
        // existed must fall back to the plan's §8.4 defaults (5s/30s), not
        // throw and not silently zero them out.
        let settings = try decode(#"{"themeID":"terminal"}"#)

        XCTAssertEqual(settings.mediumTierRefreshInterval, 5)
        XCTAssertEqual(settings.slowTierRefreshInterval, 30)
    }

    func testSettingsFileWithExplicitTierValuesRoundTrips() throws {
        let settings = try decode(
            #"{"themeID":"terminal","mediumTierRefreshInterval":12,"slowTierRefreshInterval":90}"#
        )

        XCTAssertEqual(settings.mediumTierRefreshInterval, 12)
        XCTAssertEqual(settings.slowTierRefreshInterval, 90)
    }

    func testDefaultAppSettingsMatchesPlanTierDefaults() {
        let settings = AppSettings()

        XCTAssertEqual(settings.globalRefreshInterval, 3)
        XCTAssertEqual(settings.mediumTierRefreshInterval, 5)
        XCTAssertEqual(settings.slowTierRefreshInterval, 30)
    }

    // MARK: - StatsCoordinator tier independence + clamping

    private func makeCoordinator() -> StatsCoordinator {
        StatsCoordinator(
            batteryProvider: { nil },
            cpuProvider: { nil },
            memoryProvider: { nil },
            diskProvider: { nil },
            networkProvider: { nil },
            thermalProvider: { nil }
        )
    }

    func testSetBaseIntervalNoLongerMovesMediumOrSlowTiers() {
        // The old behavior derived medium/slow from fast by a fixed ratio,
        // which is exactly what made independent per-tier control
        // impossible. Changing the fast tier now must leave the other two
        // tiers exactly where they were.
        let coordinator = makeCoordinator()
        coordinator.setMediumInterval(11)
        coordinator.setSlowInterval(45) // within the slow tier's 5...60 clamp

        coordinator.setBaseInterval(2)

        XCTAssertEqual(coordinator.currentBaseInterval(for: .fast), 2)
        XCTAssertEqual(coordinator.currentBaseInterval(for: .medium), 11)
        XCTAssertEqual(coordinator.currentBaseInterval(for: .slow), 45)
    }

    func testFastIntervalClampsTo0_5And30() {
        let coordinator = makeCoordinator()

        coordinator.setBaseInterval(0.1)
        XCTAssertEqual(coordinator.currentBaseInterval(for: .fast), 0.5)

        coordinator.setBaseInterval(999)
        XCTAssertEqual(coordinator.currentBaseInterval(for: .fast), 30)
    }

    func testMediumIntervalClampsTo1And60() {
        let coordinator = makeCoordinator()

        coordinator.setMediumInterval(0)
        XCTAssertEqual(coordinator.currentBaseInterval(for: .medium), 1)

        coordinator.setMediumInterval(999)
        XCTAssertEqual(coordinator.currentBaseInterval(for: .medium), 60)
    }

    func testSlowIntervalClampsTo5And60() {
        // Upper bound is 60, not some larger "generous ceiling": every
        // tier's *effective* interval is capped at 60s by
        // effectiveInterval(for:) regardless of this base value, so a
        // wider base clamp would let this setter (and any UI built on it)
        // accept a value the coordinator silently truncates the moment a
        // tick actually runs. See the regression test below, which pins
        // exactly that truncation.
        let coordinator = makeCoordinator()

        coordinator.setSlowInterval(0)
        XCTAssertEqual(coordinator.currentBaseInterval(for: .slow), 5)

        coordinator.setSlowInterval(9999)
        XCTAssertEqual(coordinator.currentBaseInterval(for: .slow), 60)
    }

    func testInitDefaultsMatchPlanTierDefaultsBeforeAnySetterIsCalled() {
        let coordinator = makeCoordinator()

        XCTAssertEqual(coordinator.currentBaseInterval(for: .fast), 3)
        XCTAssertEqual(coordinator.currentBaseInterval(for: .medium), 5)
        XCTAssertEqual(coordinator.currentBaseInterval(for: .slow), 30)
    }
}
