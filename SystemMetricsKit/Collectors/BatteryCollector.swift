import Foundation
import IOKit.ps
import SentryKit

/// Reads battery state from IOPowerSources (basics) plus the AppleSmartBattery
/// IORegistry entry (wattage, adapter, health, charging diagnostics).
///
/// Returns nil on desktop Macs with no internal battery.
public final class BatteryCollector: Collector {
    public init() {}

    public func collect() -> BatteryStats? {
        guard let powerSource = Self.readPowerSource() else { return nil }
        let smart = IOKitBridge.properties(forService: "AppleSmartBattery")

        let chargePercent = (powerSource[kIOPSCurrentCapacityKey as String] as? Double) ?? 0
        let isCharging = (powerSource[kIOPSIsChargingKey as String] as? Bool) ?? false
        let isPluggedIn = (powerSource[kIOPSPowerSourceStateKey as String] as? String) == kIOPSACPowerValue

        var stats = BatteryStats(
            chargePercent: chargePercent,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn
        )

        stats.timeToFullMinutes = (powerSource[kIOPSTimeToFullChargeKey as String] as? Int).flatMap { $0 >= 0 ? $0 : nil }
        stats.timeToEmptyMinutes = (powerSource[kIOPSTimeToEmptyKey as String] as? Int).flatMap { $0 >= 0 ? $0 : nil }

        guard let smart else { return stats }

        let voltageMV = smart["Voltage"] as? Int
        let amperageMA = (smart["InstantAmperage"] as? Int).map(Self.signedAmperage)
        stats.voltageMV = voltageMV
        stats.amperageMA = amperageMA
        // Voltage is mV, amperage is mA → product is µW → ÷ 1e6 for W.
        // Negative amperage means discharging; report magnitude only while charging.
        if isCharging, let voltageMV, let amperageMA {
            stats.chargingWatts = abs(Double(voltageMV) * Double(amperageMA) / 1_000_000.0)
        }

        if let telemetry = smart["PowerTelemetryData"] as? [String: Any] {
            // Only report when the key is actually present — `?? 0` here
            // would fabricate a "0.0 W" reading when the field is missing
            // (P5: absent data must surface as nil, never a made-up number).
            stats.systemPowerInWatts = (telemetry["SystemPowerIn"] as? Int).map { Double($0) / 1000.0 }
        }

        if let adapter = smart["AdapterDetails"] as? [String: Any] {
            stats.adapterRatedWatts = adapter["Watts"] as? Int
            stats.adapterDescription = adapter["Description"] as? String
        }
        stats.adapterCount = (smart["AppleRawAdapterDetails"] as? [[String: Any]])?.count ?? 0

        stats.cycleCount = smart["CycleCount"] as? Int

        let battData = smart["BatteryData"] as? [String: Any]
        let design = battData?["DesignCapacity"] as? Int ?? smart["DesignCapacity"] as? Int
        // Fallback chain per plan §5.1: FccComp1 -> NominalChargeCapacity -> AppleRawMaxCapacity.
        // NOTE: on this Mac (M-series, macOS 15) this formula computes ~92% while
        // System Settings / system_profiler report 99% — Apple's internal health
        // metric isn't fully exposed via IORegistry. Documented as an open item
        // (plan §19); this is the best publicly-derivable approximation.
        // On newer macOS (observed on Darwin 27 / macOS 26) the top-level
        // NominalChargeCapacity / AppleRawMaxCapacity keys are gone and the
        // value only exists nested as BatteryData["NominalChargeCapacity"] —
        // without that entry in the chain, health silently reads as
        // unavailable on current systems even though the data is present.
        let fcc = battData?["FccComp1"] as? Int
            ?? battData?["NominalChargeCapacity"] as? Int
            ?? smart["NominalChargeCapacity"] as? Int
            ?? smart["AppleRawMaxCapacity"] as? Int
        stats.designCapacityMAh = design
        stats.fullChargeCapacityMAh = fcc
        if let design, design > 0, let fcc {
            stats.healthPercent = Double(fcc) / Double(design) * 100.0
        }
        stats.cellVoltagesMV = battData?["CellVoltage"] as? [Int] ?? []

        if let temp = smart["Temperature"] as? Int {
            stats.temperatureCelsius = Double(temp) / 100.0
        }

        if let chargerData = smart["ChargerData"] as? [String: Any] {
            let reason = chargerData["NotChargingReason"] as? Int
            stats.notChargingReason = reason
            stats.notChargingReasonText = reason.map(Self.notChargingReasonText)
            stats.isThermallyLimited = (chargerData["TimeChargingThermallyLimited"] as? Int ?? 0) != 0
        }

        return stats
    }

    // Bounded per §14.4 rule 4, matching every other IOKit-adjacent loop in
    // this codebase — the real list is always tiny (battery ± a UPS), but
    // there's no reason for this one loop to be the exception.
    private static let maxPowerSources = 256

    private static func readPowerSource() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources.prefix(maxPowerSources) {
            if let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
               desc[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType {
                return desc
            }
        }
        return nil
    }

    /// InstantAmperage is signed but can arrive as a large two's-complement
    /// UInt32 on some models.
    private static func signedAmperage(_ raw: Int) -> Int {
        raw > Int(Int32.max) ? raw - Int(UInt32.max) - 1 : raw
    }

    /// Reason codes are undocumented, model/macOS-version dependent, and —
    /// observed live — a *bitmask*, not an enum (a real MacBook reported
    /// 0x400001, i.e. bit 0 plus an unknown high bit). Only exact matches
    /// of the two singleton codes get their specific label: with unknown
    /// bits set alongside, claiming "battery temperature" off bit 0 would
    /// be a guess dressed as a diagnosis. Everything else gets the honest
    /// minimum — the charge is on hold — with no raw code, which meant
    /// nothing to anyone and looked like a malfunction in the UI.
    private static func notChargingReasonText(_ code: Int) -> String {
        if code == 0 { return "Charging normally" }
        switch code {
        case 1 << 0: return "Paused — battery at high temperature"
        case 1 << 1: return "Paused — Optimized Battery Charging"
        default: return "Charging on hold"
        }
    }
}
