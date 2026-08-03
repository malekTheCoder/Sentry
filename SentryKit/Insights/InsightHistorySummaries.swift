import Foundation

// MARK: - Battery

/// Everything the battery-longevity rules need, already reduced from raw
/// `sample_raw` rows to a handful of numbers.
///
/// Built by `make(...)` from the exact metric series `HistoryStore` records
/// (see `HistoryStore.batteryPairs`): `battery.charge_percent`,
/// `battery.health_percent`, `battery.cycle_count`,
/// `battery.temperature_c`, and `battery.charging_watts`.
///
/// **`battery.charging_watts` is used as a charging *indicator*, not just a
/// wattage.** `BatteryCollector` only populates `chargingWatts` when
/// `isCharging` is true, and `HistoryStore` only writes a row when the field
/// is non-nil — so the mere presence of a sample at time *T* means this Mac
/// was drawing charge at *T*. That is the only charging signal in the
/// database (`isCharging`/`isPluggedIn` are booleans the flattener
/// deliberately doesn't record), and it's a sound one.
public struct BatteryHistorySummary: Sendable, Equatable {

    /// Distinct calendar days with at least one charge sample. The honest
    /// denominator for every "on N of the last M days" claim below.
    public var daysWithData: Int
    public var chargeSampleCount: Int

    /// Fraction of charge samples at or above 90% / 95%. High-state-of-charge
    /// residency is the single best-documented driver of lithium-ion calendar
    /// ageing, which is why it gets two thresholds rather than one.
    public var fractionAtOrAbove90: Double?
    public var fractionAtOrAbove95: Double?

    /// Fraction of charge samples below 20% / 10%.
    public var fractionBelow20: Double?
    public var fractionBelow10: Double?

    /// Mean of each day's (highest − lowest) charge. "How deep a swing does
    /// this Mac take in a typical day."
    public var meanDailyDepthPercent: Double?

    /// Days whose lowest reading fell under 10%.
    public var daysWithDeepDischarge: Int

    /// Days whose whole-day charge range was under 3 points — i.e. the
    /// battery essentially never moved. The signature of a Mac that lives on
    /// its charger.
    public var daysEssentiallyStatic: Int

    public var earliestHealthPercent: Double?
    public var latestHealthPercent: Double?
    /// Negative means capacity was lost over the window.
    public var healthDelta: Double? {
        guard let earliest = earliestHealthPercent, let latest = latestHealthPercent else { return nil }
        return latest - earliest
    }

    public var earliestCycleCount: Int?
    public var latestCycleCount: Int?
    public var cycleDelta: Int? {
        guard let earliest = earliestCycleCount, let latest = latestCycleCount else { return nil }
        return latest - earliest
    }

    public var meanTemperatureCelsius: Double?
    public var peakTemperatureCelsius: Double?
    /// Fraction of battery-temperature samples at or above 35 °C — the point
    /// above which lithium-ion calendar ageing accelerates noticeably.
    public var fractionTemperatureAtOrAbove35: Double?

    /// Charge samples that coincided with a hot SoC, and how many charge
    /// samples had a contemporaneous temperature reading to compare against
    /// at all. Both `nil` when the two series never lined up inside the
    /// pairing tolerance.
    public var chargingWhileHotSamples: Int?
    public var chargingComparableSamples: Int?

    public init(
        daysWithData: Int = 0,
        chargeSampleCount: Int = 0,
        fractionAtOrAbove90: Double? = nil,
        fractionAtOrAbove95: Double? = nil,
        fractionBelow20: Double? = nil,
        fractionBelow10: Double? = nil,
        meanDailyDepthPercent: Double? = nil,
        daysWithDeepDischarge: Int = 0,
        daysEssentiallyStatic: Int = 0,
        earliestHealthPercent: Double? = nil,
        latestHealthPercent: Double? = nil,
        earliestCycleCount: Int? = nil,
        latestCycleCount: Int? = nil,
        meanTemperatureCelsius: Double? = nil,
        peakTemperatureCelsius: Double? = nil,
        fractionTemperatureAtOrAbove35: Double? = nil,
        chargingWhileHotSamples: Int? = nil,
        chargingComparableSamples: Int? = nil
    ) {
        self.daysWithData = daysWithData
        self.chargeSampleCount = chargeSampleCount
        self.fractionAtOrAbove90 = fractionAtOrAbove90
        self.fractionAtOrAbove95 = fractionAtOrAbove95
        self.fractionBelow20 = fractionBelow20
        self.fractionBelow10 = fractionBelow10
        self.meanDailyDepthPercent = meanDailyDepthPercent
        self.daysWithDeepDischarge = daysWithDeepDischarge
        self.daysEssentiallyStatic = daysEssentiallyStatic
        self.earliestHealthPercent = earliestHealthPercent
        self.latestHealthPercent = latestHealthPercent
        self.earliestCycleCount = earliestCycleCount
        self.latestCycleCount = latestCycleCount
        self.meanTemperatureCelsius = meanTemperatureCelsius
        self.peakTemperatureCelsius = peakTemperatureCelsius
        self.fractionTemperatureAtOrAbove35 = fractionTemperatureAtOrAbove35
        self.chargingWhileHotSamples = chargingWhileHotSamples
        self.chargingComparableSamples = chargingComparableSamples
    }

    /// SoC temperature above which "you charged while the machine was
    /// already saturated" is a real finding rather than a warm afternoon.
    /// Deliberately below `SystemAdvisor.highSoCTempCelsius` (95 °C, the
    /// "stop starting new work" line): charging adds heat on top of whatever
    /// is already there, so the threshold for "don't add more" sits lower
    /// than the threshold for "already too hot."
    public static let hotChargingSoCThreshold: Double = 85

    /// Day-range under which a day counts as `daysEssentiallyStatic`.
    public static let staticDayRangePercent: Double = 3

    public static func make(
        chargePercent: MetricSampleSeries,
        healthPercent: MetricSampleSeries,
        cycleCount: MetricSampleSeries,
        batteryTemperatureCelsius: MetricSampleSeries,
        chargingWatts: MetricSampleSeries,
        socTemperatureCelsius: MetricSampleSeries,
        calendar: Calendar = .current
    ) -> BatteryHistorySummary {
        let charge = InsightAggregates.cleaned(chargePercent)
        let extremes = InsightAggregates.dailyExtremes(charge, calendar: calendar)
        let health = InsightAggregates.cleaned(healthPercent)
        let cycles = InsightAggregates.cleaned(cycleCount)

        let depths = extremes.map(\.range)
        let meanDepth = depths.isEmpty ? nil : depths.reduce(0, +) / Double(depths.count)

        let coincidence = InsightAggregates.coincidence(
            trigger: chargingWatts,
            condition: socTemperatureCelsius,
            conditionThreshold: hotChargingSoCThreshold
        )

        return BatteryHistorySummary(
            daysWithData: extremes.count,
            chargeSampleCount: charge.count,
            fractionAtOrAbove90: InsightAggregates.fractionOfSamples(charge, atOrAbove: 90),
            fractionAtOrAbove95: InsightAggregates.fractionOfSamples(charge, atOrAbove: 95),
            fractionBelow20: InsightAggregates.fractionOfSamples(charge, below: 20),
            fractionBelow10: InsightAggregates.fractionOfSamples(charge, below: 10),
            meanDailyDepthPercent: meanDepth,
            daysWithDeepDischarge: extremes.filter { $0.minimum < 10 }.count,
            // A day with a single sample has a range of 0 by construction and
            // would count as "static" for free — require at least two.
            daysEssentiallyStatic: extremes.filter { $0.sampleCount >= 2 && $0.range < staticDayRangePercent }.count,
            earliestHealthPercent: health.first?.value,
            latestHealthPercent: health.last?.value,
            earliestCycleCount: cycles.first.map { Int($0.value.rounded()) },
            latestCycleCount: cycles.last.map { Int($0.value.rounded()) },
            meanTemperatureCelsius: InsightAggregates.mean(batteryTemperatureCelsius),
            peakTemperatureCelsius: InsightAggregates.maximum(batteryTemperatureCelsius),
            fractionTemperatureAtOrAbove35: InsightAggregates.fractionOfSamples(batteryTemperatureCelsius, atOrAbove: 35),
            chargingWhileHotSamples: coincidence?.matching,
            chargingComparableSamples: coincidence?.comparable
        )
    }
}

// MARK: - Thermal

/// Heat exposure over time — the second-largest lever (after high-state-of-
/// charge residency) on how long a Mac's battery and solder joints last.
public struct ThermalHistorySummary: Sendable, Equatable {

    public var daysWithData: Int
    public var sampleCount: Int

    public var meanSoCTemperatureCelsius: Double?
    public var peakSoCTemperatureCelsius: Double?

    public var fractionAtOrAbove80: Double?
    public var fractionAtOrAbove95: Double?

    /// Time-weighted hours at or above 95 °C, gap-capped (see
    /// `InsightAggregates`' time-weighting note).
    public var hoursAtOrAbove95: Double

    /// Days containing a run of at least `sustainedHeatMinimumRun` at or
    /// above 90 °C.
    public var daysWithSustainedHeat: Int

    /// Fraction of `thermal.is_throttling` samples that were 1.
    public var throttlingFraction: Double?
    public var hoursThrottling: Double

    /// Mean SoC temperature over the older and newer halves of the window.
    /// A rising baseline across an unchanged workload is the classic dust /
    /// failing-fan / degraded-paste signature — and, being a comparison of
    /// this Mac against its own past, it's exactly the kind of claim this
    /// codebase is willing to make.
    public var meanFirstHalfCelsius: Double?
    public var meanSecondHalfCelsius: Double?

    public static let sustainedHeatThreshold: Double = 90
    public static let sustainedHeatMinimumRun: TimeInterval = 30 * 60

    public init(
        daysWithData: Int = 0,
        sampleCount: Int = 0,
        meanSoCTemperatureCelsius: Double? = nil,
        peakSoCTemperatureCelsius: Double? = nil,
        fractionAtOrAbove80: Double? = nil,
        fractionAtOrAbove95: Double? = nil,
        hoursAtOrAbove95: Double = 0,
        daysWithSustainedHeat: Int = 0,
        throttlingFraction: Double? = nil,
        hoursThrottling: Double = 0,
        meanFirstHalfCelsius: Double? = nil,
        meanSecondHalfCelsius: Double? = nil
    ) {
        self.daysWithData = daysWithData
        self.sampleCount = sampleCount
        self.meanSoCTemperatureCelsius = meanSoCTemperatureCelsius
        self.peakSoCTemperatureCelsius = peakSoCTemperatureCelsius
        self.fractionAtOrAbove80 = fractionAtOrAbove80
        self.fractionAtOrAbove95 = fractionAtOrAbove95
        self.hoursAtOrAbove95 = hoursAtOrAbove95
        self.daysWithSustainedHeat = daysWithSustainedHeat
        self.throttlingFraction = throttlingFraction
        self.hoursThrottling = hoursThrottling
        self.meanFirstHalfCelsius = meanFirstHalfCelsius
        self.meanSecondHalfCelsius = meanSecondHalfCelsius
    }

    public static func make(
        socTemperatureCelsius: MetricSampleSeries,
        isThrottling: MetricSampleSeries,
        calendar: Calendar = .current
    ) -> ThermalHistorySummary {
        let temps = InsightAggregates.cleaned(socTemperatureCelsius)
        let throttle = InsightAggregates.cleaned(isThrottling)
        // Each series gets a gap cap matched to its own cadence — see
        // `InsightAggregates.recommendedGapCap` for why a fixed cap silently
        // zeroes every duration when the query lands on the hourly tier.
        let tempGap = InsightAggregates.recommendedGapCap(temps)
        let throttleGap = InsightAggregates.recommendedGapCap(throttle)

        // Split at the window's midpoint in *time*, not by sample count: an
        // uneven sampling cadence (adaptive throttling slows polling while
        // the popover is closed) would otherwise put wall-clock-unequal
        // halves on either side of the comparison.
        var firstHalfMean: Double?
        var secondHalfMean: Double?
        if let first = temps.first, let last = temps.last, temps.count >= 8 {
            let midpoint = first.timestamp.addingTimeInterval(
                last.timestamp.timeIntervalSince(first.timestamp) / 2
            )
            let older = temps.filter { $0.timestamp < midpoint }
            let newer = temps.filter { $0.timestamp >= midpoint }
            if older.count >= 3, newer.count >= 3 {
                firstHalfMean = InsightAggregates.mean(older)
                secondHalfMean = InsightAggregates.mean(newer)
            }
        }

        return ThermalHistorySummary(
            daysWithData: InsightAggregates.daysWithData(temps, calendar: calendar),
            sampleCount: temps.count,
            meanSoCTemperatureCelsius: InsightAggregates.mean(temps),
            peakSoCTemperatureCelsius: InsightAggregates.maximum(temps),
            fractionAtOrAbove80: InsightAggregates.fractionOfSamples(temps, atOrAbove: 80),
            fractionAtOrAbove95: InsightAggregates.fractionOfSamples(temps, atOrAbove: 95),
            hoursAtOrAbove95: InsightAggregates.secondsAtOrAbove(temps, threshold: 95, maximumGap: tempGap) / 3600,
            daysWithSustainedHeat: InsightAggregates.daysWithSustainedRun(
                temps,
                threshold: sustainedHeatThreshold,
                minimumRunSeconds: sustainedHeatMinimumRun,
                maximumGap: tempGap,
                calendar: calendar
            ),
            throttlingFraction: InsightAggregates.fractionOfSamples(throttle, atOrAbove: 0.5),
            hoursThrottling: InsightAggregates.secondsAtOrAbove(throttle, threshold: 0.5, maximumGap: throttleGap) / 3600,
            meanFirstHalfCelsius: firstHalfMean,
            meanSecondHalfCelsius: secondHalfMean
        )
    }
}

// MARK: - Load

/// Sustained compute load — what actually generates the heat the thermal
/// summary measures.
public struct LoadHistorySummary: Sendable, Equatable {

    public var daysWithData: Int
    public var cpuSampleCount: Int

    public var meanCPUPercent: Double?
    public var peakCPUPercent: Double?
    public var fractionCPUAtOrAbove90: Double?

    /// Days containing a run of `sustainedLoadMinimumRun` or more at or
    /// above 90% CPU.
    public var daysWithSustainedCPU: Int
    /// The single longest such run anywhere in the window, in hours.
    public var longestCPURunHours: Double

    public var meanGPUPercent: Double?
    public var fractionGPUAtOrAbove80: Double?
    public var daysWithSustainedGPU: Int

    public static let sustainedLoadMinimumRun: TimeInterval = 3 * 3600

    public init(
        daysWithData: Int = 0,
        cpuSampleCount: Int = 0,
        meanCPUPercent: Double? = nil,
        peakCPUPercent: Double? = nil,
        fractionCPUAtOrAbove90: Double? = nil,
        daysWithSustainedCPU: Int = 0,
        longestCPURunHours: Double = 0,
        meanGPUPercent: Double? = nil,
        fractionGPUAtOrAbove80: Double? = nil,
        daysWithSustainedGPU: Int = 0
    ) {
        self.daysWithData = daysWithData
        self.cpuSampleCount = cpuSampleCount
        self.meanCPUPercent = meanCPUPercent
        self.peakCPUPercent = peakCPUPercent
        self.fractionCPUAtOrAbove90 = fractionCPUAtOrAbove90
        self.daysWithSustainedCPU = daysWithSustainedCPU
        self.longestCPURunHours = longestCPURunHours
        self.meanGPUPercent = meanGPUPercent
        self.fractionGPUAtOrAbove80 = fractionGPUAtOrAbove80
        self.daysWithSustainedGPU = daysWithSustainedGPU
    }

    public static func make(
        cpuTotalPercent: MetricSampleSeries,
        gpuUtilizationPercent: MetricSampleSeries,
        calendar: Calendar = .current
    ) -> LoadHistorySummary {
        let cpu = InsightAggregates.cleaned(cpuTotalPercent)
        let gpu = InsightAggregates.cleaned(gpuUtilizationPercent)
        let cpuGap = InsightAggregates.recommendedGapCap(cpu)
        let gpuGap = InsightAggregates.recommendedGapCap(gpu)

        return LoadHistorySummary(
            daysWithData: InsightAggregates.daysWithData(cpu, calendar: calendar),
            cpuSampleCount: cpu.count,
            meanCPUPercent: InsightAggregates.mean(cpu),
            peakCPUPercent: InsightAggregates.maximum(cpu),
            fractionCPUAtOrAbove90: InsightAggregates.fractionOfSamples(cpu, atOrAbove: 90),
            daysWithSustainedCPU: InsightAggregates.daysWithSustainedRun(
                cpu,
                threshold: 90,
                minimumRunSeconds: sustainedLoadMinimumRun,
                maximumGap: cpuGap,
                calendar: calendar
            ),
            longestCPURunHours: InsightAggregates.longestRunSecondsAtOrAbove(cpu, threshold: 90, maximumGap: cpuGap) / 3600,
            meanGPUPercent: InsightAggregates.mean(gpu),
            fractionGPUAtOrAbove80: InsightAggregates.fractionOfSamples(gpu, atOrAbove: 80),
            daysWithSustainedGPU: InsightAggregates.daysWithSustainedRun(
                gpu,
                threshold: 80,
                minimumRunSeconds: sustainedLoadMinimumRun,
                maximumGap: gpuGap,
                calendar: calendar
            )
        )
    }
}

// MARK: - Memory

/// Memory pressure and swap behaviour.
///
/// **Why used-percent rather than `memory.pressure_percent`.**
/// `HistoryStore.memoryPairs` records `memory.used_bytes` /
/// `wired_bytes` / `compressed_bytes` / `cached_bytes` / `swap_used_bytes`
/// but deliberately does *not* record a pressure level, so there is no
/// pressure history in the database to read. Used-bytes over this Mac's
/// installed RAM (a constant from `DeviceFacts`) is the honest available
/// proxy, and the strings this feature renders say "memory in use," never
/// "memory pressure was critical," because the latter is a claim the stored
/// data can't support.
public struct MemoryHistorySummary: Sendable, Equatable {

    public var daysWithData: Int
    public var sampleCount: Int

    public var meanUsedPercent: Double?
    public var peakUsedPercent: Double?
    public var fractionUsedAtOrAbove85: Double?

    public var meanCompressedBytes: Double?
    public var peakCompressedBytes: Double?

    public var peakSwapUsedBytes: Double?
    public var meanSwapUsedBytes: Double?
    /// Sum of every rise in swap usage across the window — a *lower bound*
    /// on bytes written to swap. See `InsightAggregates.cumulativeIncrease`.
    public var swapGrowthBytes: Double
    public var daysWithSwapAboveGigabyte: Int

    public init(
        daysWithData: Int = 0,
        sampleCount: Int = 0,
        meanUsedPercent: Double? = nil,
        peakUsedPercent: Double? = nil,
        fractionUsedAtOrAbove85: Double? = nil,
        meanCompressedBytes: Double? = nil,
        peakCompressedBytes: Double? = nil,
        peakSwapUsedBytes: Double? = nil,
        meanSwapUsedBytes: Double? = nil,
        swapGrowthBytes: Double = 0,
        daysWithSwapAboveGigabyte: Int = 0
    ) {
        self.daysWithData = daysWithData
        self.sampleCount = sampleCount
        self.meanUsedPercent = meanUsedPercent
        self.peakUsedPercent = peakUsedPercent
        self.fractionUsedAtOrAbove85 = fractionUsedAtOrAbove85
        self.meanCompressedBytes = meanCompressedBytes
        self.peakCompressedBytes = peakCompressedBytes
        self.peakSwapUsedBytes = peakSwapUsedBytes
        self.meanSwapUsedBytes = meanSwapUsedBytes
        self.swapGrowthBytes = swapGrowthBytes
        self.daysWithSwapAboveGigabyte = daysWithSwapAboveGigabyte
    }

    public static let oneGigabyte: Double = 1_073_741_824

    public static func make(
        usedBytes: MetricSampleSeries,
        compressedBytes: MetricSampleSeries,
        swapUsedBytes: MetricSampleSeries,
        totalMemoryBytes: UInt64?,
        calendar: Calendar = .current
    ) -> MemoryHistorySummary {
        let used = InsightAggregates.cleaned(usedBytes)
        let swap = InsightAggregates.cleaned(swapUsedBytes)

        // `nil` total means no honest percentage exists — leave the percent
        // fields nil rather than dividing by a guess.
        let usedPercent: MetricSampleSeries
        if let total = totalMemoryBytes, total > 0 {
            let denominator = Double(total)
            usedPercent = used.map { (timestamp: $0.timestamp, value: $0.value / denominator * 100) }
        } else {
            usedPercent = []
        }

        let swapExtremes = InsightAggregates.dailyExtremes(swap, calendar: calendar)

        return MemoryHistorySummary(
            daysWithData: InsightAggregates.daysWithData(used, calendar: calendar),
            sampleCount: used.count,
            meanUsedPercent: InsightAggregates.mean(usedPercent),
            peakUsedPercent: InsightAggregates.maximum(usedPercent),
            fractionUsedAtOrAbove85: InsightAggregates.fractionOfSamples(usedPercent, atOrAbove: 85),
            meanCompressedBytes: InsightAggregates.mean(compressedBytes),
            peakCompressedBytes: InsightAggregates.maximum(compressedBytes),
            peakSwapUsedBytes: InsightAggregates.maximum(swap),
            meanSwapUsedBytes: InsightAggregates.mean(swap),
            swapGrowthBytes: InsightAggregates.cumulativeIncrease(swap),
            daysWithSwapAboveGigabyte: swapExtremes.filter { $0.maximum >= oneGigabyte }.count
        )
    }
}

// MARK: - Storage

/// Startup-volume headroom and write volume.
public struct StorageHistorySummary: Sendable, Equatable {

    public var daysWithData: Int
    public var sampleCount: Int

    public var meanFreePercent: Double?
    public var minimumFreePercent: Double?
    public var latestFreePercent: Double?

    /// Consecutive most-recent days whose *best* moment still had under 10%
    /// free — an ongoing squeeze, not one bad afternoon.
    public var consecutiveDaysBelowTenPercentFree: Int

    /// Change in free-percent per day, from an OLS fit. Negative means
    /// filling up.
    public var freePercentSlopePerDay: Double?

    /// Days until free space reaches zero at the fitted rate, capped at a
    /// one-year horizon.
    public var projectedDaysUntilFull: Double?

    /// Time-integrated `disk.write_bytes_per_sec`. A best-effort estimate of
    /// bytes written across the window, using the same left-Riemann,
    /// gap-capped convention as `EnergyIntegrator`.
    public var estimatedBytesWritten: Double
    /// Wall-clock days the write estimate actually covers, so the caller can
    /// say "in the last 6 days" rather than implying the whole window.
    public var writeWindowDays: Double?

    public init(
        daysWithData: Int = 0,
        sampleCount: Int = 0,
        meanFreePercent: Double? = nil,
        minimumFreePercent: Double? = nil,
        latestFreePercent: Double? = nil,
        consecutiveDaysBelowTenPercentFree: Int = 0,
        freePercentSlopePerDay: Double? = nil,
        projectedDaysUntilFull: Double? = nil,
        estimatedBytesWritten: Double = 0,
        writeWindowDays: Double? = nil
    ) {
        self.daysWithData = daysWithData
        self.sampleCount = sampleCount
        self.meanFreePercent = meanFreePercent
        self.minimumFreePercent = minimumFreePercent
        self.latestFreePercent = latestFreePercent
        self.consecutiveDaysBelowTenPercentFree = consecutiveDaysBelowTenPercentFree
        self.freePercentSlopePerDay = freePercentSlopePerDay
        self.projectedDaysUntilFull = projectedDaysUntilFull
        self.estimatedBytesWritten = estimatedBytesWritten
        self.writeWindowDays = writeWindowDays
    }

    /// - Parameters:
    ///   - usedPercent: the `disk.used_percent` series `HistoryStore` records.
    ///     Converted to free-percent here so every field below reads in the
    ///     direction the rules and the UI talk in ("headroom").
    ///   - writeBytesPerSecond: the `disk.write_bytes_per_sec` series.
    public static func make(
        usedPercent: MetricSampleSeries,
        writeBytesPerSecond: MetricSampleSeries,
        calendar: Calendar = .current
    ) -> StorageHistorySummary {
        let used = InsightAggregates.cleaned(usedPercent)
        let free: MetricSampleSeries = used.map { (timestamp: $0.timestamp, value: 100 - $0.value) }
        let extremes = InsightAggregates.dailyExtremes(free, calendar: calendar)

        // A day counts as squeezed only if even its *most* free moment was
        // under 10% — the strong reading, so the claim can't be produced by
        // a single transient dip.
        let streak = InsightAggregates.currentConsecutiveDayStreak(extremes, calendar: calendar) {
            $0.maximum < 10
        }

        let writes = InsightAggregates.cleaned(writeBytesPerSecond)
        let writeGap = InsightAggregates.recommendedGapCap(writes)
        var writtenBytes: Double = 0
        if writes.count >= 2 {
            for index in 1..<writes.count {
                let previous = writes[index - 1]
                guard previous.value > 0 else { continue }
                let gap = writes[index].timestamp.timeIntervalSince(previous.timestamp)
                guard gap > 0 else { continue }
                writtenBytes += previous.value * Swift.min(gap, writeGap)
            }
        }

        return StorageHistorySummary(
            daysWithData: extremes.count,
            sampleCount: used.count,
            meanFreePercent: InsightAggregates.mean(free),
            minimumFreePercent: InsightAggregates.minimum(free),
            latestFreePercent: free.last?.value,
            consecutiveDaysBelowTenPercentFree: streak,
            freePercentSlopePerDay: InsightAggregates.slopePerDay(free),
            projectedDaysUntilFull: InsightAggregates.projectedDaysUntil(free, reaches: 0),
            estimatedBytesWritten: writtenBytes,
            writeWindowDays: InsightAggregates.observedSpanDays(writes)
        )
    }
}

// MARK: - Power habits

/// Adapter behaviour and how long this Mac goes between restarts.
public struct PowerHabitsSummary: Sendable, Equatable {

    /// `ProcessInfo.systemUptime` in days, carried through from
    /// `DeviceFacts` so rules read one summary rather than two.
    public var uptimeDays: Double?

    public var meanSystemPowerWatts: Double?
    public var peakSystemPowerWatts: Double?

    /// The adapter rating the snapshot currently reports, in watts.
    public var adapterRatedWatts: Int?

    /// Fraction of system-power samples that exceeded `adapterRatedWatts` —
    /// i.e. how often this Mac was draining its battery *while plugged in*
    /// because the adapter couldn't keep up.
    public var fractionDrawAboveAdapterRating: Double?

    /// A keep-awake assertion is live right now (from the snapshot, not
    /// history — `HistoryStore` doesn't flatten `sleepAssertion`).
    public var keepAwakeActive: Bool

    public init(
        uptimeDays: Double? = nil,
        meanSystemPowerWatts: Double? = nil,
        peakSystemPowerWatts: Double? = nil,
        adapterRatedWatts: Int? = nil,
        fractionDrawAboveAdapterRating: Double? = nil,
        keepAwakeActive: Bool = false
    ) {
        self.uptimeDays = uptimeDays
        self.meanSystemPowerWatts = meanSystemPowerWatts
        self.peakSystemPowerWatts = peakSystemPowerWatts
        self.adapterRatedWatts = adapterRatedWatts
        self.fractionDrawAboveAdapterRating = fractionDrawAboveAdapterRating
        self.keepAwakeActive = keepAwakeActive
    }

    public static func make(
        systemPowerWatts: MetricSampleSeries,
        adapterRatedWatts: Int?,
        uptimeSeconds: TimeInterval?,
        keepAwakeActive: Bool
    ) -> PowerHabitsSummary {
        let power = InsightAggregates.cleaned(systemPowerWatts)
        var overRating: Double?
        if let rating = adapterRatedWatts, rating > 0 {
            overRating = InsightAggregates.fractionOfSamples(power, atOrAbove: Double(rating))
        }

        return PowerHabitsSummary(
            uptimeDays: uptimeSeconds.map { $0 / 86_400 },
            meanSystemPowerWatts: InsightAggregates.mean(power),
            peakSystemPowerWatts: InsightAggregates.maximum(power),
            adapterRatedWatts: adapterRatedWatts,
            fractionDrawAboveAdapterRating: overRating,
            keepAwakeActive: keepAwakeActive
        )
    }
}
