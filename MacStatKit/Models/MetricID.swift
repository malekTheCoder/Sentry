import Foundation

/// Stable dotted identifiers from plan Appendix A, used as database rows,
/// CloudKit fields, MCP tool arguments, and theme color keys.
///
/// **Never rename a case's raw value after shipping** — add and deprecate
/// instead. The raw values are the contract; the Swift case names are not.
///
/// Templated IDs from Appendix A (`cpu.core.{n}_percent`,
/// `thermal.fan_{n}_rpm`) aren't enumerable cases — they're constructed via
/// `MetricID.cpuCore(_:)` / `MetricID.thermalFan(_:)` below, which return raw
/// strings rather than enum cases for that reason.
public enum MetricID: String, Codable, Sendable, CaseIterable, Hashable {
    case batteryChargePercent = "battery.charge_percent"
    case batteryChargingWatts = "battery.charging_watts"
    case batterySystemPowerWatts = "battery.system_power_watts"
    case batteryHealthPercent = "battery.health_percent"
    case batteryCycleCount = "battery.cycle_count"
    case batteryTemperatureC = "battery.temperature_c"
    case batteryAdapterWatts = "battery.adapter_watts"
    case batteryVoltageMV = "battery.voltage_mv"
    case batteryAmperageMA = "battery.amperage_ma"
    case batteryTimeToFullMin = "battery.time_to_full_min"
    case batteryTimeToEmptyMin = "battery.time_to_empty_min"
    case batteryFullChargeCapacityMAh = "battery.full_charge_capacity_mah"

    case cpuTotalPercent = "cpu.total_percent"
    case cpuUserPercent = "cpu.user_percent"
    case cpuSystemPercent = "cpu.system_percent"
    case cpuEcorePercent = "cpu.ecore_percent"
    case cpuPcorePercent = "cpu.pcore_percent"
    case cpuFrequencyMHz = "cpu.frequency_mhz"
    case cpuPowerWatts = "cpu.power_watts"
    case cpuLoadAvg1m = "cpu.load_avg_1m"

    case gpuUtilizationPercent = "gpu.utilization_percent"
    case gpuRendererPercent = "gpu.renderer_percent"
    case gpuTilerPercent = "gpu.tiler_percent"
    case gpuFrequencyMHz = "gpu.frequency_mhz"
    case gpuPowerWatts = "gpu.power_watts"
    case gpuVramUsedBytes = "gpu.vram_used_bytes"

    case anePowerWatts = "ane.power_watts"
    case aneActive = "ane.active"

    case memoryUsedBytes = "memory.used_bytes"
    case memoryWiredBytes = "memory.wired_bytes"
    case memoryCompressedBytes = "memory.compressed_bytes"
    case memoryCachedBytes = "memory.cached_bytes"
    case memoryPressurePercent = "memory.pressure_percent"
    case memorySwapUsedBytes = "memory.swap_used_bytes"

    case diskReadBytesPerSec = "disk.read_bytes_per_sec"
    case diskWriteBytesPerSec = "disk.write_bytes_per_sec"
    case diskReadIOPS = "disk.read_iops"
    case diskWriteIOPS = "disk.write_iops"
    case diskFreeBytes = "disk.free_bytes"
    case diskUsedPercent = "disk.used_percent"

    case networkRxBytesPerSec = "network.rx_bytes_per_sec"
    case networkTxBytesPerSec = "network.tx_bytes_per_sec"
    case networkRxTotalBytes = "network.rx_total_bytes"
    case networkTxTotalBytes = "network.tx_total_bytes"
    case networkWifiRSSIdBm = "network.wifi_rssi_dbm"
    case networkWifiTxRateMbps = "network.wifi_tx_rate_mbps"

    case thermalSocTempC = "thermal.soc_temp_c"
    case thermalPressureLevel = "thermal.pressure_level"
    case thermalIsThrottling = "thermal.is_throttling"

    case systemUptimeSeconds = "system.uptime_seconds"
    case systemProcessCount = "system.process_count"
    case systemAwakeAssertionActive = "system.awake_assertion_active"

    public static func cpuCore(_ index: Int) -> String { "cpu.core.\(index)_percent" }
    public static func thermalFan(_ index: Int) -> String { "thermal.fan_\(index)_rpm" }

    /// Which module this metric belongs to — drives grouping in the settings
    /// module list and the dropdown's card ordering.
    public var module: MetricModule {
        switch self {
        case .batteryChargePercent, .batteryChargingWatts, .batterySystemPowerWatts,
             .batteryHealthPercent, .batteryCycleCount, .batteryTemperatureC,
             .batteryAdapterWatts, .batteryVoltageMV, .batteryAmperageMA,
             .batteryTimeToFullMin, .batteryTimeToEmptyMin, .batteryFullChargeCapacityMAh:
            return .battery
        case .cpuTotalPercent, .cpuUserPercent, .cpuSystemPercent, .cpuEcorePercent,
             .cpuPcorePercent, .cpuFrequencyMHz, .cpuPowerWatts, .cpuLoadAvg1m:
            return .cpu
        case .gpuUtilizationPercent, .gpuRendererPercent, .gpuTilerPercent,
             .gpuFrequencyMHz, .gpuPowerWatts, .gpuVramUsedBytes:
            return .gpu
        case .anePowerWatts, .aneActive:
            return .ane
        case .memoryUsedBytes, .memoryWiredBytes, .memoryCompressedBytes,
             .memoryCachedBytes, .memoryPressurePercent, .memorySwapUsedBytes:
            return .memory
        case .diskReadBytesPerSec, .diskWriteBytesPerSec, .diskReadIOPS,
             .diskWriteIOPS, .diskFreeBytes, .diskUsedPercent:
            return .disk
        case .networkRxBytesPerSec, .networkTxBytesPerSec, .networkRxTotalBytes,
             .networkTxTotalBytes, .networkWifiRSSIdBm, .networkWifiTxRateMbps:
            return .network
        case .thermalSocTempC, .thermalPressureLevel, .thermalIsThrottling:
            return .thermal
        case .systemUptimeSeconds, .systemProcessCount, .systemAwakeAssertionActive:
            return .system
        }
    }

    public var unit: MetricUnit {
        switch self {
        case .batteryChargePercent, .batteryHealthPercent, .cpuTotalPercent,
             .cpuUserPercent, .cpuSystemPercent, .cpuEcorePercent, .cpuPcorePercent,
             .gpuUtilizationPercent, .gpuRendererPercent, .gpuTilerPercent,
             .memoryPressurePercent, .diskUsedPercent:
            return .percent
        case .batteryChargingWatts, .batterySystemPowerWatts, .cpuPowerWatts,
             .gpuPowerWatts, .anePowerWatts, .batteryAdapterWatts:
            return .watts
        case .batteryTemperatureC, .thermalSocTempC:
            return .celsius
        case .cpuFrequencyMHz, .gpuFrequencyMHz:
            return .megahertz
        case .memoryUsedBytes, .memoryWiredBytes, .memoryCompressedBytes,
             .memoryCachedBytes, .memorySwapUsedBytes, .diskFreeBytes,
             .gpuVramUsedBytes, .networkRxTotalBytes, .networkTxTotalBytes:
            return .bytes
        case .diskReadBytesPerSec, .diskWriteBytesPerSec, .networkRxBytesPerSec,
             .networkTxBytesPerSec:
            return .bytesPerSecond
        case .diskReadIOPS, .diskWriteIOPS:
            return .operationsPerSecond
        case .batteryTimeToFullMin, .batteryTimeToEmptyMin:
            return .minutes
        case .systemUptimeSeconds:
            return .seconds
        case .batteryVoltageMV:
            return .millivolts
        case .batteryAmperageMA:
            return .milliamps
        case .networkWifiRSSIdBm:
            return .decibelMilliwatts
        case .networkWifiTxRateMbps:
            return .megabitsPerSecond
        case .aneActive, .thermalIsThrottling, .systemAwakeAssertionActive:
            return .boolean
        case .batteryCycleCount, .batteryFullChargeCapacityMAh, .systemProcessCount:
            return .count
        // Load average is the one metric where the fraction *is* the
        // information — `.count` would render 1.75 as "2".
        case .cpuLoadAvg1m:
            return .decimal
        // A 0…3 severity ordinal, not a quantity. Rendering it as a bare
        // "2" gives the user an unlabelled integer with no legend, which
        // §9.4 explicitly calls out as meaning-without-a-label.
        case .thermalPressureLevel:
            return .thermalLevel
        }
    }

    /// Short human label for UI. Not localized yet (plan defers localization
    /// to Phase 8).
    public var shortLabel: String {
        switch self {
        case .batteryChargePercent: return "Battery"
        case .batteryChargingWatts: return "Charging"
        case .batterySystemPowerWatts: return "Power"
        case .batteryHealthPercent: return "Health"
        case .batteryCycleCount: return "Cycles"
        case .batteryTemperatureC: return "Batt Temp"
        case .cpuTotalPercent: return "CPU"
        case .cpuEcorePercent: return "E-Cores"
        case .cpuPcorePercent: return "P-Cores"
        case .cpuFrequencyMHz: return "CPU Freq"
        case .cpuPowerWatts: return "CPU Power"
        case .gpuUtilizationPercent: return "GPU"
        case .gpuPowerWatts: return "GPU Power"
        case .gpuVramUsedBytes: return "VRAM"
        case .anePowerWatts: return "ANE Power"
        case .memoryUsedBytes: return "Memory"
        case .memorySwapUsedBytes: return "Swap"
        case .diskReadBytesPerSec: return "Disk R"
        case .diskWriteBytesPerSec: return "Disk W"
        case .diskFreeBytes: return "Disk Free"
        case .networkRxBytesPerSec: return "Net ↓"
        case .networkTxBytesPerSec: return "Net ↑"
        case .thermalSocTempC: return "Temp"
        default: return rawValue
        }
    }
}

public enum MetricModule: String, Codable, Sendable, CaseIterable, Hashable {
    case battery, cpu, gpu, ane, memory, disk, network, thermal, system

    public var displayName: String {
        switch self {
        case .battery: return "Battery"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .ane: return "Neural Engine"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .network: return "Network"
        case .thermal: return "Thermals"
        case .system: return "System"
        }
    }

    /// SF Symbol for this module. Lives here rather than in each renderer
    /// because the menu bar and the settings preview both need it, and two
    /// private copies had already drifted apart — every icon in the preview
    /// was showing a different glyph than the real bar drew.
    public var symbolName: String {
        switch self {
        case .battery: return "battery.100"
        case .cpu: return "cpuchip"
        case .gpu: return "cpu"
        case .ane: return "brain"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .network: return "network"
        case .thermal: return "thermometer"
        case .system: return "gauge"
        }
    }
}

public enum MetricUnit: String, Codable, Sendable, Hashable {
    case percent, watts, celsius, megahertz, bytes, bytesPerSecond
    case operationsPerSecond, minutes, seconds, millivolts, milliamps
    case decibelMilliwatts, megabitsPerSecond, boolean, count
    /// A unitless number whose fractional part matters (load average).
    case decimal
    /// A 0…3 thermal-pressure ordinal rendered as a word, not a number.
    case thermalLevel

    /// Suffix for compact display. Byte-scale units return an empty string
    /// because their formatter emits its own ("1.2 GB"), and appending a
    /// second unit would read as "1.2 GB B".
    public var suffix: String {
        switch self {
        case .percent: return "%"
        case .watts: return "W"
        case .celsius: return "°C"
        case .megahertz: return "MHz"
        case .bytes, .bytesPerSecond, .boolean, .count,
             .decimal, .thermalLevel: return ""
        case .operationsPerSecond: return "IOPS"
        case .minutes: return "m"
        case .seconds: return "s"
        case .millivolts: return "mV"
        case .milliamps: return "mA"
        case .decibelMilliwatts: return "dBm"
        case .megabitsPerSecond: return "Mbps"
        }
    }
}
