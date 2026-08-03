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

    var body: some View {
        TabView(selection: $selection) {
            overviewPage
                .modifier(PageInsets())
                .tag(Page.overview)
            keepAwakePage
                .modifier(PageInsets())
                .tag(Page.keepAwake)
            agentActivityPage
                .modifier(PageInsets())
                .tag(Page.agents)
        }
        .tabViewStyle(.page)
        .alert(
            "Keep Awake",
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
                isStale: Self.isStale(snapshot)
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

// MARK: - PageInsets

/// The one place horizontal inset is applied to a page.
///
/// **Why it lives in the shell rather than in each page.** Every page here is
/// written flush to its own frame edges, deliberately — a page that insets
/// itself and is then hosted inside chrome that also insets ends up
/// double-padded, and on a 40mm screen that is the difference between three
/// metric tiles fitting and not. Putting the inset on the container means
/// there is exactly one number to change, it applies identically to pages
/// written by different hands, and a page can still be previewed on its own
/// at full width to see what it really does with the space.
///
/// 4pt, not 8: watchOS already supplies a small safe-area inset of its own on
/// a round-cornered display, and this stacks on top of it. Measured against
/// the simulator at 46mm and 40mm rather than picked off a spec sheet — the
/// corner radius, not the bezel, is what decides how much is enough.
private struct PageInsets: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.horizontal, 4)
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
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
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
