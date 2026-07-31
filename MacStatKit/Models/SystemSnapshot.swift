import Foundation

/// The canonical payload that flows through the whole system — UI, storage,
/// CloudKit, and MCP. Every sub-struct is optional so a Mac missing a
/// capability produces a valid, smaller snapshot rather than fake zeros.
public struct SystemSnapshot: Codable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let deviceID: String
    public let schemaVersion: Int

    public var battery: BatteryStats?
    public var cpu: CPUStats?
    public var gpu: GPUStats?
    public var ane: ANEStats?
    public var memory: MemoryStats?
    public var disk: DiskStats?
    public var network: NetworkStats?
    public var thermal: ThermalStats?
    public var sleepAssertion: SleepAssertionState?

    /// The Mac's last-captured approximate location (plan §3.2 P5's honesty
    /// discipline applies here same as everywhere else — see
    /// `MacLocation`'s and `LocationService`'s doc comments). `nil` covers
    /// every one of: location permission not granted, the feature toggled
    /// off, or no fix captured yet — `SystemSnapshot`'s consumers can't tell
    /// those apart from this field alone, which is fine, since none of them
    /// change what the UI should show ("no known location," worded
    /// specifically, not a blank/fake map pin).
    public var location: MacLocation?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        deviceID: String,
        schemaVersion: Int = 1,
        battery: BatteryStats? = nil,
        cpu: CPUStats? = nil,
        gpu: GPUStats? = nil,
        ane: ANEStats? = nil,
        memory: MemoryStats? = nil,
        disk: DiskStats? = nil,
        network: NetworkStats? = nil,
        thermal: ThermalStats? = nil,
        sleepAssertion: SleepAssertionState? = nil,
        location: MacLocation? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.deviceID = deviceID
        self.schemaVersion = schemaVersion
        self.battery = battery
        self.cpu = cpu
        self.gpu = gpu
        self.ane = ane
        self.memory = memory
        self.disk = disk
        self.network = network
        self.thermal = thermal
        self.sleepAssertion = sleepAssertion
        self.location = location
    }
}
