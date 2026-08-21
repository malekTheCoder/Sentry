import SwiftUI
import SentryKit

/// The Mac walkthrough's shell: header, step body, progress row, and the
/// Back/Next/Skip controls. The per-step interactive content lives in
/// `WalkthroughStepContent`.
///
/// **Why this replaced `WelcomeView`, whose reasoning was not wrong.** That
/// file argued — correctly, for what it was — that this app's conventions
/// favour understatement, and that a first-run flow with progress dots was
/// more surface than a single "that icon is Sentry" sentence justified. The
/// premise that changed is the second half of its own sentence: "There is
/// exactly one thing a new user needs told." There is not. A new user cannot
/// discover, by clicking around, that the menu bar item is theirs to
/// compose; that the sleep controls exist at all (they live only inside the
/// dropdown, and only when `dropdownShowsKeepAwake` is on); that Insights
/// scores this Mac out of 100; or — the thing no competitor does — that a
/// coding agent can ask this Mac whether it is fit to build on, with a
/// battery floor, a thermal auto-revoke and a kill switch standing behind
/// it. Those are five undiscoverable things, not one, and a single popover
/// sentence cannot carry them.
///
/// **What was kept from `WelcomeView` rather than redesigned.** The
/// anchoring (a popover under the status item, so step 1's "look up there"
/// is made geometrically rather than with an illustration), the palette and
/// spacing tokens, `themedBackdrop`, and the refusal to draw card chrome
/// this app's dropdown does not use.
///
/// **Why the popover is a fixed size.** The steps' content varies from one
/// paragraph to a QR code, and an `NSPopover` that resizes between steps
/// re-anchors and visibly jumps under the menu bar. A fixed frame with the
/// body in a `ScrollView` trades a scroll bar on a couple of steps for a
/// window that stays still, which is the better trade when the thing being
/// explained is *where things are*.
///
/// **Progress is never carried by colour alone.** The dot row is
/// shape-differentiated (the current step's dot is larger and filled, the
/// rest are hairline rings), it is accompanied by a literal "Step 3 of 9"
/// label rendered as text, and each dot is a real button carrying its
/// step's title as its accessibility label plus `.isSelected` when current.
/// Any one of those three would be enough on its own; the codebase's rule
/// (§9.4, quoted in `GeneralPane` and `AlertsPane`) is that colour is
/// never the only channel, and this satisfies it three times over.
struct WalkthroughView: View {

    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Seeded by `OnboardingCoordinator`, then owned here. The coordinator
    /// constructs it (so it can set `.firstRun` vs `.replay`) but does not
    /// track position — nothing outside this view needs to know which step
    /// is showing, and a coordinator that mirrored it would be a second
    /// source of truth for no reader.
    @State private var flow: WalkthroughFlow<MacWalkthroughStep>

    /// Live, not a snapshot: every toggle in `WalkthroughStepContent` writes
    /// through this and several read back from it.
    @ObservedObject private var store: SettingsStore

    /// Resolved once by the coordinator for this presentation. Not re-read
    /// from `store` on every render, because a theme change mid-walkthrough
    /// would restyle a popover the user is reading — and the coordinator
    /// already resolves the *current* theme each time it presents, which is
    /// where that freshness actually matters.
    private let theme: Theme

    /// `nil` is a legitimate configuration — see
    /// `OnboardingCoordinator.showIfNeeded`'s parameter documentation for
    /// what the agent step shows instead when it is absent, and why that is
    /// a stated fallback rather than a disabled button.
    private let endpointPublisher: MCPEndpointPublisher?

    /// `ProFeature.remoteSync`, resolved by the coordinator for this
    /// presentation — same per-presentation freshness as `theme`, and for
    /// the same reason: an entitlement flip mid-walkthrough should not
    /// restyle a popover the user is reading. Read by the `.companion`
    /// step's pairing controls.
    private let isRemoteSyncUnlocked: Bool

    /// Called exactly once, from Skip, from Escape, or from Done on the last
    /// step. The coordinator does the AppKit work and the settings write —
    /// same "UI fires closures, the composition root acts" split
    /// `DropdownView` uses for `onOpenSettings`/`onQuit`.
    private let onFinish: (WalkthroughOutcome) -> Void

    init(
        flow: WalkthroughFlow<MacWalkthroughStep>,
        store: SettingsStore,
        theme: Theme,
        endpointPublisher: MCPEndpointPublisher?,
        isRemoteSyncUnlocked: Bool,
        onFinish: @escaping (WalkthroughOutcome) -> Void
    ) {
        _flow = State(initialValue: flow)
        self.store = store
        self.theme = theme
        self.endpointPublisher = endpointPublisher
        self.isRemoteSyncUnlocked = isRemoteSyncUnlocked
        self.onFinish = onFinish
    }

    private var palette: ThemePalette {
        ThemePalette(theme: theme, scheme: systemColorScheme)
    }

    private var step: MacWalkthroughStep { flow.step }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            separator
            bodyScroll
            separator
            footer
        }
        .frame(width: 400)
        .themedBackdrop(palette)
        .environment(\.themePalette, palette)
        // Its own `NSPopover`, so it inherits nothing from the main window.
        // The walkthrough's step content paints on the backdrop directly.
        .themedToggles(on: .background)
    }

    private var separator: some View {
        Rectangle()
            .fill(palette.separator)
            .frame(height: 1)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: palette.spacingRow) {
            HStack(alignment: .firstTextBaseline, spacing: palette.spacingTight) {
                Image(systemName: step.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    // Decorative: the title beside it says the same thing,
                    // and VoiceOver reading "shield bolt, Coding agents can
                    // ask this Mac how it's doing" is strictly worse than
                    // reading the sentence.
                    .accessibilityHidden(true)

                Text(step.title)
                    .font(palette.font(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }

            Spacer(minLength: palette.spacingTight)

            // Present on every step, including the last — someone who has
            // read enough should never have to page forward to leave.
            // `.cancelAction` binds Escape, which is the only other way out
            // of an `.applicationDefined` popover (see
            // `OnboardingCoordinator.present` for why it is not
            // `.transient`).
            Button("Skip") { onFinish(.skipped) }
                .buttonStyle(.plain)
                .font(palette.font(size: 12))
                .foregroundStyle(palette.textSecondary)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Skip the walkthrough")
                .accessibilityHint("Closes this introduction. Settings, General, Walkthrough runs it again later.")
        }
        .padding(.horizontal, palette.spacingBlock)
        .padding(.vertical, palette.spacingRow)
    }

    // MARK: - Body

    private var bodyScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: palette.spacingRow) {
                Text(step.summary)
                    .font(palette.font(size: 12.5))
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(step.detail)
                    .font(palette.font(size: 11.5))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                WalkthroughStepContent(
                    step: step,
                    store: store,
                    theme: theme,
                    endpointPublisher: endpointPublisher,
                    isRemoteSyncUnlocked: isRemoteSyncUnlocked
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(palette.spacingBlock)
            // Re-identified per step so SwiftUI tears down the previous
            // step's `@State` (the notification-status probe, the QR host
            // selection) instead of carrying it into a step it does not
            // belong to.
            .id(step.id)
        }
        .frame(height: 300)
    }

    // MARK: - Footer

    /// Two rows, not one. Nine dots, a "Step 5 of 9" label and three
    /// buttons do fit across 400pt at the default system font — and stop
    /// fitting the moment a theme picks a wider face or a localisation
    /// lengthens "Back". Stacking removes the competition instead of
    /// budgeting for it, at the cost of about twenty points of height in a
    /// popover that is already a fixed size.
    private var footer: some View {
        VStack(alignment: .leading, spacing: palette.spacingTight) {
            HStack(spacing: palette.spacingRow) {
                dots

                Text(flow.progressLabel)
                    .font(palette.font(size: 10.5))
                    .foregroundStyle(palette.textTertiary)
                    // The dots' textual twin. Kept visible rather than
                    // `.accessibilityHidden` decoration, so position is
                    // legible without distinguishing a filled ring from an
                    // empty one at 8pt.
                    .accessibilityHidden(true)

                Spacer(minLength: 0)
            }

            buttonRow
        }
        .padding(.horizontal, palette.spacingBlock)
        .padding(.vertical, palette.spacingRow)
    }

    private var buttonRow: some View {
        HStack(spacing: palette.spacingRow) {
            Spacer(minLength: 0)

            Button("Back") {
                // `_ =` rather than relying on `@discardableResult`: a
                // single-expression closure implicitly *returns* its
                // expression, which would make `withAnimation`'s `Result`
                // infer as `Bool` inside a `Button` action that must be
                // `Void`. Same on Next below.
                withAnimation(ThemePalette.motion(reduceMotion: reduceMotion)) {
                    _ = flow.retreat()
                }
            }
            .disabled(flow.isFirst)
            .accessibilityLabel("Previous step")

            if flow.isLast {
                Button("Done") { onFinish(.finished) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Next") {
                    withAnimation(ThemePalette.motion(reduceMotion: reduceMotion)) {
                        _ = flow.advance()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Next step")
            }
        }
    }

    /// Tappable, because a walkthrough somebody can only traverse linearly
    /// is a slideshow — a reader who wants the agent step and nothing else
    /// should be able to get there in one click rather than seven.
    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(flow.steps, id: \.id) { candidate in
                let isCurrent = candidate == step
                Button {
                    withAnimation(ThemePalette.motion(reduceMotion: reduceMotion)) {
                        flow.go(to: candidate)
                    }
                } label: {
                    Circle()
                        // Size and fill, not hue: the current dot is bigger
                        // *and* solid, the rest are hairline rings, so the
                        // row still reads in a theme whose accent sits close
                        // to its separator colour.
                        .fill(isCurrent ? palette.accent : Color.clear)
                        .overlay(Circle().strokeBorder(isCurrent ? Color.clear : palette.separator, lineWidth: 1))
                        .frame(width: isCurrent ? 8 : 6, height: isCurrent ? 8 : 6)
                        .frame(width: 12, height: 12)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(candidate.title)
                .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Walkthrough steps")
        .accessibilityValue(flow.progressLabel)
    }
}

// MARK: - Preview

#Preview {
    WalkthroughView(
        flow: WalkthroughFlow<MacWalkthroughStep>(presentation: .replay),
        store: SettingsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("walkthrough-preview-settings.json")),
        theme: .defaultTheme,
        endpointPublisher: nil,
        // Locked — the state every fresh install is in, and the one worth
        // previewing.
        isRemoteSyncUnlocked: false,
        onFinish: { _ in }
    )
}
