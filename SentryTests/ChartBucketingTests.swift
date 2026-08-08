import XCTest
@testable import Sentry
@testable import SentryKit

/// Coverage for `SentryKit/History/ChartBucketing.swift` — the pure fold that
/// turns a dense, jagged series into a small number of equal-duration points
/// with a real min–max band behind them.
///
/// Everything asserted here is something a wrong answer would put in front of a
/// reader as fact: which readings a plotted point summarises, where on the time
/// axis it claims to sit, whether a spike survives the averaging, and — the one
/// that matters most — whether a bucket is ever allowed to average across a
/// stretch where the Mac was asleep.
final class ChartBucketingTests: XCTestCase {

    // MARK: - Helpers

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }

    /// A `.raw`-tier row: `min == avg == max`, exactly what
    /// `HistoryStore.samplesWithRange` returns for the live tier and the whole
    /// reason this file exists.
    private func raw(_ offset: TimeInterval, _ value: Double) -> ChartBucketing.RangedSample {
        (timestamp: at(offset), min: value, avg: value, max: value)
    }

    /// A rollup row, where the band already has height before bucketing.
    private func ranged(
        _ offset: TimeInterval,
        min low: Double,
        avg: Double,
        max high: Double
    ) -> ChartBucketing.RangedSample {
        (timestamp: at(offset), min: low, avg: avg, max: high)
    }

    /// Every sample must land in exactly one bucket — the invariant that
    /// separates aggregation from striding. `DashboardViewModel.downsample`
    /// makes the same promise for the same reason: a spike dropped on the floor
    /// is a spike the chart can never show.
    private func assertNothingLost(
        _ series: ChartBucketing.Series,
        _ input: [ChartBucketing.RangedSample],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            series.buckets.reduce(0) { $0 + $1.count },
            input.count,
            "every input sample must be absorbed by exactly one bucket",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            series.buckets.count,
            input.count,
            "bucketing must never invent points",
            file: file,
            line: line
        )
    }

    // MARK: - Edges

    func testEmptySeriesProducesNothing() {
        let series = ChartBucketing.bucket([], target: 48, gapThreshold: 60)
        XCTAssertTrue(series.isEmpty)
        XCTAssertEqual(series.interval, 0)
    }

    func testSingleSampleIsItsOwnBucketAndKeepsItsOwnTimestamp() {
        // No span to divide, so there is no lattice: the identity case. The one
        // point must come back unchanged and stamped with its real time — this
        // is the case where a "bucket midpoint" could have invented an instant
        // and must not.
        let input = [raw(0, 41)]
        let series = ChartBucketing.bucket(input, target: 48, gapThreshold: 60)
        XCTAssertEqual(series.buckets.count, 1)
        XCTAssertEqual(series.interval, 0, "a zero-duration series has no cell width to report")
        let only = series.buckets[0]
        XCTAssertEqual(only.start, at(0))
        XCTAssertEqual(only.end, at(0))
        XCTAssertEqual(only.timestamp, at(0))
        XCTAssertEqual(only.min, 41)
        XCTAssertEqual(only.avg, 41)
        XCTAssertEqual(only.max, 41)
        XCTAssertEqual(only.count, 1)
        XCTAssertFalse(only.hasRange, "one reading is not a range")
        assertNothingLost(series, input)
    }

    func testFewerSamplesThanBucketsIsAnIdentityFold() {
        // 10 evenly spaced samples into 48 cells: every sample gets its own
        // cell, so the chart draws exactly what it was handed. Bucketing must
        // not thin a series that was never dense.
        let input = (0..<10).map { raw(Double($0) * 60, Double($0)) }
        let series = ChartBucketing.bucket(input, target: 48, gapThreshold: 0)
        XCTAssertEqual(series.buckets.count, input.count)
        XCTAssertEqual(series.buckets.map(\.count), Array(repeating: 1, count: 10))
        XCTAssertEqual(series.buckets.map(\.avg), (0..<10).map(Double.init))
        assertNothingLost(series, input)
    }

    func testNonPositiveTargetReturnsTheDataUndamaged() {
        // A misconfigured caller should draw a noisy chart, not a blank one.
        let input = (0..<5).map { raw(Double($0) * 60, Double($0)) }
        for target in [0, -1] {
            let series = ChartBucketing.bucket(input, target: target, gapThreshold: 0)
            XCTAssertEqual(series.buckets.count, input.count, "target \(target)")
            XCTAssertEqual(series.interval, 0, "target \(target)")
            assertNothingLost(series, input)
        }
    }

    func testSamplesThatDoNotDivideEvenlyAllLandSomewhere() {
        // 10 samples 10s apart (a 90s span) into 4 cells of 22.5s — a division
        // with no clean answer. The counts are allowed to be uneven; what is
        // not allowed is a sample falling through the cracks or a cell being
        // conjured out of the rounding.
        let input = (0..<10).map { raw(Double($0) * 10, Double($0)) }
        let series = ChartBucketing.bucket(input, target: 4, gapThreshold: 0)
        XCTAssertEqual(series.buckets.map(\.count), [3, 2, 2, 3])
        XCTAssertEqual(series.interval, 22.5, accuracy: 0.0001)
        assertNothingLost(series, input)
        // And they stay in order — a chart draws these left to right.
        XCTAssertEqual(series.buckets.map(\.timestamp), series.buckets.map(\.timestamp).sorted())
    }

    // MARK: - Time, not index

    func testBucketsAreByTimeNotByArrayIndex() {
        // Eight readings in the first eight seconds and one a minute and a half
        // later — the shape irregular sampling actually produces (dedup, a
        // module that reports occasionally, a tier switch). Index bucketing
        // into two would split 5/4 and place the second point in the middle of
        // the plot, where nothing was measured. Time bucketing puts the dense
        // cluster in one cell and the straggler in the other, which is where
        // they happened.
        //
        // `gapThreshold: 0` disables gap splitting so this asserts the
        // bucketing rule alone; the gap behaviour has its own tests below.
        let input = (0..<8).map { raw(Double($0), 10) } + [raw(100, 90)]
        let series = ChartBucketing.bucket(input, target: 2, gapThreshold: 0)
        XCTAssertEqual(series.buckets.map(\.count), [8, 1])
        XCTAssertEqual(series.buckets[0].avg, 10, accuracy: 0.0001)
        XCTAssertEqual(series.buckets[1].avg, 90, accuracy: 0.0001)
        assertNothingLost(series, input)
    }

    func testBucketIsPlottedAtTheMidpointOfWhatItCovers() {
        // A cell holding readings only in its first sliver must be drawn over
        // that sliver, not at the cell's centre — otherwise the point sits
        // where nothing was measured and the x-axis quietly stops meaning what
        // it says.
        let input = [raw(0, 1), raw(2, 3), raw(4, 5), raw(100, 7)]
        let series = ChartBucketing.bucket(input, target: 2, gapThreshold: 0)
        XCTAssertEqual(series.buckets.count, 2)
        // First bucket covers 0...4, so it is drawn at 2 — not at 25, the
        // centre of its 0...50 cell.
        XCTAssertEqual(series.buckets[0].start, at(0))
        XCTAssertEqual(series.buckets[0].end, at(4))
        XCTAssertEqual(series.buckets[0].timestamp, at(2))
        // A single-sample bucket is drawn at that sample's own instant.
        XCTAssertEqual(series.buckets[1].timestamp, at(100))
    }

    // MARK: - The band

    func testBandCarriesTheTrueExtremesSoAveragingHidesNothing() {
        // The whole justification for drawing a mean at all. Four readings
        // averaging 30 with one real 95% spike among them: the line drops to
        // 30, and the spike has to still be on screen as the band's ceiling.
        let input = [raw(0, 5), raw(1, 10), raw(2, 95), raw(3, 10)]
        let series = ChartBucketing.bucket(input, target: 1, gapThreshold: 0)
        XCTAssertEqual(series.buckets.count, 1)
        let only = series.buckets[0]
        XCTAssertEqual(only.avg, 30, accuracy: 0.0001)
        XCTAssertEqual(only.min, 5)
        XCTAssertEqual(only.max, 95, "a smoothed line without this number would be a lie")
        XCTAssertTrue(only.hasRange)
    }

    func testBandNeverShrinksBelowAnAlreadyRangedInput() {
        // Rollup rows arrive with a band already. Folding them must widen it to
        // the union, never re-derive it from the averages — the same promise
        // `DashboardViewModel.downsample` makes.
        let input = [
            ranged(0, min: 1, avg: 20, max: 40),
            ranged(10, min: 15, avg: 22, max: 90)
        ]
        let series = ChartBucketing.bucket(input, target: 1, gapThreshold: 0)
        XCTAssertEqual(series.buckets.count, 1)
        XCTAssertEqual(series.buckets[0].min, 1)
        XCTAssertEqual(series.buckets[0].max, 90)
        XCTAssertEqual(series.buckets[0].avg, 21, accuracy: 0.0001)
    }

    func testFlatSeriesReportsNoRange() {
        // A metric that genuinely did not move. The band collapses to a
        // hairline, which is the mathematically honest rendering — and
        // `hasRange` is what stops a readout printing "41%–41%".
        let input = (0..<20).map { raw(Double($0) * 10, 41) }
        let series = ChartBucketing.bucket(input, target: 4, gapThreshold: 0)
        XCTAssertFalse(series.buckets.contains(where: \.hasRange))
    }

    // MARK: - Gaps

    func testABucketNeverSpansAGap() {
        // The case the whole segment-then-bucket ordering exists for: three
        // readings, an 80-second hole, three more — and a lattice coarse enough
        // that all six fall in ONE cell. Grouping by cell alone would average
        // the reading before the hole together with the reading after it and
        // present the result as a single confident point, erasing the gap from
        // the plotted series after the query went to the trouble of preserving
        // it.
        let input = [raw(0, 10), raw(10, 12), raw(20, 11), raw(100, 80), raw(110, 82), raw(120, 81)]
        let threshold = ChartScrubbing.gapThreshold(cadence: 10)   // 25s
        let series = ChartBucketing.bucket(input, target: 1, gapThreshold: threshold)

        XCTAssertEqual(series.buckets.count, 2, "one cell, two runs, two buckets")
        XCTAssertEqual(series.buckets.map(\.segment), [0, 1], "the stroke has to break between them")
        // Neither bucket's covered span contains the hole.
        XCTAssertEqual(series.buckets[0].start, at(0))
        XCTAssertEqual(series.buckets[0].end, at(20))
        XCTAssertEqual(series.buckets[1].start, at(100))
        XCTAssertEqual(series.buckets[1].end, at(120))
        // And neither average was contaminated by the other side.
        XCTAssertEqual(series.buckets[0].avg, 11, accuracy: 0.0001)
        XCTAssertEqual(series.buckets[1].avg, 81, accuracy: 0.0001)
        assertNothingLost(series, input)
    }

    func testSegmentNumbersFollowChartScrubbingsOwnSplit() {
        // Bucketing must not invent its own idea of where the holes are — the
        // segment numbers it stamps have to be the runs `ChartScrubbing
        // .segments` already found, or the drawn breaks and the shaded gaps
        // would disagree about the same night.
        let offsets: [TimeInterval] = [0, 10, 20, 500, 510, 520, 1000, 1010]
        let input = offsets.map { raw($0, 5) }
        let threshold = ChartScrubbing.gapThreshold(cadence: 10)
        let expected = ChartScrubbing.segments(timestamps: input.map(\.timestamp), threshold: threshold)
        XCTAssertEqual(expected.count, 3, "sanity: the fixture really does have two holes")

        let series = ChartBucketing.bucket(input, target: 3, gapThreshold: threshold)
        XCTAssertEqual(Set(series.buckets.map(\.segment)), Set(0..<expected.count))
        // Segments only ever advance left to right.
        XCTAssertEqual(series.buckets.map(\.segment), series.buckets.map(\.segment).sorted())
        assertNothingLost(series, input)
    }

    func testAGaplessSeriesIsASingleSegment() {
        // The equivalence that lets the chart use the segmented path
        // unconditionally: with nothing missing, everything is run zero and the
        // output is one unbroken line.
        let input = (0..<40).map { raw(Double($0) * 10, Double($0 % 7)) }
        let series = ChartBucketing.bucket(input, target: 8, gapThreshold: ChartScrubbing.gapThreshold(cadence: 10))
        XCTAssertEqual(series.buckets.map(\.segment), Array(repeating: 0, count: series.buckets.count))
        XCTAssertEqual(series.buckets.count, 8)
        assertNothingLost(series, input)
    }

    func testNonPositiveGapThresholdTreatsTheSeriesAsUnbroken() {
        // A caller with no cadence to derive a threshold from gets the
        // pre-existing single-series behaviour rather than a crash or an
        // arbitrary split — the same contract `ChartScrubbing.segments` states.
        let input = [raw(0, 1), raw(10, 2), raw(10_000, 3)]
        let series = ChartBucketing.bucket(input, target: 2, gapThreshold: 0)
        XCTAssertEqual(Set(series.buckets.map(\.segment)), [0])
        assertNothingLost(series, input)
    }

    // MARK: - Shared grid

    func testAnExplicitGridControlsTheLattice() {
        // What small multiples need: three lanes bucketed over one span so a
        // pointer lands on the same interval in every lane. Ten samples 10s
        // apart, laid over a 180s grid in 6 cells of 30s — cells past the data
        // simply produce no bucket rather than an empty point.
        let input = (0..<10).map { raw(Double($0) * 10, Double($0)) }
        let series = ChartBucketing.bucket(
            input,
            over: at(0)...at(180),
            target: 6,
            gapThreshold: 0
        )
        XCTAssertEqual(series.interval, 30, accuracy: 0.0001)
        XCTAssertEqual(series.buckets.map(\.count), [3, 3, 3, 1])
        assertNothingLost(series, input)
    }

    func testTwoSeriesOnOneGridShareCellBoundaries() {
        // The property the shared grid exists to guarantee: two metrics sampled
        // at different cadences over the same window produce buckets whose
        // covered spans nest inside the same cells, so one stated interval is
        // right about both.
        let grid = at(0)...at(120)
        let dense = (0..<24).map { raw(Double($0) * 5, 1) }
        let sparse = (0..<7).map { raw(Double($0) * 20, 2) }
        let a = ChartBucketing.bucket(dense, over: grid, target: 4, gapThreshold: 0)
        let b = ChartBucketing.bucket(sparse, over: grid, target: 4, gapThreshold: 0)
        XCTAssertEqual(a.interval, b.interval)
        for series in [a, b] {
            for bucket in series.buckets {
                let cell = ChartBucketing.cell(containing: bucket.timestamp, over: grid, target: 4)
                XCTAssertNotNil(cell)
                XCTAssertTrue(
                    bucket.start >= cell!.lowerBound && bucket.end <= cell!.upperBound,
                    "a bucket must stay inside the cell that names it"
                )
            }
        }
    }

    func testSamplesOutsideAnExplicitGridAreClampedIntoIt() {
        // A union grid computed from a neighbour's span, or a row written a
        // moment after the window was captured. Nothing may index out of the
        // lattice, and nothing may be dropped for being slightly outside it.
        let input = [raw(-50, 1), raw(20, 2), raw(30, 3), raw(500, 4)]
        let series = ChartBucketing.bucket(
            input,
            over: at(0)...at(100),
            target: 4,
            gapThreshold: 0
        )
        assertNothingLost(series, input)
        XCTAssertFalse(series.isEmpty)
    }

    // MARK: - Cells

    func testCellNamesTheIntervalUnderAPointer() {
        let grid = at(0)...at(120)
        let first = ChartBucketing.cell(containing: at(10), over: grid, target: 4)
        XCTAssertEqual(first?.lowerBound, at(0))
        XCTAssertEqual(first?.upperBound, at(30))

        let middle = ChartBucketing.cell(containing: at(59), over: grid, target: 4)
        XCTAssertEqual(middle?.lowerBound, at(30))
        XCTAssertEqual(middle?.upperBound, at(60))

        // A boundary belongs to the cell it opens, not the one it closes.
        let boundary = ChartBucketing.cell(containing: at(60), over: grid, target: 4)
        XCTAssertEqual(boundary?.lowerBound, at(60))
    }

    func testCellClampsTheGridsUpperEdgeIntoTheLastCell() {
        // Hovering the exact right edge of the plot must name the last
        // interval, not nothing at all.
        let grid = at(0)...at(120)
        let last = ChartBucketing.cell(containing: at(120), over: grid, target: 4)
        XCTAssertEqual(last?.lowerBound, at(90))
        XCTAssertEqual(last?.upperBound, at(120))
    }

    func testCellIsNilWhereThereIsNothingToName() {
        let grid = at(0)...at(120)
        XCTAssertNil(ChartBucketing.cell(containing: at(-1), over: grid, target: 4))
        XCTAssertNil(ChartBucketing.cell(containing: at(121), over: grid, target: 4))
        XCTAssertNil(ChartBucketing.cell(containing: at(10), over: grid, target: 0))
        XCTAssertNil(ChartBucketing.cell(containing: at(0), over: at(0)...at(0), target: 4))
    }

    // MARK: - The real shape

    func testTheLiveRangeCollapsesToAFollowableLine() {
        // The end-to-end case this change exists for, at the scale it actually
        // happens: a day of 3-second raw readings swinging 10%–90% between
        // consecutive samples, already thinned to `maxPointsPerSeries` by the
        // view model, then bucketed for drawing.
        //
        // The assertions are the two halves of the fix — the drawn line has to
        // be short enough to follow, and the extremes have to survive it.
        let dayLong: [ChartBucketing.RangedSample] = (0..<360).map { index in
            raw(Double(index) * 240, index.isMultiple(of: 2) ? 10 : 90)
        }
        let series = ChartBucketing.bucket(
            dayLong,
            target: ActivityLanesChart.targetBuckets,
            gapThreshold: ChartScrubbing.gapThreshold(cadence: 240)
        )
        XCTAssertEqual(series.buckets.count, ActivityLanesChart.targetBuckets)
        XCTAssertEqual(series.interval, (359 * 240) / 48, accuracy: 0.5)
        // Every drawn point sits near the true mean instead of alternating
        // between the floor and the ceiling 360 times across 840pt.
        //
        // Asserted as a collapse in *amplitude* rather than against an exact
        // midpoint, because the midpoint is unreachable and that is arithmetic
        // rather than a defect: 360 samples over 48 buckets is 7.5 each, so a
        // bucket holding an odd 7 alternating values is either four lows and
        // three highs (44.3) or the reverse (55.7). Pinning `accuracy: 5`
        // failed exactly half the buckets for a correct implementation. What
        // the fix actually claims is that the drawn line stops swinging: the
        // raw series sits 40 either side of the mean, the bucketed line under
        // 6 — a better than sixfold collapse, which is the readable/unreadable
        // difference this whole change is for.
        for bucket in series.buckets {
            XCTAssertLessThan(abs(bucket.avg - 50), 10)
            // ...and every one of them still shows both extremes.
            XCTAssertEqual(bucket.min, 10)
            XCTAssertEqual(bucket.max, 90)
        }
        assertNothingLost(series, dayLong)
    }
}
