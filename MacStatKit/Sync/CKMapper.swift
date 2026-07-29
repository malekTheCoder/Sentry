import CloudKit
import Foundation

/// Bidirectional conversion between the plain-data record models in
/// `SyncRecords.swift` and `CKRecord`. See that file's top-level doc
/// comment for why this can be built and tested today with no enrolled
/// Apple Developer account and no real CloudKit container — everything
/// here constructs/reads `CKRecord` values in-process and never touches
/// `CKContainer`/`CKDatabase`.
///
/// **Naming convention:** for each model type `X`, `CKMapper` exposes a
/// pair:
/// - `static func record(from x: X, zoneID: CKRecordZone.ID) -> CKRecord`
/// - `static func x(from record: CKRecord) throws -> X` (lowerCamelCase of
///   the type name — e.g. `device(from:)`, `snapshotRecord(from:)`,
///   `dailyHealth(from:)`, `controlCommand(from:)`, `controlStatus(from:)`)
///
/// The `throws` direction can fail (`MapperError`) because a `CKRecord`
/// pulled from a real container is untyped key-value storage — nothing
/// stops a record from being missing a key or holding the wrong Swift type
/// at runtime, so decoding validates shape defensively even though every
/// record this codebase itself constructs is well-formed.
///
/// **recordName convention:** `Device.deviceID` is used verbatim as
/// `CKRecord.ID.recordName` (plan §7.3: "recordName; stable UUID persisted
/// in app support dir") — this makes a `Device` record's identity globally
/// stable and lets every other record type reference a Mac by building a
/// `CKRecord.ID` from `deviceID` directly, with no lookup required. The
/// other four record types have no natural stable identity of their own
/// (multiple `Snapshot`s, `ControlCommand`s, etc. exist per device), so
/// their `recordName` is a fresh random UUID generated at `record(from:)`
/// time — CloudKit only needs *a* unique name, and nothing in these models
/// needs to recover that name later (the owning device is always resolved
/// via the `deviceRef` reference, not the record's own name).
public enum CKMapper {

    // MARK: - Record type names

    public enum RecordType {
        public static let device = "Device"
        public static let snapshot = "Snapshot"
        public static let dailyHealth = "DailyHealth"
        public static let controlCommand = "ControlCommand"
        public static let controlStatus = "ControlStatus"
    }

    public enum MapperError: Error, Equatable {
        case missingField(String)
        case wrongType(String)
    }

    // MARK: - Device

    public static func recordID(forDeviceID deviceID: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: deviceID, zoneID: zoneID)
    }

    public static func record(from device: Device, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: RecordType.device,
            recordID: recordID(forDeviceID: device.deviceID, zoneID: zoneID)
        )
        record["deviceName"] = device.deviceName as CKRecordValue
        record["model"] = device.model as CKRecordValue
        record["chip"] = device.chip as CKRecordValue
        record["osVersion"] = device.osVersion as CKRecordValue
        record["appVersion"] = device.appVersion as CKRecordValue
        record["lastSeen"] = device.lastSeen as CKRecordValue
        record["capabilitiesJSON"] = device.capabilitiesJSON as CKRecordValue
        return record
    }

    public static func device(from record: CKRecord) throws -> Device {
        try Device(
            deviceID: record.recordID.recordName,
            deviceName: field(record, "deviceName"),
            model: field(record, "model"),
            chip: field(record, "chip"),
            osVersion: field(record, "osVersion"),
            appVersion: field(record, "appVersion"),
            lastSeen: field(record, "lastSeen"),
            capabilitiesJSON: field(record, "capabilitiesJSON")
        )
    }

    // MARK: - SnapshotRecord

    public static func record(from snapshot: SnapshotRecord, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: RecordType.snapshot,
            recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        )
        record["deviceRef"] = deviceReference(deviceID: snapshot.deviceID, zoneID: zoneID, action: .deleteSelf)
        record["timestamp"] = snapshot.timestamp as CKRecordValue
        record["schemaVersion"] = Int64(snapshot.schemaVersion) as CKRecordValue
        record["payload"] = snapshot.payload as CKRecordValue
        record["batteryPercent"] = snapshot.batteryPercent as CKRecordValue
        record["batteryHealth"] = snapshot.batteryHealth as CKRecordValue
        record["chargingWatts"] = snapshot.chargingWatts as CKRecordValue
        record["cpuPercent"] = snapshot.cpuPercent as CKRecordValue
        record["memoryPercent"] = snapshot.memoryPercent as CKRecordValue
        record["isAwakeAsserted"] = (snapshot.isAwakeAsserted ? Int64(1) : Int64(0)) as CKRecordValue
        return record
    }

    public static func snapshotRecord(from record: CKRecord) throws -> SnapshotRecord {
        let deviceID = try referencedDeviceID(record, "deviceRef")
        let schemaVersion: Int64 = try field(record, "schemaVersion")
        let isAwakeAsserted: Int64 = try field(record, "isAwakeAsserted")
        return try SnapshotRecord(
            deviceID: deviceID,
            timestamp: field(record, "timestamp"),
            schemaVersion: Int(schemaVersion),
            payload: field(record, "payload"),
            batteryPercent: field(record, "batteryPercent"),
            batteryHealth: field(record, "batteryHealth"),
            chargingWatts: field(record, "chargingWatts"),
            cpuPercent: field(record, "cpuPercent"),
            memoryPercent: field(record, "memoryPercent"),
            isAwakeAsserted: isAwakeAsserted != 0
        )
    }

    // MARK: - DailyHealth

    public static func record(from health: DailyHealth, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: RecordType.dailyHealth,
            recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        )
        record["deviceRef"] = deviceReference(deviceID: health.deviceID, zoneID: zoneID, action: .none)
        record["day"] = health.day as CKRecordValue
        record["healthPercent"] = health.healthPercent as CKRecordValue
        record["cycleCount"] = Int64(health.cycleCount) as CKRecordValue
        record["fullChargeCapacity"] = Int64(health.fullChargeCapacity) as CKRecordValue
        record["minCharge"] = health.minCharge as CKRecordValue
        record["maxCharge"] = health.maxCharge as CKRecordValue
        record["timeOnACSeconds"] = Int64(health.timeOnACSeconds) as CKRecordValue
        return record
    }

    public static func dailyHealth(from record: CKRecord) throws -> DailyHealth {
        let deviceID = try referencedDeviceID(record, "deviceRef")
        let cycleCount: Int64 = try field(record, "cycleCount")
        let fullChargeCapacity: Int64 = try field(record, "fullChargeCapacity")
        let timeOnACSeconds: Int64 = try field(record, "timeOnACSeconds")
        return try DailyHealth(
            deviceID: deviceID,
            day: field(record, "day"),
            healthPercent: field(record, "healthPercent"),
            cycleCount: Int(cycleCount),
            fullChargeCapacity: Int(fullChargeCapacity),
            minCharge: field(record, "minCharge"),
            maxCharge: field(record, "maxCharge"),
            timeOnACSeconds: Int(timeOnACSeconds)
        )
    }

    // MARK: - ControlCommand

    public static func record(from command: ControlCommand, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: RecordType.controlCommand,
            recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        )
        record["deviceRef"] = deviceReference(deviceID: command.deviceID, zoneID: zoneID, action: .none)
        record["issuedAt"] = command.issuedAt as CKRecordValue
        record["commandType"] = command.commandType as CKRecordValue
        record["parametersJSON"] = command.parametersJSON as CKRecordValue
        record["nonce"] = command.nonce as CKRecordValue
        record["expiresAt"] = command.expiresAt as CKRecordValue
        return record
    }

    public static func controlCommand(from record: CKRecord) throws -> ControlCommand {
        let deviceID = try referencedDeviceID(record, "deviceRef")
        return try ControlCommand(
            deviceID: deviceID,
            issuedAt: field(record, "issuedAt"),
            commandType: field(record, "commandType"),
            parametersJSON: field(record, "parametersJSON"),
            nonce: field(record, "nonce"),
            expiresAt: field(record, "expiresAt")
        )
    }

    // MARK: - ControlStatus

    public static func record(from status: ControlStatus, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: RecordType.controlStatus,
            recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        )
        record["deviceRef"] = deviceReference(deviceID: status.deviceID, zoneID: zoneID, action: .none)
        record["respondsToNonce"] = status.respondsToNonce as CKRecordValue
        record["state"] = status.state as CKRecordValue
        record["message"] = status.message as CKRecordValue
        record["assertionActive"] = (status.assertionActive ? Int64(1) : Int64(0)) as CKRecordValue
        if let expiresAt = status.assertionExpiresAt {
            record["assertionExpiresAt"] = expiresAt as CKRecordValue
        }
        record["updatedAt"] = status.updatedAt as CKRecordValue
        return record
    }

    public static func controlStatus(from record: CKRecord) throws -> ControlStatus {
        let deviceID = try referencedDeviceID(record, "deviceRef")
        let assertionActive: Int64 = try field(record, "assertionActive")
        return try ControlStatus(
            deviceID: deviceID,
            respondsToNonce: field(record, "respondsToNonce"),
            state: field(record, "state"),
            message: field(record, "message"),
            assertionActive: assertionActive != 0,
            assertionExpiresAt: record["assertionExpiresAt"] as? Date,
            updatedAt: field(record, "updatedAt")
        )
    }

    // MARK: - Shared helpers

    private static func deviceReference(
        deviceID: String,
        zoneID: CKRecordZone.ID,
        action: CKRecord.ReferenceAction
    ) -> CKRecord.Reference {
        CKRecord.Reference(recordID: recordID(forDeviceID: deviceID, zoneID: zoneID), action: action)
    }

    private static func referencedDeviceID(_ record: CKRecord, _ key: String) throws -> String {
        guard let reference = record[key] as? CKRecord.Reference else {
            throw MapperError.missingField(key)
        }
        return reference.recordID.recordName
    }

    private static func field<T>(_ record: CKRecord, _ key: String) throws -> T {
        guard let value = record[key] else {
            throw MapperError.missingField(key)
        }
        guard let typed = value as? T else {
            throw MapperError.wrongType(key)
        }
        return typed
    }
}
