import SwiftUI
import SentryKit

// MARK: - OnboardingView (first-run walkthrough)

/// The walkthrough a fresh install shows before `RootTabView`, and the same
/// one Settings ▸ Walkthrough re-runs later.
///
/// **What this replaced, and why the replacement is longer rather than
/// shorter.** The previous version of this file was a three-page
/// `.page`-style `TabView` whose own doc comment argued at length for
/// brevity: "this app's whole tone… is understated and gets out of the way
/// fast," so three screens, "each answerable at a glance." That argument was
/// right about *tone* and wrong about *coverage*, and it is worth being
/// precise about which half changed. Three screens covered what the app is,
/// that it needs a Mac, and that a QR code exists. They did not cover: that
/// the Dashboard's sleep card sends real commands the Mac really answers;
/// that History and Alerts are as deep as the Mac's own records and will
/// have more tomorrow; that the Watch app exists at all; or that the Mac
/// this app talks to can hand a read-only view of itself to coding agents
/// behind a battery floor and a kill switch. Those are the things a user
/// cannot find by tapping around, which is the only test that matters for
/// what belongs in a first run. Seven short steps, still no illustrations,
/// still no exclamation marks.
///
/// **Two factual corrections carried in the copy**, both inherited bugs
/// rather than new prose (see `WalkthroughSteps.swift`'s header for the full
/// list): the old page 2 told users to "turn on Local Access (same Wi-Fi)"
/// on the Mac, and there is no such toggle — local sync runs unconditionally
/// and the Mac's only sync switch is Remote Access; and page 3 said the QR
/// appears "once Local or Remote Access is on," when in fact it renders only
/// when Remote Access is.
///
/// **Why a hand-driven `WalkthroughFlow` and not `.page`-style `TabView`
/// again.** The old flow had no per-screen logic, so paging for free was the
/// right call. This one does: step 2 talks to `AppDataSource` and reports a
/// live connection state, and the step list, ordering and skip semantics are
/// now shared with the Mac through `SentryKit`'s `WalkthroughFlow` — which
/// is what makes any of it testable from `SentryTests` (a macOS bundle that
/// cannot import this target at all; see that type's doc comment). A
/// `TabView` would have kept its own parallel notion of "which page," and
/// two sources of truth for the current step is precisely the drift the
/// shared model exists to prevent.
///
/// **Skip still means done, not "later."** Unchanged in effect from the
/// previous version, but the policy now lives in
/// `WalkthroughGate.completedFlag(after:)` and is pinned by a test rather
/// than implied by two call sites that happen to agree.
struct OnboardingView: View {

    /// Called exactly once, from Skip or from Done on the last step. The
    /// call site (`SentryMobileApp`) owns the persisted flag and the
    /// dismissal — this view only reports *how* the user left, and lets
    /// `WalkthroughGate` decide what that means. Taking the outcome rather
    /// than nothing is what lets the phone and the Mac share one written-down
    /// answer to "does Skip count?"
    var onFinish: (WalkthroughOutcome) -> Void

    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var flow = WalkthroughFlow<PhoneWalkthroughStep>()

    /// Bumped by Skip and by Get Started, purely as a haptic trigger.
    ///
    /// **Why the two ways out share one counter, and why they need one at
    /// all.** They share it because they mean the same thing — the
    /// walkthrough is over — and this app's rule is that two controls
    /// meaning the same thing feel the same; `WalkthroughGate.completedFlag
    /// (after:)` already encodes that they agree, and giving Skip its own
    /// flavour would contradict it by feel. They need a counter because the
    /// state that records the outcome (`hasCompletedOnboarding`) belongs to
    /// `SentryMobileApp`, one hierarchy up and behind a `.fullScreenCover`
    /// — this view reports *how* the user left and owns nothing that
    /// changes when they do.
    @State private var finishTaps = 0

    private var step: PhoneWalkthroughStep { flow.step }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedScreenBackground(palette)
        // Next, Back, and the dot row all do one thing — move between the
        // seven steps — so they share `.selection`, the same case the tab bar
        // and every picker in the app use. One modifier on the flow's current
        // step rather than three on three buttons is what guarantees that:
        // it cannot fire twice for one move, and tapping the dot for the step
        // you are already on changes nothing and so produces nothing.
        //
        // Next is a big accent-filled primary button and a dot is 7pt of
        // outline, and they still feel identical, because the rule is what
        // happened rather than what was pressed.
        .haptic(.selection, on: step)
        // Leaving the walkthrough is `.tap` — dismissing something, which is
        // what that case is for. Not `.confirmed`: nothing was sent anywhere
        // and nothing agreed.
        .haptic(.tap, onTapOf: finishTaps)
    }

    // MARK: - Skip

    private var topBar: some View {
        HStack {
            Spacer(minLength: 0)
            Button("Skip") {
                finishTaps += 1
                onFinish(.skipped)
            }
                .scaledFont(palette, size: 13, weight: .medium)
                .foregroundStyle(palette.textSecondary)
                .accessibilityLabel("Skip the walkthrough")
                .accessibilityHint("Closes this introduction. Settings, Walkthrough runs it again later.")
        }
        .padding(.horizontal, palette.spacingPage)
        .padding(.top, palette.spacingBlock)
    }

    // MARK: - Body

    /// A `ScrollView` unconditionally, not only at accessibility sizes: this
    /// flow's longest step is four sentences plus a live status card, which
    /// already overflows a small phone at the *default* text size once the
    /// footer is accounted for. A layout that only scrolls when it has to is
    /// a layout that silently truncates on the devices nobody tested.
    ///
    /// **The `GeometryReader` is what keeps the short steps from looking
    /// broken.** A plain `ScrollView` pins its content to the top, so a
    /// three-sentence step renders as a paragraph clinging to the status bar
    /// above half a screen of nothing. Giving the content a `minHeight` of
    /// the viewport and centring within it means short steps sit in the
    /// middle of the screen and long ones scroll from the top — the same
    /// behaviour the previous `.page`-style `TabView` got for free from its
    /// leading and trailing `Spacer(minLength: 0)`, which do not work inside
    /// a scroll view because there is no bounded height for them to divide.
    private var content: some View {
        GeometryReader { proxy in
            scrollBody(viewportHeight: proxy.size.height)
        }
    }

    private func scrollBody(viewportHeight: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: palette.spacingSection) {
                Image(systemName: step.symbolName)
                    .scaledSystemFont(size: 52, weight: .light)
                    .foregroundStyle(palette.accent)
                    // Decorative — the title says the same thing, and the
                    // doubled announcement is worse than none.
                    .accessibilityHidden(true)

                VStack(spacing: palette.spacingRow) {
                    Text(step.title)
                        .scaledFont(palette, size: 22, weight: .semibold)
                        .foregroundStyle(palette.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(step.summary)
                        .scaledFont(palette, size: 14)
                        .foregroundStyle(palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Headline and its one-liner read as a single VoiceOver
                // stop; `detail` below stays separate so a user can skip
                // past the elaboration without skipping the point.
                .accessibilityElement(children: .combine)

                Text(step.detail)
                    .scaledFont(palette, size: 12.5)
                    .foregroundStyle(palette.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                OnboardingStepContent(step: step)
            }
            .padding(.horizontal, palette.spacingPage)
            .padding(.vertical, palette.spacingSection)
            .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .center)
            // Re-identified per step so the connection card's `@State`
            // (its in-flight flag, its last result) is torn down with the
            // step it belongs to rather than leaking into the next one.
            .id(step.id)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: palette.spacingRow) {
            HStack(spacing: palette.spacingTight) {
                dots
                Spacer(minLength: palette.spacingTight)
                Text(flow.progressLabel)
                    .scaledFont(palette, size: 11)
                    .foregroundStyle(palette.textTertiary)
                    // The dot row's textual twin, kept visible so position
                    // never depends on telling a filled dot from a ring.
                    // Hidden from VoiceOver because `dots` already carries
                    // the same sentence as its accessibility value.
                    .accessibilityHidden(true)
            }

            // Vertical at accessibility sizes: two side-by-side buttons at
            // 300% text either truncate their labels or squeeze the primary
            // action to a stub. Same reasoning, same helper, as
            // `AdaptiveRow` elsewhere in this target.
            AdaptiveStack(spacing: palette.spacingRow) {
                if !flow.isFirst {
                    Button {
                        withAnimation(ThemePalette.motion(reduceMotion: reduceMotion)) {
                            _ = flow.retreat()
                        }
                    } label: {
                        Text("Back")
                            .scaledFont(palette, size: 14, weight: .medium)
                            .foregroundStyle(palette.textSecondary)
                            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
                            .padding(.vertical, palette.spacingBlock)
                            .padding(.horizontal, palette.spacingSection)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Previous step")
                }

                Button {
                    if flow.isLast {
                        finishTaps += 1
                        onFinish(.finished)
                    } else {
                        withAnimation(ThemePalette.motion(reduceMotion: reduceMotion)) {
                            _ = flow.advance()
                        }
                    }
                } label: {
                    Text(flow.isLast ? "Get Started" : "Next")
                        .scaledFont(palette, size: 14, weight: .semibold)
                        .foregroundStyle(palette.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, palette.spacingBlock)
                        .background(
                            palette.accent,
                            in: RoundedRectangle(cornerRadius: palette.cornerRadius * 0.6, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(flow.isLast ? "Get started" : "Next step")
            }
        }
        .padding(.horizontal, palette.spacingPage)
        .padding(.bottom, palette.spacingSection)
    }

    /// Tappable, and shape-differentiated rather than colour-differentiated:
    /// the current step's dot is larger and filled, the rest are hairline
    /// rings. Position is additionally carried by the visible "Step 3 of 7"
    /// label and by this row's accessibility value, so no single channel —
    /// least of all hue — is load-bearing.
    private var dots: some View {
        HStack(spacing: 0) {
            ForEach(flow.steps, id: \.id) { candidate in
                let isCurrent = candidate == step
                Button {
                    withAnimation(ThemePalette.motion(reduceMotion: reduceMotion)) {
                        flow.go(to: candidate)
                    }
                } label: {
                    Circle()
                        .fill(isCurrent ? palette.accent : Color.clear)
                        .overlay(
                            Circle().strokeBorder(isCurrent ? Color.clear : palette.separator, lineWidth: 1)
                        )
                        .frame(width: isCurrent ? 9 : 7, height: isCurrent ? 9 : 7)
                        // Padded out to a 26 × 34pt hit box rather than the
                        // 44pt HIG minimum, and that is a considered
                        // exception rather than an oversight: seven 44pt
                        // targets are 308pt, which does not fit beside the
                        // "Step 3 of 7" label on a 320pt-wide phone. These
                        // dots are a shortcut, not the navigation — Back and
                        // the primary button below are full-height controls
                        // that reach every step on their own — so trading
                        // width here costs a user nothing they cannot do
                        // another way.
                        .frame(width: 26, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(candidate.title)
                .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
            }
        }
        // Cancels half a hit box at each end so the row still *looks* like a
        // tight run of dots flush with the leading margin.
        .padding(.horizontal, -9)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Walkthrough steps")
        .accessibilityValue(flow.progressLabel)
    }
}

// MARK: - Per-step content

/// The steps that show something beyond words.
///
/// Only two do, and the restraint is deliberate: this app's onboarding has
/// nothing it can legitimately demonstrate offline. There is no fabricated
/// dashboard preview here and no sample chart, because a first-run user has
/// no way to tell a mock reading from their own Mac's, and this app's
/// standing problem is precisely that it shows demo data before a Mac is
/// connected (`AppDataSource.transport` starts as a `MockDataSource`). An
/// onboarding that opened with more of the same would be reinforcing the
/// confusion it exists to clear up.
private struct OnboardingStepContent: View {

    let step: PhoneWalkthroughStep

    @Environment(\.themePalette) private var palette

    var body: some View {
        switch step {
        case .pairing:
            ConnectionStatusCard()
        case .tabs:
            tabLegend
        case .companionRole, .controls, .agents, .watch, .done:
            EmptyView()
        }
    }

    /// The four tabs, named with the same symbols `RootTabView` puts in the
    /// tab bar — so the step is a legend for a bar the user is about to see
    /// rather than a re-description of it in different icons.
    private var tabLegend: some View {
        VStack(alignment: .leading, spacing: palette.spacingRow) {
            legendRow("gauge.with.dots.needle.50percent", "Dashboard", "Right now: battery, CPU, memory, temperature, and the sleep card.")
            legendRow("chart.xyaxis.line", "History", "The same readings over hours and days, as far back as your Mac has recorded.")
            legendRow("bell.badge", "Alerts", "What your Mac's alert rules have fired, and when.")
            legendRow("gearshape", "Settings", "The connection to your Mac, the theme, and this walkthrough.")
        }
        .padding(palette.spacingBlock)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(palette)
    }

    private func legendRow(_ symbol: String, _ name: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: palette.spacingRow) {
            Image(systemName: symbol)
                .scaledSystemFont(size: 15)
                .foregroundStyle(palette.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .scaledFont(palette, size: 13, weight: .medium)
                    .foregroundStyle(palette.textPrimary)
                Text(detail)
                    .scaledFont(palette, size: 11.5)
                    .foregroundStyle(palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Live connection state

/// The one genuinely interactive thing in the phone's walkthrough: what this
/// app's connection to a Mac is doing *right now*, and a button that retries
/// it.
///
/// **Why this belongs in onboarding at all.** The single most likely
/// first-run outcome for this app is a user who installs it, sees demo data,
/// and concludes it is broken. Naming that in prose (step 1 does) helps;
/// showing the actual state on the step that explains pairing, with the same
/// `retryConnection()` the Dashboard's banner and the foreground-resume path
/// already call, is what turns "it says it needs a Mac" into "it can see my
/// Mac" while the user is still reading.
///
/// **It never claims a connection it doesn't have.** The three states are
/// distinct on purpose — searching, connected, and not-found are three
/// different sentences, never collapsed into an optimistic one — matching
/// `SleepStatusCard`'s rule for its own command feedback ("a send failure, a
/// silent Mac, and a Mac that actively declined are three distinct messages,
/// never collapsed into one optimistic 'Done'").
private struct ConnectionStatusCard: View {

    @Environment(\.themePalette) private var palette

    /// The process-wide instance, read directly rather than through
    /// `@EnvironmentObject`: this view is presented inside a
    /// `.fullScreenCover`, which starts a separate view hierarchy — the same
    /// reason `SentryMobileApp` re-injects `\.themePalette` into the cover
    /// by hand instead of relying on inheritance. `AppDataSource`'s own doc
    /// comment establishes that reading the singleton is the supported path
    /// for callers with no environment.
    @ObservedObject private var dataSource = AppDataSource.shared

    @State private var isRetrying = false

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacingRow) {
            HStack(alignment: .firstTextBaseline, spacing: palette.spacingRow) {
                // §9.4's rule as this codebase applies it everywhere: the
                // glyph and the sentence each carry the state, so nothing
                // depends on distinguishing green from amber.
                Image(systemName: symbolName)
                    .scaledSystemFont(size: 15)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .scaledFont(palette, size: 13, weight: .medium)
                        .foregroundStyle(palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .scaledFont(palette, size: 11.5)
                        .foregroundStyle(palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            Button {
                retry()
            } label: {
                HStack(spacing: palette.spacingTight) {
                    if isRetrying {
                        ProgressView().controlSize(.small)
                    }
                    Text(isRetrying ? "Looking…" : "Look for my Mac now")
                        .scaledFont(palette, size: 12.5, weight: .medium)
                        .foregroundStyle(palette.accent)
                }
            }
            .buttonStyle(.plain)
            .disabled(isRetrying)
            .accessibilityLabel("Look for my Mac now")
            .accessibilityHint("Searches this Wi-Fi network, then tries any saved remote Mac.")
        }
        .padding(palette.spacingBlock)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(palette)
        // The same `.tap` the Dashboard's Retry gets, because it is the same
        // action — `retryConnection()`, reached from a second place. Keyed
        // off `isRetrying` turning `true`, which happens synchronously in
        // the button's action, rather than off the search's outcome: a
        // connection that comes up (or doesn't) seconds later is not
        // something to buzz about, for the reason `DashboardTabView
        // .retryTaps` sets out at length. The `when:` clause is what keeps
        // the search's *end* silent.
        .haptic(.tap, on: isRetrying) { $0 }
    }

    private var isConnected: Bool {
        dataSource.isUsingLocalSync && dataSource.isLocalSyncConnected
    }

    private var headline: String {
        if isConnected {
            return String(localized: "Connected to your Mac")
        }
        return String(localized: "No Mac connected yet")
    }

    private var detail: String {
        if isConnected {
            if let identity = dataSource.connectedMacIdentity {
                return String(localized: "\(identity) — everything you see from here is real.")
            }
            return String(localized: "Everything you see from here is real.")
        }
        // Deliberately the *same* two sentences `SettingsTabView`'s
        // `remoteConnectFailureMessage(for:)` shows for these cases, not a
        // softened onboarding-flavoured paraphrase. A user who reads one
        // wording here and a different one in Settings ten seconds later has
        // to work out whether they are two problems.
        if let reason = dataSource.remoteConnectFailureReason {
            switch reason {
            case .wrongPairingCode:
                return String(localized: "Wrong code? The Mac rejected the saved pairing code — check it against Settings ▸ Sync ▸ Remote Access on the Mac.")
            case .unreachable:
                return String(localized: "Mac not responding — check it's awake and on the network. The saved address or port may also be wrong.")
            }
        }
        // Split rather than "Mac(s)": this app writes real sentences
        // everywhere else, and a parenthesised plural in the one screen a
        // user reads before deciding whether to keep the app is a poor first
        // impression. Two cases is the whole cost.
        switch dataSource.discoveredMacs.count {
        case 0:
            break
        case 1:
            return String(localized: "A Mac running Sentry is visible on this network but isn't connected yet.")
        default:
            let count = dataSource.discoveredMacs.count
            return String(localized: "\(count) Macs running Sentry are visible on this network. Settings can pick which one.")
        }
        return String(localized: "Until one is, the app shows demo readings. Nothing is wrong — there's just nothing to read yet.")
    }

    private var symbolName: String {
        isConnected ? "laptopcomputer.and.iphone" : "questionmark.circle"
    }

    private var tint: Color {
        isConnected ? palette.success : palette.textTertiary
    }

    private func retry() {
        isRetrying = true
        Task {
            await dataSource.retryConnection()
            isRetrying = false
        }
    }
}
