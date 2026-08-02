import MacStatKit
import SwiftUI

// MARK: - OverviewPage: the first and default page of the paged watch app

/// The page a raise-to-wake lands on. Four key readouts about the Mac, plus
/// the freshness badge that qualifies all of them.
///
/// **The four, and why these four.**
///
/// 1. **Battery** — the hero, the one number the eye lands on, and the
///    question this app was originally built to answer. On a Mac that
///    reported no battery (`WatchRelaySnapshot.batteryIsReported == false`,
///    i.e. a Mac mini/Studio/Pro) CPU takes the hero slot instead: a
///    desktop's headline fact is what it is doing, not a charge level it
///    does not have, and a giant "—" as the headline of a perfectly healthy
///    machine would be its own kind of lie by emphasis.
/// 2. **CPU** — "is my Mac busy" is what a glance at a *remote* machine is
///    usually asking. A render finished, an export stalled, something ran
///    away while the lid was shut.
/// 3. **Memory** — the one people misread, which is exactly why it is here
///    with its pressure tier beside it rather than alone; see
///    `WatchRelaySnapshot.memoryUsedPercent`.
/// 4. **Thermal** — kept from the original screen, and now paired with the
///    throttling flag, which is the difference between a state the user has
///    to interpret ("Serious") and a consequence they can act on
///    ("Throttling").
///
/// Disk rides along as a third tile rather than as a fifth headline. It is
/// the slowest-moving number here and the least urgent, but it is also the
/// one nothing else in a user's day surfaces until it is already a problem —
/// a Mac at 3% free stops taking snapshots and starts failing saves — and it
/// costs one `Double` on the wire and one tile of width.
///
/// **Why not more.** Eight stacked rows was the obvious way to satisfy "fit
/// more data" and is the wrong one: a face read in two seconds has room for
/// one number the eye lands on and a handful it can scan. The tiles are the
/// scan; the hero is the landing point. Anything past the freshness badge is
/// below the fold on a 40mm screen, where — this is the part that matters —
/// it would be data the user believes they have glanced at and has not. The
/// two things that genuinely wanted more room, keep-awake control and agent
/// activity, got their own pages instead of a longer list here.
///
/// **Honesty rules.** Every value is Optional at the wire and a missing one
/// renders as `WatchFormatting.placeholder` — "—" — with **no fill bar drawn
/// at all**, because an empty bar next to a dash reads as zero, and "this Mac
/// didn't report it" is not zero. `sourceIsDemoData` keeps its badge,
/// promoted from a caption at the bottom of the old screen to a chip
/// directly under the device name: it qualifies every number below it, so it
/// belongs above them. And every number still sits above a `FreshnessBadge`,
/// per plan §12.2 — nothing here is live, all of it is a claim about the
/// recent past.
struct OverviewPage: View {
    let snapshot: WatchRelaySnapshot

    var body: some View {
        ScrollView {
            // 4pt, not the 8 this started at. Every point of vertical
            // spacing here is paid for four times over (header, hero, tiles,
            // chips), and at 40mm the difference between 6 and 4 is whether
            // the thermal chip is on screen at rest or one flick of the crown
            // away. Tightened against the smallest supported face and then
            // re-checked at 46mm rather than tuned to look right on the big
            // one and left to fall off the small one.
            VStack(alignment: .leading, spacing: 4) {
                // **One header line: which Mac, and how old this is.**
                //
                // Two things were learned on the simulator here, both worth
                // recording because both look like styling and are not.
                //
                // The freshness badge used to sit *below* the readouts, which
                // was fine when the screen had four facts and no page
                // indicator. With this page's content it lands inside the
                // `.page` dot strip on a 46mm face and falls off a 40mm one
                // entirely — so the one element plan §12.2 says must never be
                // missed became the one most likely to be. It moved to the
                // top, where it is unconditionally on screen at every size,
                // and where it reads in the right order anyway: it qualifies
                // everything below it.
                //
                // The device name then shrank from `.headline` on its own row
                // to `.caption` sharing this one, because a full-height name
                // row pushed the thermal chip off the bottom. That is the
                // right thing to sacrifice: the name identifies *which* Mac,
                // which most users only ever answer once, while the chips
                // below it are live state. It stays first and stays legible;
                // it just stops being a headline.
                HStack(spacing: 6) {
                    Text(snapshot.deviceName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 2)
                    FreshnessBadge(lastSeen: snapshot.lastSeen)
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .layoutPriority(1)
                }

                if snapshot.sourceIsDemoData {
                    DemoDataChip()
                }

                HeroReadout(snapshot: snapshot)

                MetricTiles(snapshot: snapshot)

                StatusChips(snapshot: snapshot)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Clears the `.page` style's dot indicator, which floats over the
            // bottom of every page rather than reserving space above it.
            // Without this the freshness badge — the one element on the page
            // that is never allowed to be missed (plan §12.2) — sits directly
            // under the dots on a 46mm face and is clipped entirely on a
            // 40mm one. Measured on the simulator, not guessed.
            .padding(.bottom, 18)
        }
    }
}

// MARK: - Demo-data disclosure

/// The disclosure `WatchRelaySnapshot.sourceIsDemoData` exists to carry (see
/// that field's doc comment: a watch surface has no companion banner to say
/// this any other way). Kept as icon-plus-text rather than an orange tint
/// alone — colour by itself is invisible to a colourblind user and to anyone
/// reading in direct sunlight, which is most of the time a watch is read.
struct DemoDataChip: View {
    var body: some View {
        Label("Demo data", systemImage: "theatermasks.fill")
            .font(.caption2)
            .foregroundStyle(.orange)
            .accessibilityLabel("Demo data. These numbers are fabricated, not from a real Mac.")
    }
}

// MARK: - Hero

private struct HeroReadout: View {
    let snapshot: WatchRelaySnapshot

    /// `nil` (the v1 case) is treated as "has a battery" — see
    /// `WatchRelaySnapshot.batteryIsReported`'s doc comment on why the watch
    /// must not invent a meaning for an old phone's silence.
    private var showsBattery: Bool { snapshot.batteryIsReported ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: heroSymbol)
                    .font(.title3)
                    .foregroundStyle(heroTint)
                    .accessibilityHidden(true)
                Text(heroValue)
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            if let caption = heroCaption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var heroValue: String {
        showsBattery
            ? WatchFormatting.percent(snapshot.batteryPercent)
            : WatchFormatting.percent(snapshot.cpuPercent)
    }

    /// A lightning bolt only while actually charging; otherwise a *static*
    /// `battery.100`, deliberately not one of SF Symbols' fill-level battery
    /// variants. Those quantise to 0/25/50/75/100, so `battery.25` next to
    /// the text "38%" is two different claims about the same fact. The number
    /// is the claim; the icon is only a category marker.
    private var heroSymbol: String {
        guard showsBattery else { return "cpu" }
        return snapshot.isCharging ? "bolt.fill" : "battery.100"
    }

    private var heroTint: Color {
        guard showsBattery else { return .blue }
        if snapshot.isCharging { return .green }
        return snapshot.batteryPercent <= 20 ? .orange : .primary
    }

    /// Priority order, most informative first. Runway beats plug state
    /// because "3h 40m left" already implies "not charging," while "Plugged
    /// in" says nothing about how long anything will last. All four cases can
    /// be absent, and absence renders as no line rather than as a filler
    /// phrase.
    private var heroCaption: String? {
        guard showsBattery else {
            return snapshot.cpuPercent == nil
                ? String(localized: "CPU not reported")
                : String(localized: "CPU load")
        }
        if let minutes = snapshot.batteryTimeRemainingMinutes {
            let duration = WatchFormatting.duration(minutes: minutes)
            return snapshot.isCharging
                ? String(localized: "\(duration) to full")
                : String(localized: "\(duration) left")
        }
        if snapshot.isCharging { return String(localized: "Charging") }
        if snapshot.isPluggedIn { return String(localized: "Plugged in") }
        return nil
    }

    private var accessibilityText: String {
        let subject = showsBattery ? String(localized: "Battery") : String(localized: "CPU")
        let caption = heroCaption.map { ", \($0)" } ?? ""
        return "\(subject) \(heroValue)\(caption)"
    }
}

// MARK: - Metric tiles

/// CPU, memory and disk as three compact tiles.
///
/// **Why `ViewThatFits` rather than a fixed `HStack` or a `Grid`.** The
/// smallest supported face (40mm) is about 162pt of usable width; three
/// tiles fit there comfortably at default Dynamic Type and stop fitting well
/// before the largest accessibility sizes. Rather than let the numbers shrink
/// toward illegibility — the failure mode of leaning on `minimumScaleFactor`
/// as a layout strategy — the horizontal arrangement is offered first and a
/// full-width row-per-metric layout takes over when it no longer fits. Both
/// arrangements carry identical information; only the shape changes.
private struct MetricTiles: View {
    let snapshot: WatchRelaySnapshot

    /// A named type rather than a tuple purely so `ForEach` has something
    /// `Identifiable` to hold onto.
    private struct Metric: Identifiable {
        let id: String
        /// Shown on the tile. Separate from `id`, which stays a stable
        /// English identity for `ForEach` while the label localizes.
        let label: String
        let percent: Double?
        let tint: Color
    }

    /// CPU first because it answers "is something wrong right now"; memory
    /// second because it is the one people misread; disk last because it is
    /// the slowest-moving and the least urgent, and last is where a scan
    /// naturally puts the least urgent thing.
    ///
    /// GPU and network throughput were considered for a fourth tile and
    /// rejected. Both are rate-shaped: a throughput figure relayed up to five
    /// minutes ago (`WatchRelayPolicy.minimumRelayInterval`) describes an
    /// instant that is long over, and rendering it as a current reading is
    /// precisely the kind of quiet lie the freshness discipline exists to
    /// prevent. An aggregate CPU percentage survives that latency because a
    /// Mac pinned at 95% is still pinned a minute later; "12 MB/s" is not
    /// true of any interval but the one it was sampled over.
    private var metrics: [Metric] {
        [
            Metric(id: "CPU", label: String(localized: "CPU"), percent: snapshot.cpuPercent, tint: .blue),
            Metric(id: "MEM", label: String(localized: "MEM"), percent: snapshot.memoryUsedPercent, tint: .purple),
            Metric(id: "DISK", label: String(localized: "DISK"), percent: snapshot.diskUsedPercent, tint: .teal),
        ]
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(metrics) { metric in
                    MetricTile(label: metric.label, percent: metric.percent, tint: metric.tint)
                }
            }
            VStack(spacing: 6) {
                ForEach(metrics) { metric in
                    MetricTile(label: metric.label, percent: metric.percent, tint: metric.tint)
                }
            }
        }
    }
}

/// One tile: label, percent, fill bar.
///
/// The bar is drawn **only when there is a value**. A track with no fill is
/// visually indistinguishable from a genuine 0%, and this codebase's standing
/// rule (plan §3.2 P5, and every Optional in `SystemSnapshot`) is that "not
/// reported" must never be rendered as a number — so an unavailable metric
/// gets "—" and a blank space where the bar would be, not an empty bar.
private struct MetricTile: View {
    let label: String
    let percent: Double?
    let tint: Color

    /// Clamped for the bar only. The *text* prints the value as relayed:
    /// clamping a hypothetical 103% down to 100 in the readout would hide a
    /// collector bug behind a plausible number, whereas a bar wider than its
    /// track is just a rendering artefact.
    private var fraction: Double? {
        guard let percent, percent.isFinite else { return nil }
        return min(max(percent / 100, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(WatchFormatting.percent(percent))
                .font(.system(.body, design: .rounded).weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            barOrGap
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            // Localized explicitly: a ternary of interpolated literals is a
            // plain `String`, which would pick the verbatim overload.
            percent == nil
                ? String(localized: "\(label), not reported")
                : "\(label) \(WatchFormatting.percent(percent))"
        )
    }

    @ViewBuilder
    private var barOrGap: some View {
        if let fraction {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(tint)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 3)
        } else {
            // Same height as the bar so the three tiles keep a common
            // baseline whether or not each has data — a tile that collapses
            // when its metric is missing makes the row look broken rather
            // than incomplete.
            Color.clear.frame(height: 3)
        }
    }
}

// MARK: - Status chips

/// Thermal always; throttling and elevated memory pressure only when they
/// apply.
///
/// **Why the conditional chips are not dishonest by omission.** A readout
/// that disappears is normally ambiguous — the reader can't tell "fine" from
/// "not reported." These two are not, because each has an unconditional
/// companion on screen: memory pressure only qualifies the MEM tile directly
/// above, which already shows "—" when the Mac reported no memory at all, and
/// throttling sits beside the thermal chip, which is always present and shows
/// "Unknown" when the Mac reported no thermal module. So "no memory-pressure
/// chip" means normal *when the MEM tile has a number*, and means nothing at
/// all when it doesn't — which is exactly what the screen shows.
private struct StatusChips: View {
    let snapshot: WatchRelaySnapshot

    /// A chip is data, not a view, so the three arrangements below can lay
    /// the same set out differently without the conditional logic being
    /// written three times.
    private struct ChipSpec: Identifiable {
        let id: String
        let symbol: String
        let tint: Color
    }

    private var chips: [ChipSpec] {
        var specs = [
            ChipSpec(
                id: Self.thermalLabel(snapshot.thermalPressure),
                symbol: "thermometer.medium",
                tint: Self.thermalTint(snapshot.thermalPressure)
            )
        ]
        if snapshot.isThrottling == true {
            specs.append(ChipSpec(id: String(localized: "Throttling"), symbol: "tortoise.fill", tint: .red))
        }
        if let pressure = snapshot.memoryPressure, pressure != .normal {
            specs.append(
                ChipSpec(
                    id: Self.memoryPressureLabel(pressure),
                    symbol: "memorychip.fill",
                    tint: pressure == .critical ? .red : .orange
                )
            )
        }
        return specs
    }

    /// **Three arrangements, and the middle one exists because of a specific
    /// thing seen on the simulator.** A Mac that is hot *and* throttling
    /// *and* out of memory produces three chips. One row does not fit them at
    /// 46mm; a row each does fit, but pushes the third — "Memory critical",
    /// the most alarming state this screen can report — below the fold, where
    /// the user has to scroll to find out about it. Two per row lands them
    /// all on screen. The all-vertical arrangement is kept as the last resort
    /// for large accessibility text sizes, where nothing else fits and
    /// scrolling is the honest answer.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chipViews(chips) }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(stride(from: 0, to: chips.count, by: 2)), id: \.self) { start in
                    HStack(spacing: 6) {
                        chipViews(Array(chips[start..<min(start + 2, chips.count)]))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) { chipViews(chips) }
        }
    }

    @ViewBuilder
    private func chipViews(_ specs: [ChipSpec]) -> some View {
        ForEach(specs) { spec in
            StatusChip(text: spec.id, symbol: spec.symbol, tint: spec.tint)
        }
    }

    /// "Normal" rather than the wire's "nominal" — `nominal` is
    /// `ProcessInfo.ThermalState`'s word and it is the wrong register for a
    /// watch face. `.unknown` is spelled out rather than hidden: a Mac that
    /// reported no thermal data is a different situation from a cool one, and
    /// this chip is the only place the screen can say so.
    static func thermalLabel(_ pressure: ThermalPressureSummary) -> String {
        switch pressure {
        case .nominal: return String(localized: "Normal")
        case .fair: return String(localized: "Fair")
        case .serious: return String(localized: "Serious")
        case .critical: return String(localized: "Critical")
        case .unknown: return String(localized: "Unknown")
        }
    }

    static func thermalTint(_ pressure: ThermalPressureSummary) -> Color {
        switch pressure {
        case .nominal: return .secondary
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }

    /// `.unknown` here means "a newer phone named a pressure tier this build
    /// can't" (see `WatchRelaySnapshot`'s decoder), which is worth surfacing
    /// rather than silently treating as normal — it is the one case where the
    /// watch knows something is being said and cannot repeat it.
    static func memoryPressureLabel(_ pressure: MemoryPressureSummary) -> String {
        switch pressure {
        case .normal: return String(localized: "Memory OK")
        case .warning: return String(localized: "Memory pressure")
        case .critical: return String(localized: "Memory critical")
        case .unknown: return String(localized: "Memory: unrecognised")
        }
    }
}

private struct StatusChip: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityElement(children: .combine)
    }
}
