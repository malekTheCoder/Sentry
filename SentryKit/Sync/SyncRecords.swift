import Foundation

// MARK: - CloudKit sync: not-yet-live, by design

/// Plain-data record models for CloudKit sync (plan §7 — "CloudKit Sync
/// Design"), plus `CKMapper` (see `CKMapper.swift`) for converting them
/// to/from `CKRecord`.
///
/// **Why this whole directory imports `CloudKit` but has never touched a
/// real container:** as of this writing there is no enrolled Apple
/// Developer Program account for this project. `project.yml` has
/// `CODE_SIGNING_REQUIRED: NO` and `DEVELOPMENT_TEAM: ""` — there is no
/// provisioning profile, no push entitlement, and no way to create the
/// `iCloud.dev.malekswilam.sentry` container plan §7.2 specifies. `CKRecord`,
/// `CKRecord.ID`, and `CKRecordZone.ID` are just Foundation-adjacent value
/// types, though — constructing, populating, and serializing them requires
/// no entitlement and performs no network I/O, so the model/mapper/encoding
/// layer can be built and fully unit-tested in-process today. What's
/// deliberately *not* here yet: `CKContainer`, `CKDatabase`,
/// `CKModifyRecordsOperation` actually executing, push subscriptions, or
/// anything else that would dial out. That's the `SyncService`/transport
/// layer (plan §7.1's `StatsTransport` protocol) — separate work, gated on
/// enrollment.
///
/// **What "done" looks like once enrollment happens:** add the CloudKit
/// capability + push entitlement in `project.yml`, point a `SyncService` at
/// `CKContainer(identifier: "iCloud.dev.malekswilam.sentry")`, and wire it
/// up to call `CKMapper`'s existing `record(from:zoneID:)` /
/// `xxx(from:)` functions before `.save()`/after `.fetch()`. Nothing in
/// *this* file needs to change — the model types and their CloudKit
/// projection are already correct and already tested against real
/// `CKRecord` instances (constructed locally, never saved). Only the
/// network-calling glue above this layer is new work.
///
/// Field names/types below follow plan §7.3's tables exactly so other
/// pieces of the sync stack (transport, nonce/heartbeat/pruning logic,
/// built by other agents in sibling files in this same directory) can
/// depend on this API surface without re-deriving it.

// MARK: - Device

/// One record per Mac, written once by the Mac and updated on change.
///
/// `lastViewedAt` is the one exception to "Mac writes this record": plan
/// §7.4 has the *iPhone* write it directly, on foreground, so the Mac can
/// read it back and enter fast-cadence mode for 10 minutes (see
/// `HeartbeatTracker.isFastCadence(lastViewedAt:now:)`, which takes this
/// field's value as a plain `Date?` rather than a whole `Device`, so it
/// stays testable without constructing one).
public struct Device: Codable, Sendable, Equatable {
    /// Stable UUID persisted in the app support dir. Used verbatim as the
    /// `CKRecord.ID.recordName` — see `CKMapper.recordID(forDeviceID:)`.
    public var deviceID: String
    public var deviceName: String
    public var model: String
    public var chip: String
    public var osVersion: String
    public var appVersion: String
    /// Heartbeat: last time the Mac wrote this record.
    public var lastSeen: Date
    /// JSON-encoded capability description so the phone knows which
    /// modules to render without a schema round-trip.
    public var capabilitiesJSON: String
    /// Last time the iPhone app was foregrounded, written by the iPhone —
    /// `nil` until the phone app exists and writes it at least once (plan
    /// §5's iPhone app is a later phase). `SyncService`/`HeartbeatTracker`
    /// must treat `nil` as "not recently active," never as "always fast
    /// cadence" — an absent value is the honest default for "we don't know."
    public var lastViewedAt: Date?

    public init(
        deviceID: String,
        deviceName: String,
        model: String,
        chip: String,
        osVersion: String,
        appVersion: String,
        lastSeen: Date,
        capabilitiesJSON: String,
        lastViewedAt: Date? = nil
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.model = model
        self.chip = chip
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.lastSeen = lastSeen
        self.capabilitiesJSON = capabilitiesJSON
        self.lastViewedAt = lastViewedAt
    }
}

// MARK: - SnapshotRecord

/// The CloudKit projection of a `SystemSnapshot` (plan §7.3's `Snapshot`
/// record type).
///
/// Deliberately named `SnapshotRecord`, not `Snapshot` — `SystemSnapshot`
/// (`SentryKit/Models/SystemSnapshot.swift`) is the canonical in-process
/// payload that flows through the UI, `HistoryStore`, and MCP. This type is
/// a *different, CloudKit-specific shape*: `SystemSnapshot` gzip-encoded
/// into `payload`, plus a handful of scalar fields duplicated at the top
/// level purely so cheap CloudKit queries (widget/dashboard first paint)
/// don't have to gunzip+decode the full payload just to show battery% and
/// CPU%. Naming it `SnapshotRecord` makes that distinction impossible to
/// miss at the call site (`SnapshotRecord` vs `SystemSnapshot`), whereas a
/// bare `Snapshot` would silently collide/confuse with the existing type.
public struct SnapshotRecord: Codable, Sendable, Equatable {
    /// Owning device. Reference → `Device`, `.deleteSelf` action per plan
    /// §7.3 — deleting the `Device` record cascades and deletes this.
    public var deviceID: String
    /// Queryable + sortable index in the real container (plan §7.3).
    public var timestamp: Date
    public var schemaVersion: Int
    /// Gzipped JSON of `SystemSnapshot` — see `GzipPayloadCoder`.
    public var payload: Data
    // Scalars duplicated from `payload` for cheap top-level queries: the
    // widget/dashboard first paint reads these directly and only decodes
    // `payload` when the user opens a detail view.
    public var batteryPercent: Double
    public var batteryHealth: Double
    public var chargingWatts: Double
    public var cpuPercent: Double
    public var memoryPercent: Double
    public var isAwakeAsserted: Bool

    public init(
        deviceID: String,
        timestamp: Date,
        schemaVersion: Int,
        payload: Data,
        batteryPercent: Double,
        batteryHealth: Double,
        chargingWatts: Double,
        cpuPercent: Double,
        memoryPercent: Double,
        isAwakeAsserted: Bool
    ) {
        self.deviceID = deviceID
        self.timestamp = timestamp
        self.schemaVersion = schemaVersion
        self.payload = payload
        self.batteryPercent = batteryPercent
        self.batteryHealth = batteryHealth
        self.chargingWatts = chargingWatts
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.isAwakeAsserted = isAwakeAsserted
    }
}

// MARK: - DailyHealth

/// Long-term battery trend, one record per Mac per day (plan §7.3).
public struct DailyHealth: Codable, Sendable, Equatable {
    public var deviceID: String
    /// Midnight UTC for the day this record summarizes.
    public var day: Date
    public var healthPercent: Double
    public var cycleCount: Int
    public var fullChargeCapacity: Int
    public var minCharge: Double
    public var maxCharge: Double
    public var timeOnACSeconds: Int

    public init(
        deviceID: String,
        day: Date,
        healthPercent: Double,
        cycleCount: Int,
        fullChargeCapacity: Int,
        minCharge: Double,
        maxCharge: Double,
        timeOnACSeconds: Int
    ) {
        self.deviceID = deviceID
        self.day = day
        self.healthPercent = healthPercent
        self.cycleCount = cycleCount
        self.fullChargeCapacity = fullChargeCapacity
        self.minCharge = minCharge
        self.maxCharge = maxCharge
        self.timeOnACSeconds = timeOnACSeconds
    }
}

// MARK: - ControlCommand

/// iPhone → Mac. Create-only; never updated (plan §7.6 — iPhone is
/// authoritative for this record type).
public struct ControlCommand: Codable, Sendable, Equatable {
    /// Target Mac. Reference → `Device`.
    public var deviceID: String
    public var issuedAt: Date
    /// `keepAwake` / `releaseAwake` / `extendAwake` / `truncateAwake` /
    /// `refreshNow` / `setSetting`. `extendAwake`/`truncateAwake` mirror
    /// `PowerControlService.adjustAssertion(bySeconds:)` on the Mac side —
    /// same "extend positive, truncate negative" split, carried in
    /// `parametersJSON`'s `deltaSeconds`.
    public var commandType: String
    /// e.g. `{"durationSeconds":3600,"mode":"system"}` for `keepAwake`, or
    /// `{"deltaSeconds":900}` for `extendAwake`/`truncateAwake`.
    public var parametersJSON: String
    /// Idempotency key — the Mac ignores a nonce it has already run.
    public var nonce: String
    /// The Mac ignores commands older than this (default issuedAt + 5 min).
    public var expiresAt: Date

    public init(
        deviceID: String,
        issuedAt: Date,
        commandType: String,
        parametersJSON: String,
        nonce: String,
        expiresAt: Date
    ) {
        self.deviceID = deviceID
        self.issuedAt = issuedAt
        self.commandType = commandType
        self.parametersJSON = parametersJSON
        self.nonce = nonce
        self.expiresAt = expiresAt
    }
}

// MARK: - ControlStatus

/// Mac → iPhone acknowledgement. Create-or-update by nonce; Mac is
/// authoritative (plan §7.6).
public struct ControlStatus: Codable, Sendable, Equatable {
    /// Reference → `Device`.
    public var deviceID: String
    public var respondsToNonce: String
    /// `accepted` / `rejected` / `completed` / `expired`.
    public var state: String
    public var message: String
    public var assertionActive: Bool
    public var assertionExpiresAt: Date?
    public var updatedAt: Date

    public init(
        deviceID: String,
        respondsToNonce: String,
        state: String,
        message: String,
        assertionActive: Bool,
        assertionExpiresAt: Date?,
        updatedAt: Date
    ) {
        self.deviceID = deviceID
        self.respondsToNonce = respondsToNonce
        self.state = state
        self.message = message
        self.assertionActive = assertionActive
        self.assertionExpiresAt = assertionExpiresAt
        self.updatedAt = updatedAt
    }
}

// MARK: - AlertPush

/// Mac → iPhone: one record per fired `AlertAction.pushToPhone` — a
/// planned feature that was cut before any delivery path existed (the
/// engine hook and local queue that once recorded these were deleted;
/// `AlertAction.pushToPhone` itself survives only for decode
/// compatibility). This payload type remains solely because `CKMapper`
/// still round-trips it; nothing constructs one at runtime.
public struct AlertPush: Codable, Sendable, Equatable {
    /// Reference → `Device`.
    public var deviceID: String
    public var ruleName: String
    public var title: String
    public var body: String
    public var firedAt: Date

    public init(deviceID: String, ruleName: String, title: String, body: String, firedAt: Date) {
        self.deviceID = deviceID
        self.ruleName = ruleName
        self.title = title
        self.body = body
        self.firedAt = firedAt
    }
}
