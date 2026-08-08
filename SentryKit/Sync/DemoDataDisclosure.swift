import Foundation

// MARK: - DemoDataDisclosure: the one place that decides how loudly the app admits it is faking

/// What the app shows, and says, while it is rendering `MockDataSource`'s
/// fabricated readings instead of a real Mac's.
///
/// **Why this type exists at all.** `SentryMobile` falls back to
/// `MockDataSource` when no Mac answers (`AppDataSource.resolveIfNeeded()` —
/// see that type's doc comment for why that fallback is the honest choice
/// rather than an empty app). The fallback itself is fine. What was not fine
/// is how thinly it was disclosed: the Dashboard carried a 12pt sentence with
/// a 6pt amber dot that scrolled out of view after two finger-flicks, History
/// carried a differently-worded card saying the same thing, and **Alerts and
/// Settings disclosed nothing at all** — a phone screen full of plausible
/// CPU, memory, thermal and battery numbers with no indication anywhere that
/// every one of them was invented. This codebase already treats that as a bug
/// class rather than a cosmetic gap (`SyncPane.swift`'s "confident UI
/// describing a reality that isn't true"; `WidgetSnapshot.sourceIsDemoData`
/// and `WatchRelaySnapshot.sourceIsDemoData`, both of which exist precisely so
/// the flag *travels with the data* to surfaces that have no banner of their
/// own). The phone was the one surface that had the banner and still got it
/// wrong.
///
/// It is also, bluntly, the difference between an App Store approval and a
/// Guideline 2.3 rejection: a reviewer opens this app with no Mac on their
/// network, so fabricated data is the *only* data they will ever see. Either
/// every screenshot they take is self-evidently labelled a sample, or the app
/// looks like it invents system readings.
///
/// **Why the copy lives on this model and not in the view.** Identical
/// argument to `WalkthroughStep`'s (`SentryKit/Onboarding/WalkthroughFlow
/// .swift`), and it is the load-bearing one here too: `SentryTests` is a
/// macOS bundle hosted by the `Sentry` app and **cannot import
/// `SentryMobile`**, so any sentence written inside an iOS view is, by
/// construction, untestable in this repository. The sentence most likely to
/// be wrong — one that quietly stops mentioning that the numbers are fake, or
/// that starts blaming iCloud again (connection-honesty review bug #6, see
/// `HistoryTabView.demoDataBanner`'s old wording) — is exactly the sentence
/// worth pinning with an assertion. `DemoDataDisclosureTests` pins all three.
///
/// **Rejected: a `Bool` and three string literals in `RootTabView`.** That is
/// what the app already had, three times over, in three files, in three
/// different wordings. The whole point of this type is that "is this demo
/// data, and what do we say about it" has one answer.
///
/// **Rejected: putting this on `AppDataSource`.** `AppDataSource` is
/// `@MainActor`, `ObservableObject`, iOS-app-target-only, and owns live
/// network machinery. The *decision* is a pure function of two booleans and
/// belongs somewhere a test can call it without standing up a Bonjour
/// browser. `AppDataSource.isShowingDemoData` remains the app's source of
/// truth for the input; this type is what the input means.
public enum DemoDataDisclosure {

    // MARK: - How loudly

    /// How prominently the disclosure is drawn right now.
    ///
    /// **There is deliberately no `hidden` case reachable while demo data is
    /// on screen.** The user can quiet the banner, and `.marker` is what that
    /// leaves behind — a permanent, still-visible tag pinned in the same
    /// place, not nothing. A dismissal that could reach `.hidden` would mean
    /// a reviewer (or a user) able to put the app into a state where invented
    /// numbers are presented with no disclosure at all, which is the exact
    /// state this type exists to make unrepresentable.
    public enum Prominence: String, Equatable, Sendable, CaseIterable {

        /// Real data from a real Mac. Nothing is shown — see
        /// `prominence(isShowingDemoData:isQuieted:)` on why this must be
        /// immediate and total.
        case hidden

        /// The full banner: headline, cause, and both actions.
        case full

        /// The quieted form: icon plus a short tag, same position, same
        /// warning colour, still un-scrollable. Enough to keep every
        /// screenshot honest; small enough that someone who has read the
        /// banner once is not fighting it.
        case marker

        /// Whether the individual data surfaces (charts, the vitals ledger)
        /// should carry their own inline `SAMPLE` tag.
        ///
        /// True for **both** visible cases, on purpose. Quieting the banner
        /// is a statement about the banner, not a licence to let a chart full
        /// of invented numbers pass as telemetry — and the tags are what
        /// survive a cropped screenshot of a single card, which a banner
        /// never does.
        public var marksIndividualValues: Bool { self != .hidden }
    }

    /// The whole decision, as a function of the two things that can vary.
    ///
    /// - Parameters:
    ///   - isShowingDemoData: `AppDataSource.isShowingDemoData` — literally
    ///     `transport is MockDataSource`, not a proxy for it. The distinction
    ///     matters: `isUsingLocalSync` is false both while a `MockDataSource`
    ///     is on screen *and* for the brief window before discovery has
    ///     resolved, and it stays true across a dropped connection when the
    ///     transport is still the real `LocalSyncClient`. Only "what type is
    ///     actually producing these numbers" answers "are these numbers
    ///     fabricated."
    ///   - isQuieted: whether the user has tapped the banner's quiet control
    ///     *this launch*. See `RootTabView.isDemoBannerQuieted` for why that
    ///     flag is deliberately not persisted.
    ///
    /// The `hidden` branch is the honesty obligation running the other way,
    /// and it is not a lesser one: a stale "this is a sample" banner sitting
    /// over a real Mac's real readings is the same lie inverted, and worse,
    /// because it teaches the user to ignore the banner. Because this is a
    /// pure function of `@Published` state, the disappearance is a SwiftUI
    /// re-render on the frame `transport` changes — not a timer, not an
    /// animation that could be interrupted, not a flag anybody has to
    /// remember to clear.
    public static func prominence(isShowingDemoData: Bool, isQuieted: Bool) -> Prominence {
        guard isShowingDemoData else { return .hidden }
        return isQuieted ? .marker : .full
    }

    // MARK: - What it says

    /// SF Symbol for the banner and the inline tags. Decorative at every call
    /// site (each one is inside a combined accessibility element whose label
    /// already says this in words) — but *present*, because §9.4's standing
    /// rule in this codebase is that state is never carried by hue alone, and
    /// a reviewer skimming a screenshot at thumbnail size is the canonical
    /// glance case. Text, glyph, and the theme's warning colour all carry it.
    ///
    /// `wand.and.stars` rather than a warning triangle on purpose: demo data
    /// is not an error condition, it is a synthesized one. The triangle would
    /// read as "something is broken," which is the misreading the walkthrough
    /// already works to prevent ("Nothing is wrong — there's just nothing to
    /// read yet," `OnboardingView`).
    public static let symbolName = "wand.and.stars"

    /// Line 1 of the required three: **these numbers are a sample, and they
    /// are not from a real Mac.**
    ///
    /// Says both halves rather than picking one. "Sample data" alone invites
    /// "a sample of *my* Mac's data, then"; "not from a real Mac" alone
    /// leaves open that something failed and these are stale real readings.
    public static var headline: String {
        String(localized: "Sample data — not from a real Mac")
    }

    /// Line 2: **why.** Names the actual cause — nothing answered on this
    /// network — because the previous wording on the History tab blamed
    /// iCloud, a transport this build never even attempts, and sent users
    /// looking for a fix in the wrong place entirely (connection-honesty
    /// review, bug #6).
    public static var cause: String {
        String(localized: "No Mac running Sentry was found on this network, so Sentry is showing made-up readings instead.")
    }

    /// Line 3: **what to do about it**, written so that it also answers the
    /// question a first-time reviewer or a curious installer actually has,
    /// which is not "how do I fix this" but "what *is* this app." Sentry on
    /// iPhone is a readout of a Mac; someone who never installs the Mac app
    /// should be able to close the app understanding that, from this sentence
    /// alone.
    public static var remedy: String {
        String(localized: "Sentry for iPhone shows what the Sentry app on your Mac reports. Install it there and keep both on the same Wi-Fi, then try again.")
    }

    /// The quieted banner's tag, and the inline tag on individual charts and
    /// values. Upper case at the call sites; kept sentence-shaped here so a
    /// translation is free to disagree about casing.
    public static var markerLabel: String {
        String(localized: "Sample")
    }

    /// Label for the control that quiets the full banner down to `.marker`.
    /// Says what it does — not "Dismiss," "Close," or an unlabelled ✕, all of
    /// which promise a disappearance this deliberately does not offer.
    public static var quietActionLabel: String {
        String(localized: "Quiet")
    }

    /// Label for the retry action. Same verb the Dashboard's connection line
    /// and the walkthrough's connection card already use for the identical
    /// `AppDataSource.retryConnection()` call.
    public static var retryActionLabel: String {
        String(localized: "Try again")
    }

    /// Label for the action that opens the walkthrough, whose pairing step
    /// carries the live connection card and the QR-pairing explanation.
    public static var setUpActionLabel: String {
        String(localized: "How to connect")
    }

    // MARK: - VoiceOver

    /// The single announcement for the banner, in both prominences.
    ///
    /// Built here rather than left to SwiftUI's `children: .combine` for two
    /// reasons. First, the quieted marker shows one word on screen but must
    /// still *say* all three things — a VoiceOver user who quiets the banner
    /// has not thereby agreed to be told less than a sighted one. Second, the
    /// banner is the highest-priority element on every screen in this app
    /// while it is up, and the sentence a screen reader reads first should be
    /// composed deliberately, not assembled from whatever child views happen
    /// to be laid out at the time.
    public static func accessibilityLabel(for prominence: Prominence) -> String {
        switch prominence {
        case .hidden:
            return ""
        case .full, .marker:
            return "\(headline). \(cause) \(remedy)"
        }
    }
}
