import SentryKit
import SwiftUI

// MARK: - ContentView: the paged shell

/// The Watch app's root: three horizontally-paged screens.
///
/// **Why pages rather than one longer screen.** The app used to be a single
/// column of four facts, and the obvious response to "it can show more" is a
/// taller column. That is the wrong shape twice over. A watch screen read in
/// two seconds has room for one number the eye lands on and a handful it can
/// scan — everything below that is data the user *believes* they glanced at
/// and did not. And two of the three things this app now does are not
/// readouts at all: Keep Awake is a control with consequences, and Agent
/// Activity is a log. Stacking a control under a stats table means every
/// glance at the battery scrolls past a button that sends a command to the
/// Mac. Separate pages give each one the whole screen and make the swipe,
/// not a scroll position, the thing that decides what you are looking at.
///
/// **Why `.tabViewStyle(.page)` — horizontal — and not `.verticalPage`.**
/// watchOS 10 makes vertical paging the default idiom for a *single* stream
/// of related content, and the Digital Crown scrolls vertically inside each
/// of these pages already (the Overview scrolls, and the Agent Activity log
/// can be long). Putting page navigation on the same axis as content
/// scrolling makes the two fight. Horizontal paging keeps the crown meaning
/// "move within this page" and a swipe meaning "change page," which is also
/// what the owner asked for in as many words.
///
/// **Page order is by frequency, not by importance.** Overview is first
/// because it is what a raise-to-wake should land on nine times out of ten;
/// it is also the page a complication tap should feel continuous with. Keep
/// Awake is second because it is the one thing here a user actively goes
/// looking for. Agent Activity is last because it is the one that is read
/// deliberately rather than glanced at.
///
/// **What each page does when the watch has no data.** `WatchRelayStore`
/// returning `nil` covers three situations the watch cannot tell apart (App
/// Group unreachable, nothing relayed yet, a payload too old or too new to
/// decode — see `WatchRelayStore.read()`), so all three pages fall back to
/// `UnavailablePage` rather than to a plausible-looking default. This matters
/// most on Keep Awake: `KeepAwakePage` takes a non-Optional `isActive: Bool`,
/// and there is no honest `Bool` for "we don't know." Passing `false` would
/// draw a control asserting the Mac will sleep normally, which is a claim
/// this app cannot make and which the user might act on. So the shell — not
/// the page — decides whether there is anything true to render, and the same
/// applies when a relay arrived but `awakeIsActive` is `nil` because the Mac
/// reported no sleep-assertion state or the phone predates the field.
struct ContentView: View {
    @EnvironmentObject private var sessionController: WatchSessionController

    /// Explicit selection state so the shell can be driven from elsewhere
    /// later (a complication tap landing on a specific page, say) without
    /// restructuring — and so `.page` styling has stable identity to animate
    /// between.
    @State private var selection: Page = .overview

    /// The result of the last keep-awake command, surfaced as an alert.
    ///
    /// **Why an alert rather than in-place state.** The command travels
    /// watch → iPhone → Mac (`WatchControlBridge`), and the *only* thing this
    /// app learns about the outcome is the sentence that bridge returns. The
    /// Mac's new state arrives separately, on the relay's own schedule, which
    /// may be minutes away — so optimistically flipping the page's toggle
    /// would be showing the user a state the Mac has not confirmed and might
    /// have rejected. The alert reports exactly what happened and the page
    /// keeps showing the last state the Mac actually reported. See
    /// `WatchRelayPolicy.isSignificantChange`, which relays an
    /// `awakeIsActive` transition promptly for precisely this reason.
    @State private var actionResult: String?

    private enum Page: Hashable {
        case overview, keepAwake, agents
    }

    /// The palette every page reads from the environment, resolved from the
    /// theme the phone relayed — see `WatchPalette`. Computed here, once, so
    /// no page has to know where a colour came from and none can quietly fall
    /// back to a hardcoded one.
    private var palette: WatchPalette {
        WatchPalette(snapshot: sessionController.latestSnapshot)
    }

    var body: some View {
        TabView(selection: $selection) {
            overviewPage
                .modifier(PageChrome())
                .tag(Page.overview)
            keepAwakePage
                .modifier(PageChrome())
                .tag(Page.keepAwake)
            agentActivityPage
                .modifier(PageChrome())
                .tag(Page.agents)
        }
        .tabViewStyle(.page)
        .environment(\.palette, palette)
        // **Tell SwiftUI which appearance is actually on screen.** watchOS
        // reports `colorScheme == .dark` unconditionally — the platform has
        // no light mode of its own — so every semantic colour in every view
        // this app renders resolves for a dark background, including inside
        // shared components this target does not own (`FreshnessBadge`, in
        // `SentryKit/Sync/`, whose "Live" label came out pale grey on a white
        // page). Overriding the environment fixes all of them at once and is
        // the honest statement: under a light theme, this app *is* rendering
        // light, whatever the platform assumes.
        .environment(\.colorScheme, palette.appearance == .light ? .light : .dark)
        // The canvas, behind every page and behind the status bar's own
        // area. `ignoresSafeArea` so the theme's background runs to the
        // physical edge rather than leaving a system-coloured band around a
        // themed page — which is most visible under a light preset, where
        // the default black would frame the content.
        .background(palette.background.ignoresSafeArea())
        .overlay(alignment: .top) { clockScrim }
        .alert(
            // "Sentry", not "Keep Awake": this alert now reports outcomes
            // for both the keep-awake taps and the agent kill switch, and a
            // title naming the wrong feature would misattribute the message.
            "Sentry",
            isPresented: Binding(
                get: { actionResult != nil },
                set: { if !$0 { actionResult = nil } }
            )
        ) {
            Button("OK", role: .cancel) { actionResult = nil }
        } message: {
            Text(actionResult ?? "")
        }
    }

    // MARK: Clock legibility

    /// A soft dark wash across the top of the screen, drawn **only under a
    /// light appearance**.
    ///
    /// **Why this has to exist.** watchOS draws the time in the top-right
    /// corner itself, always in white, and gives an app no way to restyle or
    /// suppress it. That is invisible on a light page — verified on the
    /// simulator under the Paper preset, where the clock disappeared
    /// completely. It is also the single worst thing a watch app can break:
    /// whatever else Sentry is showing, the device is a watch and the time
    /// has to be readable.
    ///
    /// **Why a gradient scrim rather than the alternatives.** A solid bar
    /// would read as a black status strip stapled onto a white page. Keeping
    /// the whole canvas dark and only lightening the cards was tried first
    /// and is the thing this change exists to stop doing — it is what made
    /// the watch not match a light phone. Darkening the theme's background
    /// until white text lands on it would mean not honouring the light theme
    /// at all. A wash that is strongest at the very top and gone by the time
    /// content starts costs the design almost nothing, reads as a vignette
    /// rather than as chrome, and buys back the ~4.5:1 the clock needs.
    ///
    /// Height is `topScrimHeight` — deliberately taller than the clock's own
    /// glyphs so the fade completes above the first row of page content and
    /// never tints a card.
    @ViewBuilder
    private var clockScrim: some View {
        if palette.appearance == .light {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.42), location: 0),
                    .init(color: .black.opacity(0.30), location: 0.35),
                    .init(color: .black.opacity(0.10), location: 0.72),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.topScrimHeight)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Measured against the 42mm simulator: the system clock's baseline sits
    /// around 30pt from the physical top, so the wash has to still be dark at
    /// 30 and fully clear by roughly 54, which is where `PageChrome`'s
    /// content begins.
    private static let topScrimHeight: CGFloat = 54

    // MARK: Pages

    @ViewBuilder
    private var overviewPage: some View {
        if let snapshot = sessionController.latestSnapshot {
            OverviewPage(snapshot: snapshot)
        } else {
            UnavailablePage(
                symbol: "applewatch.radiowaves.left.and.right",
                title: String(localized: "No data yet"),
                detail: String(localized: "Open Sentry on your iPhone while on the same Wi-Fi as your Mac.")
            )
        }
    }

    /// Rendered only when the watch actually knows the Mac's sleep-assertion
    /// state — see this type's doc comment on why `false` is not a usable
    /// stand-in for "unknown" here.
    @ViewBuilder
    private var keepAwakePage: some View {
        if let snapshot = sessionController.latestSnapshot, let isActive = snapshot.awakeIsActive {
            KeepAwakePage(
                isActive: isActive,
                // Only meaningful while active; an expiry left over from a
                // released assertion would render as a countdown to nothing.
                expiresAt: isActive ? snapshot.awakeExpiresAt : nil,
                modeLabel: isActive ? snapshot.awakeModeLabel : nil,
                onKeepAwake: { minutes in send(.keepAwake(minutes: minutes)) },
                onRelease: { send(.release) },
                onExtend: { minutes in send(.extend(minutes: minutes)) }
            )
        } else {
            UnavailablePage(
                symbol: "moon.zzz",
                title: String(localized: "Sleep state unknown"),
                detail: sessionController.latestSnapshot == nil
                    ? String(localized: "Nothing has been relayed from your iPhone yet.")
                    : String(localized: "Your Mac hasn't reported whether it's being kept awake.")
            )
        }
    }

    /// Wired to the real payload fields, which are `nil` today for a reason
    /// documented at length on `WatchRelaySnapshot.agentToolCallCount`: no
    /// Mac→iPhone message carries agent activity, so there is nothing for the
    /// phone to relay. `AgentActivityPage` takes `toolCallCount` as `Int?`
    /// precisely so it can say "nothing reported" instead of "0", and that is
    /// what it will show until the Mac side of that gap is built. No
    /// placeholder numbers are synthesised here to make the page look
    /// finished.
    @ViewBuilder
    private var agentActivityPage: some View {
        if let snapshot = sessionController.latestSnapshot {
            AgentActivityPage(
                toolCallCount: snapshot.agentToolCallCount,
                lastActivityAt: snapshot.agentLastActivityAt,
                recentToolNames: snapshot.agentRecentToolNames ?? [],
                // Staleness of the *relay*, not of the agent log: if the
                // whole snapshot is old, so is anything it says about agents.
                isStale: Self.isStale(snapshot),
                onStopAgents: { sendStopAgents() },
                agentAccessPaused: snapshot.agentAccessPaused,
                onResumeAgents: { sendResumeAgents() }
            )
        } else {
            UnavailablePage(
                symbol: "sparkles",
                title: String(localized: "No agent data"),
                detail: String(localized: "Nothing has been relayed from your iPhone yet.")
            )
        }
    }

    /// `.stale`/`.asleep` from the same `Freshness` tiers every other surface
    /// in this codebase buckets against, rather than a threshold invented
    /// here — see `Freshness`'s doc comment on why that discipline is
    /// centralised.
    private static func isStale(_ snapshot: WatchRelaySnapshot) -> Bool {
        switch Freshness(lastSeen: snapshot.lastSeen) {
        case .stale, .asleep: return true
        case .live, .recent: return false
        }
    }

    // MARK: Keep-awake commands

    /// The three commands the Keep Awake page can issue, named so `send`
    /// below has one place to build each `ControlCommand` and one place to
    /// word each success sentence.
    private enum AwakeAction {
        case keepAwake(minutes: Int)
        case release
        case extend(minutes: Int)
    }

    /// Routes every Keep Awake tap through `WatchControlBridge` — the same
    /// path `WatchKeepAwakeIntent` and friends
    /// (`SentryWatch/Intents/SentryWatchIntents.swift`) already use for
    /// Siri, deliberately rather than a second command path. The bridge
    /// already handles all four failure modes with their own honest sentence
    /// (no `WCSession`, iPhone unreachable, Mac declined/expired, no reply in
    /// time), so nothing here needs to invent error wording, and nothing here
    /// reports success the Mac did not confirm.
    ///
    /// `commandType`/`parametersJSON` are copied from those intents verbatim,
    /// including `deviceID: "unknown"` — the watch has never known the Mac's
    /// `deviceID` (the relay payload carries a display *name*, not an ID),
    /// and the phone's `AppDataSource.transport` addresses the Mac it is
    /// already connected to rather than routing on this field. Inventing a
    /// different placeholder here would only make the two paths diverge.
    private func send(_ action: AwakeAction) {
        let command: ControlCommand
        let successSentence: String

        switch action {
        case .keepAwake(let minutes):
            // `KeepAwakePage.indefiniteMinutes` is that page's documented
            // sentinel for "until I turn it off" — the Mac supports an
            // untimed assertion (`PowerControlService.startAssertion(duration:
            // nil)`) and a non-Optional minute count has no other way to
            // spell it. Branched on explicitly, and against the *named*
            // constant rather than a bare `0`: the obvious
            // `durationSeconds: minutes * 60` would send `0`, which
            // `LocalCommandExecutor.executeKeepAwake` happens to coerce to
            // `nil` by way of its `> 0` guard — right answer, wrong reason,
            // and it would stop being right the moment either side changed.
            // Referring to the symbol also means that if the sentinel is ever
            // replaced by an `Int?` signature, this stops compiling instead of
            // quietly sending a one-second assertion.
            if minutes == KeepAwakePage.indefiniteMinutes {
                // No `durationSeconds` key at all, rather than an explicit
                // zero — the same shape the phone's own indefinite request
                // sends, so the Mac never has to interpret a zero.
                command = Self.command(
                    type: "keepAwake",
                    parametersJSON: #"{"mode":"systemOnly"}"#
                )
                successSentence = String(localized: "Your Mac will stay awake until you turn it off.")
            } else {
                command = Self.command(
                    type: "keepAwake",
                    parametersJSON: #"{"durationSeconds":\#(max(minutes, 0) * 60),"mode":"systemOnly"}"#
                )
                successSentence = String(localized: "Your Mac will stay awake for \(String(minutes)) minutes.")
            }
        case .release:
            command = Self.command(type: "releaseAwake", parametersJSON: "{}")
            successSentence = String(localized: "Your Mac can sleep normally again.")
        case .extend(let minutes):
            command = Self.command(
                type: "extendAwake",
                parametersJSON: #"{"deltaSeconds":\#(max(minutes, 0) * 60)}"#
            )
            successSentence = String(localized: "Added \(String(minutes)) minutes to your Mac's keep-awake time.")
        }

        Task { @MainActor in
            actionResult = await WatchControlBridge.sendAndDescribe(command, whenCompleted: successSentence)
        }
    }

    // MARK: Agent kill switch

    /// The Agent Activity page's stop control: a `setAgentAccessPaused`
    /// `ControlCommand` through the same watch → iPhone → Mac bridge every
    /// keep-awake tap uses, landing in `LocalCommandExecutor`
    /// (`SentryKit/Services/LocalCommandExecutor.swift`), which flips the
    /// Mac's `AgentGuardrailSettings.killSwitchEngaged`.
    private func sendStopAgents() {
        let command = Self.command(type: "setAgentAccessPaused", parametersJSON: #"{"paused":true}"#)
        Task { @MainActor in
            actionResult = await WatchControlBridge.sendAndDescribe(
                command,
                whenCompleted: String(localized: "Agent access on your Mac is paused. Resume it from Sentry on the Mac.")
            )
        }
    }

    /// The un-pause counterpart, wired to `AgentActivityPage`'s "Resume
    /// Agents" button — shown only while `snapshot.agentAccessPaused ==
    /// true`, i.e. only once the watch has a truthful pause state to show a
    /// resume control against (see `AgentActivityPage.agentAccessPaused`'s
    /// doc comment). Same command type as `sendStopAgents()`, `paused:false`
    /// instead of `true` — `LocalCommandExecutor` already accepts either.
    private func sendResumeAgents() {
        let command = Self.command(type: "setAgentAccessPaused", parametersJSON: #"{"paused":false}"#)
        Task { @MainActor in
            actionResult = await WatchControlBridge.sendAndDescribe(
                command,
                whenCompleted: String(localized: "Agent access on your Mac has been resumed.")
            )
        }
    }

    /// The `nonce`/`expiresAt` envelope every `ControlCommand` in this app
    /// carries: a fresh nonce per command so the Mac's replay protection
    /// (`NonceTracker`) can reject a duplicate, and a five-minute expiry so a
    /// command that sat queued while the phone was unreachable is dropped
    /// rather than acted on long after the user stopped wanting it. Both
    /// match the watch Siri intents exactly.
    private static func command(type: String, parametersJSON: String) -> ControlCommand {
        ControlCommand(
            deviceID: "unknown",
            issuedAt: Date(),
            commandType: type,
            parametersJSON: parametersJSON,
            nonce: UUID().uuidString,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
    }
}

// MARK: - PageChrome

/// The margins and bottom clearance every page gets, applied once by the
/// shell.
///
/// **Why it lives in the shell rather than in each page.** Every page here is
/// written flush to its own frame edges, deliberately — a page that insets
/// itself and is then hosted inside chrome that also insets ends up
/// double-padded, and on a 42mm screen that is the difference between three
/// metric dials fitting and not. Putting the inset on the container means
/// there is exactly one number to change and it applies identically to pages
/// written by different hands.
///
/// **What changed in the redesign, and why both halves were needed.** The
/// horizontal inset was 4pt, chosen to clear the bezel — but the constraint
/// that actually bites is the display's *corner radius*, which curves in over
/// the top and bottom of any line of text near the edge. At 4pt the
/// simulator rendered the Overview header's device name and Keep Awake's mode
/// label visibly clipped on their right-hand side. `WatchLayout
/// .horizontalMargin` clears the curve at every supported size.
///
/// The bottom half is new and fixes the other half of the same complaint:
/// `TabView`'s `.page` style floats its dot indicator *over* the bottom of
/// the page instead of reserving space above it, so whatever each page put
/// last was the thing sitting under the dots. Each page used to pad its own
/// bottom by a number it picked itself, and all three picked one too small.
/// A `safeAreaInset` here means the clearance is structural — it applies to
/// the page's scroll view as real safe area, so content scrolls clear of the
/// dots instead of merely starting clear of them — and a page cannot forget
/// it.
private struct PageChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, WatchLayout.horizontalMargin)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: WatchLayout.pagingIndicatorClearance)
            }
    }
}

// MARK: - UnavailablePage

/// The one "we don't have this" page, used by all three tabs.
///
/// Deliberately one shared view with caller-supplied wording rather than
/// three bespoke empty states: the *shape* of "nothing to show here" should
/// be identical everywhere so a user learns it once, while the sentence has
/// to differ, because "nothing has been relayed yet" and "your Mac didn't
/// report this" are different problems with different fixes. The detail line
/// describes what the user can act on and never guesses at a cause the app
/// cannot distinguish.
struct UnavailablePage: View {
    @Environment(\.palette) private var palette

    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // Circled and tinted rather than a bare glyph: an empty state
                // is the first thing a new user sees, and a lone grey symbol
                // on black reads as a rendering failure rather than as a
                // designed state.
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(palette.accent)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(palette.surface))

                Text(title)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                    .multilineTextAlignment(.center)

                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
        }
    }
}

// MARK: - Formatting

/// The watch app's own tiny formatting helpers, shared by the pages.
///
/// **Why not `MetricFormatting` (`SentryKit/Models/MetricFormatter.swift`),
/// which already does all of this.** `SentryKit_watchOS` (`project.yml`)
/// deliberately compiles a hand-picked handful of files rather than the whole
/// framework, because most of `SentryKit` is macOS-only IOKit/XPC code or
/// depends on GRDB. Pulling `MetricFormatter.swift` in to reuse two functions
/// would drag its dependencies along behind it and undo that target's whole
/// reason for existing. The duplication is a few lines and is noted here so
/// the next reader sees it was measured, not missed.
enum WatchFormatting {
    /// The same em-dash `MetricFormatting.placeholder` uses on the other
    /// platforms, so "no value" looks identical wherever the user meets it.
    static let placeholder = "—"

    /// A non-finite value (`nan`/`infinity` from a divide-by-zero upstream)
    /// is treated as no value rather than printed — `Int(Double.nan)` traps,
    /// and even if it didn't, "nan%" is not a thing to show a person.
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return placeholder }
        return "\(Int(value.rounded()))%"
    }

    /// "45m", "3h", "3h 40m" — hours dropped when zero, minutes dropped when
    /// zero, so a caption never reads "3h 0m". Negative input is impossible
    /// by the time it reaches here (`WatchRelayManager.batteryRunwayMinutes`
    /// discards non-positive estimates) but is clamped anyway rather than
    /// rendering "-2h left" if that ever stops being true.
    static func duration(minutes: Int) -> String {
        let total = max(0, minutes)
        let hours = total / 60
        let remainder = total % 60
        if hours == 0 { return "\(remainder)m" }
        if remainder == 0 { return "\(hours)h" }
        return "\(hours)h \(remainder)m"
    }
}

// MARK: - Previews

#Preview("Populated") {
    ContentView()
        .environmentObject(WatchSessionController(preview: .fullyPopulated))
}

#Preview("Partial data") {
    ContentView()
        .environmentObject(WatchSessionController(preview: .batteryOnly))
}

#Preview("Nothing relayed") {
    ContentView()
        .environmentObject(WatchSessionController())
}
