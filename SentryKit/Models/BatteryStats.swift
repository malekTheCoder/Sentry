import Foundation

public struct BatteryStats: Codable, Sendable {
    public var chargePercent: Double
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var chargingWatts: Double?
    public var systemPowerInWatts: Double?
    public var adapterRatedWatts: Int?
    public var adapterDescription: String?
    public var adapterCount: Int
    /// nil when the AppleSmartBattery IORegistry read failed (transient
    /// IOKit hiccup, or a Mac with no smart battery controller) — a real
    /// zero reading and "no data" must stay distinguishable, since a
    /// dashboard/alert rule reading "0%" or "0 mV" as literal would be
    /// actively misleading rather than merely incomplete.
    public var voltageMV: Int?
    public var amperageMA: Int?
    public var cycleCount: Int?
    public var designCapacityMAh: Int?
    public var fullChargeCapacityMAh: Int?
    public var healthPercent: Double?
    public var temperatureCelsius: Double?
    public var cellVoltagesMV: [Int]
    public var timeToFullMinutes: Int?
    public var timeToEmptyMinutes: Int?
    public var notChargingReason: Int?
    public var notChargingReasonText: String?
    public var isThermallyLimited: Bool

    public init(
        chargePercent: Double,
        isCharging: Bool,
        isPluggedIn: Bool,
        chargingWatts: Double? = nil,
        systemPowerInWatts: Double? = nil,
        adapterRatedWatts: Int? = nil,
        adapterDescription: String? = nil,
        adapterCount: Int = 0,
        voltageMV: Int? = nil,
        amperageMA: Int? = nil,
        cycleCount: Int? = nil,
        designCapacityMAh: Int? = nil,
        fullChargeCapacityMAh: Int? = nil,
        healthPercent: Double? = nil,
        temperatureCelsius: Double? = nil,
        cellVoltagesMV: [Int] = [],
        timeToFullMinutes: Int? = nil,
        timeToEmptyMinutes: Int? = nil,
        notChargingReason: Int? = nil,
        notChargingReasonText: String? = nil,
        isThermallyLimited: Bool = false
    ) {
        self.chargePercent = chargePercent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.chargingWatts = chargingWatts
        self.systemPowerInWatts = systemPowerInWatts
        self.adapterRatedWatts = adapterRatedWatts
        self.adapterDescription = adapterDescription
        self.adapterCount = adapterCount
        self.voltageMV = voltageMV
        self.amperageMA = amperageMA
        self.cycleCount = cycleCount
        self.designCapacityMAh = designCapacityMAh
        self.fullChargeCapacityMAh = fullChargeCapacityMAh
        self.healthPercent = healthPercent
        self.temperatureCelsius = temperatureCelsius
        self.cellVoltagesMV = cellVoltagesMV
        self.timeToFullMinutes = timeToFullMinutes
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.notChargingReason = notChargingReason
        self.notChargingReasonText = notChargingReasonText
        self.isThermallyLimited = isThermallyLimited
    }
}
