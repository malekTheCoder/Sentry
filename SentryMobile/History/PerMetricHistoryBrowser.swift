import SwiftUI
import SentryKit

/// Plan §12.1's "per-metric history browser," deliberately scoped down to a
/// browsable list of the *latest snapshot's current values*, grouped by
/// module, rather than a full synthetic history per metric.
///
/// **Why the scope-down.** A real per-metric history browser implies a
/// CloudKit query over `SnapshotRecord`/rollup tables — the same job
/// `HistoryStore` does on the Mac side — and no such fetch API exists for
/// this transport (same gap `MockDataSource.dailyHealthHistory`'s doc
/// comment describes for `DailyHealth`, just for every `SnapshotRecord`
/// field instead of one). Fabricating a plausible-looking synthetic
/// *history* for all ~50 `MetricID` cases (`SentryKit/Models/MetricID.swift`)
/// would be a large amount of invented, never-real numbers for a browser
/// whose actual job is letting someone find "what does GPU power currently
/// read" — disproportionate effort for what this build can honestly offer.
/// This instead reuses the one thing this app already has that's at least
/// *shaped* like real data: the latest `SystemSnapshot` from
/// `MockDataSource.snapshots()`, read out per-metric via
/// `SystemSnapshot.value(for:)` (`SentryKit/Models/SystemSnapshot+MetricValue.swift`)
/// — the same accessor the Mac dropdown's chart uses
/// (`DropdownViewModel.value(of:in:)`), so a `nil` here means the same thing
/// it means there: "this Mac doesn't report this field," not "zero."
struct PerMetricHistoryBrowser: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let snapshot: SystemSnapshot?

    @State private var selectedModule: MetricModule = .battery

    /// Chip label size. `palette.font(size:)` builds a fixed-size
    /// `Font.system(size:)` (see `SentryMobile/Theme/ThemeColor+SwiftUI.swift`),
    /// which does *not* respond to Dynamic Type — fine for the menu-bar-derived
    /// designs it was written for, wrong for a touch control that a user with
    /// large text needs to read. `@ScaledMetric` scales the number instead, so
    /// the chips keep the theme's font family and still grow with the system
    /// text size. Growth is safe here precisely because the row scrolls: wider
    /// chips push the row longer rather than squeezing the labels.
    @ScaledMetric(relativeTo: .body) private var chipFontSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            header
            modulePicker

            if let snapshot {
                metricList(for: snapshot)
            } else {
                Text("No snapshot yet")
                    .font(.caption)
                    .foregroundStyle(palette.textTertiary)
            }
        }
        .padding(palette.spacing * 1.6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(palette)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Per-Metric Browser")
                .font(palette.font(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text("Current values only — no per-metric history query exists yet")
                .font(.caption2)
                .foregroundStyle(palette.textTertiary)
        }
    }

    // MARK: - Module picker

    /// A horizontally scrolling row of chips, one per `MetricModule`, each
    /// showing that module's SF Symbol and its **full** localized name.
    ///
    /// **Why this replaced `.pickerStyle(.segmented)`, and why nobody should
    /// put that back.** `UISegmentedControl` divides its width equally among
    /// its segments. There are nine `MetricModule` cases, so inside this
    /// card on an iPhone each segment got roughly 35pt — less than "Memory"
    /// needs, let alone "Neural Engine" — and the control rendered as
    /// `Ba… CPU GPU Ne… Me… Disk Ne… Th… Sy…`, which is what the bug report
    /// showed.
    ///
    /// That is not merely ugly. **"Neural Engine" and "Network" both truncate
    /// to "Ne…"**, so two different modules rendered as the same string:
    /// the control was genuinely ambiguous, and no amount of tapping told
    /// you which "Ne…" you were about to select. That collision is what
    /// rules out the whole family of "make it fit" fixes — a smaller font,
    /// `.minimumScaleFactor`, hand-abbreviated labels ("ANE"/"Net"), or
    /// `.lineLimit(1)` with tighter padding. Any of those keeps a fixed
    /// width budget divided nine ways, and localization makes it strictly
    /// worse: `displayName` is `String(localized:)`, and these names are
    /// longer in German/French than in English, so a layout tuned until the
    /// English strings just barely fit is a layout that ships broken
    /// everywhere else.
    ///
    /// A scrolling chip row inverts the constraint: each chip is sized by
    /// *its own* text (`fixedSize`, no line limit games), and the row — not
    /// the label — absorbs the overflow. Nothing can ever truncate, at any
    /// Dynamic Type size or in any language; the row just becomes longer and
    /// the user scrolls, and the icons make the modules scannable while
    /// scrolling. This is also not a new pattern in this app:
    /// `SentryMobile/Settings/SettingsTabView.swift` already presents its
    /// theme swatches as a `ScrollView(.horizontal, showsIndicators: false)`
    /// row of 44pt tappable cells with `.isSelected` traits, and reusing
    /// that beats inventing a second interaction for the same job.
    ///
    /// **Alternatives considered.** `.pickerStyle(.menu)` is compact and
    /// also cannot truncate, and it was the close runner-up; it was rejected
    /// because it hides all nine options behind a tap and shows only the
    /// current one, and the actual task here is browsing — "which modules
    /// are there, and what's in each" — where at-a-glance scanning of the
    /// full set is the point. A wrapping (multi-line) flow of chips shows
    /// everything at once with no scrolling, but its height changes with
    /// text size and language, which would make this card grow and shove the
    /// metric list around; a fixed-height scroller keeps the card stable.
    ///
    /// The selected chip is filled with the theme accent and carries the
    /// `.isSelected` accessibility trait; unselected chips are the theme's
    /// elevated surface with a separator hairline. All colors come from
    /// `palette` — no literals — so it stays consistent with `.glassCard`.
    private var modulePicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: palette.spacingTight) {
                    ForEach(MetricModulePicker.items(selected: selectedModule)) { item in
                        chip(item)
                    }
                }
                .padding(.vertical, 2)
            }
            // Keep the current selection visible when it changes from
            // somewhere other than a tap (e.g. VoiceOver moving through the
            // row, or a future restored-state default that isn't `.battery`).
            // Reduce Motion asks for no movement, not less, so the jump is
            // unanimated there — matching `ThemePalette.motion(reduceMotion:)`.
            .onChange(of: selectedModule) { _, module in
                withAnimation(ThemePalette.motion(reduceMotion: reduceMotion)) {
                    proxy.scrollTo(module, anchor: .center)
                }
            }
        }
    }

    /// One chip. `fixedSize(horizontal: true, vertical: false)` is the load
    /// bearing part: it lets the label claim exactly the width its text needs
    /// at the current Dynamic Type size, so the chip grows instead of the
    /// text shrinking or eliding. The 44pt `minHeight` is the standard touch
    /// target (and the same number the theme swatches use); larger text
    /// sizes push past it rather than being clipped by it.
    private func chip(_ item: MetricModulePicker.Item) -> some View {
        let shape = Capsule(style: .continuous)
        return Button {
            selectedModule = item.module
        } label: {
            HStack(spacing: palette.spacingTight) {
                Image(systemName: item.symbolName)
                    .imageScale(.small)
                Text(item.title)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(palette.font(size: chipFontSize, weight: item.isSelected ? .semibold : .regular))
            .foregroundStyle(item.isSelected ? palette.background : palette.textSecondary)
            .padding(.horizontal, palette.spacingBlock)
            .padding(.vertical, palette.spacingTight)
            .frame(minHeight: 44)
            .background(shape.fill(item.isSelected ? palette.accent : palette.surfaceElevated))
            .overlay(shape.strokeBorder(item.isSelected ? palette.accent : palette.separator, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .id(item.module)
        // Always the full localized name — never the rendered/abbreviated
        // form. This is the same string the chip draws, but stating it
        // explicitly keeps it true if the visual label ever gains an icon-
        // only compact mode.
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(item.isSelected ? [.isSelected] : [])
    }

    private func metricList(for snapshot: SystemSnapshot) -> some View {
        let metrics = MetricID.allCases.filter { $0.module == selectedModule }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element) { index, metric in
                HStack {
                    Text(metric.shortLabel)
                        .font(.callout)
                        .foregroundStyle(palette.textSecondary)
                    Spacer(minLength: palette.spacing)
                    Text(MetricFormatting.value(snapshot.value(for: metric), metric: metric))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(palette.textPrimary)
                }
                .padding(.vertical, 6)
                if index < metrics.count - 1 {
                    Divider().opacity(0.3)
                }
            }
        }
    }
}
