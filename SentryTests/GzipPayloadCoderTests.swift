import XCTest
@testable import Sentry
import SentryKit

/// Round-trip coverage for `GzipPayloadCoder` (`SentryKit/Sync/GzipPayloadCoder.swift`),
/// which compresses `SnapshotRecord.payload` (plan §7.3). Pure in-memory
/// transform — no CloudKit or network involvement, safe to test without any
/// iCloud container entitlement.
final class GzipPayloadCoderTests: XCTestCase {

    // MARK: - Fixtures

    /// A `SystemSnapshot` with every optional sub-struct populated and
    /// several array fields non-trivially sized, so the JSON encoding is a
    /// realistic multi-KB payload rather than a couple hundred bytes — the
    /// point is to confirm compression actually shrinks something, not
    /// just that encode/decode is a no-op round trip.
    private func fullSnapshot() -> SystemSnapshot {
        SystemSnapshot(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            deviceID: "test-device-full",
            schemaVersion: 1,
            battery: BatteryStats(
                chargePercent: 87.5,
                isCharging: true,
                isPluggedIn: true,
                chargingWatts: 32.4,
                systemPowerInWatts: 18.2,
                adapterRatedWatts: 96,
                adapterDescription: "96W USB-C Power Adapter",
                adapterCount: 1,
                voltageMV: 12800,
                amperageMA: 1500,
                cycleCount: 341,
                designCapacityMAh: 5900,
                fullChargeCapacityMAh: 5450,
                healthPercent: 92.4,
                temperatureCelsius: 29.8,
                cellVoltagesMV: [4200, 4198, 4201, 4199],
                timeToFullMinutes: 42,
                timeToEmptyMinutes: nil,
                notChargingReason: nil,
                notChargingReasonText: nil,
                isThermallyLimited: false
            ),
            cpu: CPUStats(
                totalPercent: 34.7,
                perCorePercent: Array(repeating: 0, count: 12).enumerated().map { Double($0.offset) * 3.1 },
                ecorePercent: 12.0,
                pcorePercent: 55.4,
                effectiveFrequencyMHz: 3504,
                packagePowerWatts: 8.9,
                loadAverage1m: 2.14,
                processCount: 412
            ),
            gpu: GPUStats(
                utilizationPercent: 22.1,
                rendererPercent: 18.4,
                tilerPercent: 3.7,
                vramUsedBytes: 511_705_088,
                vramAllocatedBytes: 1_073_741_824,
                frequencyMHz: 1296,
                powerWatts: 4.2
            ),
            ane: ANEStats(powerWatts: 0.8, isActive: true),
            memory: MemoryStats(
                usedBytes: 12_884_901_888,
                appMemoryBytes: 8_589_934_592,
                wiredBytes: 2_147_483_648,
                compressedBytes: 1_073_741_824,
                cachedBytes: 4_294_967_296,
                totalBytes: 38_654_705_664,
                swapUsedBytes: 0,
                swapTotalBytes: 1_073_741_824,
                pressureLevel: .normal
            ),
            disk: DiskStats(
                freeBytes: 85_899_345_920,
                totalBytes: 994_662_584_320,
                readBytesPerSec: 1_048_576,
                writeBytesPerSec: 524_288,
                readIOPS: 120,
                writeIOPS: 60
            ),
            network: NetworkStats(
                rxBytesPerSec: 204_800,
                txBytesPerSec: 51_200,
                rxSessionTotalBytes: 5_368_709_120,
                txSessionTotalBytes: 1_073_741_824,
                activeInterface: "en0",
                isWiFi: true,
                localIPAddress: "192.168.1.42",
                wifiSSID: "TestNetwork-5G",
                wifiRSSIdBm: -52,
                wifiNoisedBm: -90,
                wifiTxRateMbps: 866.7
            ),
            thermal: ThermalStats(
                socTemperatureCelsius: 61.3,
                fanRPMs: [1800, 1795],
                pressureLevel: .fair,
                isThrottling: false
            ),
            sleepAssertion: .active(mode: .systemOnly, expiresAt: Date(timeIntervalSince1970: 1_700_003_600), reason: "iPhone keep-awake command")
        )
    }

    // MARK: - encode/decode round trip

    func testFullSnapshotRoundTripsExactly() throws {
        let original = fullSnapshot()
        let payload = try GzipPayloadCoder.encode(original)
        let decoded = try GzipPayloadCoder.decode(payload)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.timestamp, original.timestamp)
        XCTAssertEqual(decoded.deviceID, original.deviceID)
        XCTAssertEqual(decoded.schemaVersion, original.schemaVersion)

        // `Data` equality on two independent `JSONEncoder().encode(...)` calls
        // isn't guaranteed byte-for-byte (Foundation's dictionary/JSON key
        // ordering isn't contractually stable across encodes), so compare
        // with `.sortedKeys` to get a deterministic ordering instead of
        // asserting encoder-internal determinism we don't actually depend on.
        let sortedEncoder = JSONEncoder()
        sortedEncoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try sortedEncoder.encode(decoded), try sortedEncoder.encode(original))
    }

    func testCompressionActuallyShrinksRealisticPayload() throws {
        let original = fullSnapshot()
        let json = try JSONEncoder().encode(original)
        let compressed = try GzipPayloadCoder.compress(json)

        // A multi-hundred-byte JSON document with repeated key names and
        // structured numeric data should compress meaningfully, not just
        // round-trip. This is the "not just gzip(x) == x" check the task
        // calls for.
        XCTAssertGreaterThan(json.count, 800, "fixture should be a realistic multi-hundred-byte+ payload")
        XCTAssertLessThan(compressed.count, json.count, "compressed payload should be smaller than raw JSON")
    }

    func testMinimalSnapshotRoundTrips() throws {
        let minimal = SystemSnapshot(deviceID: "minimal-device")
        let payload = try GzipPayloadCoder.encode(minimal)
        let decoded = try GzipPayloadCoder.decode(payload)
        XCTAssertEqual(decoded.deviceID, minimal.deviceID)
        XCTAssertNil(decoded.battery)
        XCTAssertNil(decoded.cpu)
    }

    // MARK: - Raw compress/decompress edge cases

    func testEmptyDataRoundTrips() throws {
        let compressed = try GzipPayloadCoder.compress(Data())
        XCTAssertEqual(compressed, Data())
        let decompressed = try GzipPayloadCoder.decompress(compressed)
        XCTAssertEqual(decompressed, Data())
    }

    func testSmallIncompressibleDataRoundTrips() throws {
        // Single random byte — too small for zlib to shrink, exercises the
        // "compressed size can legitimately exceed input" path.
        let data = Data([0x42])
        let compressed = try GzipPayloadCoder.compress(data)
        let decompressed = try GzipPayloadCoder.decompress(compressed)
        XCTAssertEqual(decompressed, data)
    }

    func testLargePayloadRoundTrips() throws {
        // ~2 MB of semi-repetitive data (unusually large Snapshot payload
        // per the task's edge-case ask) — also exercises the decompress
        // buffer-growth loop, since output will exceed the initial guess.
        var bytes = [UInt8]()
        bytes.reserveCapacity(2_000_000)
        for i in 0..<2_000_000 {
            bytes.append(UInt8((i * 37 + i / 101) % 256))
        }
        let large = Data(bytes)

        let compressed = try GzipPayloadCoder.compress(large)
        let decompressed = try GzipPayloadCoder.decompress(compressed)
        XCTAssertEqual(decompressed, large)
    }

    func testHighlyRepetitiveLargeDataCompressesSubstantially() throws {
        let repetitive = Data(repeating: 0xAB, count: 500_000)
        let compressed = try GzipPayloadCoder.compress(repetitive)
        XCTAssertLessThan(compressed.count, repetitive.count / 10)
        let decompressed = try GzipPayloadCoder.decompress(compressed)
        XCTAssertEqual(decompressed, repetitive)
    }

    func testDecompressingGarbageThrows() {
        let garbage = Data([0xFF, 0x00, 0x13, 0x37, 0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertThrowsError(try GzipPayloadCoder.decompress(garbage))
    }
}
