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
/// Disk rides along as a third dial rather than as a fifth headline. It is
/// the slowest-moving number here and the least urgent, but it is also the
/// one nothing else in a user's day surfaces until it is already a problem —
/// a Mac at 3% free stops taking snapshots and starts failing saves — and it
/// costs one `Double` on the wire and one dial of width.
///
/// **Why not more.** Eight stacked rows was the obvious way to satisfy "fit
/// more data" and is the wrong one: a face read in two seconds has room for
/// one number the eye lands on and a handful it can scan. The dials are the
/// scan; the hero is the landing point. Anything past the freshness badge is
/// below the fold on a 40mm screen, where — this is the part that matters —
/// it would be data the user believes they have glanced at and has not. The
/// two things that genuinely wanted more room, keep-awake control and agent
/// activity, got their own pages instead of a longer list here.
///
/// **Why this page is now radial.** It used to be a flat, left-aligned column
/// of labels above straight progress bars — a shape indistinguishable from a
/// Settings screen, on the one Apple platform whose native readout vocabulary
/// is the arc, for an app whose icon *is* a dial. `SentryDial`'s header sets
/// out that argument in full. What matters here is what the change bought on
/// this specific page, which is three things beyond looking like the product:
/// the hero and its caption now sit side by side instead of stacked, which
/// reclaims the dead horizontal space to the right of a two-digit percentage;
/// three arcs read as one instrument cluster where three left-aligned rows
/// read as a list with no grouping; and a partial arc communicates a
/// proportion pre-linguistically, so the eye gets an answer before it has
/// finished reading the digits.
///
/// **What did *not* change, deliberately.** No amber. The icon's fill is
/// `#f0a63c → #d97a2b`, and using it as a data colour here would collide head
/// on with this app's existing colour grammar, where orange already means
/// *elevated* — `FreshnessBadge` renders `.recent` in orange, `StatusChips`
/// renders a warning memory tier in orange, and `MetricSeverity.elevated` is
/// orange. A healthy battery drawn in the brand's amber would be
/// indistinguishable from a battery the app is worried about. So the brand is
/// carried by the dial's *form* — the 270° sweep, the bottom gap, the dotted
/// collar — and not by its hue, which is the part of it that was already
/// spoken for. (The usual "check it in light and dark" follow-up does not
/// arise: watchOS has no light appearance. `simctl ui … appearance light`
/// returns "Runtime does not support userInterfaceStyle" against the watchOS
/// runtime, which is the OS saying the same thing.)
///
/// **Honesty rules.** Every value is Optional at the wire and a missing one
/// renders as `WatchFormatting.placeholder` — "—" — inside a **dotted** ring
/// with no fill drawn at all, because a solid track with a zero-length fill is
/// pixel-identical to a genuine 0%, and "this Mac didn't report it" is not
/// zero. That is the same rule the old straight bars followed by drawing no
/// bar; the dotted ring is a stronger version of it, because it puts a
/// positive mark of absence where the old layout left a gap.
/// `sourceIsDemoData` keeps its badge directly under the header: it qualifies
/// every number below it, so it belongs above them. And every number still
/// sits with a `FreshnessBadge`, per plan §12.2 — nothing here is live, all of
/// it is a claim about the recent past.
///
/// **Accessibility text sizes get the old layout back, on purpose.** At
/// `.accessibility1` and above this page abandons the dials entirely and
/// renders the flat, full-width, one-metric-per-row layout that preceded them
/// (`MetricTile`, still here, no longer dead). A ring is a fixed-aspect shape;
/// text inside it can only grow so far before it is scaled into illegibility,
/// and a radial gauge whose label has been squeezed to 40% to fit is strictly
/// worse than the plain row it replaced. The dials are the better design at
/// the sizes most people use and the wrong one at the sizes some people need,
/// so the page picks per reader rather than committing to one and papering
/// over the other with `minimumScaleFactor`.
struct OverviewPage: View {
    let snapshot: WatchRelaySnapshot

    /// Drives the one structural branch on this page — see the type header's
    /// note on why accessibility sizes get the pre-dial layout rather than a
    /// shrunken version of this one.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var usesDials: Bool { !dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        ScrollView {
            // 4pt, not the 8 this started at. Every point of vertical
            // spacing here is paid for four times over (header, hero, dials,
            // chips), and at 40mm the difference between 6 and 4 is whether
            // the thermal chip is on screen at rest or one flick of the crown
            // away. Tightened against the smallest supported face and then
            // re-checked at 46mm rather than tuned to look right on the big
            // one and left to fall off the small one.
            VStack(alignment: .leading, spacing: 4) {
                header

                if snapshot.sourceIsDemoData {
                    DemoDataChip()
                }

                HeroReadout(snapshot: snapshot, usesDial: usesDials)

                MetricReadouts(snapshot: snapshot, usesDials: usesDials)

                StatusChips(snapshot: snapshot)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Clears the `.page` style's dot indicator, which floats over the
            // bottom of every page rather than reserving space above it.
            // Without this the status chips — including "Memory critical", the
            // most alarming state this screen can report — sit under the dots
            // on a 46mm face and are clipped entirely on a 40mm one. Measured
            // on the simulator, not guessed.
            .padding(.bottom, 18)
        }
    }

    // MARK: Header

    /// **One header line: how old this is, and which Mac.** In that order,
    /// which is a reversal of what this row used to do and the point of it.
    ///
    /// Three things were learned on the simulator here, all of which look like
    /// styling and are not.
    ///
    /// The freshness badge used to sit *below* the readouts. With this page's
    /// content it lands inside the `.page` dot strip on a 46mm face and falls
    /// off a 40mm one entirely — so the one element plan §12.2 says must never
    /// be missed became the one most likely to be. It moved to the top, where
    /// it is unconditionally on screen at every size.
    ///
    /// The device name then shrank from `.headline` on its own row to
    /// `.caption` sharing this one, because a full-height name row pushed the
    /// thermal chip off the bottom.
    ///
    /// **And now it has been demoted a second time**, to trailing-aligned
    /// `.caption2` secondary, with the badge taking the leading position it
    /// used to hold. The earlier note had it right that the name is answered
    /// once and the state below it is live, but it stopped one step short: a
    /// user with a single Mac learns *nothing at all* from that string, every
    /// time they raise their wrist, and it was still the boldest thing in the
    /// top third of the screen. It is not removed — a user with two Macs needs
    /// it to know which one this is, and this app must never be ambiguous
    /// about whose numbers these are — but it is now clearly the caption to
    /// the badge rather than the headline of the page. The badge leads because
    /// it qualifies everything below it and because "Live" is the word that
    /// decides whether the rest of the screen is worth reading.
    private var header: some View {
        HStack(spacing: 6) {
            FreshnessBadge(lastSeen: snapshot.lastSeen)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .layoutPriority(1)
            if showsDeviceName {
                Spacer(minLength: 2)
                Text(snapshot.deviceName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.6)
            }
        }
    }

    /// The device name is dropped entirely in the `.asleep` tier rather than
    /// truncated.
    ///
    /// **Why a tier check and not a layout container.** `Freshness.label`
    /// produces one long string and three short ones: "Live", "9m ago",
    /// "3h ago" — and "Mac asleep — last seen 3h ago". With the badge holding
    /// `layoutPriority(1)`, that fourth case leaves the name about eight points
    /// of width, and the simulator rendered "Malek's MacBook Pro" as a single
    /// capital M pinned to the right edge. One truncated letter conveys nothing
    /// and looks like a bug, which is worse than the absence it is standing in
    /// for.
    ///
    /// `ViewThatFits` was the obvious alternative and was rejected: both
    /// candidates would have to contain a flexible `Spacer`, whose ideal width
    /// is its `minLength`, so the measurement it makes the decision on is not
    /// the one that matters — the same class of silent-wrong-answer
    /// `MetricReadouts` and `KeepAwakePage.extendRow` both document avoiding.
    /// A tier check is deterministic, readable, and says the thing out loud.
    ///
    /// It is also the right *editorial* call, not just a layout escape. When
    /// the app is telling you the reading is hours old and the Mac is asleep,
    /// that sentence is the whole message; which machine it came from is the
    /// least useful thing on the screen at that moment, and it is still one
    /// swipe away on any page that names it. The badge is the element plan
    /// §12.2 says must never be missed, so when only one of the two can be
    /// whole, it is the one that survives.
    private var showsDeviceName: Bool {
        Freshness(lastSeen: snapshot.lastSeen) != .asleep
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

/// The landing point: one big dial, and the sentence that qualifies it.
///
/// **Why the dial and the caption sit side by side.** Stacked, this was a
/// glyph, a very large percentage, and a caption underneath — which left the
/// right two-thirds of the widest line on the screen empty and made the page
/// read as one long left-aligned column with nothing but font size
/// distinguishing its parts. Side by side, the dial is a fixed anchor on the
/// left and the words hang off it, which is both a use for that dead space and
/// the only grouping cue this page has that is not typographic.
private struct HeroReadout: View {
    let snapshot: WatchRelaySnapshot

    /// False at accessibility text sizes, where the page falls back to the
    /// flat layout — see `OverviewPage`'s header.
    let usesDial: Bool

    /// Grows with the text it encloses. A fixed ring around text that scales
    /// with Dynamic Type would clip its own value at the top of the
    /// non-accessibility range, which is exactly the failure this design was
    /// warned about; tying the diameter to `.title3` (the value's own text
    /// style) keeps the ratio of ring to digits constant across the whole
    /// range this branch actually serves.
    ///
    /// 58, down from the 68 this was first drawn at, and the ten points were
    /// not cosmetic. At 68 the worst case this screen can render — hot,
    /// throttling *and* memory-critical, which is three status chips — pushed
    /// "Memory critical" under the `.page` dot strip at 46mm. That is the most
    /// alarming thing the page can say, and `StatusChips` has a whole comment
    /// about arranging the chips two-per-row specifically so it stays visible;
    /// a hero dial big enough to break that promise is a hero dial that is too
    /// big. Verified on the simulator in that exact state, not reasoned about.
    /// Multiplied by `WatchFace.scale`, which is what makes the same number
    /// work on a 40mm SE and a 49mm Ultra — see that type for why a ring, alone
    /// among the things on this page, cannot just be left to reflow.
    @ScaledMetric(relativeTo: .title3) private var baseDiameter: CGFloat = 58

    private var diameter: CGFloat { baseDiameter * WatchFace.scale }

    /// `nil` (the v1 case) is treated as "has a battery" — see
    /// `WatchRelaySnapshot.batteryIsReported`'s doc comment on why the watch
    /// must not invent a meaning for an old phone's silence.
    private var showsBattery: Bool { snapshot.batteryIsReported ?? true }

    var body: some View {
        Group {
            if usesDial { dialLayout } else { flatLayout }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Layouts

    private var dialLayout: some View {
        HStack(spacing: 10) {
            SentryDial(fraction: heroFraction, tint: tint, lineWidth: 5) {
                VStack(spacing: -1) {
                    Image(systemName: heroSymbol)
                        .font(.system(size: 9))
                        .foregroundStyle(tint)
                    Text(heroValue)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
            .frame(width: diameter, height: diameter)

            VStack(alignment: .leading, spacing: 1) {
                // Named in words because the dial's centre glyph is 9pt and
                // cannot carry the subject on its own — and because the
                // desktop case swaps the subject entirely, which a user who
                // has only ever seen this app on a laptop would otherwise have
                // to infer from a `cpu` glyph the size of a full stop.
                Text(subject)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let caption = heroCaption {
                    Text(caption)
                        .font(.caption)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let word = severityWord {
                    // The non-colour carrier for the hero. A red "7%" alone
                    // fails this codebase's rule that colour is never the only
                    // signal; the word is what a colourblind user, a
                    // sunlit screen, and VoiceOver all get instead.
                    Label(word, systemImage: severity.symbol ?? "exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The pre-dial layout, kept for accessibility text sizes. Unchanged in
    /// substance from what this page shipped before, with the severity tint
    /// and word added — those are readable at any size and there is no reason
    /// to withhold them here.
    private var flatLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: heroSymbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(heroValue)
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            if let caption = heroCaption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            if let word = severityWord {
                Label(word, systemImage: severity.symbol ?? "exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    // MARK: Values

    /// On a desktop Mac this reads "CPU" while the first metric dial below
    /// also reads "CPU", showing the same number twice. That duplication
    /// predates this pass and is kept deliberately: suppressing the dial would
    /// leave the desktop layout with two dials where every other Mac has
    /// three, so the row would reflow and the page would look structurally
    /// different depending on which machine you own — a worse outcome than one
    /// repeated figure, and one that makes the screen harder to learn.
    private var subject: String { showsBattery ? "Battery" : "CPU" }

    private var heroPercent: Double? {
        showsBattery ? snapshot.batteryPercent : snapshot.cpuPercent
    }

    private var heroValue: String { WatchFormatting.percent(heroPercent) }

    /// `nil` — no arc at all — whenever the underlying number is missing or
    /// non-finite, which on the desktop path is a real and common case
    /// (`cpuPercent` is Optional and a v1 phone never sends it). The battery
    /// path can only be non-finite, since `batteryPercent` is non-Optional at
    /// the wire.
    private var heroFraction: Double? {
        guard let percent = heroPercent, percent.isFinite else { return nil }
        return percent / 100
    }

    private var severity: MetricSeverity {
        showsBattery
            ? .battery(percent: snapshot.batteryPercent, isCharging: snapshot.isCharging)
            : .cpu(snapshot.cpuPercent)
    }

    private var severityWord: String? {
        showsBattery
            ? severity.accessibilityWord(elevated: "Low", high: "Critically low")
            : severity.accessibilityWord(elevated: "Busy", high: "Very busy")
    }

    /// A lightning bolt only while actually charging; otherwise a *static*
    /// `battery.100`, deliberately not one of SF Symbols' fill-level battery
    /// variants. Those quantise to 0/25/50/75/100, so `battery.25` next to
    /// the text "38%" is two different claims about the same fact. The number
    /// is the claim; the icon is only a category marker — and now the arc
    /// carries the proportion properly, which is what those symbol variants
    /// were badly approximating.
    private var heroSymbol: String {
        guard showsBattery else { return "cpu" }
        return snapshot.isCharging ? "bolt.fill" : "battery.100"
    }

    /// Charging wins over severity: green says "resolving," and it is the more
    /// useful thing to know about a Mac at 8% on a charger. Otherwise the
    /// severity tint, falling back to `.primary` — the "no opinion" colour, so
    /// a healthy battery is not painted a hue that means something.
    private var tint: Color {
        if showsBattery && snapshot.isCharging { return .green }
        return severity.tint ?? .primary
    }

    /// Priority order, most informative first. Runway beats plug state
    /// because "3h 40m left" already implies "not charging," while "Plugged
    /// in" says nothing about how long anything will last. All four cases can
    /// be absent, and absence renders as no line rather than as a filler
    /// phrase.
    private var heroCaption: String? {
        guard showsBattery else {
            return snapshot.cpuPercent == nil ? "Not reported" : "Load right now"
        }
        if let minutes = snapshot.batteryTimeRemainingMinutes {
            let duration = WatchFormatting.duration(minutes: minutes)
            return snapshot.isCharging ? "\(duration) to full" : "\(duration) left"
        }
        if snapshot.isCharging { return "Charging" }
        if snapshot.isPluggedIn { return "Plugged in" }
        return nil
    }

    private var accessibilityText: String {
        let caption = heroCaption.map { ", \($0)" } ?? ""
        let word = severityWord.map { ", \($0)" } ?? ""
        return "\(subject) \(heroValue)\(caption)\(word)"
    }
}

// MARK: - Metric readouts

/// CPU, memory and disk — three dials at normal text sizes, three full-width
/// rows at accessibility sizes.
///
/// **Why an explicit `usesDials` flag rather than `ViewThatFits`.** The old
/// version of this view offered a horizontal arrangement and let `ViewThatFits`
/// fall back to a vertical one. That worked for straight bars because a bar
/// row reports an honest ideal width. It does not work here: a dial is
/// `aspectRatio(1, contentMode: .fit)` inside a `maxWidth: .infinity` frame,
/// which reports an ideal width small enough to always "fit", so the
/// horizontal candidate would win unconditionally and the fallback would be
/// dead code — the same trap `KeepAwakePage.extendRow` documents hitting with
/// its extend buttons. Reading the environment once, in the page, and passing
/// the answer down makes the rule legible and deterministic.
private struct MetricReadouts: View {
    let snapshot: WatchRelaySnapshot
    let usesDials: Bool

    /// A named type rather than a tuple purely so `ForEach` has something
    /// `Identifiable` to hold onto.
    private struct Metric: Identifiable {
        let id: String
        let percent: Double?
        /// The metric's identity colour, used when severity has no opinion.
        let tint: Color
        let severity: MetricSeverity
        /// Per-metric severity vocabulary — see `MetricSeverity`'s header on
        /// why "disk nearly full" beats a generic "elevated".
        let elevatedWord: String
        let highWord: String
    }

    /// CPU first because it answers "is something wrong right now"; memory
    /// second because it is the one people misread; disk last because it is
    /// the slowest-moving and the least urgent, and last is where a scan
    /// naturally puts the least urgent thing.
    ///
    /// GPU and network throughput were considered for a fourth dial and
    /// rejected. Both are rate-shaped: a throughput figure relayed up to five
    /// minutes ago (`WatchRelayPolicy.minimumRelayInterval`) describes an
    /// instant that is long over, and rendering it as a current reading is
    /// precisely the kind of quiet lie the freshness discipline exists to
    /// prevent. An aggregate CPU percentage survives that latency because a
    /// Mac pinned at 95% is still pinned a minute later; "12 MB/s" is not
    /// true of any interval but the one it was sampled over.
    private var metrics: [Metric] {
        [
            Metric(
                id: "CPU",
                percent: snapshot.cpuPercent,
                tint: .blue,
                severity: .cpu(snapshot.cpuPercent),
                elevatedWord: "busy",
                highWord: "very busy"
            ),
            Metric(
                id: "MEM",
                percent: snapshot.memoryUsedPercent,
                tint: .purple,
                // From pressure, never from the percentage. `MetricSeverity`'s
                // header and `WatchRelaySnapshot.memoryUsedPercent` both spell
                // out why: on macOS a high used-percent is normal, and this is
                // the one number on the screen that would be actively
                // misleading if colour treated it as a problem.
                severity: .memory(snapshot.memoryPressure),
                elevatedWord: "under pressure",
                highWord: "critically low"
            ),
            Metric(
                id: "DISK",
                percent: snapshot.diskUsedPercent,
                tint: .teal,
                severity: .disk(snapshot.diskUsedPercent),
                elevatedWord: "nearly full",
                highWord: "critically full"
            ),
        ]
    }

    var body: some View {
        if usesDials {
            HStack(alignment: .top, spacing: 4) {
                ForEach(metrics) { metric in
                    MetricDial(
                        label: metric.id,
                        percent: metric.percent,
                        tint: metric.tint,
                        severity: metric.severity,
                        elevatedWord: metric.elevatedWord,
                        highWord: metric.highWord
                    )
                }
            }
        } else {
            VStack(spacing: 6) {
                ForEach(metrics) { metric in
                    MetricTile(
                        label: metric.id,
                        percent: metric.percent,
                        tint: metric.tint,
                        severity: metric.severity,
                        elevatedWord: metric.elevatedWord,
                        highWord: metric.highWord
                    )
                }
            }
        }
    }
}

/// One dial: an arc, the percentage in the well, the metric's name beneath.
///
/// The arc is drawn **only when there is a value** — a missing metric gets
/// `SentryDial`'s dotted ring and an em dash, never a solid track with a
/// zero-length fill, which would be pixel-identical to a genuine 0%. That is
/// this codebase's standing rule (plan §3.2 P5, and every Optional in
/// `SystemSnapshot`) applied to a shape instead of a bar.
private struct MetricDial: View {
    let label: String
    let percent: Double?
    let tint: Color
    let severity: MetricSeverity
    let elevatedWord: String
    let highWord: String

    /// 40, not 46, for the same reason the hero shrank to 58 — see that
    /// property. Relative to `.caption2`, the text style of the percentage in
    /// the well, so ring and digits scale together. At 40mm this is also the
    /// binding constraint on width: three of these plus two 4pt gaps is 128pt
    /// inside roughly 154pt of usable width, which leaves the row comfortable
    /// rather than exactly full.
    @ScaledMetric(relativeTo: .caption2) private var baseDiameter: CGFloat = 40

    private var diameter: CGFloat { baseDiameter * WatchFace.scale }

    private var fraction: Double? {
        guard let percent, percent.isFinite else { return nil }
        // Clamped for the arc only. The *text* prints the value as relayed:
        // clamping a hypothetical 103% down to 100 in the readout would hide a
        // collector bug behind a plausible number, whereas an arc longer than
        // its track is just a rendering artefact.
        return percent / 100
    }

    private var arcTint: Color { severity.tint ?? tint }

    private var severityWord: String? {
        severity.accessibilityWord(elevated: elevatedWord, high: highWord)
    }

    var body: some View {
        VStack(spacing: 1) {
            SentryDial(fraction: fraction, tint: arcTint, lineWidth: 4) {
                Text(WatchFormatting.percent(percent))
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(percent == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(arcTint))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .frame(maxWidth: .infinity, maxHeight: diameter)

            // The severity glyph rides with the label rather than inside the
            // well: the well is 30-odd points across and already holds the
            // number, and a warning triangle in there would compete with the
            // value it is warning about. Beside the name it reads as an
            // annotation on the metric, which is what it is.
            HStack(spacing: 1) {
                Text(label)
                if let symbol = severity.symbol {
                    Image(systemName: symbol)
                }
            }
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .foregroundStyle(severity.tint ?? .secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.spokenLabel(
            label: label,
            percent: percent,
            severityWord: severityWord
        ))
    }

    /// `static` and parameterised so the wording is one expression rather than
    /// three branches inlined in the body — and so it reads the same way as
    /// `MetricTile`'s, which must not drift from it just because one layout is
    /// radial and the other is not.
    static func spokenLabel(label: String, percent: Double?, severityWord: String?) -> String {
        guard percent != nil else { return "\(label), not reported" }
        let suffix = severityWord.map { ", \($0)" } ?? ""
        return "\(label) \(WatchFormatting.percent(percent))\(suffix)"
    }
}

/// The flat, pre-dial readout: label, percent, fill bar. **Not dead code** —
/// this is what accessibility text sizes get, for the reason `OverviewPage`'s
/// header gives. It is full-width here rather than one of three columns,
/// because at those sizes there is only ever one per row.
///
/// The bar is drawn **only when there is a value**, on the same reasoning as
/// `MetricDial`'s arc: a track with no fill is visually indistinguishable from
/// a genuine 0%.
private struct MetricTile: View {
    let label: String
    let percent: Double?
    let tint: Color
    let severity: MetricSeverity
    let elevatedWord: String
    let highWord: String

    private var fraction: Double? {
        guard let percent, percent.isFinite else { return nil }
        return min(max(percent / 100, 0), 1)
    }

    private var barTint: Color { severity.tint ?? tint }

    private var severityWord: String? {
        severity.accessibilityWord(elevated: elevatedWord, high: highWord)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                HStack(spacing: 2) {
                    Text(label)
                    if let symbol = severity.symbol {
                        Image(systemName: symbol)
                    }
                }
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .foregroundStyle(severity.tint ?? .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

                Spacer(minLength: 4)

                Text(WatchFormatting.percent(percent))
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(percent == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(barTint))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            barOrGap
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(MetricDial.spokenLabel(
            label: label,
            percent: percent,
            severityWord: severityWord
        ))
    }

    @ViewBuilder
    private var barOrGap: some View {
        if let fraction {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(barTint)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 3)
        } else {
            // Same height as the bar so the rows keep a common rhythm whether
            // or not each has data — a row that collapses when its metric is
            // missing makes the group look broken rather than incomplete.
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
/// companion on screen: memory pressure only qualifies the MEM dial directly
/// above, which already shows "—" in a dotted ring when the Mac reported no
/// memory at all, and throttling sits beside the thermal chip, which is always
/// present and shows "Unknown" when the Mac reported no thermal module. So "no
/// memory-pressure chip" means normal *when the MEM dial has a number*, and
/// means nothing at all when it doesn't — which is exactly what the screen
/// shows.
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
            specs.append(ChipSpec(id: "Throttling", symbol: "tortoise.fill", tint: .red))
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
    ///
    /// `ViewThatFits` *is* the right container here and remains one, unlike in
    /// `MetricReadouts` above: every candidate is built from `Label`s with
    /// intrinsic widths, so each one reports an ideal size that can genuinely
    /// fail to fit, which is the precondition the API needs and the dials do
    /// not meet.
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
        case .nominal: return "Normal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
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
        case .normal: return "Memory OK"
        case .warning: return "Memory pressure"
        case .critical: return "Memory critical"
        case .unknown: return "Memory: unrecognised"
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
