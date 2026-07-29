import CloudKit
import XCTest
@testable import MacStat
import MacStatKit

/// Round-trip coverage for `CKMapper` (`MacStatKit/Sync/CKMapper.swift`) —
/// model → `CKRecord` → model for all five plan §7.3 record types, plus the
/// `Snapshot`/`DailyHealth`/`ControlCommand`/`ControlStatus` → `Device`
/// reference wiring. Every `CKRecord` here is constructed in-process; none
/// is ever saved to or fetched from a real container (no enrolled Apple
/// Developer account exists for this project yet — see
/// `MacStatKit/Sync/SyncRecords.swift`'s top-level doc comment).
final class CKMapperTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: "MacStatZone", ownerName: CKCurrentUserDefaultName)

    // MARK: - Device

    func testDeviceRoundTrips() throws {
        let device = Device(
            deviceID: "11111111-1111-1111-1111-111111111111",
            deviceName: "Malek's MacBook Pro",
            model: "MacBookPro18,2",
            chip: "Apple M4 Pro",
            osVersion: "15.1",
            appVersion: "0.1.0",
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000),
            capabilitiesJSON: #"{"battery":true}"#
        )

        let record = CKMapper.record(from: device, zoneID: zoneID)
        XCTAssertEqual(record.recordType, CKMapper.RecordType.device)
        XCTAssertEqual(record.recordID.recordName, device.deviceID)

        let decoded = try CKMapper.device(from: record)
        XCTAssertEqual(decoded, device)
    }

    func testDeviceWithLastViewedAtRoundTrips() throws {
        let device = Device(
            deviceID: "22222222-2222-2222-2222-222222222222",
            deviceName: "n", model: "m", chip: "c", osVersion: "o", appVersion: "a",
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000),
            capabilitiesJSON: "{}",
            lastViewedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        let record = CKMapper.record(from: device, zoneID: zoneID)
        let decoded = try CKMapper.device(from: record)
        XCTAssertEqual(decoded, device)
        XCTAssertEqual(decoded.lastViewedAt, device.lastViewedAt)
    }

    func testDeviceWithNilLastViewedAtOmitsTheKeyEntirely() throws {
        // Confirms the "no iPhone has ever opened the app yet" case reads
        // back as nil, not as some sentinel/zero date — and that the
        // CKRecord genuinely has no key for it (optionalField's nil path,
        // not a present-but-empty value).
        let device = Device(
            deviceID: "33333333-3333-3333-3333-333333333333",
            deviceName: "n", model: "m", chip: "c", osVersion: "o", appVersion: "a",
            lastSeen: Date(), capabilitiesJSON: "{}"
        )
        let record = CKMapper.record(from: device, zoneID: zoneID)
        XCTAssertNil(record["lastViewedAt"])

        let decoded = try CKMapper.device(from: record)
        XCTAssertNil(decoded.lastViewedAt)
    }

    func testDeviceRecordNameIsDeviceID() {
        let device = Device(
            deviceID: "stable-uuid-123",
            deviceName: "n", model: "m", chip: "c", osVersion: "o", appVersion: "a",
            lastSeen: Date(), capabilitiesJSON: "{}"
        )
        let record = CKMapper.record(from: device, zoneID: zoneID)
        XCTAssertEqual(record.recordID.recordName, "stable-uuid-123")
    }

    // MARK: - SnapshotRecord

    func testSnapshotRecordRoundTrips() throws {
        let snapshot = SnapshotRecord(
            deviceID: "device-abc",
            timestamp: Date(timeIntervalSince1970: 1_700_000_500),
            schemaVersion: 1,
            payload: Data([0x1f, 0x8b, 0x00, 0x01, 0x02]),
            batteryPercent: 87.5,
            batteryHealth: 91.0,
            chargingWatts: 32.4,
            cpuPercent: 12.3,
            memoryPercent: 55.6,
            isAwakeAsserted: true
        )

        let record = CKMapper.record(from: snapshot, zoneID: zoneID)
        XCTAssertEqual(record.recordType, CKMapper.RecordType.snapshot)

        let reference = try XCTUnwrap(record["deviceRef"] as? CKRecord.Reference)
        XCTAssertEqual(reference.recordID.recordName, "device-abc")
        XCTAssertEqual(reference.action, .deleteSelf)

        let decoded = try CKMapper.snapshotRecord(from: record)
        XCTAssertEqual(decoded, snapshot)
    }

    func testSnapshotRecordIsAwakeAssertedFalseRoundTrips() throws {
        let snapshot = SnapshotRecord(
            deviceID: "device-abc", timestamp: Date(), schemaVersion: 1, payload: Data(),
            batteryPercent: 0, batteryHealth: 0, chargingWatts: 0, cpuPercent: 0,
            memoryPercent: 0, isAwakeAsserted: false
        )
        let record = CKMapper.record(from: snapshot, zoneID: zoneID)
        let decoded = try CKMapper.snapshotRecord(from: record)
        XCTAssertFalse(decoded.isAwakeAsserted)
    }

    func testSnapshotRecordsGetDistinctRecordNames() {
        let snapshot = SnapshotRecord(
            deviceID: "device-abc", timestamp: Date(), schemaVersion: 1, payload: Data(),
            batteryPercent: 0, batteryHealth: 0, chargingWatts: 0, cpuPercent: 0,
            memoryPercent: 0, isAwakeAsserted: false
        )
        let recordA = CKMapper.record(from: snapshot, zoneID: zoneID)
        let recordB = CKMapper.record(from: snapshot, zoneID: zoneID)
        XCTAssertNotEqual(recordA.recordID.recordName, recordB.recordID.recordName)
    }

    // MARK: - DailyHealth

    func testDailyHealthRoundTrips() throws {
        let health = DailyHealth(
            deviceID: "device-xyz",
            day: Date(timeIntervalSince1970: 1_700_000_000),
            healthPercent: 92.4,
            cycleCount: 341,
            fullChargeCapacity: 4500,
            minCharge: 22.0,
            maxCharge: 100.0,
            timeOnACSeconds: 45_000
        )

        let record = CKMapper.record(from: health, zoneID: zoneID)
        XCTAssertEqual(record.recordType, CKMapper.RecordType.dailyHealth)
        let reference = try XCTUnwrap(record["deviceRef"] as? CKRecord.Reference)
        XCTAssertEqual(reference.recordID.recordName, "device-xyz")

        let decoded = try CKMapper.dailyHealth(from: record)
        XCTAssertEqual(decoded, health)
    }

    // MARK: - ControlCommand

    func testControlCommandRoundTrips() throws {
        let command = ControlCommand(
            deviceID: "device-target",
            issuedAt: Date(timeIntervalSince1970: 1_700_001_000),
            commandType: "keepAwake",
            parametersJSON: #"{"durationSeconds":3600,"mode":"system"}"#,
            nonce: "nonce-001",
            expiresAt: Date(timeIntervalSince1970: 1_700_001_300)
        )

        let record = CKMapper.record(from: command, zoneID: zoneID)
        XCTAssertEqual(record.recordType, CKMapper.RecordType.controlCommand)

        let decoded = try CKMapper.controlCommand(from: record)
        XCTAssertEqual(decoded, command)
    }

    // MARK: - ControlStatus

    func testControlStatusRoundTrips() throws {
        let status = ControlStatus(
            deviceID: "device-target",
            respondsToNonce: "nonce-001",
            state: "accepted",
            message: "Keep-awake assertion active",
            assertionActive: true,
            assertionExpiresAt: Date(timeIntervalSince1970: 1_700_004_600),
            updatedAt: Date(timeIntervalSince1970: 1_700_001_050)
        )

        let record = CKMapper.record(from: status, zoneID: zoneID)
        XCTAssertEqual(record.recordType, CKMapper.RecordType.controlStatus)

        let decoded = try CKMapper.controlStatus(from: record)
        XCTAssertEqual(decoded, status)
    }

    func testControlStatusNilAssertionExpiresAtRoundTrips() throws {
        let status = ControlStatus(
            deviceID: "device-target",
            respondsToNonce: "nonce-002",
            state: "rejected",
            message: "Already awake via another assertion",
            assertionActive: false,
            assertionExpiresAt: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_001_100)
        )

        let record = CKMapper.record(from: status, zoneID: zoneID)
        XCTAssertNil(record["assertionExpiresAt"])

        let decoded = try CKMapper.controlStatus(from: record)
        XCTAssertEqual(decoded, status)
        XCTAssertNil(decoded.assertionExpiresAt)
    }

    // MARK: - Error paths

    func testDecodingMissingFieldThrows() {
        let record = CKRecord(recordType: CKMapper.RecordType.device, recordID: CKMapper.recordID(forDeviceID: "d", zoneID: zoneID))
        // Deliberately leave every field unset.
        XCTAssertThrowsError(try CKMapper.device(from: record)) { error in
            guard case CKMapper.MapperError.missingField = error else {
                return XCTFail("expected missingField, got \(error)")
            }
        }
    }

    func testDecodingWrongTypeThrows() {
        let record = CKRecord(recordType: CKMapper.RecordType.device, recordID: CKMapper.recordID(forDeviceID: "d", zoneID: zoneID))
        record["deviceName"] = 42 as CKRecordValue // should be a String
        record["model"] = "m" as CKRecordValue
        record["chip"] = "c" as CKRecordValue
        record["osVersion"] = "o" as CKRecordValue
        record["appVersion"] = "a" as CKRecordValue
        record["lastSeen"] = Date() as CKRecordValue
        record["capabilitiesJSON"] = "{}" as CKRecordValue

        XCTAssertThrowsError(try CKMapper.device(from: record)) { error in
            guard case CKMapper.MapperError.wrongType = error else {
                return XCTFail("expected wrongType, got \(error)")
            }
        }
    }

    func testDecodingSnapshotWithoutDeviceRefThrows() {
        let record = CKRecord(recordType: CKMapper.RecordType.snapshot, recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
        XCTAssertThrowsError(try CKMapper.snapshotRecord(from: record))
    }
}
