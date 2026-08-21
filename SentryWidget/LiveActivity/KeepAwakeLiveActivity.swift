// MARK: - iOS-only: ActivityKit has no macOS counterpart

// `SentryWidget/` compiles for both `SentryWidgetExtension` (iOS) and
// `SentryWidgetExtension_macOS`, and ActivityKit exists on neither the macOS
// 14 SDK this project targets nor any later one. Compile-time fence rather
// than `@available`, for the same reason `MacAwakeControlWidget.swift` uses
// one: `@available` still requires the declarations to type-check against
// the macOS SDK, and `ActivityConfiguration`/`DynamicIsland` do not exist
// there to type-check against.
#if os(iOS)

import ActivityKit
import AppIntents
import SentryKit
import SwiftUI
import WidgetKit

// MARK: - KeepAwakeLiveActivity

/// The Lock Screen and Dynamic Island presentations of a keep-awake session.
///
/// **Read `KeepAwakeActivityState`'s doc comment first** — it carries the
/// argument for why this app has a Live Activity for a *session* and cannot
/// have one for *stats*. The one-line version: updating a Live Activity for
/// a backgrounded app requires an APNs push from a server, this project has
/// promised in its shipped privacy policy that it runs no server, and
/// therefore the only content a Sentry Live Activity may show is content the
/// system can keep correct by itself. A deadline is such content;
/// `Text(timerInterval:)` and `ProgressView(timerInterval:)` are rendered
/// and ticked by the system with zero involvement from this app, so a
/// two-hour hold counts down accurately for two hours while nothing of ours
/// executes. A CPU percentage is not such content, and would freeze.
///
/// **Registered in the existing bundle, not a new extension.** This is a
/// `Widget` like any other and joins `SentryWidgetBundle`'s `body` beside
/// `SentryWidget` and `MacAwakeControlWidget`. A second appex would mean a
/// second bundle to sign, provision, privacy-manifest and version-match
/// against the host app, in exchange for nothing.
///
/// **Colours.** Exactly the vocabulary the rest of this extension already
/// uses, and no more: `.purple` with `moon.zzz.fill` for a hold that is
/// credibly live, `.secondary` with `moon.zzz` for one that is not — the
/// pair `MediumWidgetView.sleepRow` established, so a user who sees the
/// widget and the Lock Screen sees one app. `ThemePalette` is unreachable
/// from an app extension (it is `internal` to the app targets — see
/// `FreshnessBadge`'s doc comment for the full dependency-direction
/// argument), and inventing a second palette here to compensate would give
/// this app two colour languages instead of one. Nothing state-bearing is
/// carried by hue or glyph alone: every distinction below is also spelled
/// out in words, per the standing rule `WidgetDemoDataTag` records.
struct KeepAwakeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: KeepAwakeActivityAttributes.self) { context in
            KeepAwakeLockScreenView(context: context)
        } dynamicIsland: { context in
            KeepAwakeDynamicIsland.island(for: context)
        }
    }
}

// MARK: - Shared vocabulary

/// The words and glyphs every presentation below shares, derived once from
/// the state so the Lock Screen, the expanded island and the compact island
/// cannot describe the same session three different ways.
///
/// **Why `isStale` is an input rather than something computed here.** It is
/// the system's answer, not ours: ActivityKit flips
/// `ActivityViewContext.isStale` when it passes the `staleDate` the app
/// supplied (`KeepAwakeActivityState.staleDate(asOf:isMacReachable:)`), and
/// crucially it *re-renders the view* at that instant. That re-render is the
/// only clock a Live Activity has — a view body's `Date()` is evaluated once
/// when the content is archived and never again — so `isStale` is what lets
/// this presentation stop making a present-tense claim without a server
/// pushing it a correction. It is the whole reason a server-less Live
/// Activity can be honest.
struct KeepAwakeChrome {

    let presentation: KeepAwakeActivityPresentation
    let isStale: Bool
    let state: KeepAwakeActivityState
    let deviceName: String

    init(context: ActivityViewContext<KeepAwakeActivityAttributes>) {
        self.state = context.state
        self.deviceName = context.attributes.deviceName
        self.isStale = context.isStale
        self.presentation = context.state.presentation(asOf: Date())
    }

    /// Whether this surface may speak in the present tense about the Mac.
    /// Both conditions are necessary: the hold has to still be running *and*
    /// the phone has to have heard about it recently enough that the system
    /// has not aged the activity.
    var claimsActive: Bool {
        guard !isStale else { return false }
        if case .ended = presentation { return false }
        return true
    }

    var glyph: String { claimsActive ? "moon.zzz.fill" : "moon.zzz" }

    var tint: Color { claimsActive ? .purple : .secondary }

    /// The one-line headline. Four distinct sentences for four distinct
    /// situations — a single "Keeping Mac awake" with the differences buried
    /// in a subtitle is how the phone came to show "● Active" for holds that
    /// had ended.
    var headline: String {
        if case .ended = presentation {
            return String(localized: "Keep-awake time is up")
        }
        if isStale {
            return String(localized: "Keep awake — unconfirmed")
        }
        return String(localized: "Keeping \(deviceName) awake")
    }

    /// The line under the headline: what the Mac is holding, or why this
    /// surface has stopped vouching for it.
    var detail: String {
        if let endFailure = state.endFailure { return endFailure }
        if case .ended = presentation {
            return String(localized: "Waiting for your Mac to confirm it ended.")
        }
        if isStale {
            return String(localized: "Your Mac hasn't confirmed since \(Self.timeText(state.lastConfirmedAt)) — it may have ended.")
        }
        return state.mode.liveActivityModeLabel
    }

    /// The line describing the session's end — the load-bearing
    /// timed-versus-indefinite distinction, in words rather than only in the
    /// presence or absence of a bar.
    var endDescription: String {
        switch presentation {
        case .countingDown(let until):
            // "by", not "at". The recorded deadline is enforced by the Mac's
            // own OS-level assertion timeout, so it is a guaranteed upper
            // bound; it is not a guarantee the hold will still be running
            // right up to it, since it can be released early on the Mac
            // while this phone is out of contact. See
            // `KeepAwakeActivityState.staleDate(asOf:isMacReachable:)`.
            return String(localized: "Ends by \(Self.timeText(until))")
        case .indefinite:
            return String(localized: "No end time — runs until you end it")
        case .ended(let at):
            return String(localized: "Was due to end at \(Self.timeText(at))")
        }
    }

    /// Short form for the Dynamic Island's expanded trailing region, where
    /// there is room for a couple of words and not a sentence.
    var compactEndDescription: String {
        switch presentation {
        case .countingDown: return String(localized: "left")
        case .indefinite: return String(localized: "No end")
        case .ended: return String(localized: "Time's up")
        }
    }

    /// A range safe to hand `Text(timerInterval:)` and
    /// `ProgressView(timerInterval:)`, both of which trap on an empty or
    /// inverted range. `startedAt` can legitimately sit after `expiresAt`
    /// once a hold has been truncated below its own elapsed time, which is a
    /// real command (`TruncateAwakeIntent`, `SleepStatusCard`'s "-15m") and
    /// not a hypothetical.
    static func timerRange(from start: Date, to end: Date) -> ClosedRange<Date> {
        let lower = min(start, end.addingTimeInterval(-1))
        return lower...end
    }

    static func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - AwakeMode wording

extension AwakeMode {

    /// The mode, as a whole sentence fragment for a Lock Screen line.
    ///
    /// Same three distinctions and the same words as
    /// `MediumWidgetView.sleepRow`'s "Awake: display on" / "system only" /
    /// "while on AC", restated here as complete localized phrases rather
    /// than composed from a shared fragment. That is the same tradeoff that
    /// file already makes, and for the same reason: three whole strings give
    /// a translator three things to translate and a place to put a language's
    /// own word order, where a shared fragment plus a format string gives
    /// them a jigsaw. `AwakeMode.mobileShortLabel` is the phone app's
    /// equivalent and is unreachable from here — an app extension cannot
    /// import its containing app's target.
    var liveActivityModeLabel: String {
        switch self {
        case .displayAndSystem: return String(localized: "Display stays on")
        case .systemOnly: return String(localized: "System only — the display may still sleep")
        case .systemWhileOnAC: return String(localized: "Only while plugged in")
        }
    }

    /// The Dynamic Island's expanded-leading form, where the region is about
    /// as wide as two short words.
    var liveActivityShortLabel: String {
        switch self {
        case .displayAndSystem: return String(localized: "Display on")
        case .systemOnly: return String(localized: "System only")
        case .systemWhileOnAC: return String(localized: "While on AC")
        }
    }
}

// MARK: - End button

/// The End control, in one place so the Lock Screen and the expanded island
/// cannot end up wired to different intents or different labels.
///
/// **No tint.** The app's own "End Now" is `palette.danger`, but this
/// extension has no palette (see `KeepAwakeLiveActivity`'s doc comment) and
/// `.red` already means "battery below 20%" in this bundle's vocabulary
/// (`BatteryArcView.arcColor`). A bordered button with a plain word is
/// legible in every Lock Screen wallpaper condition and introduces no new
/// colour meaning — the same restraint `SentryWidgetEntryView` shows in
/// using the semantic `.background` style rather than picking a surface
/// colour of its own.
struct KeepAwakeEndButton: View {
    let activityID: String
    var compact: Bool = false

    var body: some View {
        Button(intent: EndKeepAwakeIntent(activityID: activityID)) {
            Text("End")
                .font(compact ? .caption2 : .caption)
                .fontWeight(.semibold)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .accessibilityLabel(Text("End keep-awake on your Mac"))
    }
}

// MARK: - Lock Screen

/// The banner shown on the Lock Screen and, when the phone is unlocked, at
/// the top of Notification Center.
struct KeepAwakeLockScreenView: View {
    let context: ActivityViewContext<KeepAwakeActivityAttributes>

    private var chrome: KeepAwakeChrome { KeepAwakeChrome(context: context) }

    var body: some View {
        let chrome = self.chrome
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: chrome.glyph)
                    .font(.title3)
                    .foregroundStyle(chrome.tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(chrome.headline)
                        .font(.headline)
                        .lineLimit(1)
                    Text(chrome.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        // Never truncated to one line: the stale and
                        // end-failure sentences are the ones a reader most
                        // needs whole, and vertical space on a Lock Screen
                        // banner is cheap.
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                KeepAwakeEndButton(activityID: context.activityID)
            }

            countdown(chrome)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The timed-versus-indefinite fork, and the only place in this file a
    /// system-rendered timer is created.
    @ViewBuilder
    private func countdown(_ chrome: KeepAwakeChrome) -> some View {
        switch chrome.presentation {
        case .countingDown(let until) where !chrome.isStale:
            let range = KeepAwakeChrome.timerRange(from: context.attributes.startedAt, to: until)
            VStack(alignment: .leading, spacing: 4) {
                // Both of these are drawn by the system from the range
                // alone. Neither needs — or can receive — an update from
                // this app, which is what makes an unattended countdown on a
                // server-less app possible at all.
                ProgressView(timerInterval: range, countsDown: true) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.linear)
                .tint(.purple)

                HStack {
                    Text(timerInterval: range, countsDown: true)
                        .font(.system(.title3, design: .monospaced))
                        .monospacedDigit()
                    Spacer()
                    Text(chrome.endDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

        case .countingDown, .indefinite, .ended:
            // Everything that is *not* a live countdown gets the same
            // treatment: a sentence, and no ticking anything.
            //
            // For `.indefinite` that is the requirement outright — there is
            // no end to count towards, and a count-*up* timer, the obvious
            // substitute, reads as a live measurement of a machine this
            // phone may not currently be hearing from.
            //
            // For a stale timed hold it is the same judgment arrived at
            // differently: the countdown would still be arithmetically
            // correct, but a ticking number is the most confident present-
            // tense claim this surface can make, and the system has just
            // told us the content is past the point where we vouched for it.
            Text(chrome.endDescription)
                .font(.subheadline)
                .foregroundStyle(chrome.claimsActive ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Dynamic Island

/// The three Dynamic Island presentations. Grouped in a type of their own
/// rather than inlined in `KeepAwakeLiveActivity.body` purely for the type
/// checker's sake — the `DynamicIsland` builder with four expanded regions
/// plus three collapsed ones in one expression is past what it will solve in
/// reasonable time, the same problem `SleepStatusCard.body` splits itself to
/// avoid.
enum KeepAwakeDynamicIsland {

    static func island(for context: ActivityViewContext<KeepAwakeActivityAttributes>) -> DynamicIsland {
        let chrome = KeepAwakeChrome(context: context)
        return DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                HStack(spacing: 6) {
                    Image(systemName: chrome.glyph)
                        .foregroundStyle(chrome.tint)
                        .accessibilityHidden(true)
                    Text(chrome.state.mode.liveActivityShortLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            DynamicIslandExpandedRegion(.trailing) {
                expandedTrailing(chrome, context: context)
            }
            DynamicIslandExpandedRegion(.center) {
                Text(chrome.headline)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            DynamicIslandExpandedRegion(.bottom) {
                HStack(alignment: .center, spacing: 12) {
                    Text(chrome.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    KeepAwakeEndButton(activityID: context.activityID, compact: true)
                }
            }
        } compactLeading: {
            Image(systemName: chrome.glyph)
                .foregroundStyle(chrome.tint)
                .accessibilityLabel(Text(chrome.headline))
        } compactTrailing: {
            compactTrailing(chrome, context: context)
        } minimal: {
            // One glyph is all there is room for, so it carries the state on
            // its own here — the single exception to the never-hue-alone
            // rule, forced by the surface: the minimal presentation is a
            // circle roughly the size of a status-bar icon. `accessibilityLabel`
            // restores the words for anyone reading it aloud.
            Image(systemName: chrome.glyph)
                .foregroundStyle(chrome.tint)
                .accessibilityLabel(Text(chrome.headline))
        }
    }

    @ViewBuilder
    private static func expandedTrailing(
        _ chrome: KeepAwakeChrome,
        context: ActivityViewContext<KeepAwakeActivityAttributes>
    ) -> some View {
        switch chrome.presentation {
        case .countingDown(let until) where !chrome.isStale:
            let range = KeepAwakeChrome.timerRange(from: context.attributes.startedAt, to: until)
            VStack(alignment: .trailing, spacing: 0) {
                Text(timerInterval: range, countsDown: true)
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 82)
                Text(chrome.compactEndDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .countingDown, .indefinite, .ended:
            Text(chrome.compactEndDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private static func compactTrailing(
        _ chrome: KeepAwakeChrome,
        context: ActivityViewContext<KeepAwakeActivityAttributes>
    ) -> some View {
        switch chrome.presentation {
        case .countingDown(let until) where !chrome.isStale:
            Text(
                timerInterval: KeepAwakeChrome.timerRange(from: context.attributes.startedAt, to: until),
                countsDown: true
            )
            .monospacedDigit()
            // The compact presentation shares the notch with whatever else
            // is running, so it is given a hard ceiling rather than allowed
            // to push its neighbour out.
            .frame(maxWidth: 62)
        case .indefinite where !chrome.isStale:
            // The indefinite hold's compact form. An infinity glyph, never a
            // number: there is nothing to count, and a timer here would be a
            // fabricated deadline rendered in the most authoritative place
            // this app can put one.
            Image(systemName: "infinity")
                .accessibilityLabel(Text("No end time"))
        case .countingDown, .indefinite, .ended:
            Image(systemName: "questionmark")
                .accessibilityLabel(Text(chrome.headline))
        }
    }
}

#endif
