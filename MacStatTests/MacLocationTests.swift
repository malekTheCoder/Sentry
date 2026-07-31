import XCTest
@testable import MacStatKit

/// Coverage for the "Location Log" feature's pure, testable logic — the
/// `MacLocation` wire model, `SystemSnapshot.location`'s round trip through
/// `LocalSyncFraming` (the same transport `LocalSyncFramingTests` already
/// covers for every other field), `StatsCoordinator.location`'s push-through
/// property (mirroring `sleepAssertionState`, which has no dedicated test of
/// its own but is exercised identically here), and `AppSettings
/// .locationLogEnabled`'s forward-compatible decode.
///
/// Deliberately excludes anything that touches real `CLLocationManager` —
/// `LocationService` itself is macOS-only glue code around a system
/// framework's delegate callbacks, the same "networking/IOKit-adjacent,
/// not unit-tested directly" category as `LocalSyncServer`/`LocalSyncClient`
/// (see `LocalSyncFramingTests`'s own doc comment on why the framing layer,
/// not the `NWConnection` wrapper, is what's covered here).
final class MacLocationTests: XCTestCase {

    // MARK: - MacLocation Codable round trip

    func testMacLocationRoundTripsThroughJSON() throws {
        let original = MacLocation(
            latitude: 37.3349,
            longitude: -122.0090,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            horizontalAccuracyMeters: 65.0
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MacLocation.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testMacLocationWithNilAccuracyRoundTrips() throws {
        let original = MacLocation(
            latitude: 0,
            longitude: 0,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MacLocation.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.horizontalAccuracyMeters)
    }

    // MARK: - SystemSnapshot.location through LocalSyncFraming

    func testSnapshotWithLocationRoundTripsThroughLocalSyncFraming() throws {
        let location = MacLocation(
            latitude: 51.5074,
            longitude: -0.1278,
            timestamp: Date(timeIntervalSince1970: 1_700_000_500),
            horizontalAccuracyMeters: 120
        )
        let snapshot = SystemSnapshot(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            deviceID: "test-device",
            location: location
        )

        let framed = try LocalSyncFraming.encode(snapshot)
        let decoded = try LocalSyncFraming.decode(framed)

        XCTAssertEqual(decoded.location, location)
    }

    func testSnapshotWithoutLocationRoundTripsAsNil() throws {
        let snapshot = SystemSnapshot(deviceID: "test-device")

        let framed = try LocalSyncFraming.encode(snapshot)
        let decoded = try LocalSyncFraming.decode(framed)

        XCTAssertNil(decoded.location)
    }

    // MARK: - StatsCoordinator.location push-through

    @MainActor
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

    @MainActor
    func testCoordinatorLocationDefaultsToNil() {
        let coordinator = makeCoordinator()
        XCTAssertNil(coordinator.location)
    }

    @MainActor
    func testCoordinatorLocationReadsBackWhatWasSet() {
        let coordinator = makeCoordinator()
        let location = MacLocation(latitude: 1, longitude: 2, timestamp: Date(timeIntervalSince1970: 1_700_000_000))

        coordinator.location = location

        // `location`'s setter hops onto the coordinator's private serial
        // queue asynchronously (same shape as `sleepAssertionState`'s own
        // setter) — the getter's `queue.sync` waits for that hop to finish,
        // so this read is deterministic without needing an expectation.
        XCTAssertEqual(coordinator.location, location)
    }

    @MainActor
    func testCoordinatorLocationCanBeClearedBackToNil() {
        let coordinator = makeCoordinator()
        coordinator.location = MacLocation(latitude: 1, longitude: 2, timestamp: Date())

        coordinator.location = nil

        XCTAssertNil(coordinator.location)
    }

    // MARK: - AppSettings.locationLogEnabled forward-compatible decode

    func testSettingsFileWithoutLocationLogKeyDecodesToDisabled() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"themeID":"terminal"}"#.utf8))
        XCTAssertFalse(settings.locationLogEnabled)
    }

    func testSettingsFileWithExplicitLocationLogValueRoundTrips() throws {
        let settings = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"themeID":"terminal","locationLogEnabled":true}"#.utf8)
        )
        XCTAssertTrue(settings.locationLogEnabled)
    }

    func testDefaultAppSettingsHasLocationLogDisabled() {
        // Off by default is a hard requirement — this is a permission-gated
        // feature that must never silently opt a user in.
        XCTAssertFalse(AppSettings().locationLogEnabled)
    }
}
