import SwiftUI
import SentryKit

/// Thin `Picker` wrapper around `HistoryRange` (`SentryKit/History/HistoryRange.swift`),
/// mirroring `TimeRangePickerView`'s (`Sentry/Dashboard/TimeRangePicker.swift`)
/// shape on the Mac side — same "not theme-styled beyond the system
/// segmented control" reasoning applies: this is a standard
/// `.pickerStyle(.segmented)` control, and re-skinning it to match
/// `ThemePalette` would fight the platform's native look for no benefit the
/// way a custom `Chart` does.
struct HistoryRangeSelector: View {
    @Binding var selection: HistoryRange

    var body: some View {
        Picker("Range", selection: $selection) {
            ForEach(HistoryRange.allCases) { range in
                Text(Self.displayLabel(for: range))
                    .accessibilityLabel(range.accessibilityLabel)
                    .tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // The one clamp in this app, and it is a property of the control, not
        // a layout convenience. `UISegmentedControl` divides its width equally
        // among its segments and neither wraps nor scrolls; with five segments
        // on a phone that is roughly 60pt each. Past `.accessibility1` the
        // labels stop fitting and UIKit truncates them, at which point "30d"
        // and "90d" both render as an ellipsis and the control becomes
        // ambiguous — the exact failure `PerMetricHistoryBrowser`'s doc
        // comment documents for its own former segmented picker, and the
        // reason that one became a scrolling chip row.
        //
        // The same escape isn't available here: unlike the module picker's
        // nine long names, these are five two-to-three-character labels that
        // are *already* as short as they can be, so there is nothing left to
        // shorten and no truncation-free shape a segmented control can take.
        // Everything around this control scales normally; the range labels
        // stop growing at `.accessibility1` and stay legible rather than
        // growing into an ellipsis.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    /// Display-only override of `HistoryRange.label`, confined to this view.
    ///
    /// The Nocturne redesign spec asks for the same 5-range wording
    /// (24h/7d/30d/90d/6mo) on both platforms' history/dashboard range
    /// controls. The macOS Dashboard's `TimeRangePicker`
    /// (`Sentry/Dashboard/TimeRangePicker.swift`) is being renamed to that
    /// case set independently and concurrently by another agent; per this
    /// task's scope, `HistoryRange` itself (`SentryKit/History/HistoryRange.swift`)
    /// is out of bounds here — it's a `SentryKit` file another agent may
    /// also be touching, and per the "near-duplicate, no cross-target
    /// sharing" convention documented on `ThemeColor+SwiftUI.swift`, this
    /// tab's range control is intentionally independent of the Mac's
    /// anyway. So this remaps `HistoryRange`'s existing 5 cases to the
    /// shared label text at the rendering layer only — `HistoryRange.label`,
    /// `.since(now:)`, and `.syntheticDayCount` are all untouched, including
    /// `.all`'s underlying "since the beginning" semantics; only its segment
    /// text changes, to "6mo", for visual parity with the Mac's control.
    private static func displayLabel(for range: HistoryRange) -> String {
        switch range {
        case .last24Hours: return "24h"
        case .last7Days: return "7d"
        case .last30Days: return "30d"
        case .last90Days: return "90d"
        case .all: return "6mo"
        }
    }
}
