import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The stable facts about *this* machine that rules need in order to be
/// personal rather than generic — the difference between "enable FileVault"
/// and "FileVault is off on a laptop that has been away from its usual
/// location six times this month."
///
/// Every field is optional. A fact this app cannot read honestly is `nil`,
/// and rules that need it simply don't fire — the same posture
/// `BatteryStats`' optionals take (see that type's doc comment on why a real
/// zero and "no data" must stay distinguishable).
///
/// **Why this lives in SentryKit and not SystemMetricsKit.** It is pure
/// `sysctl`/`ProcessInfo` reading with no IOKit, no subprocess, and no
/// AppKit, so it compiles for iOS along with the rest of this module and
/// lets `ProtectionInsightsEngine` and its tests stay in one place. The
/// values are meaningless on iOS (`hw.model` reports an iPhone identifier
/// there) — nothing on the phone builds an `InsightContext`, and
/// `isPortable` is documented below as Mac-only in meaning.
public struct DeviceFacts: Codable, Sendable, Equatable {

    /// `hw.model`, e.g. `"Mac14,7"`. The raw identifier, not a marketing
    /// name — deliberately not mapped through a lookup table this app would
    /// have to keep current with every new Mac, which would go stale and
    /// start lying within one hardware cycle.
    public var modelIdentifier: String?

    /// `machdep.cpu.brand_string`, e.g. `"Apple M2 Pro"`.
    public var chipName: String?

    /// `ProcessInfo.processInfo.physicalMemory`.
    public var physicalMemoryBytes: UInt64?

    /// e.g. `"14.5.0"`.
    public var macOSVersion: String?

    /// `true` for a MacBook, `false` for a desktop Mac, `nil` when the model
    /// identifier couldn't be read at all.
    ///
    /// Several rules turn on this: FileVault matters more on a machine that
    /// leaves the house, deep discharges matter more on one that runs off
    /// its battery by design, and "always plugged in at 100%" is not a
    /// finding worth reporting on a Mac mini.
    public var isPortable: Bool?

    /// Seconds since boot, from `ProcessInfo.processInfo.systemUptime`.
    ///
    /// Note this is *uptime*, which on macOS keeps advancing across sleep —
    /// it answers "how long since the last restart," not "how long awake."
    /// The one rule that uses it says exactly that.
    public var uptimeSeconds: TimeInterval?

    /// Total capacity of the startup volume, when the caller has a
    /// `DiskStats` to supply it from. Carried here rather than re-read so
    /// the whole context stays a plain value.
    public var startupVolumeTotalBytes: UInt64?

    public init(
        modelIdentifier: String? = nil,
        chipName: String? = nil,
        physicalMemoryBytes: UInt64? = nil,
        macOSVersion: String? = nil,
        isPortable: Bool? = nil,
        uptimeSeconds: TimeInterval? = nil,
        startupVolumeTotalBytes: UInt64? = nil
    ) {
        self.modelIdentifier = modelIdentifier
        self.chipName = chipName
        self.physicalMemoryBytes = physicalMemoryBytes
        self.macOSVersion = macOSVersion
        self.isPortable = isPortable
        self.uptimeSeconds = uptimeSeconds
        self.startupVolumeTotalBytes = startupVolumeTotalBytes
    }

    /// Reads what this process can read without any permission prompt or
    /// privileged call. Never throws; anything unreadable stays `nil`.
    public static func current(startupVolumeTotalBytes: UInt64? = nil) -> DeviceFacts {
        let model = sysctlString("hw.model")
        let version = ProcessInfo.processInfo.operatingSystemVersion

        return DeviceFacts(
            modelIdentifier: model,
            chipName: sysctlString("machdep.cpu.brand_string"),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            isPortable: model.map { $0.hasPrefix("MacBook") },
            uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            startupVolumeTotalBytes: startupVolumeTotalBytes
        )
    }

    /// `sysctlbyname` string read, in two calls (size, then value) as the
    /// API requires. Returns `nil` on any failure rather than an empty
    /// string, so a caller can't mistake "unreadable" for "blank".
    static func sysctlString(_ name: String) -> String? {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // Decode up to the first NUL rather than over the whole buffer —
        // `size` includes the terminator, and decoding it produces a String
        // with a trailing "\0" that then shows up in the UI.
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let text = String(decoding: bytes, as: UTF8.self)
        return text.isEmpty ? nil : text
        #else
        return nil
        #endif
    }
}
