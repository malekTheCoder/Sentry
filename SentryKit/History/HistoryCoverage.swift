import Foundation

/// How much of a requested time window a series of recorded samples actually
/// covers — the arithmetic behind "you asked for 90 days; Sentry has 3."
///
/// **The bug this type exists to fix.** Both range pickers
/// (`Sentry/Dashboard/TimeRangePicker.swift`, `SentryKit/History/HistoryRange.swift`)
/// offer 24h/7d/30d/90d/6mo, and both feed a `since` bound straight into a
/// `WHERE ts >= since` query. Nothing anywhere fabricates or backfills rows, so
/// the *data* was never dishonest. The *presentation* was: no chart in this
/// product pinned its x-axis, so Swift Charts auto-fitted the domain to
/// whatever rows came back. A user three days into owning the app who tapped
/// "90d" got a line that filled the plot edge to edge and had every reason to
/// read it as ninety days of history. The owner asked exactly that question —
/// "what happens if someone hasn't had the app for that long… is this fake" —
/// and the answer being "no, it's real, it's just drawn to fill the width" is
/// not an answer a chart should make anybody ask.
///
/// **The two candidate fixes, and why this type serves both.**
///   1. *Pin the x-domain to the requested window.* Three days of a 90-day
///      window then render as a short trace hugging the right edge with the
///      unrecorded span visibly empty. Instantly legible and impossible to
///      misread — but on its own it only shows a *shape*, and a reader still
///      has to estimate "so… four days?" off the proportion.
///   2. *State the coverage in words next to the range control.* Exact, works
///      even when the shape is ambiguous — but on its own it is a caption
///      somebody can skim past while the chart underneath still looks full.
/// Neither is sufficient alone and they fail in opposite directions, so both
/// ship: `requestedDomain` drives (1), `label` drives (2), and
/// `unrecordedEdges` bridges them by washing the empty span so the caption's
/// number and the plot's geometry are visibly the same claim.
///
/// **Rejected: pad the series to the window with zeros/nulls/interpolation.**
/// This is the shape of fix that makes the chart look tidiest and it is a lie
/// in every variant. Zeros claim CPU was idle when the Mac was off. `nil`s
/// plotted as a flat baseline claim the same thing more quietly. Interpolating
/// backwards from the first real sample invents a trend nobody measured. The
/// whole point is that absence is data: the plot must show *nothing* where
/// there is nothing.
///
/// **Rejected: silently clamp the picker to the ranges the user has data for.**
/// Hiding "90d" until ninety days of history exist would make the control
/// honest by making it useless — and would hide the very fact ("I have three
/// days") this feature exists to communicate. A user is allowed to ask a
/// question whose answer is "not much yet."
///
/// **Why this lives in `SentryKit` rather than beside either chart.** Same
/// reasoning as its neighbour `ChartScrubbing`: both apps draw over the same
/// shape of data, "how much of the window do these timestamps cover" is
/// arithmetic rather than rendering, and one implementation with one test file
/// (`SentryTests/HistoryCoverageTests.swift`) is the only way macOS and iOS can
/// be guaranteed to phrase the same shortfall the same way. Foundation-only,
/// like the rest of `SentryKit/History`, so `SentryKit_iOS` (no GRDB, no
/// AppKit) compiles it unchanged.
public struct HistoryCoverage: Equatable, Sendable {

    // MARK: - Inputs

    /// The window the user asked for, or `nil` for an unbounded "all history"
    /// request.
    ///
    /// `nil` is not a degenerate case to guard past — it is what
    /// `BatteryOverviewCard`/`BatteryHealthTrendCard` genuinely ask for
    /// (`.distantPast`, all-time) and what `HistoryRange.all` means. There is
    /// no dishonest x-domain to correct in that case, because "everything" has
    /// no left edge to fall short of: the auto-fitted domain *is* the truthful
    /// one. What those callers still want from this type is the `label` — a
    /// three-day-old install looking at an all-time health chart still deserves
    /// to be told it is three days old.
    public let requested: ClosedRange<Date>?

    /// Timestamp of the oldest recorded sample, or `nil` when the series is
    /// empty.
    public let earliest: Date?

    /// Timestamp of the newest recorded sample, or `nil` when the series is
    /// empty.
    public let latest: Date?

    /// Expected spacing between consecutive rows, from
    /// `ChartScrubbing.effectiveCadence(expected:timestamps:)` or a caller that
    /// knows its tier outright.
    ///
    /// Used only as a floor under `edgeTolerance`, and it matters: a `.halfYear`
    /// chart reads one row per day, so its newest row is on average half a day
    /// old, and flagging "the last half day is unrecorded" every single time
    /// would turn a permanent, meaningless artefact of the rollup schedule into
    /// a standing warning. `0` (the default) is correct for a caller with no
    /// cadence to declare — the fractional floor below still applies.
    public let resolution: TimeInterval

    // MARK: - Construction

    public init(
        requested: ClosedRange<Date>?,
        earliest: Date?,
        latest: Date?,
        resolution: TimeInterval = 0
    ) {
        self.requested = requested
        self.earliest = earliest
        self.latest = latest
        self.resolution = resolution
    }

    /// Convenience for the common call shape: a chart holding the ascending
    /// series it is about to draw.
    ///
    /// - Parameter timestamps: ascending, as every `HistoryStore` read path
    ///   already guarantees (and as `ChartScrubbing.gaps` documents for the
    ///   same input). Non-ascending input isn't rejected — this is a drawing
    ///   helper, not a validator — it simply reports whatever sits at the ends.
    public init(requested: ClosedRange<Date>?, timestamps: [Date], resolution: TimeInterval = 0) {
        self.init(
            requested: requested,
            earliest: timestamps.first,
            latest: timestamps.last,
            resolution: resolution
        )
    }

    /// Folds several per-metric series into one statement about the window as a
    /// whole — what the Dashboard header needs, since "when does my history
    /// start" is a property of the database, not of whichever metric a
    /// particular card happens to plot.
    ///
    /// Takes the *earliest* earliest and the *latest* latest across every
    /// series, deliberately: a module the user enabled yesterday has a much
    /// later first row than CPU does, and reporting the pessimistic (newest)
    /// start would understate the history the user actually has. The header is
    /// answering "how far back does this Mac's record go," and the answer is
    /// the oldest row anything holds.
    public static func combining(_ coverages: [HistoryCoverage]) -> HistoryCoverage? {
        guard let first = coverages.first else { return nil }
        return HistoryCoverage(
            requested: first.requested,
            earliest: coverages.compactMap(\.earliest).min(),
            latest: coverages.compactMap(\.latest).max(),
            resolution: coverages.map(\.resolution).max() ?? 0
        )
    }

    // MARK: - Spans

    /// Length of the requested window; `0` for an unbounded request.
    public var requestedDuration: TimeInterval {
        guard let requested else { return 0 }
        return requested.upperBound.timeIntervalSince(requested.lowerBound)
    }

    /// The part of the window the record actually spans, end to end.
    ///
    /// Measured from the oldest to the newest sample, clipped to the window —
    /// *not* from the oldest sample to "now". The difference shows up on a Mac
    /// that has been shut for two days: the record still only reaches from its
    /// first row to its last, and counting the silent tail as "recorded" would
    /// re-introduce, in the caption, exactly the overclaim the pinned domain
    /// removes from the plot.
    public var recordedDuration: TimeInterval {
        guard let earliest, let latest else { return 0 }
        guard let requested else { return Swift.max(0, latest.timeIntervalSince(earliest)) }
        let low = Swift.max(earliest, requested.lowerBound)
        let high = Swift.min(latest, requested.upperBound)
        return Swift.max(0, high.timeIntervalSince(low))
    }

    /// `recordedDuration / requestedDuration`, clamped to `0...1`. `0` for an
    /// unbounded request, which has no denominator — callers wanting a
    /// proportion should have a window.
    public var fraction: Double {
        guard requestedDuration > 0 else { return 0 }
        return Swift.min(1, Swift.max(0, recordedDuration / requestedDuration))
    }

    // MARK: - Materiality

    /// Below this share of the requested window, an unrecorded edge is treated
    /// as an artefact of where rows happened to land rather than as missing
    /// history.
    ///
    /// 1% rather than something looser: the label states the shortfall in
    /// words, so being precise costs nothing — "88 of 90 days recorded" is
    /// simply true and no more alarming than it should be. The threshold exists
    /// only to stop the *wash* and the "N of M" phrasing from firing on a
    /// window whose first row landed a few seconds after the query's `since`,
    /// which is the normal state of every full chart in the app. Anything
    /// looser would start hiding real shortfalls: 5% of a 90-day window is four
    /// and a half days, which is most of a new user's entire history.
    public static let edgeToleranceFraction: Double = 0.01

    /// How much unrecorded time at either edge is noise rather than news — the
    /// larger of `edgeToleranceFraction` of the window and one `resolution`
    /// step, because a series that only produces a row per day cannot be
    /// expected to have one within the last minute.
    public var edgeTolerance: TimeInterval {
        Swift.max(requestedDuration * Self.edgeToleranceFraction, resolution)
    }

    /// The leading span of the requested window with no data in it — the
    /// "before Sentry was recording" region — or `nil` when the record reaches
    /// back far enough to cover it.
    ///
    /// An empty series returns the *whole* window: nothing was recorded
    /// anywhere in it, and a chart with no line at all should still show the
    /// span it was asked about rather than nothing.
    public var unrecordedLead: ClosedRange<Date>? {
        guard let requested else { return nil }
        guard let earliest else { return requested }
        guard earliest > requested.lowerBound,
              earliest.timeIntervalSince(requested.lowerBound) > edgeTolerance else { return nil }
        return requested.lowerBound...Swift.min(earliest, requested.upperBound)
    }

    /// The trailing span with no data — a Mac that has been shut since
    /// Tuesday — or `nil` when the record runs up to the window's end.
    ///
    /// Distinct from an interior gap (`ChartScrubbing.gaps`) only in that
    /// nothing bounds it on the right, which is precisely why the auto-fitted
    /// domain hid it: with no pinning, the newest sample simply *became* the
    /// right edge and three days of silence looked like "now".
    public var unrecordedTail: ClosedRange<Date>? {
        guard let requested, let latest else { return nil }
        guard requested.upperBound > latest,
              requested.upperBound.timeIntervalSince(latest) > edgeTolerance else { return nil }
        return Swift.max(latest, requested.lowerBound)...requested.upperBound
    }

    /// Both unrecorded edges, in chronological order — what a chart shades.
    ///
    /// Deliberately the *same* regions type and the same visual treatment as
    /// `ChartScrubbing.gaps` gets, rather than a second, louder "you have no
    /// history" band. A hole because the Mac slept and a hole because Sentry
    /// wasn't installed yet are the same fact to a reader looking at the plot —
    /// nothing was measured here — and inventing a second wash for the second
    /// cause would make one chart speak two visual languages about one absence.
    /// What distinguishes them is the *words*: the scrub readout names the
    /// cause (see `HistoryCoverage.beganRecording`), and the caption states the
    /// span.
    public var unrecordedEdges: [ClosedRange<Date>] {
        [unrecordedLead, unrecordedTail].compactMap { $0 }
    }

    /// True when the record covers the whole requested window to within
    /// `edgeTolerance` at both ends. Always false for an empty series with a
    /// window; always true for an unbounded request, which cannot fall short of
    /// an edge it doesn't have.
    public var isComplete: Bool {
        unrecordedLead == nil && unrecordedTail == nil
    }

    /// When the record begins — the point before which a chart must not imply
    /// anything at all. `nil` for an empty series.
    ///
    /// Exists as a named property (rather than callers reading `earliest`
    /// directly) because it is used for a different job: `earliest` is a
    /// statistic, this is the boundary a scrub readout consults to decide
    /// between "no data — Mac asleep or app not running" and "no data — before
    /// Sentry started recording." Those are different sentences and only one of
    /// them is true on either side of this instant.
    public var beganRecording: Date? { earliest }

    /// The x-domain a chart should pin to, or `nil` when it should keep its
    /// auto-fitted one (an unbounded "all history" request).
    public var requestedDomain: ClosedRange<Date>? { requested }

    // MARK: - Phrasing

    /// The unit a duration is best stated in. Two units only, because these are
    /// the two the range picker's own cases live in — the shortest window is a
    /// day and the longest six months, so nothing here ever wants seconds, and
    /// "0.4 months" is not a sentence anybody says.
    public enum Unit: String, Equatable, Sendable {
        case hours, days
    }

    /// A duration as a whole number of hours or days, floored.
    ///
    /// Floored rather than rounded, on purpose and in one direction: this
    /// number's whole job is to stop the app overstating how much history it
    /// has, so 3.9 days reads as "3 days". Rounding would let 3.6 days claim
    /// "4 days recorded" — a small lie, but a lie of exactly the kind this file
    /// exists to remove.
    ///
    /// The hours/days switch is at 48h to match `DashboardChart.xAxisFormat`'s
    /// own boundary, so the caption's unit and the axis labels' granularity
    /// change at the same moment rather than disagreeing across it.
    public static func quantity(_ duration: TimeInterval) -> (value: Int, unit: Unit) {
        let seconds = Swift.max(0, duration)
        if seconds < 48 * 3600 {
            return (Int(seconds / 3600), .hours)
        }
        return (Int(seconds / 86400), .days)
    }

    /// "3 days", "1 hour", "under an hour".
    public static func phrase(_ duration: TimeInterval) -> String {
        let (value, unit) = quantity(duration)
        if unit == .hours && value < 1 {
            // Not "0 hours": a fresh install genuinely has *some* history and
            // rendering it as zero would read as "none", which is the opposite
            // error from the one this file fixes but an error all the same.
            return String(localized: "under an hour")
        }
        let count = String(value)
        switch (unit, value) {
        case (.hours, 1): return String(localized: "1 hour")
        case (.hours, _): return String(localized: "\(count) hours")
        case (.days, 1): return String(localized: "1 day")
        case (.days, _): return String(localized: "\(count) days")
        }
    }

    /// The one sentence both platforms put next to their range control, and the
    /// note a full-size chart repeats under its plot when it falls short.
    ///
    /// Shown *always*, not only when short, which is the deliberate half of
    /// treatment (2): a caption that appears only in the bad case is a warning,
    /// and a reader learns to read its absence as "fine" without ever learning
    /// what the number is. Stated every time, it is just a fact about the
    /// window — "90 days recorded" — and the day it reads "3 of 90 days
    /// recorded" the reader already knows what kind of statement it is.
    ///
    /// Returns `nil` only when there is genuinely nothing to say: an unbounded
    /// request with no samples at all, where the chart's own empty state
    /// already carries the whole message.
    public var label: String? {
        guard requested != nil else {
            guard earliest != nil else { return nil }
            return String(localized: "\(Self.phrase(recordedDuration)) recorded")
        }
        let total = Self.phrase(requestedDuration)
        guard earliest != nil else {
            return String(localized: "nothing recorded in the last \(total)")
        }
        if isComplete {
            return String(localized: "\(total) recorded")
        }
        let (recordedValue, recordedUnit) = Self.quantity(recordedDuration)
        // "3 of 90 days recorded" when the two land in the same unit, and the
        // longer "5 hours of 90 days recorded" when they don't — a bare "5 of
        // 90" that silently meant hours-of-days would be worse than clunky, it
        // would be wrong by a factor of 24.
        let recorded = recordedUnit == Self.quantity(requestedDuration).unit && recordedValue >= 1
            ? String(recordedValue)
            : Self.phrase(recordedDuration)
        return String(localized: "\(recorded) of \(total) recorded")
    }

    /// "since Jun 27" — where the record starts, for callers with room to say
    /// it alongside `label`. `nil` for an empty series.
    ///
    /// A date rather than another duration because the two answer different
    /// questions and a reader wants both: "3 of 90 days" says how much is
    /// missing, "since Jun 27" says whether that matches when they installed
    /// the app — which is what turns "is this fake?" into "oh, right, I got
    /// this in June."
    public func startDescription(includeYear: Bool = false) -> String? {
        guard let earliest else { return nil }
        let format: Date.FormatStyle = includeYear
            ? .dateTime.month(.abbreviated).day().year()
            : .dateTime.month(.abbreviated).day()
        let day = earliest.formatted(format)
        return String(localized: "since \(day)")
    }

    /// `label`, plus `startDescription` when the window is short — the exact
    /// string both range controls render.
    ///
    /// The start date is appended only in the shortfall case on purpose: on a
    /// complete window it is derivable from the range the user just picked
    /// ("90 days recorded" starting, obviously, 90 days ago) and would be pure
    /// duplication in a caption that has to stay short enough to sit beside a
    /// five-segment picker.
    public var summary: String? {
        guard let label else { return nil }
        guard !isComplete || requested == nil, let start = startDescription() else { return label }
        return "\(label) · \(start)"
    }
}
