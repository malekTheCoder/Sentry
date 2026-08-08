import XCTest
@testable import Sentry
@testable import SentryKit

/// Coverage for the pure half of interactive chart scrubbing and gap-aware
/// drawing: `SentryKit/History/ChartScrubbing.swift`, the cadence derivation
/// on `Sentry/Dashboard/TimeRangePicker.swift`, and the readout strings on
/// `Sentry/Dashboard/DashboardChart.swift`.
///
/// The gestures themselves are not tested — a hover handler is three lines of
/// coordinate arithmetic wrapped around `ChartProxy`, and a test would be
/// asserting that SwiftUI called back. What *is* tested is everything a wrong
/// answer would show a reader as fact: which sample the pointer lands on,
/// whether there is a sample there at all, and how the number is spelled.
final class ChartScrubbingTests: XCTestCase {

    // MARK: - Helpers

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func times(_ offsets: [TimeInterval]) -> [Date] {
        offsets.map { epoch.addingTimeInterval($0) }
    }

    /// Evenly spaced timestamps, `count` of them, `step` apart.
    private func evenTimes(count: Int, step: TimeInterval) -> [Date] {
        (0..<count).map { epoch.addingTimeInterval(Double($0) * step) }
    }

    // MARK: - Cadence derivation

    func testExpectedCadenceIsBaseIntervalWhenNotDownsampled() {
        // 200 rows, cap 360 — `DashboardViewModel.downsample` no-ops, so the
        // plotted spacing is still one row apart.
        XCTAssertEqual(
            ChartScrubbing.expectedCadence(baseInterval: 3, inputCount: 200, outputCount: 200),
            3,
            accuracy: 0.0001
        )
    }

    func testExpectedCadenceScalesByDownsampleFactor() {
        // The worst case the downsample cap exists for: 24h of 3s raw rows
        // (28,800) folded into 360 buckets. Each bucket then spans 80 rows,
        // so consecutive plotted points are 240s apart — not 3s, which is why
        // a fixed "gap = more than a minute" threshold would break every
        // 24h chart.
        XCTAssertEqual(
            ChartScrubbing.expectedCadence(baseInterval: 3, inputCount: 28_800, outputCount: 360),
            240,
            accuracy: 0.0001
        )
    }

    func testExpectedCadenceNeverShrinksBelowBaseInterval() {
        // outputCount > inputCount is nonsense a caller can't actually produce
        // (downsample only ever reduces), but it must not yield a sub-row
        // cadence that would classify every normal spacing as a gap.
        XCTAssertEqual(
            ChartScrubbing.expectedCadence(baseInterval: 3600, inputCount: 10, outputCount: 360),
            3600,
            accuracy: 0.0001
        )
    }

    func testExpectedCadenceGuardsDegenerateInputs() {
        XCTAssertEqual(ChartScrubbing.expectedCadence(baseInterval: 0, inputCount: 100, outputCount: 10), 0)
        XCTAssertEqual(ChartScrubbing.expectedCadence(baseInterval: 3, inputCount: 0, outputCount: 0), 3)
    }

    func testTimeRangePickerRowIntervalFollowsTheTierItQueries() {
        // `.day` is the only range routed to `.raw`, so it is the only one
        // whose cadence depends on the user's refresh-interval setting.
        XCTAssertEqual(TimeRangePicker.day.expectedRowInterval(samplingInterval: 3), 3)
        XCTAssertEqual(TimeRangePicker.day.expectedRowInterval(samplingInterval: 0.5), 0.5)
        for range in [TimeRangePicker.week, .month, .quarter] {
            XCTAssertEqual(range.expectedRowInterval(samplingInterval: 3), 3600, "\(range) should use the hourly rollup's cadence")
        }
        XCTAssertEqual(TimeRangePicker.halfYear.expectedRowInterval(samplingInterval: 3), 86400)
    }

    // MARK: - Median / effective cadence

    func testMedianSpacingOddAndEvenCounts() {
        // Spacings 10, 20, 30 -> median 20.
        XCTAssertEqual(ChartScrubbing.medianSpacing(times([0, 10, 30, 60]))!, 20, accuracy: 0.0001)
        // Spacings 10, 20 -> mean of the middle pair, 15.
        XCTAssertEqual(ChartScrubbing.medianSpacing(times([0, 10, 30]))!, 15, accuracy: 0.0001)
    }

    func testMedianSpacingIgnoresAnOutlyingGap() {
        // Nine 60s steps and one nine-hour hole: the median must stay at 60,
        // which is the entire reason it is used as a floor rather than a mean.
        let night: TimeInterval = 9 * 3600
        let offsets: [TimeInterval] = [0, 60, 120, 180, 240, 240 + night, 300 + night, 360 + night, 420 + night]
        XCTAssertEqual(ChartScrubbing.medianSpacing(times(offsets))!, 60, accuracy: 0.0001)
    }

    func testMedianSpacingNeedsTwoPoints() {
        XCTAssertNil(ChartScrubbing.medianSpacing([]))
        XCTAssertNil(ChartScrubbing.medianSpacing(times([0])))
    }

    func testEffectiveCadenceTakesTheLargerOfDeclaredAndObserved() {
        let sparse = times([0, 600, 1200, 1800])
        // Declared 3s but rows are actually 600s apart (a metric its module
        // only reports occasionally): trust the data, or every point becomes
        // its own gap.
        XCTAssertEqual(ChartScrubbing.effectiveCadence(expected: 3, timestamps: sparse)!, 600, accuracy: 0.0001)
        // Declared 3600s and rows are 600s apart: trust the declaration, so a
        // series that is mostly gap can't redefine "normal" as its own gap.
        XCTAssertEqual(ChartScrubbing.effectiveCadence(expected: 3600, timestamps: sparse)!, 3600, accuracy: 0.0001)
        XCTAssertEqual(ChartScrubbing.effectiveCadence(expected: nil, timestamps: sparse)!, 600, accuracy: 0.0001)
        XCTAssertEqual(ChartScrubbing.effectiveCadence(expected: 42, timestamps: [])!, 42, accuracy: 0.0001)
        XCTAssertNil(ChartScrubbing.effectiveCadence(expected: nil, timestamps: []))
    }

    // MARK: - Gap detection

    func testGapThresholdIsTwoAndAHalfCadences() {
        XCTAssertEqual(ChartScrubbing.gapThreshold(cadence: 240), 600, accuracy: 0.0001)
    }

    func testNoGapsInAnEvenlySampledSeries() {
        let timestamps = evenTimes(count: 50, step: 240)
        XCTAssertTrue(ChartScrubbing.gaps(timestamps: timestamps, threshold: 600).isEmpty)
    }

    func testASingleMissedSampleIsNotAGap() {
        // 480s is two cadences — ordinary jitter, not an interruption. The
        // 2.5x multiplier exists precisely so this does not break the line.
        let timestamps = times([0, 240, 720, 960])
        XCTAssertTrue(ChartScrubbing.gaps(timestamps: timestamps, threshold: 600).isEmpty)
    }

    func testAnOvernightSleepIsAGap() {
        // 11pm to 8am at a 240s cadence.
        let timestamps = times([0, 240, 480, 480 + 9 * 3600, 480 + 9 * 3600 + 240])
        let gaps = ChartScrubbing.gaps(timestamps: timestamps, threshold: 600)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.start, epoch.addingTimeInterval(480))
        XCTAssertEqual(gaps.first?.end, epoch.addingTimeInterval(480 + 9 * 3600))
        XCTAssertEqual(gaps.first?.duration ?? 0, 9 * 3600, accuracy: 0.0001)
    }

    func testMultipleGaps() {
        let timestamps = times([0, 240, 10_000, 10_240, 50_000])
        XCTAssertEqual(ChartScrubbing.gaps(timestamps: timestamps, threshold: 600).count, 2)
    }

    func testGapsOnDegenerateInput() {
        XCTAssertTrue(ChartScrubbing.gaps(timestamps: [], threshold: 600).isEmpty)
        XCTAssertTrue(ChartScrubbing.gaps(timestamps: times([0]), threshold: 600).isEmpty)
        XCTAssertTrue(ChartScrubbing.gaps(timestamps: times([0, 99_999]), threshold: 0).isEmpty)
    }

    // MARK: - Segmentation

    func testAGaplessSeriesIsOneSegment() {
        // The equivalence that lets the chart use the segmented drawing path
        // unconditionally: with no gaps it must produce exactly the old
        // single-series rendering.
        let timestamps = evenTimes(count: 20, step: 240)
        XCTAssertEqual(ChartScrubbing.segments(timestamps: timestamps, threshold: 600), [0..<20])
    }

    func testSegmentsSplitAtEachGap() {
        let timestamps = times([0, 240, 480, 480 + 9 * 3600, 480 + 9 * 3600 + 240, 200_000])
        XCTAssertEqual(
            ChartScrubbing.segments(timestamps: timestamps, threshold: 600),
            [0..<3, 3..<5, 5..<6]
        )
    }

    func testSegmentsCoverEveryIndexExactlyOnce() {
        let timestamps = times([0, 240, 480, 480 + 9 * 3600, 480 + 9 * 3600 + 240, 200_000])
        let segments = ChartScrubbing.segments(timestamps: timestamps, threshold: 600)
        XCTAssertEqual(segments.flatMap { Array($0) }, Array(0..<timestamps.count))
    }

    func testSegmentsOnDegenerateInput() {
        XCTAssertTrue(ChartScrubbing.segments(timestamps: [], threshold: 600).isEmpty)
        XCTAssertEqual(ChartScrubbing.segments(timestamps: times([0]), threshold: 600), [0..<1])
    }

    // MARK: - Nearest sample

    func testNearestIndexExactHit() {
        let timestamps = evenTimes(count: 10, step: 100)
        XCTAssertEqual(ChartScrubbing.nearestIndex(to: epoch.addingTimeInterval(400), timestamps: timestamps), 4)
    }

    func testNearestIndexPicksTheCloserNeighbour() {
        let timestamps = evenTimes(count: 10, step: 100)
        XCTAssertEqual(ChartScrubbing.nearestIndex(to: epoch.addingTimeInterval(441), timestamps: timestamps), 4)
        XCTAssertEqual(ChartScrubbing.nearestIndex(to: epoch.addingTimeInterval(461), timestamps: timestamps), 5)
    }

    func testNearestIndexTieResolvesToTheEarlierSample() {
        // Fixed, not arbitrary-per-call: a pointer sitting still exactly
        // between two samples must not flicker between two readouts.
        let timestamps = evenTimes(count: 10, step: 100)
        XCTAssertEqual(ChartScrubbing.nearestIndex(to: epoch.addingTimeInterval(450), timestamps: timestamps), 4)
    }

    func testNearestIndexClampsOffEitherEnd() {
        let timestamps = evenTimes(count: 10, step: 100)
        XCTAssertEqual(ChartScrubbing.nearestIndex(to: epoch.addingTimeInterval(-9999), timestamps: timestamps), 0)
        XCTAssertEqual(ChartScrubbing.nearestIndex(to: epoch.addingTimeInterval(9999), timestamps: timestamps), 9)
    }

    func testNearestIndexOnEmptySeries() {
        XCTAssertNil(ChartScrubbing.nearestIndex(to: epoch, timestamps: []))
    }

    // MARK: - Resolving a pointer position

    func testResolveSnapsToARealSample() {
        let timestamps = evenTimes(count: 10, step: 240)
        XCTAssertEqual(
            ChartScrubbing.resolve(at: epoch.addingTimeInterval(500), timestamps: timestamps, cadence: 240),
            .sample(index: 2)
        )
    }

    func testResolveInsideAGapReportsNoData() {
        // The headline case: hovering the middle of an overnight sleep must
        // not read out 11pm's value.
        let timestamps = times([0, 240, 480, 480 + 9 * 3600, 480 + 9 * 3600 + 240])
        let midGap = epoch.addingTimeInterval(480 + 4.5 * 3600)
        XCTAssertEqual(ChartScrubbing.resolve(at: midGap, timestamps: timestamps, cadence: 240), .noData)
    }

    func testResolveJustInsideAGapEdgeStillSnapsToTheBoundingSample() {
        // Within one cadence of a real sample is still that sample — the plot
        // is drawn at pixel resolution and a half-cadence offset is sub-pixel.
        let timestamps = times([0, 240, 480, 480 + 9 * 3600])
        XCTAssertEqual(
            ChartScrubbing.resolve(at: epoch.addingTimeInterval(600), timestamps: timestamps, cadence: 240),
            .sample(index: 2)
        )
        XCTAssertEqual(
            ChartScrubbing.resolve(at: epoch.addingTimeInterval(900), timestamps: timestamps, cadence: 240),
            .noData
        )
    }

    func testResolveOffTheEndsReportsNoData() {
        let timestamps = evenTimes(count: 5, step: 240)
        XCTAssertEqual(
            ChartScrubbing.resolve(at: epoch.addingTimeInterval(-10_000), timestamps: timestamps, cadence: 240),
            .noData
        )
        XCTAssertEqual(
            ChartScrubbing.resolve(at: epoch.addingTimeInterval(100_000), timestamps: timestamps, cadence: 240),
            .noData
        )
    }

    func testResolveWithNoKnownCadenceNeverClaimsNoData() {
        // A caller with a single point has no spacing to derive a cadence
        // from; refusing to read out its one sample would be worse than
        // snapping to it.
        let timestamps = times([0])
        XCTAssertEqual(
            ChartScrubbing.resolve(at: epoch.addingTimeInterval(99_999), timestamps: timestamps, cadence: 0),
            .sample(index: 0)
        )
    }

    func testResolveOnEmptySeriesIsNil() {
        XCTAssertNil(ChartScrubbing.resolve(at: epoch, timestamps: [], cadence: 240))
    }

    // MARK: - Extremes

    func testExtremesAreTheRangesOwnMinAndMaxNotTheEndSamples() {
        // The exact bug `DashboardChart.rangeDescription` had: first-sample
        // min and last-sample max are two unrelated numbers, and here both are
        // wrong — the real floor is in the middle and the real peak is too.
        let mins = [40.0, 12.0, 38.0]
        let maxes = [55.0, 91.0, 60.0]
        let extremes = ChartScrubbing.extremes(mins: mins, maxes: maxes)
        XCTAssertEqual(extremes?.min, 12)
        XCTAssertEqual(extremes?.max, 91)
    }

    func testExtremesSkipNonFiniteValues() {
        let extremes = ChartScrubbing.extremes(mins: [.nan, 5, .infinity], maxes: [.nan, 9])
        XCTAssertEqual(extremes?.min, 5)
        XCTAssertEqual(extremes?.max, 9)
    }

    func testExtremesOnEmptyInput() {
        XCTAssertNil(ChartScrubbing.extremes(mins: [], maxes: []))
        XCTAssertNil(ChartScrubbing.extremes(mins: [.nan], maxes: [.nan]))
    }

    // MARK: - Readout strings

    private func sample(_ offset: TimeInterval, _ value: Double) -> (timestamp: Date, min: Double, avg: Double, max: Double) {
        (timestamp: epoch.addingTimeInterval(offset), min: value, avg: value, max: value)
    }

    func testReadoutIsNilWhenNotScrubbing() {
        XCTAssertNil(
            DashboardChart.readoutText(reading: nil, samples: [sample(0, 1)], unit: .percent, format: .dateTime.hour().minute())
        )
    }

    func testReadoutInAGapSaysSoRatherThanShowingANumber() {
        XCTAssertEqual(
            DashboardChart.readoutText(
                reading: .noData,
                samples: [sample(0, 41)],
                unit: .percent,
                format: .dateTime.hour().minute()
            ),
            "no data — Mac asleep or app not running"
        )
    }

    func testReadoutBeforeTheRecordBeginsBlamesTheRightThing() {
        // Only reachable since the x-domain got pinned to the requested range:
        // before that there was no plot to the left of the first sample, so
        // every "no data" hover was necessarily inside the data's own span and
        // sleep was always the right guess. On a fresh install's 90-day chart
        // most of the plot is now to the left of the first row, and blaming
        // sleep there would be a confidently wrong answer to the exact question
        // this feature exists to answer.
        XCTAssertEqual(
            DashboardChart.readoutText(
                reading: .noData,
                samples: [sample(0, 41)],
                unit: .percent,
                format: .dateTime.hour().minute(),
                beforeRecordStart: true
            ),
            "no data — Sentry wasn't recording yet"
        )
        // Inside the record's own span, the original wording stands.
        XCTAssertEqual(
            DashboardChart.readoutText(
                reading: .noData,
                samples: [sample(0, 41)],
                unit: .percent,
                format: .dateTime.hour().minute(),
                beforeRecordStart: false
            ),
            "no data — Mac asleep or app not running"
        )
    }

    func testBeforeRecordStartNeverSuppressesARealSample() {
        // The flag only ever picks between two "no data" wordings. A hover that
        // resolved to a real row must read that row out regardless — a stale
        // `beforeRecordStart` must not be able to blank a measurement.
        let text = DashboardChart.readoutText(
            reading: .sample(index: 0),
            samples: [sample(0, 41.4)],
            unit: .percent,
            format: .dateTime.hour().minute(),
            beforeRecordStart: true
        )
        XCTAssertEqual(text?.hasSuffix("· 41%"), true, "unexpected readout: \(text ?? "nil")")
    }

    func testReadoutUsesTheMetricsOwnUnit() {
        let samples = [sample(0, 41.4), sample(240, 12.3)]
        let percent = DashboardChart.readoutText(
            reading: .sample(index: 0),
            samples: samples,
            unit: .percent,
            format: .dateTime.hour().minute()
        )
        XCTAssertNotNil(percent)
        // Routed through `MetricFormatter.compact`, the same path the cards
        // and the menu bar use — a second formatting path here is exactly what
        // would let one number render two ways.
        XCTAssertTrue(percent!.hasSuffix("· 41%"), "unexpected readout: \(percent!)")

        let bytes = DashboardChart.readoutText(
            reading: .sample(index: 0),
            samples: [sample(0, 1_500_000_000)],
            unit: .bytes,
            format: .dateTime.hour().minute()
        )
        XCTAssertNotNil(bytes)
        XCTAssertTrue(bytes!.contains("GB"), "byte-scale readout should carry its own scaled unit: \(bytes!)")
    }

    func testReadoutGuardsAnOutOfBoundsIndex() {
        XCTAssertNil(
            DashboardChart.readoutText(
                reading: .sample(index: 9),
                samples: [sample(0, 1)],
                unit: .percent,
                format: .dateTime.hour().minute()
            )
        )
    }

    // MARK: - Activity lane rows

    /// A bucket built by hand, so the readout's phrasing can be asserted
    /// without going through `ChartBucketing` (which has its own suite).
    private func bucket(
        from: TimeInterval,
        to: TimeInterval,
        min low: Double,
        avg: Double,
        max high: Double,
        count: Int = 4
    ) -> ChartBucketing.Bucket {
        ChartBucketing.Bucket(
            start: epoch.addingTimeInterval(from),
            end: epoch.addingTimeInterval(to),
            min: low,
            avg: avg,
            max: high,
            count: count,
            segment: 0
        )
    }

    func testLaneRowShowsEachSeriesRealValueInItsOwnUnit() {
        // The point of the per-lane readout: CPU reads as a percent and memory
        // as bytes, never as a y-position on a shared normalized axis.
        let cpu = ActivityLanesChart.rowText(
            .cpu,
            bucket: bucket(from: 0, to: 1800, min: 12, avg: 41.4, max: 88)
        )
        XCTAssertEqual(cpu, "CPU avg 41% · 12%–88%")

        let memory = ActivityLanesChart.rowText(
            .memory,
            bucket: bucket(from: 0, to: 1800, min: 11_000_000_000, avg: 12_000_000_000, max: 13_000_000_000)
        )
        XCTAssertTrue(memory.hasPrefix("Memory avg "), "unexpected row: \(memory)")
        XCTAssertTrue(memory.contains("GB"), "unexpected row: \(memory)")
    }

    func testLaneRowOmitsTheRangeWhenNothingWasAveraged() {
        // A single-reading bucket. Printing "41%–41%" would dress one
        // measurement up as an aggregate, and printing "avg" would claim an
        // averaging that did not happen.
        XCTAssertEqual(
            ActivityLanesChart.rowText(
                .cpu,
                bucket: bucket(from: 0, to: 0, min: 41.4, avg: 41.4, max: 41.4, count: 1)
            ),
            "CPU 41%"
        )
    }

    func testLaneRowSaysNoDataPerSeries() {
        // One lane can be in a gap while its neighbours are not — they are
        // separate queries with separate holes.
        XCTAssertEqual(ActivityLanesChart.rowText(.gpu, bucket: nil), "GPU no data")
    }

    // MARK: - Activity lane captions

    func testPointCaptionNamesTheBucketDuration() {
        // The line the whole change hangs on: a point stopped being a reading,
        // so the caption has to say what it is now.
        XCTAssertEqual(
            ActivityLanesChart.pointCaption(interval: 1800),
            "each point averages 30 min · the band is that interval's full range"
        )
    }

    func testPointCaptionClaimsNoAveragingWhenNoneHappened() {
        // `ChartBucketing`'s identity case — one sample, or a series with no
        // duration to divide — reports a zero interval.
        XCTAssertEqual(
            ActivityLanesChart.pointCaption(interval: 0),
            "each point is a single reading"
        )
    }

    func testIntervalLabelPicksTheCoarsestRoundUnit() {
        XCTAssertEqual(ActivityLanesChart.intervalLabel(3), "3 s")
        XCTAssertEqual(ActivityLanesChart.intervalLabel(89), "89 s")
        // 90s is where minutes take over, so this reads "2 min" rather than a
        // lumpy "90 s".
        XCTAssertEqual(ActivityLanesChart.intervalLabel(90), "2 min")
        // The default 24h range: 48 cells across a day is exactly half an hour.
        XCTAssertEqual(ActivityLanesChart.intervalLabel(86_400 / 48), "30 min")
        // 7d across 48 cells.
        XCTAssertEqual(ActivityLanesChart.intervalLabel(7 * 86_400 / 48), "4 h")
        // 6mo across 48 cells.
        XCTAssertEqual(ActivityLanesChart.intervalLabel(182 * 86_400 / 48), "4 d")
        XCTAssertEqual(ActivityLanesChart.intervalLabel(0), "under a second")
        // A negative interval can only come from a clock adjustment; it must
        // not render as "-3 s".
        XCTAssertEqual(ActivityLanesChart.intervalLabel(-10), "under a second")
    }

    func testLaneSummaryReportsTheBandsExtremesNotTheLinesAndNamesTheBucket() {
        // The sentence VoiceOver reads, and the one place the averaging could
        // silently swallow a spike: the extremes must come from the band, so a
        // 95% peak is announced even though no drawn point is above 60%.
        let buckets = [
            bucket(from: 0, to: 1800, min: 2, avg: 20, max: 95),
            bucket(from: 1800, to: 3600, min: 5, avg: 60, max: 71)
        ]
        let summary = ActivityLanesChart.laneSummary(.cpu, buckets: buckets, interval: 1800)
        XCTAssertEqual(summary, "CPU, 2 points, each a 30 min average, ranging from 2% to 95%")
    }

    func testLaneSummaryHandlesTheUnbucketedAndEmptyCases() {
        XCTAssertEqual(
            ActivityLanesChart.laneSummary(
                .cpu,
                buckets: [bucket(from: 0, to: 0, min: 41, avg: 41, max: 41, count: 1)],
                interval: 0
            ),
            "CPU, 1 readings, ranging from 41% to 41%"
        )
        XCTAssertEqual(
            ActivityLanesChart.laneSummary(.gpu, buckets: [], interval: 1800),
            "GPU, no data"
        )
    }

    func testSpanCaptionStatesAnIntervalRatherThanAnInstant() {
        // The readout's "when". An instant would be a precision the drawn line
        // no longer has — the number beside it is a whole cell's mean.
        let cell = epoch...epoch.addingTimeInterval(1800)
        let text = ActivityLanesChart.spanCaption(cell, format: .dateTime.hour().minute())
        XCTAssertTrue(text.contains("–"), "expected a range, got: \(text)")
        XCTAssertEqual(
            text,
            "\(cell.lowerBound.formatted(.dateTime.hour().minute())) – \(cell.upperBound.formatted(.dateTime.hour().minute()))"
        )
    }
}
