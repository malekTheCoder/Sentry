import SwiftUI

// MARK: - FreshnessBadge: the one reusable rendering of `Freshness`

/// A small color+icon+label pill for a `Freshness` value, so every screen
/// that shows Mac-derived data (Dashboard, History, Alerts — plan §12.1)
/// renders the *same* freshness indicator rather than each screen inventing
/// its own dot/label pairing. Plan §12.2's discipline ("never render a
/// number without its freshness indicator nearby") only holds if dropping
/// the indicator in is as cheap as `FreshnessBadge(lastSeen: device.lastSeen)`
/// — a view any other agent building History/Alerts content can reach for
/// without re-deriving color/icon/label rules per screen.
///
/// **Why plain `SwiftUI.Color`, not `ThemePalette`.** `ThemePalette`
/// (Mac: `Sentry/Dropdown/ThemeColor+SwiftUI.swift`; iOS: the equivalent
/// file in `SentryMobile/`) resolves a `Theme` against a `ColorScheme` and
/// lives in the *app* targets, not `SentryKit` — it isn't available to a
/// framework-level view without inverting that dependency (app targets
/// depend on `SentryKit`, not the reverse). Freshness's own color meanings
/// (green=live, amber=recent, gray=stale) are also plan-specified constants,
/// not user-themeable tokens the way CPU/GPU chart colors are — so using
/// SwiftUI's semantic `.green`/`.orange`/`.secondary` here is the correct
/// choice on the merits, not just a dependency-direction workaround.
///
/// **Why this lives in `SentryKit` despite being the framework's first
/// SwiftUI file.** `Freshness` itself already lives here (see that file's
/// doc comment on why it's cross-platform logic, not iOS-specific), and
/// `import SwiftUI` + a plain `View` body below has no AppKit/UIKit
/// dependency — it compiles for both the `SentryKit_macOS` and
/// `SentryKit_iOS` framework targets exactly like the rest of this file's
/// neighbors. Keeping the view next to the type it renders means "how do I
/// show a `Freshness`" has exactly one answer, discoverable from either
/// platform's app target.
public struct FreshnessBadge: View {
    private let lastSeen: Date
    /// `nil` when this instance was built via the auto-refreshing
    /// initializer below — see `refreshInterval`'s doc comment for why
    /// those two are mutually exclusive.
    private let fixedNow: Date?
    /// `nil` for the default, render-once behavior every existing caller
    /// already gets. Set only by `init(lastSeen:refreshingEvery:)`.
    private let refreshInterval: TimeInterval?

    /// - Parameters:
    ///   - lastSeen: the timestamp being described (e.g. `Device.lastSeen`).
    ///   - now: defaults to `Date()`; overridable so SwiftUI previews and
    ///     screenshot tests can pin a frozen instant instead of racing the
    ///     real clock, matching `Freshness.init(lastSeen:now:)`'s own
    ///     testability-first parameter.
    ///
    /// Renders once, from whatever `now` was at init time. That is exactly
    /// right for a view that gets rebuilt on every relay (Dashboard, History,
    /// Alerts) but wrong for a screen that can sit on-screen for a long time
    /// with nothing forcing a re-render — see `init(lastSeen:refreshingEvery:)`
    /// for that case.
    public init(lastSeen: Date, now: Date = Date()) {
        self.lastSeen = lastSeen
        self.fixedNow = now
        self.refreshInterval = nil
    }

    /// A `FreshnessBadge` that keeps itself current without depending on the
    /// caller to re-render it.
    ///
    /// **Why this exists.** Every other caller of this type gets a fresh
    /// `now` for free because something external already redraws the screen
    /// on a relevant cadence (a new relay arriving, a list re-fetching). The
    /// Watch app's paged shell (`SentryWatch/Pages/OverviewPage.swift`) is
    /// the one place that assumption breaks: if the phone stops relaying
    /// while the watch face stays raised, nothing forces `OverviewPage`'s
    /// `body` to re-evaluate, so a badge built with the plain initializer
    /// keeps reporting the `now` it was handed at the last render — "Live"
    /// can outlive its actual 60-second window indefinitely. `KeepAwakePage`
    /// solves the identical problem for its countdown with a self-ticking
    /// `Text(_:style: .timer)`; a freshness *label* has no `Text` style
    /// equivalent, so this wraps the body in a `TimelineView(.periodic)`
    /// instead, which is the general-purpose version of the same idea.
    ///
    /// **Why an opt-in initializer rather than making every badge tick.**
    /// `FreshnessBadge` is used from a `List` row (`LocationLogSection`,
    /// `SentryMobile/Settings/`) and inside a widget's timeline entry
    /// (`LargeWidgetView`, `SentryWidget/Views/`), where an unconditional
    /// internal timer would mean N redundant `TimelineView`s ticking in a
    /// scrollable list, or a widget extension redrawing itself between the
    /// timeline reloads that are its actual update mechanism. Neither of
    /// those callers has this problem — they already get a fresh `now` from
    /// outside — so forcing the behavior on them would trade a real bug on
    /// one screen for a needless one everywhere else. This initializer is
    /// therefore the only way to opt in; the default initializer's behavior
    /// is unchanged, and no existing call site needs to change.
    ///
    /// `interval` is deliberately **not** defaulted, even though
    /// `defaultRefreshInterval` below exists to hand it a sensible value.
    /// `init(lastSeen:now:)` above already defaults its one parameter after
    /// `lastSeen`, and Swift resolves `FreshnessBadge(lastSeen: x)` between
    /// two initializers by which optional parameters are present, not by
    /// their labels — if this one also defaulted `interval`, that call
    /// becomes ambiguous between "render once at `Date()`" and "refresh
    /// every `defaultRefreshInterval`", and every existing call site
    /// (`FreshnessBadge(lastSeen:)` with no second argument) would stop
    /// compiling. Requiring `interval` explicitly keeps the two initializers
    /// unambiguous while still leaving `defaultRefreshInterval` as the
    /// value callers should reach for.
    ///
    /// - Parameters:
    ///   - lastSeen: as above.
    ///   - interval: how often the label recomputes. `defaultRefreshInterval`
    ///     (20s) is inside `Freshness.liveThreshold` (60s), so the
    ///     "Live" -> "1m ago" flip is never more than 20s late, but far
    ///     enough apart that this is a label refreshing, not a clock: the
    ///     callers this exists for don't need per-second precision, and the
    ///     always-on watch display doesn't need the extra redraws.
    public init(lastSeen: Date, refreshingEvery interval: TimeInterval) {
        self.lastSeen = lastSeen
        self.fixedNow = nil
        self.refreshInterval = interval
    }

    /// The recommended `interval` for `init(lastSeen:refreshingEvery:)` —
    /// see that initializer's doc comment for why it isn't just a default
    /// parameter value instead.
    public static let defaultRefreshInterval: TimeInterval = 20

    public var body: some View {
        if let refreshInterval {
            TimelineView(.periodic(from: .now, by: refreshInterval)) { context in
                badge(now: context.date)
            }
        } else {
            badge(now: fixedNow ?? Date())
        }
    }

    private func badge(now: Date) -> some View {
        let freshness = Freshness(lastSeen: lastSeen, now: now)
        return Label {
            Text(freshness.label(lastSeen: lastSeen, now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: freshness.symbolName)
                .font(.system(size: freshness == .asleep ? 11 : 8))
                .foregroundStyle(Self.color(for: freshness))
        }
        .labelStyle(.titleAndIcon)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(freshness.label(lastSeen: lastSeen, now: now))
    }

    /// Plan §12.2's exact color assignment. `.asleep` has no color of its
    /// own in the plan (it's carried entirely by the moon glyph vs. the
    /// other tiers' dot), so it reuses the same secondary gray as `.stale`
    /// rather than introducing a fifth, unspecified color.
    private static func color(for freshness: Freshness) -> Color {
        switch freshness {
        case .live: return .green
        case .recent: return .orange
        case .stale, .asleep: return .secondary
        }
    }
}

#if DEBUG
struct FreshnessBadge_Previews: PreviewProvider {
    static var previews: some View {
        let now = Date(timeIntervalSince1970: 1_000_000)
        VStack(alignment: .leading, spacing: 8) {
            FreshnessBadge(lastSeen: now, now: now)
            FreshnessBadge(lastSeen: now.addingTimeInterval(-120), now: now)
            FreshnessBadge(lastSeen: now.addingTimeInterval(-1_080), now: now)
            FreshnessBadge(lastSeen: now.addingTimeInterval(-3 * 3600), now: now)
        }
        .padding()
    }
}
#endif
