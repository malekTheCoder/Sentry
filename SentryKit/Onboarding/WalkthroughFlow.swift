import Foundation

// MARK: - Walkthrough: the platform-neutral half

/// The ordering, navigation and first-run gating rules shared by the Mac
/// walkthrough (`Sentry/Onboarding/`) and the iPhone one
/// (`SentryMobile/Onboarding/`).
///
/// **Why this lives in `SentryKit` and not twice in the two app targets.**
/// Two apps that both claim to run "the walkthrough" but disagree about what
/// Skip means, or about whether re-running it from Settings re-arms the
/// first-run flag, is exactly the kind of drift this codebase already pays
/// to avoid elsewhere (`MCPToolID.isWrite` is "the one place that
/// distinction is encoded" precisely so `AppSettings.default` and
/// `MCPAccessController` cannot disagree about which tools are writes). The
/// rules below are the same rules on both platforms; encoding them once
/// means a change to "Skip counts as done" is one edit, not two edits and a
/// hope.
///
/// **There is a second, blunter reason, and it is the load-bearing one:
/// testability.** `SentryTests` is a macOS unit-test bundle
/// (`project.yml`'s `SentryTests` target: `platform: macOS`, hosted by the
/// `Sentry` app). It cannot import `SentryMobile` at all. Any iPhone
/// walkthrough logic written inside `SentryMobile/` is, by construction,
/// untestable in this repository — and the task that produced this file
/// asked specifically for tests on step ordering, gating and skip/re-run.
/// Putting the flow model in `SentryKit`, which `SentryTests` already links
/// (77 of its files `@testable import SentryKit`), is what makes the phone's
/// rules testable at all. That argument beats the tidier-sounding
/// "platform UI copy belongs in the platform target," and it is the same
/// trade `SentryKit/Watch/WatchRelayPolicy.swift` already made for the
/// Watch's transmit rules.
///
/// **Rejected: a single shared step list with per-platform filtering.** The
/// two flows genuinely teach different things — the Mac's is about a menu
/// bar item, permissions and an MCP server; the phone's is about being a
/// *readout* of a Mac that must first be found. A merged enum with
/// `#if os(macOS)`-shaped predicates would have made every step's presence
/// a conditional a reader has to evaluate in their head, to save duplicating
/// a state machine that is forty lines long. Two enums, one shared
/// navigator.
///
/// **Rejected: making this an `ObservableObject`.** The Mac presents its
/// walkthrough from an AppKit-owned `NSPopover` and the phone from a
/// SwiftUI `fullScreenCover`; the natural state ownership differs
/// (`@State` in a view vs. a coordinator property). A plain `Equatable`
/// value type is usable from both without either adopting the other's
/// lifetime model — and it means the tests below construct one with `var`
/// and no main-actor hop.

// MARK: - Step role

/// What a step is *for*, as distinct from what it says.
///
/// Views branch on this for chrome (a `.permission` step earns an explicit
/// "you can decide later" line and a decline-shaped secondary button; a
/// `.finish` step gets a Done button instead of Next), and the tests branch
/// on it to assert structural rules that would otherwise only be enforced by
/// somebody remembering — e.g. that a flow never opens by asking for a
/// system permission before it has explained what the app is.
public enum WalkthroughStepRole: String, Equatable, Sendable, CaseIterable {

    /// Pure explanation. Nothing on this step changes any state.
    case teach

    /// This step can cause the operating system to put a permission prompt
    /// in front of the user (notifications, location). Distinguished from
    /// `.setup` because the cost of getting it wrong is different: a denied
    /// system permission is expensive to reverse (it means a trip to System
    /// Settings), so these steps must be skippable and must say so.
    case permission

    /// This step flips a Sentry setting or installs a Sentry component. No
    /// OS prompt, and everything it does is reversible from Settings later.
    case setup

    /// The closing step. Exactly one per flow, and it is last — asserted in
    /// `WalkthroughFlowTests`.
    case finish
}

// MARK: - Step protocol

/// One screen of a walkthrough.
///
/// **Why the copy lives on the model and not in the view.** The alternative
/// — an enum of bare cases with a `switch` in each platform's view
/// producing titles and bodies — was tried on paper and rejected for one
/// concrete reason: it puts the thing most likely to be wrong (a sentence
/// promising a feature the app doesn't have) in the one place the test
/// bundle cannot reach. With the strings on the model, `WalkthroughCopyTests`
/// can assert that every step has a non-empty title and body, that no two
/// steps share an id, and — the check that actually earns its keep — that
/// the copy never contains a fabricated reading. `MCPToolID.displayName`/
/// `toolDescription` and `MetricModule.displayName` set the precedent for
/// user-facing vocabulary living on a `SentryKit` model.
///
/// `AllCases == [Self]` is required so `WalkthroughFlow` can index into
/// `allCases` positionally; every conformer is a plain `CaseIterable` enum,
/// for which that is already true.
public protocol WalkthroughStep: CaseIterable, Hashable, Identifiable, Sendable where AllCases == [Self] {

    /// Stable across renames of the Swift case. Persisted nowhere today, but
    /// it is what an analytics or resume-where-you-left-off feature would
    /// key on, and making it stable now costs nothing.
    var id: String { get }

    /// SF Symbol name. Decorative on every platform — every call site marks
    /// it `accessibilityHidden`, because the title beside it already says
    /// the same thing and a doubled announcement is worse than none.
    var symbolName: String { get }

    /// The one-line headline. Sentence case, no trailing period — matches
    /// every section header in Settings.
    var title: String { get }

    /// One sentence a reader can stop after. This is the part that has to
    /// stand alone: at large Dynamic Type sizes on the phone, `detail` may
    /// be below the fold.
    var summary: String { get }

    /// The teaching paragraph. Concrete and checkable — names the actual
    /// pane, the actual toggle, the actual limitation.
    var detail: String { get }

    var role: WalkthroughStepRole { get }
}

extension WalkthroughStep where Self: RawRepresentable, Self.RawValue == String {
    /// Raw values are chosen to read as stable identifiers rather than as
    /// Swift case names, so renaming a case is a compile-time change and
    /// not a silent identity change.
    public var id: String { rawValue }
}

extension WalkthroughStep {

    /// Position in the flow. `allCases` order *is* the flow order — there is
    /// deliberately no separate `ordered` array to keep in sync with the
    /// declaration order, the same call `MCPToolID.readTools` documents
    /// ("`CaseIterable`'s synthesized order already follows declaration
    /// order above, so this is just documentation of that fact").
    public var indexInFlow: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

// MARK: - Why the walkthrough is on screen

/// How the walkthrough came to be presented. This is not cosmetic: it
/// decides whether the "already seen it" flag gets written, which is the
/// difference between a re-run and a re-arm.
public enum WalkthroughPresentation: String, Equatable, Sendable, CaseIterable {

    /// The app decided, because the user has never seen it.
    case firstRun

    /// The user asked, from Settings. Must not touch the first-run flag:
    /// the flag already says "seen," and a replay that re-wrote it would at
    /// best be a redundant settings write (`SettingsStore` debounces on
    /// `settings != oldValue`, so it would in fact be a no-op) and at worst,
    /// if the write direction were ever inverted by a later edit, would turn
    /// "show me that again" into "nag me at every launch from now on."
    case replay
}

/// How a walkthrough ended.
public enum WalkthroughOutcome: String, Equatable, Sendable, CaseIterable {

    /// The user reached the last step and pressed Done.
    case finished

    /// The user pressed Skip, or closed the window, at any step.
    case skipped
}

// MARK: - Gating

/// The two decisions that keep a first-run flow from either nagging or
/// vanishing. Static, pure, and deliberately trivial to read — every one of
/// these is a one-liner whose *value* is that there is exactly one of it.
public enum WalkthroughGate {

    /// Should the app present the walkthrough unasked at launch?
    ///
    /// Reuses whatever "already seen" flag the platform already had rather
    /// than introducing a parallel one: `AppSettings.hasSeenWelcome` on the
    /// Mac (see that property's doc comment for its own crash-safety
    /// argument) and the `"hasCompletedOnboarding"` `@AppStorage` key on the
    /// phone. Two flags for one question is how a user ends up seeing an
    /// introduction twice.
    public static func shouldPresentOnLaunch(hasCompletedWalkthrough: Bool) -> Bool {
        !hasCompletedWalkthrough
    }

    /// Should presenting the walkthrough immediately write the "seen" flag,
    /// before the user has done anything with it?
    ///
    /// `true` for `.firstRun` — inherited unchanged from
    /// `OnboardingCoordinator`'s existing behaviour and from
    /// `AppSettings.hasSeenWelcome`'s doc comment, which argues it at
    /// length: a crash (or a quit) between "shown" and "dismissed" must not
    /// leave the app believing this is still first run, because the failure
    /// mode of the alternative is an introduction that reappears forever.
    ///
    /// `false` for `.replay`, which by definition happens when the flag is
    /// already set.
    ///
    /// **Note the platform asymmetry this deliberately does not paper
    /// over.** The phone writes its flag on *finish*, not on present, and
    /// cannot do otherwise: `SentryMobileApp` derives the
    /// `fullScreenCover`'s `isPresented` binding from `!hasCompletedOnboarding`,
    /// so writing the flag at present time would dismiss the cover in the
    /// same frame it appeared. Forcing the Mac to match would mean giving up
    /// the crash-safety property above for no gain; forcing the phone to
    /// match would mean replacing a binding that has exactly one source of
    /// truth with a second `@State` flag. The honest answer is that they
    /// differ, and the difference is confined to this one function.
    public static func shouldMarkCompletedOnPresent(_ presentation: WalkthroughPresentation) -> Bool {
        presentation == .firstRun
    }

    /// What the "already seen" flag should read after a walkthrough ends.
    ///
    /// `true` for both outcomes — **Skip means done, not "later."** This
    /// looks like a function that ignores its argument, and that is the
    /// point: the policy is written down and pinned by a test, so a future
    /// change to make Skip re-nag has to be a deliberate edit that breaks a
    /// named assertion rather than an accident of somebody forgetting to
    /// set the flag on one of the two paths. The reasoning is the one
    /// `SentryMobile/Onboarding/OnboardingView.swift` already argued for the
    /// phone's three-screen flow and which this inherits: the walkthrough
    /// exists to orient a user once, not to gate the app behind itself, and
    /// someone re-installing shouldn't be nagged on every launch for not
    /// sitting through it.
    public static func completedFlag(after outcome: WalkthroughOutcome) -> Bool {
        switch outcome {
        case .finished, .skipped: return true
        }
    }
}

// MARK: - Navigation

/// Where the user is in a walkthrough, and the only four things they can do
/// about it.
///
/// **Why a value type with a clamped index and not an optional-returning
/// cursor.** Every mutator clamps rather than failing, and `step` is
/// non-optional. A `next() -> Step?` shape would push a "what do I render
/// when it's nil" branch into both platforms' views for a condition that
/// cannot occur — the Next button is hidden on the last step, and Back on
/// the first. Clamping means a stray keyboard repeat or a double-tap on
/// Next at the end of the flow is a no-op instead of an index-out-of-range
/// crash in front of a first-time user, which is the single worst place in
/// the app to have one.
public struct WalkthroughFlow<Step: WalkthroughStep>: Equatable, Sendable {

    public let presentation: WalkthroughPresentation

    /// Clamped to `0..<stepCount` by every mutator. Exposed read-only so a
    /// view can drive a progress indicator without being able to put it out
    /// of range.
    public private(set) var stepIndex: Int

    /// - Parameter presentation: why the flow is on screen — see
    ///   `WalkthroughGate.shouldMarkCompletedOnPresent`.
    ///
    /// The precondition is deliberate rather than a silent `first` fallback
    /// or an optional `step`. A `WalkthroughStep` conformer with no cases is
    /// a programming error with no sensible runtime behaviour — there is
    /// nothing to show — and trapping at construction points at the empty
    /// enum instead of at whatever renders `flow.step` several frames later.
    /// `WalkthroughStepInventoryTests` covers the real conformers so this
    /// can never fire in shipping code.
    public init(presentation: WalkthroughPresentation = .firstRun) {
        precondition(
            !Step.allCases.isEmpty,
            "A WalkthroughStep conformer must have at least one case; \(Step.self) has none."
        )
        self.presentation = presentation
        self.stepIndex = 0
    }

    public var steps: [Step] { Step.allCases }

    public var stepCount: Int { Step.allCases.count }

    public var step: Step { Step.allCases[stepIndex] }

    /// One-based, for display. `stepIndex` stays zero-based for indexing;
    /// mixing the two conventions in one property is how off-by-ones get
    /// shipped, so they are named apart.
    public var stepNumber: Int { stepIndex + 1 }

    public var isFirst: Bool { stepIndex == 0 }

    public var isLast: Bool { stepIndex == stepCount - 1 }

    /// The VoiceOver announcement for the progress indicator.
    ///
    /// Both platforms draw progress as a row of dots, which is
    /// `.accessibilityHidden` on its own — a dot row read out as eight
    /// unlabeled images is noise. This sentence is what replaces it, and it
    /// is here rather than in either view so the two cannot word it
    /// differently. It is also why the dots are never the *only* indication
    /// of position: the Back/Next buttons' enabled state and this label both
    /// carry it, so nothing depends on seeing which dot is filled.
    public var progressLabel: String {
        String(localized: "Step \(stepNumber) of \(stepCount)")
    }

    /// Moves forward one step. Returns `false` (and changes nothing) when
    /// already on the last step, so a caller that wants to treat "Next on
    /// the last step" as "Done" can, without first re-deriving `isLast`.
    @discardableResult
    public mutating func advance() -> Bool {
        guard stepIndex < stepCount - 1 else { return false }
        stepIndex += 1
        return true
    }

    /// Moves back one step. Returns `false` on the first step.
    @discardableResult
    public mutating func retreat() -> Bool {
        guard stepIndex > 0 else { return false }
        stepIndex -= 1
        return true
    }

    /// Back to the beginning. Used by the Mac's replay path, which reuses a
    /// long-lived coordinator rather than building a fresh flow, so the
    /// index has to be reset explicitly.
    public mutating func restart() {
        stepIndex = 0
    }

    /// Jumps straight to a step. The dot row is tappable on both platforms
    /// (a walkthrough someone can only traverse linearly is a slideshow),
    /// and this is what it calls.
    public mutating func go(to step: Step) {
        stepIndex = step.indexInFlow
    }
}
