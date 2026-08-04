import Foundation

/// Pure CSV/JSON formatting for a metric's exported history.
///
/// **Why this exists.** Nothing in the app lets a user get history data out
/// of it — `HistoryStore` only ever hands rows to another Swift caller
/// (`samples`/`samplesWithRange`), never to a file. The Dashboard's
/// "Export…" action (`DashboardChart.exportContext`, wired from
/// `DashboardGrid`/`DashboardView`) is the first, and this file is
/// deliberately just the text-shaping half of it: no `NSSavePanel`, no file
/// I/O, no `HistoryStore` call. That split is what lets the exact output for
/// fabricated sample data be asserted in `SentryTests/HistoryExportTests.swift`
/// without a database, a save panel, or the filesystem anywhere in the test.
///
/// **Why `timestamp, value, unit` and not the `(min, avg, max)` band
/// `HistoryStore.samplesWithRange` actually returns.** A file a user opens in
/// Numbers or a script is answering "what was this metric over time," which
/// is one number per moment — the min/max band is a charting concern
/// (`DashboardChart`'s `AreaMark`), not a fact about the metric itself, and
/// exporting three columns for `.raw`-tier data where `min == avg == max`
/// (see that method's own doc comment) would just be two redundant columns.
/// Callers reduce a ranged sample to `Sample(timestamp:value:)` by taking
/// `avg` — the same number the chart's own line (`LineMark`) plots.
public enum HistoryExport {

    /// One row of exported history. Its own type rather than reusing
    /// `HistoryStore.samplesWithRange`'s tuple shape — a tuple can't conform
    /// to `Equatable`, which the tests here want, and `value`/`unit` need to
    /// be independently optional at the call site (see below), which the
    /// tuple's `Double`/non-optional shape doesn't allow.
    public struct Sample: Equatable, Sendable {
        public let timestamp: Date
        /// `nil` for "a moment was recorded but there is no reading for it" —
        /// distinguished from `0`, the same P5 "never fabricate a zero"
        /// discipline `MetricFormatting`/`VitalDetail` already apply
        /// everywhere else in this app. In practice every row
        /// `HistoryStore.samplesWithRange` produces has a value (its SQL
        /// guards `NOT NULL` columns), so this case is exercised by tests
        /// rather than by any real query today — kept optional anyway so a
        /// future gap-aware source (or a hand-built row) can say so honestly
        /// instead of the caller inventing a placeholder number.
        public let value: Double?

        public init(timestamp: Date, value: Double?) {
            self.timestamp = timestamp
            self.value = value
        }
    }

    /// ISO 8601, UTC (`ISO8601DateFormatter`'s default `timeZone` is UTC) —
    /// the one timestamp format every spreadsheet app and script re-imports
    /// without a locale-dependent parse, and unambiguous regardless of what
    /// time zone the exporting or importing Mac is set to.
    private static let timestampFormatter = ISO8601DateFormatter()

    /// Renders a `Double` the same way regardless of the user's region — a
    /// bare `.` decimal separator, never a locale's `,` (which a US-locale
    /// CSV importer would misread as a column break). Non-finite values
    /// (`NaN`/`±infinity`) collapse to the same "no reading" empty field a
    /// nil `value` produces, rather than writing text a numeric column
    /// parser would choke on.
    private static func valueText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return String(value)
    }

    // MARK: - CSV

    /// `timestamp,value,unit` — a header row, then one row per sample, in
    /// the order given (callers are expected to hand this rows already
    /// sorted ascending, the same guarantee every `HistoryStore` read path
    /// makes — this function does not re-sort).
    ///
    /// `unit` is repeated on every row rather than stated once, so a row
    /// extracted from the middle of the file (or the file re-merged with
    /// another metric's export) is still self-describing. `metricID` isn't a
    /// column at all — every row in one export names exactly one metric by
    /// construction (the caller queried one `MetricID`), so repeating it
    /// per-row would be redundant with the file itself; it exists as a
    /// parameter purely so callers have one obvious place to also derive a
    /// suggested filename (`DashboardChart`'s save panel does exactly that),
    /// keeping "what metric is this" in sync between the two without a
    /// second constant.
    ///
    /// `unit` is `nil`-able for the same reason `Sample.value` is: a caller
    /// that genuinely has no unit for a series (a future, unitless metric)
    /// gets an honest empty field instead of a fabricated one.
    public static func csv(metricID: String, unit: MetricUnit?, samples: [Sample]) -> String {
        var lines = ["timestamp,value,unit"]
        lines.reserveCapacity(samples.count + 1)
        let unitText = unit?.rawValue ?? ""
        for sample in samples {
            let timestampText = timestampFormatter.string(from: sample.timestamp)
            lines.append("\(timestampText),\(valueText(sample.value)),\(unitText)")
        }
        // Trailing newline: the POSIX-text convention every other file this
        // app writes (settings.json via `JSONEncoder`, etc. aside) — most
        // Unix tools and `diff` treat a file with no final newline as
        // malformed.
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - JSON

    /// One object per sample, `{"timestamp": "...", "value": ..., "unit":
    /// "..."}` — same three fields and the same nil handling as `csv`, so a
    /// consumer that reads both formats never sees a fact expressed one way
    /// in one file and a different way in the other. `value`/`unit` encode
    /// as JSON `null` when absent, never a sentinel number or the string
    /// `"null"`, so "no reading" stays distinguishable from a real `0` in a
    /// language-agnostic way (JSON's own null, not a string this app made up).
    private struct JSONRow: Encodable {
        let timestamp: String
        let value: Double?
        let unit: String?

        private enum CodingKeys: String, CodingKey {
            case timestamp, value, unit
        }

        /// Hand-written rather than the synthesized `Encodable` this struct
        /// would otherwise get for free: Swift's auto-synthesis encodes an
        /// `Optional` property via `encodeIfPresent`, which *omits the key
        /// entirely* when the value is `nil` — not the explicit JSON `null`
        /// this type's own doc comment promises. `encodeNil(forKey:)` is
        /// what actually writes `null`.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(timestamp, forKey: .timestamp)
            if let value {
                try container.encode(value, forKey: .value)
            } else {
                try container.encodeNil(forKey: .value)
            }
            if let unit {
                try container.encode(unit, forKey: .unit)
            } else {
                try container.encodeNil(forKey: .unit)
            }
        }
    }

    /// - Returns: Pretty-printed, UTF-8 JSON — an empty `samples` array
    ///   encodes as `[]`, not an error or an omitted file, matching every
    ///   other "queried and genuinely empty" case in this app (P5).
    public static func json(metricID: String, unit: MetricUnit?, samples: [Sample]) -> Data {
        let rows = samples.map { sample in
            JSONRow(
                timestamp: timestampFormatter.string(from: sample.timestamp),
                // Non-finite values are sanitized to `nil` here rather than
                // left for `JSONEncoder` to reject: the default encoding
                // strategy *throws* on `NaN`/`±infinity`, which would turn a
                // single bad sample into a failed export for the whole file
                // instead of the same honest `null` the CSV path already
                // gives that row.
                value: (sample.value?.isFinite ?? false) ? sample.value : nil,
                unit: unit?.rawValue
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // `JSONRow` only contains a `String`/`Double?`/`String?` — none of
        // which this encoder configuration can fail to encode once the
        // non-finite case above is handled — so a thrown error here would
        // indicate a programmer mistake, not a runtime condition callers
        // need to react to. `try!` says so rather than silently swallowing
        // it behind `try?` and returning empty JSON that looks like a
        // legitimate "no samples" export.
        return try! encoder.encode(rows)
    }
}
