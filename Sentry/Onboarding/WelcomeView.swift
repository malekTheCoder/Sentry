import SwiftUI
import SentryKit

/// The one-time first-run popover shown once, ever, by `OnboardingCoordinator`.
///
/// **Why this exists.** `AppDelegate.applicationDidFinishLaunching` sets
/// `.accessory` activation policy and goes straight into building the status
/// item and starting sampling — a first-time user gets a silent icon
/// appearing in their menu bar with zero explanation of what it is or where
/// settings live. This popover is that one missing sentence.
///
/// **Why one screen, not a wizard.** This app's own conventions favor
/// understatement — see `DropdownView`'s doc comment ("Restraint over
/// chrome... There are no cards here") and `AboutPane`'s decision to fold a
/// whole About experience into one settings pane rather than a separate
/// window. A first-run flow with progress dots and a "Next" button would be
/// more surface than a single-sentence explanation justifies. There is
/// exactly one thing a new user needs told — "that icon is Sentry, and here's
/// how you get to Settings" — so there is exactly one screen.
///
/// **Styling matches `DropdownView`/`AboutPane` exactly**: the same
/// `ThemePalette` (`Sentry/Dropdown/ThemeColor+SwiftUI.swift`) spacing scale
/// (`spacingBlock`/`spacingRow`/`spacingTight`), the same `palette.font`
/// calls in place of literal `Font` values, and `themedBackdrop(_:)` for the
/// same material/opaque-theme-aware background every themed surface in this
/// app wears — nothing here is ad hoc.
struct WelcomeView: View {

    @Environment(\.colorScheme) private var systemColorScheme

    /// The user's active theme, resolved by the caller the same way
    /// `AppDelegate.configurePopover` resolves it for `DropdownView` — this
    /// view has no `SettingsStore` of its own and never should, since its
    /// only job is to render, not to own state.
    let theme: Theme

    /// Closes the popover. Owned by `OnboardingCoordinator`, not this view —
    /// same "UI fires closures, the composition root does the AppKit work"
    /// split `DropdownView` uses for `onOpenSettings`/`onOpenHistory`/`onQuit`.
    let onDismiss: () -> Void

    private var palette: ThemePalette {
        ThemePalette(theme: theme, scheme: systemColorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacingRow) {
            // The pointer: an upward arrow plus the headline it sits next to,
            // reading as one glance-able unit. The popover itself opens
            // anchored directly beneath the status item (see
            // `OnboardingCoordinator.showIfNeeded`), so "up" is already
            // pointing at the right place — no custom arrow graphic needed to
            // say what the system's own anchoring already says geometrically.
            HStack(alignment: .firstTextBaseline, spacing: palette.spacingTight) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.accent)
                Text("Sentry is running")
                    .font(palette.font(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
            }
            .accessibilityElement(children: .combine)

            Text("Look for its icon at the top of your screen, in the menu bar — that's where your Mac's stats live from now on.")
                .font(palette.font(size: 12))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("⌘, or a right-click on the icon opens Settings any time.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Got it", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(palette.spacingBlock)
        .frame(width: 260)
        .themedBackdrop(palette)
        .environment(\.themePalette, palette)
    }
}

// MARK: - Preview

#Preview {
    WelcomeView(theme: .defaultTheme, onDismiss: {})
}
