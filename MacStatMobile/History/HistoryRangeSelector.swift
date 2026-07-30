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
                Text(range.label)
                    .accessibilityLabel(range.accessibilityLabel)
                    .tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
