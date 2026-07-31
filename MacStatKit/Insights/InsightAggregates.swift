import Foundation

/// The exact tuple shape `HistoryStore.samples(metric:since:)` returns, named
/// so the aggregate functions below can be read without re-deriving it.
public typealias MetricSampleSeries = [(timestamp: Date, value: Double)]

/// Pure statistics over a Mac's own recorded history.
///
/// **Why these are free functions over plain sample arrays rather than
/// methods on `HistoryStore`.** Same split `AnomalyDetector`,
/// `BatteryHealthForecast`, and `EnergyIntegrator` already use in this
/// codebase: the arithmetic is the part worth unit-testing, and it has
/// nothing to do with SQLite. `InsightContextBuilder` does the querying;
/// everything here is a deterministic function of its inputs, so a test can
/// hand it fourteen synthetic days and assert on the number.
///
/// **Time-weighting convention.** Anything that answers "for how long" uses
/// left-Riemann steps with a gap cap, exactly as `EnergyIntegrator`
/// documents: each sample's value is assumed to hold until the next sample,
/// but never for longer than `maximumGap`. That cap is what keeps sleep
/// honest — a Mac that slept eight hours between a 97 °C sample and the next
/// one was not at 97 °C for eight hours, and the samples simply aren't there
/// while it sleeps.
public enum InsightAggregates {

    /// Default gap cap. Comfortably above the slowest sampling tier
    /// (`AppSettings.slowTierRefreshInterval`, 30 s by default) and far
    /// below any realistic sleep window. Same value and same reasoning as
    /// `EnergyIntegrator.maximumGap`.
    public static let maximumGap: TimeInterval = 300

    // MARK: - Cleaning

    /// Sorted ascending with non-finite values dropped. Every function here
    /// runs its input through this first, so callers never have to.
    public static func cleaned(_ samples: MetricSampleSeries) -> MetricSampleSeries {
        samples
            .filter { $0.value.isFinite }
            .sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Coverage

    /// Wall-clock days between the first and last sample. `nil` for fewer
    /// than two samples — a single reading spans no time at all, and
    /// reporting "0 days" would invite a caller to divide by it.
    ///
    /// Deliberately *not* "days since `since`": a query window of 30 days
    /// against a 6-day-old install must report 6, or every per-day rate this
    /// feature computes is understated fivefold.
    public static func observedSpanDays(_ samples: MetricSampleSeries) -> Double? {
        let clean = cleaned(samples)
        guard let first = clean.first, let last = clean.last, clean.count >= 2 else { return nil }
        let span = last.timestamp.timeIntervalSince(first.timestamp)
        guard span > 0 else { return nil }
        return span / 86_400
    }

    /// Number of distinct calendar days that contain at least one sample.
    /// The honest denominator for "on N of the last M days" claims — a
    /// window can span 14 days while the Mac was only powered on for 9.
    public static func daysWithData(_ samples: MetricSampleSeries, calendar: Calendar = .current) -> Int {
        var days = Set<Date>()
        for sample in samples where sample.value.isFinite {
            days.insert(calendar.startOfDay(for: sample.timestamp))
        }
        return days.count
    }

    /// The gap cap to use for *this* series, derived from its own observed
    /// cadence.
    ///
    /// **Why a fixed 300 s cap isn't enough.** `HistoryStore` serves a
    /// 30-day query from the **hourly** rollup tier (see its
    /// `samples(metric:since:)` doc comment), where consecutive samples are
    /// 3,600 s apart by construction. A 300 s cap would treat every single
    /// hourly bucket as an isolated island, and every "for how long" figure
    /// in this feature would silently come back as zero — a whole class of
    /// findings failing quietly, which is the worst way for one to fail.
    ///
    /// So the cap follows the data: 2.5× the median inter-sample gap,
    /// floored at 60 s (so a fast raw series doesn't get an absurdly tight
    /// cap from a 3 s median) and ceilinged at 5,400 s. The ceiling is what
    /// keeps sleep honest at hourly resolution — consecutive hourly buckets
    /// (3,600 s) still chain together, but a two-hour hole where the Mac was
    /// asleep does not.
    public static func recommendedGapCap(_ samples: MetricSampleSeries) -> TimeInterval {
        let clean = cleaned(samples)
        guard clean.count >= 3 else { return maximumGap }

        var gaps: [TimeInterval] = []
        gaps.reserveCapacity(clean.count - 1)
        for index in 1..<clean.count {
            let gap = clean[index].timestamp.timeIntervalSince(clean[index - 1].timestamp)
            if gap > 0 { gaps.append(gap) }
        }
        guard !gaps.isEmpty else { return maximumGap }

        gaps.sort()
        let median = gaps[gaps.count / 2]
        return Swift.min(Swift.max(median * 2.5, 60), 5_400)
    }

    // MARK: - Central tendency

    public static func mean(_ samples: MetricSampleSeries) -> Double? {
        let values = samples.map(\.value).filter(\.isFinite)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    public static func maximum(_ samples: MetricSampleSeries) -> Double? {
        samples.map(\.value).filter(\.isFinite).max()
    }

    public static func minimum(_ samples: MetricSampleSeries) -> Double? {
        samples.map(\.value).filter(\.isFinite).min()
    }

    /// Fraction (0…1) of samples satisfying `predicate`. `nil` when there
    /// are no samples at all — "0% of nothing" is not a finding.
    public static func fractionOfSamples(
        _ samples: MetricSampleSeries,
        where predicate: (Double) -> Bool
    ) -> Double? {
        let values = samples.map(\.value).filter(\.isFinite)
        guard !values.isEmpty else { return nil }
        return Double(values.filter(predicate).count) / Double(values.count)
    }

    public static func fractionOfSamples(
        _ samples: MetricSampleSeries,
        atOrAbove threshold: Double
    ) -> Double? {
        fractionOfSamples(samples) { $0 >= threshold }
    }

    public static func fractionOfSamples(
        _ samples: MetricSampleSeries,
        below threshold: Double
    ) -> Double? {
        fractionOfSamples(samples) { $0 < threshold }
    }

    // MARK: - Time above a threshold

    /// Total time the series spent at or above `threshold`, left-Riemann
    /// with `maximumGap` capping. See the type doc comment for why the cap
    /// exists.
    public static func secondsAtOrAbove(
        _ samples: MetricSampleSeries,
        threshold: Double,
        maximumGap: TimeInterval = maximumGap
    ) -> TimeInterval {
        let clean = cleaned(samples)
        guard clean.count >= 2 else { return 0 }

        var total: TimeInterval = 0
        for index in 1..<clean.count {
            let previous = clean[index - 1]
            guard previous.value >= threshold else { continue }
            let gap = clean[index].timestamp.timeIntervalSince(previous.timestamp)
            guard gap > 0 else { continue }
            total += Swift.min(gap, maximumGap)
        }
        return total
    }

    /// The single longest *uninterrupted* stretch at or above `threshold`.
    /// A gap wider than `maximumGap` breaks the run rather than being
    /// counted through — an overnight sleep is not three more hours of
    /// sustained load.
    public static func longestRunSecondsAtOrAbove(
        _ samples: MetricSampleSeries,
        threshold: Double,
        maximumGap: TimeInterval = maximumGap
    ) -> TimeInterval {
        let clean = cleaned(samples)
        guard clean.count >= 2 else { return 0 }

        var longest: TimeInterval = 0
        var current: TimeInterval = 0
        for index in 1..<clean.count {
            let previous = clean[index - 1]
            let gap = clean[index].timestamp.timeIntervalSince(previous.timestamp)
            if previous.value >= threshold, gap > 0, gap <= maximumGap {
                current += gap
                longest = Swift.max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    /// How many calendar days contained a run of at least
    /// `minimumRunSeconds` at or above `threshold`. This is what backs
    /// claims of the shape "3+ hours of pinned CPU on 9 of the last 14
    /// days" — the run is computed per day, so a day is only counted if the
    /// load was genuinely sustained *within* that day.
    public static func daysWithSustainedRun(
        _ samples: MetricSampleSeries,
        threshold: Double,
        minimumRunSeconds: TimeInterval,
        maximumGap: TimeInterval = maximumGap,
        calendar: Calendar = .current
    ) -> Int {
        var byDay: [Date: MetricSampleSeries] = [:]
        for sample in cleaned(samples) {
            byDay[calendar.startOfDay(for: sample.timestamp), default: []].append(sample)
        }
        return byDay.values.filter {
            longestRunSecondsAtOrAbove($0, threshold: threshold, maximumGap: maximumGap) >= minimumRunSeconds
        }.count
    }

    // MARK: - Daily extremes

    /// One day's low/high for a metric.
    public struct DailyExtreme: Sendable, Equatable {
        public var dayStart: Date
        public var minimum: Double
        public var maximum: Double
        public var sampleCount: Int

        public init(dayStart: Date, minimum: Double, maximum: Double, sampleCount: Int) {
            self.dayStart = dayStart
            self.minimum = minimum
            self.maximum = maximum
            self.sampleCount = sampleCount
        }

        /// High minus low. For battery charge this is the day's discharge
        /// depth; for temperature, its swing.
        public var range: Double { maximum - minimum }
    }

    /// Per-calendar-day minimum/maximum, oldest day first.
    ///
    /// Used instead of a peak/trough state machine for battery
    /// discharge-depth analysis: "the deepest your battery went on a given
    /// day" is both simpler to compute correctly and simpler to *state* to
    /// the user than a charge-cycle segmentation heuristic that would need
    /// its own noise thresholds and would still be an approximation.
    public static func dailyExtremes(
        _ samples: MetricSampleSeries,
        calendar: Calendar = .current
    ) -> [DailyExtreme] {
        var byDay: [Date: (min: Double, max: Double, count: Int)] = [:]
        for sample in samples where sample.value.isFinite {
            let day = calendar.startOfDay(for: sample.timestamp)
            if let existing = byDay[day] {
                byDay[day] = (
                    min: Swift.min(existing.min, sample.value),
                    max: Swift.max(existing.max, sample.value),
                    count: existing.count + 1
                )
            } else {
                byDay[day] = (min: sample.value, max: sample.value, count: 1)
            }
        }
        return byDay
            .map { DailyExtreme(dayStart: $0.key, minimum: $0.value.min, maximum: $0.value.max, sampleCount: $0.value.count) }
            .sorted { $0.dayStart < $1.dayStart }
    }

    /// The longest run of consecutive *calendar* days (no gaps) whose
    /// `predicate` held, counting back from the most recent day with data.
    ///
    /// Counting back from the end rather than finding the longest run
    /// anywhere is deliberate: "the disk has been under 10% free for 11
    /// straight days" is an ongoing condition the user can act on, whereas
    /// an 11-day run that ended in March is history.
    public static func currentConsecutiveDayStreak(
        _ extremes: [DailyExtreme],
        calendar: Calendar = .current,
        where predicate: (DailyExtreme) -> Bool
    ) -> Int {
        let ordered = extremes.sorted { $0.dayStart > $1.dayStart }
        var streak = 0
        var expectedDay: Date?
        for day in ordered {
            if let expected = expectedDay, !calendar.isDate(day.dayStart, inSameDayAs: expected) {
                // A calendar day with no data at all breaks the streak —
                // the app cannot claim a condition held on a day it never
                // observed.
                break
            }
            guard predicate(day) else { break }
            streak += 1
            expectedDay = calendar.date(byAdding: .day, value: -1, to: day.dayStart)
        }
        return streak
    }

    // MARK: - Deltas and trends

    /// Sum of every positive step in the series — a lower bound on how much
    /// the underlying quantity grew in total, even if it also shrank in
    /// between.
    ///
    /// This is how swap "written" is estimated: swap *usage* falling and
    /// rising again means bytes really were written the second time, so
    /// summing the rises is closer to the truth than `last - first`. It is
    /// still a lower bound (writes that happened entirely between two
    /// samples at the same level are invisible), and every string this app
    /// renders from it says "at least."
    public static func cumulativeIncrease(_ samples: MetricSampleSeries) -> Double {
        let clean = cleaned(samples)
        guard clean.count >= 2 else { return 0 }
        var total: Double = 0
        for index in 1..<clean.count {
            let delta = clean[index].value - clean[index - 1].value
            if delta > 0 { total += delta }
        }
        return total
    }

    /// Last value minus first value. `nil` for fewer than two samples.
    public static func netChange(_ samples: MetricSampleSeries) -> Double? {
        let clean = cleaned(samples)
        guard let first = clean.first, let last = clean.last, clean.count >= 2 else { return nil }
        return last.value - first.value
    }

    /// Ordinary-least-squares slope in units per day. `nil` when there
    /// aren't at least `minimumSamples` points spanning `minimumSpanDays` —
    /// same "don't let a few hours speak about a month" discipline
    /// `BatteryHealthForecast` applies to its own fit.
    public static func slopePerDay(
        _ samples: MetricSampleSeries,
        minimumSamples: Int = 5,
        minimumSpanDays: Double = 2
    ) -> Double? {
        let clean = cleaned(samples)
        guard clean.count >= minimumSamples, let first = clean.first, let last = clean.last else { return nil }
        let spanDays = last.timestamp.timeIntervalSince(first.timestamp) / 86_400
        guard spanDays >= minimumSpanDays else { return nil }

        let n = Double(clean.count)
        let xs = clean.map { $0.timestamp.timeIntervalSince(first.timestamp) / 86_400 }
        let ys = clean.map(\.value)
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let sumXX = xs.reduce(0) { $0 + $1 * $1 }
        let denominator = n * sumXX - sumX * sumX
        guard denominator > 0 else { return nil }
        return (n * sumXY - sumX * sumY) / denominator
    }

    /// Days until the fitted line reaches `target`, from the most recent
    /// sample. `nil` when there's no defensible fit, when the trend moves
    /// away from the target, or when the answer lands beyond
    /// `horizonDays` — extrapolating a two-week disk-usage slope out three
    /// years is astrology, not a forecast (`BatteryHealthForecast.horizon`
    /// makes the same call for the same reason).
    public static func projectedDaysUntil(
        _ samples: MetricSampleSeries,
        reaches target: Double,
        horizonDays: Double = 365
    ) -> Double? {
        let clean = cleaned(samples)
        guard let last = clean.last, let slope = slopePerDay(clean), slope != 0 else { return nil }
        let distance = target - last.value
        // Moving away from (or already past) the target.
        guard distance / slope > 0 else { return nil }
        let days = distance / slope
        guard days.isFinite, days > 0, days <= horizonDays else { return nil }
        return days
    }

    // MARK: - Coincidence between two series

    /// How often a `trigger` sample coincided in time with the `condition`
    /// series being at or above `conditionThreshold`.
    ///
    /// This is what lets the app say "you charged while the SoC was already
    /// over 90 °C" — two metrics recorded on different sampling tiers, with
    /// no shared row in `sample_raw` to join on. Pairs each trigger sample
    /// with its nearest condition sample and ignores pairs further apart
    /// than `tolerance`, so a trigger with no contemporaneous temperature
    /// reading is excluded from the denominator rather than assumed cool.
    ///
    /// Returns `nil` when no pair fell inside `tolerance` — there is nothing
    /// to report, which is different from "it never happened."
    public static func coincidence(
        trigger: MetricSampleSeries,
        condition: MetricSampleSeries,
        conditionThreshold: Double,
        tolerance: TimeInterval = 120
    ) -> (matching: Int, comparable: Int)? {
        let triggers = cleaned(trigger)
        let conditions = cleaned(condition)
        guard !triggers.isEmpty, !conditions.isEmpty else { return nil }

        var conditionIndex = 0
        var matching = 0
        var comparable = 0

        for sample in triggers {
            // `triggers` is ascending, so the nearest condition index never
            // moves backwards — one forward scan across both series total.
            while conditionIndex + 1 < conditions.count {
                let currentDistance = abs(conditions[conditionIndex].timestamp.timeIntervalSince(sample.timestamp))
                let nextDistance = abs(conditions[conditionIndex + 1].timestamp.timeIntervalSince(sample.timestamp))
                guard nextDistance <= currentDistance else { break }
                conditionIndex += 1
            }
            let nearest = conditions[conditionIndex]
            guard abs(nearest.timestamp.timeIntervalSince(sample.timestamp)) <= tolerance else { continue }
            comparable += 1
            if nearest.value >= conditionThreshold { matching += 1 }
        }

        guard comparable > 0 else { return nil }
        return (matching: matching, comparable: comparable)
    }
}
