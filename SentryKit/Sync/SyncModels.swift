import Foundation

// MARK: - Shared device-sync models

/// The plain-data models device sync actually uses, shared by the Mac and
/// iPhone/Watch targets.
///
/// These four types originally lived in a CloudKit record-model file
/// (`SyncRecords.swift`, deleted — see git history) alongside a mapper and
/// upload service that were never wired to a real container. The CloudKit
/// layer is gone; these survive because they were never CloudKit-specific:
/// `ControlCommand`/`ControlStatus` are the LocalSync control channel's wire
/// payloads (`LocalSyncFraming` frames them as JSON), and `Device`/
/// `DailyHealth` are the iPhone app's on-screen models, built today from
/// live `SystemSnapshot`s (`AppDataSource`) or demo data (`MockDataSource`).

// MARK: - Device

/// The phone's description of one Mac — who it is, what it runs, and when
/// it was last seen. Built by `AppDataSource` from the live snapshot stream
/// (or fabricated by `MockDataSource` for demo mode) and rendered by the
/// Dashboard's device picker, History, and Settings' device card.
///
/// `lastViewedAt` records the last time the iPhone app was foregrounded —
/// `HeartbeatTracker.isFastCadence(lastViewedAt:now:)` takes this field's
/// value as a plain `Date?` rather than a whole `Device`, so it stays
/// testable without constructing one. `nil` must be treated as "not
/// recently active," never as "always fast cadence" — an absent value is
/// the honest default for "we don't know."
public struct Device: Codable, Sendable, Equatable {
    /// Stable UUID persisted in the app support dir.
    public var deviceID: String
    public var deviceName: String
    public var model: String
    public var chip: String
    public var osVersion: String
    public var appVersion: String
    /// Heartbeat: last time the Mac was observed.
    public var lastSeen: Date
    /// JSON-encoded capability description so the phone knows which
    /// modules to render without a schema round-trip.
    public var capabilitiesJSON: String
    /// Last time the iPhone app was foregrounded — see the type doc
    /// comment for the `nil` contract.
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

// MARK: - DailyHealth

/// Long-term battery trend, one record per Mac per day. Produced today by
/// `SyntheticDailyHealth` (derived from snapshot history) and
/// `MockDataSource` (demo mode); consumed by the iPhone History tab's
/// battery-health trend chart and cycle-count section.
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

/// iPhone → Mac, over the LocalSync control channel (`LocalSyncFraming`'s
/// `.command` frame). Constructed by the Siri intents and
/// `SleepStatusCard`'s buttons; executed on the Mac by
/// `LocalCommandExecutor` after `NonceTracker` deduplicates it.
public struct ControlCommand: Codable, Sendable, Equatable {
    /// Target Mac. Matches `Device.deviceID`.
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

/// Mac → iPhone acknowledgement of a `ControlCommand`, sent back over the
/// same channel (`LocalSyncFraming`'s `.status` frame) and matched to its
/// command by `respondsToNonce` — see `StatsTransport.awaitStatus(forNonce:timeout:)`.
public struct ControlStatus: Codable, Sendable, Equatable {
    /// The Mac that executed (or refused) the command.
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
