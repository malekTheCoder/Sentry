import SwiftUI
import SentryKit

/// The one column grid the whole dropdown is set on.
///
/// Stated once, here, rather than as literals at each call site: the vitals
/// rows, their expanded detail lines, the keep-awake rows and the action row
/// all have to land on the same left edge, the same right edge and the same
/// row height, and the surest way to lose that is to let four files each pick
/// their own numbers. Every value below is a whole point at every density.
enum DropdownGrid {
    /// Width of the inline usage meter column.
    static let meterWidth: CGFloat = 54
    /// Width of the right-aligned value column. Sized for "100%" plus a
    /// severity glyph so a flagged row never widens the column.
    static let valueWidth: CGFloat = 56
    /// Reserved even when no chevron is drawn, so hover-revealing one can't
    /// reflow the value beside it.
    static let chevronWidth: CGFloat = 10
    /// Also the accessibility minimum for a hit target, which is why every
    /// interactive row in the dropdown is exactly this tall.
    static let rowHeight: CGFloat = 28
    /// Subordinate rows: shorter, so an expanded group reads as one block
    /// rather than as more top-level rows.
    static let detailRowHeight: CGFloat = 22

    /// Trailing inset that puts a plain label/value row's value on the same
    /// right edge as a vitals row's value — i.e. clearing the chevron slot.
    static func valueTrailingInset(_ palette: ThemePalette) -> CGFloat {
        palette.spacingTight + chevronWidth + palette.spacingTight
    }
}

/// The dropdown's vitals table: one dense, quiet row per core reading.
///
/// **Why a table and not cards.** The previous pass rendered four readings as
/// a 2×2 grid of rounded, bordered, filled tiles with 18pt monospaced numbers.
/// That reads as four competing objects — the eye has to visit each box, and
/// nothing in the layout says which one matters. A table with a fixed column
/// grid reads as one object: labels left, meters in a column, values
/// right-aligned on a shared edge, so scanning the value column is a single
/// vertical saccade. Density is not the enemy of a calm surface; noise is, and
/// four boxes are noise.
///
/// **Why the numbers got smaller.** Size is a hierarchy tool with exactly one
/// top slot, and it belongs to the verdict line above this table
/// (`DropdownView.statusBlock`) — the sentence that actually answers "is my Mac
/// OK". The readings behind that sentence are supporting evidence and sit at
/// the surface's body size, separated from their labels by contrast rather
/// than by scale.
///
/// **Progressive disclosure.** Every row is a button; expanding one reveals
/// that module's full detail rows — what `ModuleCardStack` used to show inline,
/// minus the sparkline. Collapsed is the default and the resting height, so the
/// glance never costs a scroll: the depth is there for the one row you're
/// actually asking about, and the Dashboard still has all of it plus history.
struct VitalsSection: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let vitals: [Vital]
    /// Distinguishes "no snapshot yet" (draw the skeleton, data is coming)
    /// from "a snapshot arrived and produced no rows" (every module is off).
    let isAwaitingFirstReading: Bool
    /// Dimmed when the newest snapshot is old enough that the numbers may no
    /// longer describe the machine — see `DropdownView.staleness`.
    let isStale: Bool
    let onOpenSettings: () -> Void

    /// One row open at a time. An accordion rather than independent toggles
    /// because a 320pt popover that can grow past the screen edge is a worse
    /// failure than one extra click, and because "the thing I just asked
    /// about" is a single thing.
    @State private var expandedID: String?
    @State private var hoveredID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isAwaitingFirstReading {
                skeleton
            } else if vitals.isEmpty {
                noModulesEnabled
            } else {
                ForEach(vitals) { vital in
                    row(for: vital)
                    if expandedID == vital.id {
                        details(for: vital)
                    }
                }
            }
        }
        .opacity(isStale ? 0.5 : 1)
        .animation(ThemePalette.motion(reduceMotion: reduceMotion), value: isStale)
    }

    // MARK: Row

    private func row(for vital: Vital) -> some View {
        let isExpanded = expandedID == vital.id
        let isHovered = hoveredID == vital.id
        return Button {
            withAnimation(ThemePalette.disclosureMotion(reduceMotion: reduceMotion)) {
                expandedID = isExpanded ? nil : vital.id
            }
        } label: {
            HStack(spacing: palette.spacingTight) {
                Text(vital.title)
                    .font(palette.font(size: 11))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: palette.spacingTight)
                VitalMeter(
                    fraction: vital.fraction,
                    level: vital.level,
                    tint: palette.moduleColor(vital.module)
                )
                .frame(width: DropdownGrid.meterWidth)
                valueLabel(for: vital)
                chevron(isExpanded: isExpanded, isVisible: isHovered || isExpanded)
            }
            .padding(.horizontal, palette.spacingTight)
            .frame(height: DropdownGrid.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowHighlight(isActive: isHovered || isExpanded))
        .onHover { hovering in
            withAnimation(ThemePalette.motion(reduceMotion: reduceMotion)) {
                if hovering {
                    hoveredID = vital.id
                } else if hoveredID == vital.id {
                    hoveredID = nil
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel(for: vital))
        .accessibilityHint(isExpanded ? "Hide details" : "Show details")
    }

    /// Value and severity glyph share one right-aligned column so the numbers
    /// stay on the grid whether or not a row is flagged — a warning triangle
    /// that pushed the value left would make the whole column jump at exactly
    /// the moment something went wrong.
    private func valueLabel(for vital: Vital) -> some View {
        HStack(spacing: 3) {
            if let symbol = vital.level.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 9))
            }
            VitalValueText(value: vital.value, tint: color(for: vital.level, normal: palette.textPrimary))
        }
        .lineLimit(1)
        .frame(width: DropdownGrid.valueWidth, alignment: .trailing)
    }

    private func chevron(isExpanded: Bool, isVisible: Bool) -> some View {
        // The slot is always reserved and only its contents fade: revealing a
        // chevron on hover must not reflow the value column beside it.
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(palette.textTertiary)
            .opacity(isVisible ? 1 : 0)
            .frame(width: DropdownGrid.chevronWidth, alignment: .trailing)
    }

    @ViewBuilder
    private func rowHighlight(isActive: Bool) -> some View {
        if isActive {
            RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                .fill(palette.surface)
        }
    }

    // MARK: Details

    private func details(for vital: Vital) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let note = vital.levelNote, vital.level != .normal {
                detailLine(label: note, value: nil, level: vital.level)
            }
            ForEach(vital.details) { detail in
                detailLine(label: detail.label, value: detail.value, level: .normal)
            }
        }
        .padding(.bottom, palette.spacingTight)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(vital.title) details")
    }

    private func detailLine(label: String, value: String?, level: VitalLevel) -> some View {
        HStack(spacing: palette.spacingTight) {
            Text(label)
                .font(palette.font(size: 11))
                .foregroundStyle(color(for: level, normal: palette.textTertiary))
                .lineLimit(1)
            Spacer(minLength: palette.spacingTight)
            if let value {
                Text(value)
                    .font(palette.numericFont(size: 11))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        // Right edge matches the row's value column plus its chevron slot, so
        // detail numbers stack under the headline numbers instead of beside them.
        .padding(.leading, palette.spacingTight + palette.spacingRow)
        .padding(.trailing, palette.spacingTight + DropdownGrid.chevronWidth + palette.spacingTight)
        .frame(height: DropdownGrid.detailRowHeight)
        .accessibilityElement(children: .combine)
    }

    // MARK: Empty states

    /// Shown until the first snapshot lands. Real rows at rest rather than a
    /// spinner: the labels are already known and never change, so drawing them
    /// tells the user exactly what is about to appear — and because the
    /// skeleton is the same grid at the same height, nothing moves when the
    /// numbers arrive.
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(["CPU", "Memory", "Disk", "Battery"], id: \.self) { title in
                HStack(spacing: palette.spacingTight) {
                    Text(title)
                        .font(palette.font(size: 11))
                        .foregroundStyle(palette.textTertiary)
                    Spacer(minLength: palette.spacingTight)
                    VitalMeter(fraction: nil, level: .normal, tint: palette.textTertiary)
                        .frame(width: DropdownGrid.meterWidth)
                    Text(MetricFormatting.placeholder)
                        .font(palette.numericFont(size: 11, weight: .medium))
                        .foregroundStyle(palette.textTertiary)
                        .frame(width: DropdownGrid.valueWidth, alignment: .trailing)
                    Spacer().frame(width: DropdownGrid.chevronWidth)
                }
                .padding(.horizontal, palette.spacingTight)
                .frame(height: DropdownGrid.rowHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waiting for the first reading")
    }

    /// A snapshot arrived, but every module that would produce a row is turned
    /// off. Says so, and offers the one control that fixes it, rather than
    /// rendering an unexplained blank gap.
    private var noModulesEnabled: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("No modules are turned on.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textSecondary)
                .frame(height: DropdownGrid.detailRowHeight, alignment: .leading)
            Button(action: onOpenSettings) {
                HStack(spacing: 3) {
                    Text("Choose what to monitor")
                        .font(palette.font(size: 11, weight: .medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .medium))
                }
                .foregroundStyle(palette.accent)
                .frame(height: DropdownGrid.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose what to monitor in Settings")
        }
        .padding(.horizontal, palette.spacingTight)
    }

    // MARK: Shared

    /// The section's entire color policy in one place: neutral unless the
    /// reading crossed a threshold.
    private func color(for level: VitalLevel, normal: Color) -> Color {
        switch level {
        case .normal: return normal
        case .warning: return palette.warning
        case .critical: return palette.danger
        }
    }

    private func accessibilityLabel(for vital: Vital) -> String {
        var parts = ["\(vital.title), \(vital.value.plain)"]
        if vital.level != .normal {
            parts.append(vital.levelNote ?? vital.level.accessibilityDescription)
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Value

/// Digits at body size, unit one step smaller and one step quieter, set tight
/// against them.
///
/// A single `Text("68%")` gives the percent sign the same weight as the figure
/// and — for `ByteCountFormatter` output like "6.69 GB" — a full word space in
/// front of it, so a column of values reads as ragged pairs of words instead of
/// as numbers. Concatenated `Text` runs rather than two views so the baselines
/// are typographic, not laid out.
private struct VitalValueText: View {
    @Environment(\.themePalette) private var palette

    let value: VitalValue
    let tint: Color

    // Declared as `Text`, not `some View`: the whole point is that these are
    // two runs of one string rather than two views, and the concrete type is
    // what makes `+` (and therefore shared baselines) available.
    var body: Text {
        let digits = Text(value.number)
            .font(palette.numericFont(size: 11, weight: .medium))
            .foregroundStyle(tint)
        guard let unit = value.unit else { return digits }
        return digits + Text(unit)
            .font(palette.font(size: 9, weight: .medium))
            // Always the neutral ramp, even on a flagged row: the glyph and the
            // digits already carry the severity, and tinting a third element
            // makes a warning row look like an error page.
            .foregroundStyle(palette.textTertiary)
    }
}

// MARK: - Meter

/// A 3pt track — the entire visual budget for "how full is this".
///
/// The fill carries the module's own theme color (CPU blue, GPU green, …) —
/// the one deliberate spot of color on each row, matching the Dashboard's
/// chart tints so the two surfaces speak the same visual language. A flagged
/// reading overrides the module color with `warning`/`danger`, because
/// severity always outranks identity.
private struct VitalMeter: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// nil renders the bare track — "not measured" rather than "measured zero".
    let fraction: Double?
    let level: VitalLevel
    /// The module's theme color, used at `.normal`.
    let tint: Color

    private var fill: Color {
        switch level {
        case .normal: return tint
        case .warning: return palette.warning
        case .critical: return palette.danger
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(palette.separator)
                if let fraction, fraction > 0 {
                    Capsule(style: .continuous)
                        .fill(fill)
                        // A 2pt floor so a real-but-tiny reading (1% CPU) still
                        // shows as a mark instead of vanishing into the track
                        // and reading as "no data".
                        .frame(width: max(proxy.size.width * fraction, 2))
                }
            }
        }
        .frame(height: 3)
        .animation(ThemePalette.motion(reduceMotion: reduceMotion), value: fraction)
        .accessibilityHidden(true)
    }
}

// MARK: - Shared

/// Label/value pair used by detail sections. Values are pre-formatted so the
/// nil handling stays in `MetricFormatting`.
///
/// Moved here from the now-deleted `Sentry/Dropdown/ModuleCards/
/// MetricCard.swift` (see that commit's dead-code cleanup, and
/// `DropdownViewModel`'s doc comment for why the module cards it belonged to
/// were dead) rather than deleted along with it: `Sentry/Dashboard/
/// DashboardGrid.swift` is still a live caller, and this row happened to be
/// the one reusable piece of that file worth keeping.
struct MetricDetailRow: View {
    @Environment(\.themePalette) private var palette

    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(palette.font(size: 10))
                .foregroundStyle(palette.textTertiary)
            Spacer(minLength: palette.spacing)
            Text(value)
                .font(palette.font(size: 10))
                .monospacedDigit()
                .foregroundStyle(palette.textSecondary)
        }
    }
}

// MARK: - Preview

#Preview {
    VitalsSection(
        vitals: [],
        isAwaitingFirstReading: true,
        isStale: false,
        onOpenSettings: {}
    )
    .padding()
    .frame(width: 320)
    .environment(\.themePalette, ThemePalette(theme: .defaultTheme, scheme: .dark))
    .background(ThemePalette(theme: .defaultTheme, scheme: .dark).background)
}
