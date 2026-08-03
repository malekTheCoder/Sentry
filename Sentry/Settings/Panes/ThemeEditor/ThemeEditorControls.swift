import SwiftUI
import SentryKit

// MARK: - Section container

/// One titled group inside the theme editor.
///
/// Hand-built rather than `GroupBox` for the same reason `SettingsView`'s
/// shell is hand-built: the editor lives inside a themed window, and
/// `GroupBox` paints its own system chrome that reads as a different app
/// bolted on. Every color here comes from the *active* theme's palette —
/// the editor is app chrome and themes like the rest of it, which is also
/// why nothing in this file names a literal color.
struct ThemeEditorSection<Content: View>: View {

    @Environment(\.themePalette) private var palette

    let title: String
    /// One sentence about what the group does. Always shown — a section of
    /// twelve color wells with no explanation is a section the user has to
    /// experiment on.
    let explanation: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, explanation: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.explanation = explanation
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacingRow) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(palette.font(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                if let explanation {
                    Text(explanation)
                        .font(palette.font(size: 11))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(palette.spacingBlock)
        .background(
            RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                .fill(palette.surface)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

// MARK: - Contrast badge

/// §9.4's inline flag: the WCAG verdict for one color, next to that color's
/// well, updating as the user picks.
///
/// **Never color alone.** §9.4 is explicit that meaning must not be encoded
/// in color, and a red-vs-green pill would do exactly that — so the badge
/// always carries a symbol *and* the ratio as text, and its accessibility
/// label spells out every failing pair in words. The tint is the third
/// signal, not the only one.
///
/// **Under Increase Contrast** the badge switches from a tinted wash to a
/// solid fill with a full-strength border. That's the
/// `NSWorkspace.accessibilityDisplayShouldIncreaseContrast` requirement in
/// §9.4; SwiftUI surfaces the same system setting as
/// `\.colorSchemeContrast == .increased`, which is what this reads so the
/// value arrives through the normal environment invalidation path rather
/// than needing a `KVO` observer on `NSWorkspace`.
struct ContrastBadge: View {

    @Environment(\.themePalette) private var palette
    @Environment(\.colorSchemeContrast) private var contrast

    /// Every finding for one subject, passing and failing alike — the badge
    /// needs the failures to report and the whole set to compute the worst
    /// ratio it shows.
    let findings: [ContrastFinding]

    private var failures: [ContrastFinding] { findings.filter { !$0.passes } }
    private var unreadable: [ContrastFinding] { findings.filter(\.isUnreadable) }

    private var worstRatio: Double? { findings.compactMap(\.ratio).min() }

    private var increaseContrast: Bool { contrast == .increased }

    var body: some View {
        // A token nobody audits (a surface, a hairline) gets no badge at all
        // rather than a green "n/a" — an empty result is not a pass, and
        // printing one would be claiming a check that never ran.
        if findings.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 4) {
                Image(systemName: symbolName)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(palette.numericFont(size: 10, weight: .semibold))
            }
            .foregroundStyle(increaseContrast ? palette.background : tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(increaseContrast ? tint : tint.opacity(0.16))
            )
            .overlay(
                Capsule().strokeBorder(tint, lineWidth: increaseContrast ? 1.5 : 0)
            )
            .help(helpText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    private var tint: Color {
        if !unreadable.isEmpty { return palette.danger }
        return failures.isEmpty ? palette.success : palette.danger
    }

    private var symbolName: String {
        if !unreadable.isEmpty { return "questionmark.circle.fill" }
        return failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var label: String {
        if !unreadable.isEmpty { return String(localized: "Unreadable") }
        guard let worstRatio else { return String(localized: "—") }
        // Same truncating formatter the findings use, so the badge and the
        // tooltip can never disagree about a borderline pair.
        return ThemeContrast.format(worstRatio)
    }

    /// The tooltip lists every failing pair rather than only the worst, so a
    /// token that fails on two surfaces out of three doesn't look like it
    /// fails on one.
    private var helpText: String {
        if failures.isEmpty {
            return String(localized: "Lowest contrast across every surface and both appearances: \(label). Passes.")
        }
        return failures.map(\.summary).joined(separator: "\n")
    }

    private var accessibilityLabel: String {
        failures.isEmpty
            ? String(localized: "Contrast \(label), passes.")
            : String(localized: "Contrast warning. ") + failures.map(\.summary).joined(separator: " ")
    }
}

// MARK: - Color well row

/// One editable color token: a well, its hex, an opacity slider, its inline
/// contrast verdict, and per-token reset.
///
/// **The well edits one appearance at a time.** `ThemeColor` is a light/dark
/// pair and no single macOS color well can express both, so the editor has an
/// appearance switch at the top and this row writes into whichever half is
/// selected. The other half is shown as a small swatch beside it so a user
/// editing the light color can see they've left the dark one behind —
/// silently letting the two drift is how a theme ends up unusable in the
/// appearance its author doesn't run.
struct ThemeColorWellRow: View {

    @Environment(\.themePalette) private var palette

    let title: String
    let subtitle: String?
    let appearance: ThemeAppearance
    @Binding var color: ThemeColor
    /// Findings for this token, already filtered by the caller. Empty for a
    /// token that carries no contrast requirement.
    let findings: [ContrastFinding]
    let resetAvailability: ThemeResetAvailability
    let onReset: () -> Void

    /// The hex the *other* appearance holds, for the companion swatch.
    private var otherAppearance: ThemeAppearance {
        appearance == .light ? .dark : .light
    }

    var body: some View {
        HStack(spacing: palette.spacingRow) {
            well

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(palette.font(size: 12, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                    ContrastBadge(findings: findings)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(palette.font(size: 10))
                        .foregroundStyle(palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: palette.spacingTight)

            hexField
            opacityControl
            resetButton
        }
        .accessibilityElement(children: .contain)
    }

    private var well: some View {
        HStack(spacing: 4) {
            ColorPicker(
                title,
                selection: Binding(
                    get: { color.pickerColor(for: appearance == .dark ? .dark : .light) },
                    set: { newColor in
                        // A color the system can't express in sRGB leaves the
                        // token untouched rather than writing a guess. See
                        // `Color.themeHex()`.
                        guard let hex = newColor.themeHex() else { return }
                        color = color.settingHex(hex, for: appearance)
                    }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
            .accessibilityLabel(String(localized: "\(title), \(appearance.displayName) color"))

            // The companion swatch: read-only on purpose. Making it a second
            // well would double every row's width for a control the
            // appearance switch already provides.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color.pickerColor(for: otherAppearance == .dark ? .dark : .light))
                .frame(width: 10, height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(palette.separator, lineWidth: 1)
                )
                .help(String(localized: "\(otherAppearance.displayName): \(color.hex(for: otherAppearance)). Switch appearance above to edit it."))
                .accessibilityLabel(String(localized: "\(title), \(otherAppearance.displayName) color is \(color.hex(for: otherAppearance))"))
        }
    }

    /// Typing hex directly, because picking `#529CCA` out of a color wheel is
    /// not a thing anyone can do — and because a theme author copying values
    /// from a palette on the web has them as hex already.
    private var hexField: some View {
        TextField(
            String(localized: "Hex"),
            text: Binding(
                get: { color.hex(for: appearance) },
                set: { typed in
                    // Written straight through, valid or not. The model layer
                    // deliberately stores unvalidated strings (see
                    // `ThemeColor.light`), the renderer draws gray for
                    // anything it can't parse, and the contrast badge beside
                    // this field reports "Unreadable" — so a half-typed
                    // "#52" shows as a problem rather than being rejected
                    // keystroke by keystroke, which would make the field
                    // impossible to type into.
                    color = color.settingHex(typed, for: appearance)
                }
            )
        )
        .textFieldStyle(.roundedBorder)
        .font(palette.numericFont(size: 11))
        .frame(width: 88)
        .accessibilityLabel(String(localized: "\(title) hex value"))
    }

    private var opacityControl: some View {
        HStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { color.clampedOpacity },
                    set: { color.opacity = $0 }
                ),
                in: ThemeLimits.opacity
            )
            .frame(width: 70)
            .accessibilityLabel(String(localized: "\(title) opacity"))
            .accessibilityValue(opacityText)

            Text(opacityText)
                .font(palette.numericFont(size: 10))
                .foregroundStyle(palette.textTertiary)
                .frame(width: 32, alignment: .trailing)
        }
    }

    private var opacityText: String {
        "\(Int((color.clampedOpacity * 100).rounded()))%"
    }

    /// §9.3's per-token "Reset to preset". Disabled states print their reason
    /// in the tooltip rather than sitting there inert — this codebase does not
    /// ship a control that silently does nothing.
    private var resetButton: some View {
        Button(action: onReset) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10))
        }
        .buttonStyle(.borderless)
        .disabled(!resetAvailability.canReset)
        .foregroundStyle(resetAvailability.canReset ? palette.accent : palette.textTertiary)
        .help(resetHelp)
        .accessibilityLabel(String(localized: "Reset \(title) to preset"))
        .accessibilityHint(resetAvailability.unavailableReason ?? "")
    }

    private var resetHelp: String {
        if case .available(let presetName) = resetAvailability {
            return String(localized: "Reset \(title) to \(presetName).")
        }
        return resetAvailability.unavailableReason ?? ""
    }
}
