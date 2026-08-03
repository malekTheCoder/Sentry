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
    private let freshness: Freshness
    private let lastSeen: Date
    private let now: Date

    /// - Parameters:
    ///   - lastSeen: the timestamp being described (e.g. `Device.lastSeen`).
    ///   - now: defaults to `Date()`; overridable so SwiftUI previews and
    ///     screenshot tests can pin a frozen instant instead of racing the
    ///     real clock, matching `Freshness.init(lastSeen:now:)`'s own
    ///     testability-first parameter.
    public init(lastSeen: Date, now: Date = Date()) {
        self.lastSeen = lastSeen
        self.now = now
        self.freshness = Freshness(lastSeen: lastSeen, now: now)
    }

    public var body: some View {
        Label {
            Text(freshness.label(lastSeen: lastSeen, now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: freshness.symbolName)
                .font(.system(size: freshness == .asleep ? 11 : 8))
                .foregroundStyle(color)
        }
        .labelStyle(.titleAndIcon)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(freshness.label(lastSeen: lastSeen, now: now))
    }

    /// Plan §12.2's exact color assignment. `.asleep` has no color of its
    /// own in the plan (it's carried entirely by the moon glyph vs. the
    /// other tiers' dot), so it reuses the same secondary gray as `.stale`
    /// rather than introducing a fifth, unspecified color.
    private var color: Color {
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
