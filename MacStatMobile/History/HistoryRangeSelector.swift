import SwiftUI
import MacStatKit

/// Thin `Picker` wrapper around `HistoryRange` (`MacStatKit/History/HistoryRange.swift`),
/// mirroring `TimeRangePickerView`'s (`MacStat/Dashboard/TimeRangePicker.swift`)
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
    }

    /// Display-only override of `HistoryRange.label`, confined to this view.
    ///
    /// The Nocturne redesign spec asks for the same 5-range wording
    /// (24h/7d/30d/90d/6mo) on both platforms' history/dashboard range
    /// controls. The macOS Dashboard's `TimeRangePicker`
    /// (`MacStat/Dashboard/TimeRangePicker.swift`) is being renamed to that
    /// case set independently and concurrently by another agent; per this
    /// task's scope, `HistoryRange` itself (`MacStatKit/History/HistoryRange.swift`)
    /// is out of bounds here — it's a `MacStatKit` file another agent may
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
