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

    /// Short human label for UI. Wrapped in `String(localized:)` so it's
    /// extracted into `MacStatKit/Resources/Localizable.xcstrings` — English
    /// copy is unchanged; translations can be added to the catalog later
    /// without touching this switch.
    public var shortLabel: String {
        switch self {
        case .batteryChargePercent: return String(localized: "Battery")
        case .batteryChargingWatts: return String(localized: "Charging")
        case .batterySystemPowerWatts: return String(localized: "Power")
        case .batteryHealthPercent: return String(localized: "Health")
        case .batteryCycleCount: return String(localized: "Cycles")
        case .batteryTemperatureC: return String(localized: "Batt Temp")
        case .batteryAdapterWatts: return String(localized: "Adapter")
        case .batteryVoltageMV: return String(localized: "Voltage")
        case .batteryAmperageMA: return String(localized: "Amperage")
        case .batteryTimeToFullMin: return String(localized: "Time to Full")
        case .batteryTimeToEmptyMin: return String(localized: "Time to Empty")
        case .batteryFullChargeCapacityMAh: return String(localized: "Full Capacity")
        case .cpuTotalPercent: return String(localized: "CPU")
        case .cpuUserPercent: return String(localized: "CPU User")
        case .cpuSystemPercent: return String(localized: "CPU System")
        case .cpuEcorePercent: return String(localized: "E-Cores")
        case .cpuPcorePercent: return String(localized: "P-Cores")
        case .cpuFrequencyMHz: return String(localized: "CPU Freq")
        case .cpuPowerWatts: return String(localized: "CPU Power")
        case .cpuLoadAvg1m: return String(localized: "Load Avg")
        case .gpuUtilizationPercent: return String(localized: "GPU")
        case .gpuRendererPercent: return String(localized: "GPU Renderer")
        case .gpuTilerPercent: return String(localized: "GPU Tiler")
        case .gpuFrequencyMHz: return String(localized: "GPU Freq")
        case .gpuPowerWatts: return String(localized: "GPU Power")
        case .gpuVramUsedBytes: return String(localized: "VRAM")
        case .anePowerWatts: return String(localized: "ANE Power")
        case .aneActive: return String(localized: "ANE Active")
        case .memoryUsedBytes: return String(localized: "Memory")
        case .memoryWiredBytes: return String(localized: "Wired Mem")
        case .memoryCompressedBytes: return String(localized: "Compressed")
        case .memoryCachedBytes: return String(localized: "Cached")
        case .memoryPressurePercent: return String(localized: "Mem Pressure")
        case .memorySwapUsedBytes: return String(localized: "Swap")
        case .diskReadBytesPerSec: return String(localized: "Disk R")
        case .diskWriteBytesPerSec: return String(localized: "Disk W")
        case .diskReadIOPS: return String(localized: "Disk R IOPS")
        case .diskWriteIOPS: return String(localized: "Disk W IOPS")
        case .diskFreeBytes: return String(localized: "Disk Free")
        case .diskUsedPercent: return String(localized: "Disk Used")
        case .networkRxBytesPerSec: return String(localized: "Net ↓")
        case .networkTxBytesPerSec: return String(localized: "Net ↑")
        case .networkRxTotalBytes: return String(localized: "Net ↓ Total")
        case .networkTxTotalBytes: return String(localized: "Net ↑ Total")
        case .networkWifiRSSIdBm: return String(localized: "Wi-Fi Signal")
        case .networkWifiTxRateMbps: return String(localized: "Wi-Fi Rate")
        case .thermalSocTempC: return String(localized: "Temp")
        case .thermalPressureLevel: return String(localized: "Thermal Level")
        case .thermalIsThrottling: return String(localized: "Throttling")
        case .systemUptimeSeconds: return String(localized: "Uptime")
        case .systemProcessCount: return String(localized: "Processes")
        case .systemAwakeAssertionActive: return String(localized: "Awake Lock")
        }
    }
}

public enum MetricModule: String, Codable, Sendable, CaseIterable, Hashable {
    case battery, cpu, gpu, ane, memory, disk, network, thermal, system

    public var displayName: String {
        switch self {
        case .battery: return String(localized: "Battery")
        case .cpu: return String(localized: "CPU")
        case .gpu: return String(localized: "GPU")
        case .ane: return String(localized: "Neural Engine")
        case .memory: return String(localized: "Memory")
        case .disk: return String(localized: "Disk")
        case .network: return String(localized: "Network")
        case .thermal: return String(localized: "Thermals")
        case .system: return String(localized: "System")
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
