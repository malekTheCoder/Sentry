import Foundation

/// Folds a plotted series into a small number of equal-*duration* buckets, each
/// carrying the true `(min, avg, max)` of everything it absorbed — the
/// arithmetic behind "draw the average as a line inside a min–max band" on
/// charts whose source rows are too dense, or too jagged, to follow.
///
/// **The problem this exists for.** `HistoryStore.samplesWithRange` returns
/// `(min: avg, avg: avg, max: avg)` for the `.raw` tier — one unaggregated
/// reading per row, no range at all — and real CPU genuinely swings from 10% to
/// 90% between two readings three seconds apart. Plotted point-for-point that
/// is not a line, it is hash; overlay two more series behaving the same way and
/// no individual line can be followed at all. Every *longer* range already
/// escapes this, because `.hourly`/`.daily` rows arrive from `RollupJob` with a
/// real min/avg/max and `DashboardChart` already draws that as an average line
/// inside a translucent band. So the fix is not a new visual idea, it is
/// removing an inconsistency: give the dense tier the same aggregation the
/// sparse tiers get for free, and draw it the same way.
///
/// **Why not just smooth it.** A moving average over the raw readings would
/// produce exactly the same legible line and would be a lie: a genuine 95% CPU
/// spike would render as 60% and nothing on screen would say otherwise. The
/// band is what makes the averaging honest — the line is the mean, the band is
/// the true extremes, and the spike is still visibly there as the band's
/// ceiling. A smoothed line with no band is the one rendering this file exists
/// to make unnecessary. (`SystemSnapshot`'s "no value is invented" posture and
/// `ChartScrubbing`'s refusal to interpolate a readout are the same rule
/// applied to two other surfaces.)
///
/// **Why by time and not by array index.** `DashboardViewModel.downsample`
/// folds by index — bucket *k* is rows `k·n..<(k+1)·n` — which is correct only
/// when rows are evenly spaced. They are not: the app samples on multiple tier
/// cadences, `HistoryStore` deduplicates unchanged values down to a 60s
/// heartbeat, and a sleeping Mac writes nothing at all. Index bucketing over
/// that gives every bucket the same *number* of rows and therefore wildly
/// different *durations*, so the plotted x-positions drift away from the times
/// they claim to represent — a distortion nothing on screen would reveal. Equal
/// durations cost nothing extra and cannot drift.
///
/// **Why the grid is derived from the data, not from the chart's pinned
/// x-domain.** Laying the cells over the requested window instead was the
/// obvious alternative and is wrong in a case this app hits constantly: a fresh
/// install showing 24h of window over twenty minutes of record would put every
/// sample in one cell and collapse the entire series to a single dot, hiding
/// that there is any data at all — the precise failure `HistoryCoverage` and the
/// pinned domain exist to prevent. Bucketing over the data's own span keeps the
/// series a series; how much of the plot it occupies stays the domain's job.
/// Callers drawing several series that must share cell boundaries pass an
/// explicit `grid` instead (see `bucket(_:over:target:gapThreshold:)`).
///
/// Foundation-only, like the rest of `SentryKit/History` — `SentryKit_iOS`
/// builds this without GRDB or any UI framework.
public enum ChartBucketing {

    /// The exact tuple `HistoryStore.samplesWithRange` returns, so a caller
    /// hands a query result straight in with no translation step — the same
    /// reasoning `DashboardViewModel.RangedSamples` gives for not wrapping it.
    public typealias RangedSample = (timestamp: Date, min: Double, avg: Double, max: Double)

    // MARK: - Bucket

    /// One plotted point: the mean of everything in a time cell, plus the true
    /// extremes across it.
    ///
    /// `start`/`end` are the first and last *sample* times folded in, not the
    /// cell's own edges. That distinction matters at the ends of a run: a cell
    /// clipped by the start of a gap holds readings from only its first sliver,
    /// and reporting the cell's full width as the span these numbers describe
    /// would overstate what was measured by up to a whole cell. `Series
    /// .interval` still carries the cell width for callers that need the
    /// lattice itself.
    public struct Bucket: Equatable, Sendable {
        /// Timestamp of the earliest sample in the bucket.
        public let start: Date
        /// Timestamp of the latest sample in the bucket. Equal to `start` for a
        /// single-sample bucket.
        public let end: Date
        /// Lowest `min` any absorbed sample reported — the band's floor.
        public let min: Double
        /// Unweighted mean of the absorbed samples' `avg` — the drawn line.
        public let avg: Double
        /// Highest `max` any absorbed sample reported — the band's ceiling, and
        /// the reason averaging here hides nothing.
        public let max: Double
        /// How many input samples folded in. Never zero: an empty cell produces
        /// no bucket rather than a bucket of nothing.
        ///
        /// Deliberately *not* surfaced in any readout as "average of N
        /// samples". When the caller has already run
        /// `DashboardViewModel.downsample`, each input sample is itself the
        /// mean of dozens of rows, so this number would understate the true
        /// population by an order of magnitude while sounding precise. It is
        /// here for tests and for the one question a view legitimately asks of
        /// it — "did anything actually get averaged, or is this one reading?"
        public let count: Int
        /// Which gapless run of the source series this bucket came from.
        /// Passed to Swift Charts as the mark's `series:` value so no stroke is
        /// ever drawn across a stretch where nothing was measured.
        public let segment: Int

        public init(
            start: Date,
            end: Date,
            min: Double,
            avg: Double,
            max: Double,
            count: Int,
            segment: Int
        ) {
            self.start = start
            self.end = end
            self.min = min
            self.avg = avg
            self.max = max
            self.count = count
            self.segment = segment
        }

        /// Where the bucket is plotted: the midpoint of the span it actually
        /// covers.
        ///
        /// Not the cell's centre, for the reason `start`/`end` are sample times
        /// — a bucket holding only the first tenth of its cell would otherwise
        /// be drawn most of a cell to the right of every reading in it. Not a
        /// contained sample's own timestamp either (what `downsample` picks):
        /// this point is a statement about an interval, not about one reading,
        /// and stamping it with one reading's time would invite a scrub readout
        /// to claim that reading's precision. For a single-sample bucket the
        /// midpoint *is* that sample's time, so nothing is invented in the case
        /// where a real instant exists.
        public var timestamp: Date {
            start.addingTimeInterval(end.timeIntervalSince(start) / 2)
        }

        /// Whether the band has any height — false when one reading landed
        /// here, or when several identical ones did. A readout uses it to avoid
        /// printing "41%–41%" as if it were a range.
        public var hasRange: Bool { max > min }
    }

    /// A bucketed series plus the lattice it was laid on.
    public struct Series: Equatable, Sendable {
        public let buckets: [Bucket]

        /// Width of one grid cell. This is the spacing a chart should hand
        /// `ChartScrubbing.effectiveCadence(expected:timestamps:)` as the
        /// declared cadence: the plotted points are now cells apart, not rows
        /// apart, so the pre-bucketing cadence the view model published would
        /// classify almost every ordinary neighbour pair as a gap.
        ///
        /// Zero when no lattice was used — an empty series, a series with no
        /// duration, or a non-positive `target`, all of which fall back to one
        /// bucket per sample.
        public let interval: TimeInterval

        public init(buckets: [Bucket], interval: TimeInterval) {
            self.buckets = buckets
            self.interval = interval
        }

        public var isEmpty: Bool { buckets.isEmpty }
    }

    // MARK: - Bucketing

    /// Folds `samples` onto a lattice of `target` equal-duration cells.
    ///
    /// - Parameters:
    ///   - samples: ascending by timestamp, as every `HistoryStore` read path
    ///     already guarantees. Out-of-order input is not rejected — this is a
    ///     drawing helper, not a validator — but its cell assignment is then
    ///     meaningless, exactly as `ChartScrubbing.gaps` says of its own input.
    ///   - grid: the span to lay cells over. `nil` (the default) uses the
    ///     samples' own first-to-last span, which is what a lone chart wants;
    ///     several charts that must share cell boundaries — small multiples
    ///     under one x-axis — pass the union of their spans so a pointer lands
    ///     on the same cell in every lane. See the type doc comment for why the
    ///     *requested window* is never the right thing to pass here.
    ///   - target: how many cells to divide the span into. Non-positive falls
    ///     back to one bucket per sample rather than trapping or returning
    ///     nothing: a misconfigured caller should get its data back undamaged.
    ///   - gapThreshold: from `ChartScrubbing.gapThreshold(cadence:)`, measured
    ///     on the *source* cadence. Bucketing happens inside each gapless run,
    ///     never across one — see below.
    ///
    /// **A bucket never spans a gap.** This is the whole reason the function
    /// segments before it buckets rather than simply grouping by cell index. A
    /// cell is a fixed slice of wall-clock time and a gap can sit entirely
    /// inside one; grouping by cell alone would then average the last reading
    /// before an eight-hour sleep together with the first reading after it and
    /// present the result as one point with one honest-looking mean. It would
    /// also erase the gap from the plotted series, which is exactly what
    /// `ChartScrubbing.segments` and `DashboardChart`'s gap shading exist to
    /// prevent — a hole that survives the query only to be filled in by the
    /// downsampler is no better than one that was never detected. So a cell
    /// straddling a gap yields *two* buckets, one per run, each honestly
    /// describing only the readings on its own side, and the `segment` numbers
    /// keep the stroke broken between them.
    ///
    /// Cells with no samples in them produce no bucket at all. An absent point
    /// is the correct rendering of an unmeasured interval; a point carrying
    /// zero, or the previous cell's value, would be invented data.
    public static func bucket(
        _ samples: [RangedSample],
        over grid: ClosedRange<Date>? = nil,
        target: Int,
        gapThreshold: TimeInterval
    ) -> Series {
        guard !samples.isEmpty else { return Series(buckets: [], interval: 0) }

        let timestamps = samples.map(\.timestamp)
        // `segments` already handles both degenerate inputs the same way this
        // function needs them handled: a single sample, or a non-positive
        // threshold, yields one run covering everything.
        let runs = ChartScrubbing.segments(timestamps: timestamps, threshold: gapThreshold)

        let span = grid ?? (timestamps[0]...timestamps[timestamps.count - 1])
        let duration = span.upperBound.timeIntervalSince(span.lowerBound)
        guard target > 0, duration > 0 else {
            return Series(buckets: perSample(samples, runs: runs), interval: 0)
        }
        let interval = duration / Double(target)

        // Clamped rather than trusted: a caller passing an explicit `grid` that
        // doesn't quite contain its own samples (a union computed from a
        // different metric's span, a row written a moment after the window was
        // captured) must land in a real cell, not at index -1 or `target`. The
        // last sample sits exactly on the upper bound and would otherwise index
        // one past the end.
        func cellIndex(_ date: Date) -> Int {
            let offset = date.timeIntervalSince(span.lowerBound) / interval
            guard offset.isFinite else { return 0 }
            return Swift.min(Swift.max(Int(offset.rounded(.down)), 0), target - 1)
        }

        var result: [Bucket] = []
        result.reserveCapacity(Swift.min(target * runs.count, samples.count))
        for (segment, run) in runs.enumerated() {
            var start = run.lowerBound
            while start < run.upperBound {
                // Samples are ascending and cells are monotone in time, so
                // everything belonging to one cell within one run is
                // contiguous — a single forward scan is enough, no grouping
                // dictionary and no second pass over the series.
                let cell = cellIndex(timestamps[start])
                var end = start + 1
                while end < run.upperBound, cellIndex(timestamps[end]) == cell { end += 1 }
                result.append(fold(samples[start..<end], segment: segment))
                start = end
            }
        }
        return Series(buckets: result, interval: interval)
    }

    /// The identity case: every sample becomes its own bucket, still carrying
    /// its run number so gap-aware drawing keeps working.
    ///
    /// Reached when there is no lattice to lay — a zero-duration span (one
    /// sample, or several stamped identically) or a non-positive `target`.
    /// Returning the data unchanged rather than empty means a caller that
    /// mis-specifies the bucket count draws a noisy chart, not a blank one.
    private static func perSample(_ samples: [RangedSample], runs: [Range<Int>]) -> [Bucket] {
        var result: [Bucket] = []
        result.reserveCapacity(samples.count)
        for (segment, run) in runs.enumerated() {
            for index in run {
                result.append(fold(samples[index..<(index + 1)], segment: segment))
            }
        }
        return result
    }

    /// Collapses one contiguous slice into a single bucket.
    ///
    /// `avg` is the unweighted mean of the slice's own averages.
    ///
    /// **Rejected alternative — weight each sample by the time it covers.**
    /// Strictly more correct on irregularly spaced data, and rejected because
    /// computing it requires deciding how long the *last* sample in a bucket
    /// "lasts", which nothing in the data says: any answer is a fabricated
    /// duration attached to a real reading, and it would propagate into a
    /// number shown to a user. The unweighted mean's error is bounded by how
    /// unevenly a single cell is sampled, and within a cell — a slice of one
    /// tier's steady cadence, with anything longer than 2.5 cadences already
    /// split off as a gap — that is small enough to sit well inside the drawn
    /// stroke. The numbers a reader could actually be misled by are the
    /// extremes, and those are exact.
    private static func fold(_ slice: ArraySlice<RangedSample>, segment: Int) -> Bucket {
        var low = Double.infinity
        var high = -Double.infinity
        var total = 0.0
        for sample in slice {
            low = Swift.min(low, sample.min)
            high = Swift.max(high, sample.max)
            total += sample.avg
        }
        let count = slice.count
        // A slice of all-NaN or all-infinite rows can't produce a usable band;
        // fall back to the mean so the bucket is still drawable rather than
        // poisoning the chart's y-domain with an infinity.
        let average = total / Double(count)
        return Bucket(
            start: slice.first!.timestamp,
            end: slice.last!.timestamp,
            min: low.isFinite ? low : average,
            avg: average,
            max: high.isFinite ? high : average,
            count: count,
            segment: segment
        )
    }

    // MARK: - Cells

    /// The lattice cell `date` falls in, as a half-open span expressed with a
    /// closed range's bounds.
    ///
    /// Exists so a chart can name the interval a scrub is reading *without*
    /// asking any particular series what it holds there. On small multiples
    /// sharing one grid, each lane's bucket covers only the readings that lane
    /// has in the cell, so three lanes legitimately report three slightly
    /// different covered spans for one pointer position — and the one time span
    /// stated on screen has to be the cell itself, which is exactly what every
    /// lane's numbers are drawn from. It is also answerable when *no* lane has
    /// data there, which is when a reader most wants to know what interval they
    /// are hovering.
    ///
    /// - Returns: `nil` when `date` is outside `grid`, when `target` is
    ///   non-positive, or when `grid` has no duration — all cases where there
    ///   is no cell to name and a caller should say nothing rather than guess.
    public static func cell(
        containing date: Date,
        over grid: ClosedRange<Date>,
        target: Int
    ) -> ClosedRange<Date>? {
        guard target > 0 else { return nil }
        let duration = grid.upperBound.timeIntervalSince(grid.lowerBound)
        guard duration > 0 else { return nil }
        guard date >= grid.lowerBound, date <= grid.upperBound else { return nil }
        let interval = duration / Double(target)
        // The upper bound belongs to the last cell rather than to a
        // nonexistent cell `target`, matching `bucket`'s own clamp — otherwise
        // hovering the exact right edge of the plot would name no interval at
        // all.
        let index = Swift.min(Int((date.timeIntervalSince(grid.lowerBound) / interval).rounded(.down)), target - 1)
        let start = grid.lowerBound.addingTimeInterval(Double(index) * interval)
        return start...start.addingTimeInterval(interval)
    }
}
