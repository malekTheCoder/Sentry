import Foundation

/// The pure arithmetic behind interactive chart scrubbing and honest gap
/// rendering, shared by `Sentry/Dashboard/DashboardChart.swift` (and
/// `ActivityOverlayChart` in the same file) and
/// `SentryMobile/History/BatteryHealthTrendChart.swift`.
///
/// **Why this lives in `SentryKit` and not next to the views.** Both apps draw
/// charts over the same shape of data, and the two questions a scrubbing chart
/// has to answer — *which sample is the pointer over?* and *is there actually
/// any data there?* — are arithmetic, not rendering. Keeping them here means
/// one implementation, one set of tests (`SentryTests/ChartScrubbingTests.swift`),
/// and no chance of macOS and iOS disagreeing about what counts as a gap. It
/// is Foundation-only for the same reason the rest of `SentryKit/History` is:
/// `SentryKit_iOS` builds without GRDB and without any AppKit/UIKit surface.
///
/// **Rejected alternative — resolve the pointer position by interpolating the
/// series.** Swift Charts hands back a continuous `Date` for a pointer x, and
/// the obvious next step is to interpolate a y between the two bracketing
/// samples so the readout tracks the drawn (monotone-smoothed) curve exactly.
/// That number would be a fabrication: the curve between two samples is a
/// drawing artifact of `.interpolationMethod(.monotone)`, not a measurement.
/// Everything here snaps to a real row instead, and says "no data" when the
/// nearest real row is too far away to stand in for where the pointer is.
public enum ChartScrubbing {

    // MARK: - Cadence

    /// How far apart consecutive plotted points are *expected* to be, given
    /// the tier the rows came from and how hard they were downsampled.
    ///
    /// Derived rather than hardcoded, because both inputs are known at query
    /// time: `TimeRangePicker.queryWindow` picks the tier (and therefore the
    /// row cadence — raw rows arrive at `AppSettings.globalRefreshInterval`,
    /// hourly rollups once an hour, daily rollups once a day), and
    /// `DashboardViewModel.downsample` folds `inputCount` rows into at most
    /// `outputCount` buckets, which multiplies the spacing by exactly
    /// `inputCount / outputCount`.
    ///
    /// - Returns: `baseInterval` scaled by the downsample factor; never less
    ///   than `baseInterval` (a series under the cap is not downsampled at
    ///   all, so the factor floors at 1).
    public static func expectedCadence(
        baseInterval: TimeInterval,
        inputCount: Int,
        outputCount: Int
    ) -> TimeInterval {
        guard baseInterval > 0 else { return 0 }
        guard inputCount > 0, outputCount > 0, inputCount > outputCount else { return baseInterval }
        return baseInterval * (Double(inputCount) / Double(outputCount))
    }

    /// The median spacing between consecutive timestamps, or `nil` for a
    /// series of fewer than two points.
    ///
    /// Used as a floor under `expectedCadence` rather than as a replacement
    /// for it. The median is robust — a handful of overnight gaps barely move
    /// it — but it is derived from the data, so on a series that is *entirely*
    /// gap (a Mac that ran for ten minutes a day) it would report the gap
    /// spacing as normal and hide the thing this file exists to expose. The
    /// declared cadence can't drift that way; the median only ever raises it,
    /// covering the case where rows are genuinely sparser than the tier
    /// implies (a rollup tier with missing buckets, or a metric a module only
    /// reports occasionally).
    public static func medianSpacing(_ timestamps: [Date]) -> TimeInterval? {
        guard timestamps.count >= 2 else { return nil }
        var spacings: [TimeInterval] = []
        spacings.reserveCapacity(timestamps.count - 1)
        for index in 1..<timestamps.count {
            spacings.append(timestamps[index].timeIntervalSince(timestamps[index - 1]))
        }
        spacings.sort()
        let middle = spacings.count / 2
        if spacings.count.isMultiple(of: 2) {
            return (spacings[middle - 1] + spacings[middle]) / 2
        }
        return spacings[middle]
    }

    /// The cadence a chart should actually reason with: the declared
    /// expectation, raised to the observed median if the data is sparser than
    /// declared. See `medianSpacing` for why it is a floor and not a
    /// substitute.
    public static func effectiveCadence(
        expected: TimeInterval?,
        timestamps: [Date]
    ) -> TimeInterval? {
        let observed = medianSpacing(timestamps)
        switch (expected, observed) {
        case let (declared?, measured?): return Swift.max(declared, measured)
        case let (declared?, nil): return declared
        case let (nil, measured?): return measured
        case (nil, nil): return nil
        }
    }

    // MARK: - Gaps

    /// How many expected sample intervals must pass with no row before the
    /// line is broken.
    ///
    /// 2.5 rather than 1.5 or 2: a single dropped sample is ordinary jitter —
    /// the snapshot loop can miss a tick under load, and an hourly rollup
    /// bucket can land a few seconds either side of the hour — and breaking
    /// the stroke for that would turn a healthy chart into a dashed mess. At
    /// 2.5 the line only breaks once at least two consecutive expected samples
    /// are missing, which is the shortest interruption that means something
    /// actually stopped rather than slipped. It is deliberately *not* tuned to
    /// "long enough that only sleep shows up": a five-minute crash of the
    /// sampling loop is exactly as much of a lie to paper over as an overnight
    /// sleep is.
    public static let gapCadenceMultiplier: Double = 2.5

    /// A stretch of time between two consecutive samples that is longer than
    /// the series' cadence can explain.
    public struct Gap: Equatable, Sendable {
        /// Timestamp of the last sample before the gap.
        public let start: Date
        /// Timestamp of the first sample after the gap.
        public let end: Date

        public init(start: Date, end: Date) {
            self.start = start
            self.end = end
        }

        public var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// The threshold spacing above which two consecutive samples are
    /// considered to have a gap between them.
    public static func gapThreshold(cadence: TimeInterval) -> TimeInterval {
        cadence * gapCadenceMultiplier
    }

    /// Every gap in `timestamps`, in order. Empty when the series is dense,
    /// which is the common case — callers can cheaply skip all gap handling on
    /// an empty result.
    ///
    /// - Parameter timestamps: ascending, as every `HistoryStore` read path
    ///   already guarantees. Non-ascending input is not rejected (this is a
    ///   drawing helper, not a validator) but produces negative spacings,
    ///   which are never above the threshold and so are simply not gaps.
    public static func gaps(timestamps: [Date], threshold: TimeInterval) -> [Gap] {
        guard timestamps.count >= 2, threshold > 0 else { return [] }
        var result: [Gap] = []
        for index in 1..<timestamps.count {
            let previous = timestamps[index - 1]
            let current = timestamps[index]
            if current.timeIntervalSince(previous) > threshold {
                result.append(Gap(start: previous, end: current))
            }
        }
        return result
    }

    /// The series split into contiguous runs of indices with no gap inside
    /// them — one `LineMark` series per run, so no stroke ever spans a period
    /// with no data.
    ///
    /// Returned as index ranges rather than as sliced sample arrays so the
    /// caller can keep whatever element type it already has (the Dashboard's
    /// `(timestamp, min, avg, max)` tuple, the phone's `DailyHealth`) instead
    /// of this file needing to know about either.
    ///
    /// A gapless series returns exactly one range covering everything, so the
    /// segmented drawing path and the old single-line path produce identical
    /// output when nothing is missing — that equivalence is what lets the
    /// chart use the segmented path unconditionally.
    public static func segments(timestamps: [Date], threshold: TimeInterval) -> [Range<Int>] {
        guard !timestamps.isEmpty else { return [] }
        guard timestamps.count >= 2, threshold > 0 else { return [0..<timestamps.count] }
        var result: [Range<Int>] = []
        var start = 0
        for index in 1..<timestamps.count {
            if timestamps[index].timeIntervalSince(timestamps[index - 1]) > threshold {
                result.append(start..<index)
                start = index
            }
        }
        result.append(start..<timestamps.count)
        return result
    }

    // MARK: - Scrubbing

    /// What the pointer is actually over.
    public enum Reading: Equatable, Sendable {
        /// The index of the nearest real sample — the only thing a readout is
        /// ever allowed to show a number for.
        case sample(index: Int)
        /// The pointer is somewhere the series has no measurement: inside a
        /// gap, or off either end of the data. The readout says so rather than
        /// borrowing the neighbouring sample's value.
        case noData
    }

    /// Resolves a pointer position to a sample, or to an honest "nothing was
    /// recorded here".
    ///
    /// The snap radius is one `cadence`, not `gapThreshold`: the nearest
    /// sample in a dense series is at most half a cadence away, so a full
    /// cadence snaps every real point comfortably while still refusing to
    /// reach across a genuine gap. Using the (2.5×) gap threshold as the
    /// radius instead would let a pointer sitting two whole missing samples
    /// deep into an overnight gap still read out 11pm's CPU, which is the
    /// exact dishonesty this type exists to prevent.
    ///
    /// - Parameters:
    ///   - date: the continuous x value under the pointer, as Swift Charts
    ///     reports it.
    ///   - timestamps: ascending sample times.
    ///   - cadence: from `effectiveCadence(expected:timestamps:)`.
    /// - Returns: `nil` only when there are no samples at all — a caller with
    ///   an empty series has nothing to draw and no readout to show, which is
    ///   a different state from "this particular spot has no data".
    public static func resolve(
        at date: Date,
        timestamps: [Date],
        cadence: TimeInterval
    ) -> Reading? {
        guard !timestamps.isEmpty else { return nil }
        guard let nearest = nearestIndex(to: date, timestamps: timestamps) else { return nil }
        guard cadence > 0 else { return .sample(index: nearest) }
        let distance = abs(timestamps[nearest].timeIntervalSince(date))
        return distance <= cadence ? .sample(index: nearest) : .noData
    }

    /// Index of the sample whose timestamp is closest to `date`.
    ///
    /// Binary search rather than a linear scan: this runs on every pointer
    /// move (every mouse-move event on macOS, every touch update on iOS) over
    /// a series of up to `DashboardViewModel.maxPointsPerSeries` points, and a
    /// hover handler is not a place to spend a linear pass per frame.
    ///
    /// Ties (a `date` exactly between two samples) resolve to the earlier
    /// sample — arbitrary, but fixed, so a pointer sitting still never flickers
    /// between two readouts.
    public static func nearestIndex(to date: Date, timestamps: [Date]) -> Int? {
        guard !timestamps.isEmpty else { return nil }
        var low = 0
        var high = timestamps.count - 1
        while low < high {
            let mid = (low + high) / 2
            if timestamps[mid] < date {
                low = mid + 1
            } else {
                high = mid
            }
        }
        // `low` is now the first index at or after `date`; the nearest sample
        // is either it or the one before it.
        guard low > 0 else { return low }
        let earlier = abs(timestamps[low - 1].timeIntervalSince(date))
        let later = abs(timestamps[low].timeIntervalSince(date))
        return earlier <= later ? low - 1 : low
    }

    // MARK: - Summary

    /// The true extremes across a ranged series — the lowest `min` any bucket
    /// saw and the highest `max`.
    ///
    /// Exists because the obvious spelling (`samples.first?.min` /
    /// `samples.last?.max`) is what `DashboardChart.rangeDescription` used to
    /// do, and it describes the *first sample's* floor and the *last sample's*
    /// ceiling — two unrelated numbers that happen to be at the ends of the
    /// array. VoiceOver's only summary of a full-size chart should be the
    /// range the data actually covers.
    public static func extremes(mins: [Double], maxes: [Double]) -> (min: Double, max: Double)? {
        let finiteMins = mins.filter(\.isFinite)
        let finiteMaxes = maxes.filter(\.isFinite)
        guard let low = finiteMins.min(), let high = finiteMaxes.max() else { return nil }
        return (min: Swift.min(low, high), max: Swift.max(low, high))
    }
}
