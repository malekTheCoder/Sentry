import Foundation

/// The one impure piece of Protection Insights: turns `HistoryStore` rows
/// plus a live snapshot into the plain-value `InsightContext` the engine
/// consumes.
///
/// **Same "pure calculation, impure caller" split** as
/// `DashboardViewModel.refreshAnomalies` / `AnomalyDetector`, and for the
/// same reason: the arithmetic (`InsightAggregates`, the summaries, every
/// rule) stays testable without SQLite, and the querying lives in exactly
/// one place instead of being scattered across forty rules.
///
/// **Cost.** One `HistoryStore.samples(metric:since:)` read per metric
/// below — fifteen reads. That is far too much to run on the ~3 s snapshot
/// tick and it deliberately isn't: `InsightsViewModel` calls this on window
/// appearance and on explicit refresh only, exactly as `DashboardViewModel`
/// documents for its own history path.
public struct InsightContextBuilder: Sendable {

    /// 30 days is the shortest window over which battery capacity loss and
    /// thermal baseline drift produce a signal worth reporting, and it sits
    /// inside `HistoryStore`'s hourly tier (90 days) so the query never
    /// falls through to the coarse daily rollup.
    public static let defaultWindowDays = 30

    private let historyStore: HistoryStore

    public init(historyStore: HistoryStore) {
        self.historyStore = historyStore
    }

    /// - Parameters:
    ///   - snapshot: the latest live reading, for "right now" facts
    ///     (current free space, an active keep-awake hold, the current
    ///     Wi-Fi network). `nil` before the first tick.
    ///   - posture: from `SecurityPostureProviding`. Pass
    ///     `SecurityPosture.unknownPosture()` when it hasn't been collected
    ///     yet — never a fabricated all-clear.
    ///   - now: injectable so a test's context is deterministic.
    public func build(
        snapshot: SystemSnapshot?,
        posture: SecurityPosture,
        settings: InsightSettingsSnapshot,
        windowDays: Int = InsightContextBuilder.defaultWindowDays,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> InsightContext {
        let since = now.addingTimeInterval(-Double(windowDays) * 86_400)

        func series(_ metric: MetricID) -> MetricSampleSeries {
            historyStore.samples(metric: metric.rawValue, since: since)
        }

        // Battery
        let chargePercent = series(.batteryChargePercent)
        let healthPercent = series(.batteryHealthPercent)
        let cycleCount = series(.batteryCycleCount)
        let batteryTemperature = series(.batteryTemperatureC)
        // Present only while charging — see `BatteryHistorySummary`'s doc
        // comment on why the mere existence of a row here is the charging
        // signal.
        let chargingWatts = series(.batteryChargingWatts)
        let systemPower = series(.batterySystemPowerWatts)

        // Thermal & load
        let socTemperature = series(.thermalSocTempC)
        let isThrottling = series(.thermalIsThrottling)
        let cpuPercent = series(.cpuTotalPercent)
        let gpuPercent = series(.gpuUtilizationPercent)

        // Memory
        let memoryUsed = series(.memoryUsedBytes)
        let memoryCompressed = series(.memoryCompressedBytes)
        let swapUsed = series(.memorySwapUsedBytes)

        // Storage
        let diskUsedPercent = series(.diskUsedPercent)
        let diskWrite = series(.diskWriteBytesPerSec)

        let device = DeviceFacts.current(startupVolumeTotalBytes: snapshot?.disk?.totalBytes)

        // Coverage is the union across the three series every Mac records
        // unconditionally, so a machine with (say) no thermal sensor still
        // reports its true history depth rather than zero.
        var coverageDays = Set<Date>()
        for sampleSeries in [cpuPercent, chargePercent, diskUsedPercent] {
            for sample in sampleSeries where sample.value.isFinite {
                coverageDays.insert(calendar.startOfDay(for: sample.timestamp))
            }
        }

        let battery: BatteryHistorySummary? = (chargePercent.isEmpty && healthPercent.isEmpty && cycleCount.isEmpty)
            ? nil
            : BatteryHistorySummary.make(
                chargePercent: chargePercent,
                healthPercent: healthPercent,
                cycleCount: cycleCount,
                batteryTemperatureCelsius: batteryTemperature,
                chargingWatts: chargingWatts,
                socTemperatureCelsius: socTemperature,
                calendar: calendar
            )

        let thermal: ThermalHistorySummary? = (socTemperature.isEmpty && isThrottling.isEmpty)
            ? nil
            : ThermalHistorySummary.make(
                socTemperatureCelsius: socTemperature,
                isThrottling: isThrottling,
                calendar: calendar
            )

        let load: LoadHistorySummary? = (cpuPercent.isEmpty && gpuPercent.isEmpty)
            ? nil
            : LoadHistorySummary.make(
                cpuTotalPercent: cpuPercent,
                gpuUtilizationPercent: gpuPercent,
                calendar: calendar
            )

        let memory: MemoryHistorySummary? = (memoryUsed.isEmpty && swapUsed.isEmpty)
            ? nil
            : MemoryHistorySummary.make(
                usedBytes: memoryUsed,
                compressedBytes: memoryCompressed,
                swapUsedBytes: swapUsed,
                totalMemoryBytes: snapshot?.memory?.totalBytes ?? device.physicalMemoryBytes,
                calendar: calendar
            )

        let storage: StorageHistorySummary? = (diskUsedPercent.isEmpty && diskWrite.isEmpty)
            ? nil
            : StorageHistorySummary.make(
                usedPercent: diskUsedPercent,
                writeBytesPerSecond: diskWrite,
                calendar: calendar
            )

        var keepAwakeActive = false
        if let assertion = snapshot?.sleepAssertion, case .active = assertion {
            keepAwakeActive = true
        }

        let powerHabits = PowerHabitsSummary.make(
            systemPowerWatts: systemPower,
            adapterRatedWatts: snapshot?.battery?.adapterRatedWatts,
            uptimeSeconds: device.uptimeSeconds,
            keepAwakeActive: keepAwakeActive
        )

        return InsightContext(
            now: now,
            snapshot: snapshot,
            device: device,
            posture: posture,
            battery: battery,
            thermal: thermal,
            load: load,
            memory: memory,
            storage: storage,
            powerHabits: powerHabits,
            settings: settings,
            requestedWindowDays: windowDays,
            historyCoverageDays: coverageDays.count
        )
    }
}
