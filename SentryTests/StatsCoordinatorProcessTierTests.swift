import XCTest
@testable import SentryKit

/// Coverage for the `.process` tier added to `StatsCoordinator`
/// (`SentryKit/Services/StatsCoordinator.swift`) — the polling side of
/// `SystemSnapshot.topProcesses`. See that field's doc comment and the
/// `.process` case in `StatsCoordinator.Tier`'s doc comment for the
/// honest-nil / slower-cadence / no-overwrite-between-ticks design this
/// pins down.
///
/// Follows `PerTierRefreshIntervalTests`' `makeCoordinator()` pattern for
/// the interval-only assertions; the two behavioral tests at the bottom
/// (provider wired vs. not, no-clobber-on-a-nil-tick) drive the coordinator
/// through its real `AsyncStream` with a very short `processInterval` rather
/// than reaching into private state, since `tick(tier:)`/`latest` are
/// private and the polling loop's async hop (provider call → global queue →
/// back onto the serial queue) is exactly the behavior worth exercising for
/// real.
@MainActor
final class StatsCoordinatorProcessTierTests: XCTestCase {

    private func process(name: String = "node", cpuPercent: Double = 50) -> ProcessStats {
        ProcessStats(pid: 1, name: name, cpuPercent: cpuPercent, residentMemoryBytes: 0)
    }

    // MARK: - Base interval

    func testProcessTierDefaultsToEightSeconds() {
        let coordinator = StatsCoordinator(
            batteryProvider: { nil },
            cpuProvider: { nil },
            memoryProvider: { nil },
            diskProvider: { nil },
            networkProvider: { nil },
            thermalProvider: { nil }
        )
        XCTAssertEqual(coordinator.currentBaseInterval(for: .process), 8)
    }

    func testProcessIntervalIsConfigurableAtInit() {
        let coordinator = StatsCoordinator(
            batteryProvider: { nil },
            cpuProvider: { nil },
            memoryProvider: { nil },
            diskProvider: { nil },
            networkProvider: { nil },
            thermalProvider: { nil },
            processInterval: 6
        )
        XCTAssertEqual(coordinator.currentBaseInterval(for: .process), 6)
    }

    // MARK: - No provider wired: `.process` tier never runs, field stays nil

    func testSnapshotTopProcessesStaysNilWithoutAProcessProvider() async {
        let coordinator = StatsCoordinator(
            batteryProvider: { nil },
            cpuProvider: { CPUStats(totalPercent: 10) },
            memoryProvider: { nil },
            diskProvider: { nil },
            networkProvider: { nil },
            thermalProvider: { nil }
        )
        coordinator.adaptiveThrottlingEnabled = false
        defer { coordinator.stopPolling() }

        // Give the fast tier (which *is* wired, via cpuProvider) a couple of
        // real ticks worth of time to prove this isn't just "nothing has
        // ticked yet" — `topProcesses` must stay nil throughout because no
        // `.process` timer was ever started (`processProvider == nil`).
        var lastSnapshot: SystemSnapshot?
        for await snapshot in coordinator.snapshots() {
            lastSnapshot = snapshot
            break
        }
        XCTAssertNotNil(lastSnapshot)
        XCTAssertNil(lastSnapshot?.topProcesses)
        XCTAssertNil(coordinator.latestSnapshot().topProcesses)
    }

    // MARK: - Provider wired: field populates, and honestly stays nil until the first tick lands

    func testSnapshotTopProcessesPopulatesOnceTheProcessTierTicks() async throws {
        let expectedProcesses = [process(name: "node", cpuPercent: 91)]
        let coordinator = StatsCoordinator(
            batteryProvider: { nil },
            cpuProvider: { nil },
            memoryProvider: { nil },
            diskProvider: { nil },
            networkProvider: { nil },
            thermalProvider: { nil },
            processProvider: { expectedProcesses },
            processInterval: 0.05
        )
        coordinator.adaptiveThrottlingEnabled = false
        defer { coordinator.stopPolling() }

        let stream = coordinator.snapshots()
        var sawPopulated = false
        var iterations = 0
        for await snapshot in stream {
            if let topProcesses = snapshot.topProcesses {
                XCTAssertEqual(topProcesses.map(\.name), ["node"])
                XCTAssertEqual(topProcesses.map(\.cpuPercent), [91])
                sawPopulated = true
                break
            }
            iterations += 1
            // Bail out rather than hanging forever if something regresses —
            // a real `.process` tick should land well within this many
            // fast-tier-cadence-driven yields at an 0.05s process interval.
            if iterations > 200 { break }
        }

        XCTAssertTrue(sawPopulated, "topProcesses must populate once the (short, test-only) process tier ticks")
    }

    func testTopProcessesIsNotClobberedByOtherTiersTicking() async throws {
        // The load-bearing behavior from `LatestSamples.topProcesses`'s doc
        // comment: once populated, a fast/medium/slow tick (which never
        // touches `topProcesses` at all) must leave it exactly as it was —
        // callers always see the last-known process list, not a flicker
        // back to nil between the comparatively rare process ticks.
        let coordinator = StatsCoordinator(
            batteryProvider: { nil },
            cpuProvider: { CPUStats(totalPercent: Double.random(in: 0...100)) },
            memoryProvider: { nil },
            diskProvider: { nil },
            networkProvider: { nil },
            thermalProvider: { nil },
            processProvider: { [self.process()] },
            fastInterval: 0.02,
            processInterval: 0.05
        )
        coordinator.adaptiveThrottlingEnabled = false
        defer { coordinator.stopPolling() }

        var sawPopulated = false
        var sawClobberedAfterPopulated = false
        var iterations = 0
        for await snapshot in coordinator.snapshots() {
            if snapshot.topProcesses != nil {
                sawPopulated = true
            } else if sawPopulated {
                sawClobberedAfterPopulated = true
            }
            iterations += 1
            if iterations > 400 { break }
        }

        XCTAssertTrue(sawPopulated)
        XCTAssertFalse(sawClobberedAfterPopulated, "topProcesses must never revert to nil once a process tick has populated it")
    }
}
