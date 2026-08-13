import Foundation

/// Every way a theme-editing action can be refused before it starts. One
/// case today; its own type rather than a `Bool` return so the refusal
/// carries its sentence with it — the precedent is `FanControlWriteError`:
/// the UI shows `localizedDescription` verbatim and cannot drift from the
/// reason the gate actually gave.
public enum ThemeEditingError: Error, LocalizedError, Equatable, Sendable {
    /// Creating, editing, importing, or exporting a theme was attempted on
    /// a copy not entitled to `ProFeature.customThemes`. Produced only by
    /// `ThemeEditingGate` — nothing in the model layer (`ThemeDocument`,
    /// `Theme.resolve`, `AppSettings` decoding) ever throws this; see the
    /// gate's doc comment for why those stay entitlement-ignorant.
    case requiresPro

    public var errorDescription: String? {
        switch self {
        case .requiresPro:
            return String(localized: "Saving, importing, and exporting themes are part of Sentry Pro. Themes you already have keep working exactly as they are — they just can't be changed or exported without a license.")
        }
    }
}

/// The logic-layer half of the custom-theme Pro gate
/// (`ProFeature.customThemes`), sitting behind `ThemePane`'s withheld
/// affordances the same way `FanControlService`'s guards sit behind
/// `FanControlPane`'s locked UI: the view never constructs a gated control
/// for a free copy, and the paths such a control would have called refuse
/// anyway (defense in depth).
///
/// **What is gated:** the save commit — every fork, edit, and import lands
/// in `commit(_:into:isProUnlocked:)`, the single path that writes a custom
/// theme into settings — and the `authorize` check `ThemeFileIO` runs
/// before opening an import or export panel.
///
/// **What is deliberately NOT gated, ever — the lapse contract.** A free or
/// lapsed copy keeps everything it already has: `AppSettings.customThemes`
/// decodes untouched, `Theme.resolve` / `SettingsStore.resolvedTheme`
/// resolve a saved custom theme exactly as before — so the active look,
/// including the palette relayed to a paired iPhone or watch
/// (`WatchRelaySnapshot`), never changes underfoot — selecting any theme
/// (built-in or custom, in the pane or the dropdown's quick switcher) stays
/// free, and deleting a custom theme stays free: removal is an escape
/// hatch, per the same rule that keeps
/// `FanControlService.removePrivilegedHelper` un-gated. Gating resolution
/// would repaint a paying user's Mac the day their license lapsed, which is
/// exactly the dark pattern `ProGate`'s doctrine forbids.
///
/// Pure functions of an `isProUnlocked` Bool, like `ProGate.apply`: the
/// composition root's entitlement store stays the only authority, callers
/// pass its answer in, and tests drive the gate with a plain boolean.
public enum ThemeEditingGate {

    /// Throws rather than returning a `Bool` so a call site cannot read the
    /// answer and forget to act on it.
    public static func authorize(isProUnlocked: Bool) throws {
        guard isProUnlocked else { throw ThemeEditingError.requiresPro }
    }

    /// Commits a theme into settings: replace by id if it exists, append if
    /// it doesn't, then select it — someone who just spent time in a color
    /// editor wants to see the result on the app, and a theme must never be
    /// saved into a state the user can't immediately see.
    ///
    /// Refusal happens before the first write, so a locked commit leaves
    /// `settings` untouched — no half-applied save.
    public static func commit(
        _ theme: Theme,
        into settings: inout AppSettings,
        isProUnlocked: Bool
    ) throws {
        try authorize(isProUnlocked: isProUnlocked)
        if let index = settings.customThemes.firstIndex(where: { $0.id == theme.id }) {
            settings.customThemes[index] = theme
        } else {
            settings.customThemes.append(theme)
        }
        settings.themeID = theme.id
    }

    // MARK: - Locked-state copy

    // Kept here rather than in the pane for the `FanWriteAvailability`
    // reason: the sentences shown next to the locked state must not drift
    // from what the gate actually refuses.

    /// A few words for a badge or a footer row.
    public static let lockedShortLabel = String(localized: "Part of Sentry Pro")

    /// The sentence for the compact locked row that stands where the
    /// fork/import buttons would be.
    public static let lockedAffordanceLabel = String(localized: "Duplicating, editing, and importing themes are part of Sentry Pro.")

    /// The lapse sentence, shown only when custom themes already exist —
    /// a user with saved themes needs to hear, explicitly, that they keep
    /// them. Every claim in it is enforced by this gate's "NOT gated" list
    /// above and asserted in `ThemeEditingGateTests`.
    public static let lockedExistingThemesNote = String(localized: "Themes you've already saved keep working: they stay selectable here and in the dropdown, keep rendering everywhere — including on a paired iPhone or Apple Watch — and can still be deleted. They just can't be edited or exported without a license.")
}
