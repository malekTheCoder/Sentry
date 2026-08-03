import Foundation

public extension SystemSnapshot {
    /// Reads one metric out of this snapshot by its stable ID.
    ///
    /// Returns nil when the metric's module is absent (unsupported on this
    /// Mac) or the individual field is nil — callers must render that as
    /// "unavailable", never as zero (plan §3.2 P5, and the reason most stat
    /// fields are Optional in the first place).
    func value(for metric: MetricID) -> Double? {
        switch metric {
        case .batteryChargePercent: return battery?.chargePercent
        case .batteryChargingWatts: return battery?.chargingWatts
        case .batterySystemPowerWatts: return battery?.systemPowerInWatts
        case .batteryHealthPercent: return battery?.healthPercent
        case .batteryCycleCount: return battery?.cycleCount.map { Double($0) }
        case .batteryTemperatureC: return battery?.temperatureCelsius
        case .batteryAdapterWatts: return battery?.adapterRatedWatts.map { Double($0) }
        case .batteryVoltageMV: return battery?.voltageMV.map { Double($0) }
        case .batteryAmperageMA: return battery?.amperageMA.map { Double($0) }
        case .batteryTimeToFullMin: return battery?.timeToFullMinutes.map { Double($0) }
        case .batteryTimeToEmptyMin: return battery?.timeToEmptyMinutes.map { Double($0) }
        case .batteryFullChargeCapacityMAh: return battery?.fullChargeCapacityMAh.map { Double($0) }

        case .cpuTotalPercent: return cpu?.totalPercent
        case .cpuEcorePercent: return cpu?.ecorePercent
        case .cpuPcorePercent: return cpu?.pcorePercent
        case .cpuFrequencyMHz: return cpu?.effectiveFrequencyMHz
        case .cpuPowerWatts: return cpu?.packagePowerWatts
        case .cpuLoadAvg1m: return cpu?.loadAverage1m
        // Not separately collected yet — CPUCollector aggregates user/system
        // into totalPercent rather than splitting them out (plan §5.2 lists
        // them, but the collector doesn't surface the split).
        case .cpuUserPercent, .cpuSystemPercent: return nil

        case .gpuUtilizationPercent: return gpu?.utilizationPercent
        case .gpuRendererPercent: return gpu?.rendererPercent
        case .gpuTilerPercent: return gpu?.tilerPercent
        case .gpuFrequencyMHz: return gpu?.frequencyMHz
        case .gpuPowerWatts: return gpu?.powerWatts
        case .gpuVramUsedBytes: return gpu?.vramUsedBytes.map { Double($0) }

        case .anePowerWatts: return ane?.powerWatts
        case .aneActive: return ane?.isActive.map { $0 ? 1 : 0 }

        case .memoryUsedBytes: return memory.map { Double($0.usedBytes) }
        case .memoryWiredBytes: return memory.map { Double($0.wiredBytes) }
        case .memoryCompressedBytes: return memory.map { Double($0.compressedBytes) }
        case .memoryCachedBytes: return memory.map { Double($0.cachedBytes) }
        case .memorySwapUsedBytes: return memory?.swapUsedBytes.map { Double($0) }
        // Derived: the collector reports a 3-level pressure enum, not a
        // percent. Map it onto a rough percent so a bar/arc has something
        // sensible to fill, rather than dropping the metric entirely.
        case .memoryPressurePercent:
            return memory?.pressureLevel.map { level in
                switch level {
                case .normal: return 25
                case .warning: return 65
                case .critical: return 100
                }
            }

        case .diskReadBytesPerSec: return disk?.readBytesPerSec
        case .diskWriteBytesPerSec: return disk?.writeBytesPerSec
        case .diskReadIOPS: return disk?.readIOPS
        case .diskWriteIOPS: return disk?.writeIOPS
        case .diskFreeBytes: return disk.map { Double($0.freeBytes) }
        case .diskUsedPercent:
            guard let disk, disk.totalBytes > 0 else { return nil }
            return (Double(disk.totalBytes) - Double(disk.freeBytes)) / Double(disk.totalBytes) * 100

        case .networkRxBytesPerSec: return network?.rxBytesPerSec
        case .networkTxBytesPerSec: return network?.txBytesPerSec
        case .networkRxTotalBytes: return network.map { Double($0.rxSessionTotalBytes) }
        case .networkTxTotalBytes: return network.map { Double($0.txSessionTotalBytes) }
        case .networkWifiRSSIdBm: return network?.wifiRSSIdBm.map { Double($0) }
        case .networkWifiTxRateMbps: return network?.wifiTxRateMbps

        case .thermalSocTempC: return thermal?.socTemperatureCelsius
        case .thermalIsThrottling: return thermal.map { $0.isThrottling ? 1 : 0 }
        case .thermalPressureLevel:
            return thermal.map { t in
                switch t.pressureLevel {
                case .nominal: return 0
                case .fair: return 1
                case .serious: return 2
                case .critical: return 3
                }
            }

        // Deliberately nil rather than `ProcessInfo.systemUptime`: every
        // other case reads out of `self`. Reading the live process would
        // make a snapshot replayed from history report *now's* uptime, and
        // would make an iPhone rendering a synced Mac snapshot report the
        // iPhone's uptime labelled as the Mac's. Needs to become a captured
        // field on the snapshot before it can be reported honestly.
        case .systemUptimeSeconds: return nil
        case .systemProcessCount: return cpu?.processCount.map { Double($0) }
        case .systemAwakeAssertionActive:
            guard let sleepAssertion else { return nil }
            if case .active = sleepAssertion { return 1 }
            return 0
        }
    }

    /// A 0...1 fill fraction for bar/arc rendering, or nil when the metric
    /// has no meaningful bounded range (throughput, byte counts, frequencies
    /// — nothing to fill *relative to*).
    func normalizedValue(for metric: MetricID) -> Double? {
        guard let raw = value(for: metric) else { return nil }
        switch metric.unit {
        case .percent:
            return min(max(raw / 100, 0), 1)
        case .boolean:
            return raw > 0 ? 1 : 0
        default:
            break
        }

        switch metric {
        case .memoryUsedBytes:
            guard let total = memory?.totalBytes, total > 0 else { return nil }
            return min(max(raw / Double(total), 0), 1)
        case .diskFreeBytes:
            guard let total = disk?.totalBytes, total > 0 else { return nil }
            return min(max(raw / Double(total), 0), 1)
        case .thermalPressureLevel:
            return min(max(raw / 3, 0), 1)
        default:
            return nil
        }
    }
}
