import Foundation

/// `totalPercent`/`perCorePercent`/`ecorePercent`/`pcorePercent`/
/// `loadAverage1m`/`processCount` are populated by `CPUCollector` (plan
/// §5.2). `effectiveFrequencyMHz`/`packagePowerWatts` require the IOReport
/// bridge and stay nil until that lands.
public struct CPUStats: Codable, Sendable {
    public var totalPercent: Double
    public var perCorePercent: [Double]
    public var ecorePercent: Double?
    public var pcorePercent: Double?
    public var effectiveFrequencyMHz: Double?
    public var packagePowerWatts: Double?
    public var loadAverage1m: Double?
    public var processCount: Int?

    public init(
        totalPercent: Double,
        perCorePercent: [Double] = [],
        ecorePercent: Double? = nil,
        pcorePercent: Double? = nil,
        effectiveFrequencyMHz: Double? = nil,
        packagePowerWatts: Double? = nil,
        loadAverage1m: Double? = nil,
        processCount: Int? = nil
    ) {
        self.totalPercent = totalPercent
        self.perCorePercent = perCorePercent
        self.ecorePercent = ecorePercent
        self.pcorePercent = pcorePercent
        self.effectiveFrequencyMHz = effectiveFrequencyMHz
        self.packagePowerWatts = packagePowerWatts
        self.loadAverage1m = loadAverage1m
        self.processCount = processCount
    }
}
