import SwiftUI
import SentryKit

// MARK: - OnboardingView (first-run flow)

/// The one-time flow a fresh install shows before `RootTabView`.
///
/// **The gap this closes.** Before this file existed, a fresh install of
/// this app launched straight into `RootTabView`
/// (`SentryMobile/SentryMobileApp.swift`), waited on
/// `AppDataSource.resolveIfNeeded()` for up to
/// `AppDataSource.discoveryTimeout` seconds, and landed on a Dashboard full
/// of `MockDataSource`'s demo data (its device is literally named "Malek's
/// MacBook Pro") next to an amber "not connected" indicator — with no
/// explanation anywhere prominent that this is a *companion* app: it only
/// shows something real once Sentry is also running on a Mac with Remote or
/// Local Access turned on. That instruction existed, but only as a caption
/// buried mid-`SettingsTabView`'s "REMOTE MAC" card, which a first-run user
/// has no reason to have opened yet.
///
/// **Three screens, not a wizard.** This app's whole tone — `SyncPane`'s
/// blunt admissions, `SettingsTabView`'s honest-disclosure rows, the flat
/// no-shadow-no-glow card chrome — is understated and gets out of the way
/// fast. A multi-step "Welcome to Sentry!" carousel with animated
/// illustrations would be a different app's voice. So this is three short
/// screens, each answerable at a glance: what this app is, what it needs
/// (Sentry running on a Mac too), and how to connect one. `TabView` with
/// `.page` style rather than a hand-rolled state machine, because paging,
/// the dot indicator, and swipe-back are exactly what `.page` already gives
/// for free and this flow has no per-screen logic that would need more.
///
/// **Skip doesn't mean "come back later" — it means "done."** Per the task,
/// Skip sets the same `hasCompletedOnboarding` flag Finish does. This flow
/// exists to orient a user once, not to gate the app behind itself; someone
/// who already knows how Sentry pairs (or is re-installing) shouldn't be
/// nagged on every launch just because they didn't sit through three
/// screens once.
///
/// **Why a closure and not this view owning `@AppStorage` directly.** The
/// flag has to be visible to `SentryMobileApp`'s `fullScreenCover(isPresented:)`
/// binding too, so *something* above this view needs to own it regardless.
/// Rather than two independent `@AppStorage("hasCompletedOnboarding")`
/// properties relying on the string key to stay in sync (the pattern
/// `RootTabView`/`SettingsTabView` already accept for `"selectedThemeID"`,
/// with a doc comment explaining why that duplication is tolerated there),
/// this view takes a plain `onFinish` closure and lets the call site be the
/// single source of truth. No new call site needs the duplication tradeoff
/// when a closure works instead.
struct OnboardingView: View {
    /// Called once, from either the last screen's "Get Started" button or
    /// the "Skip" button in the top-trailing corner. The call site
    /// (`SentryMobileApp`) is responsible for setting the persisted flag and
    /// dismissing the cover — this view only signals "the user is done."
    var onFinish: () -> Void

    @Environment(\.themePalette) private var palette
    @State private var page = 0

    private static let pageCount = 3

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TabView(selection: $page) {
                welcomePage.tag(0)
                connectExplainerPage.tag(1)
                scanToPairPage.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            skipButton
        }
        .themedScreenBackground(palette)
    }

    // MARK: - Skip

    private var skipButton: some View {
        Button("Skip", action: onFinish)
            .scaledFont(palette, size: 13, weight: .medium)
            .foregroundStyle(palette.textSecondary)
            .padding(palette.spacingBlock)
            .accessibilityHint("Closes this introduction. You can always find your Mac's pairing QR code in Sentry's Settings on the Mac.")
    }

    // MARK: - Page 1: what this app is

    /// The one-liner the review flagged as missing from anywhere prominent:
    /// this app is a *readout*, not a second copy of Sentry. The icon pairs
    /// `iphone` with `applewatch` because the Watch relay
    /// (`WatchRelayManager`, started alongside discovery in
    /// `SentryMobileApp`) means the promise is genuinely both surfaces, not
    /// marketing copy for a Watch app that doesn't exist yet.
    private var welcomePage: some View {
        OnboardingPage(
            systemImage: "gauge.with.dots.needle.67percent",
            title: "Your Mac's vitals, on your phone",
            bodyText: "Sentry shows your Mac's CPU, memory, battery, and more — right here, and on your Apple Watch.",
            palette: palette
        )
    }

    // MARK: - Page 2: the piece a first-run user is missing

    /// The core message this whole flow exists to deliver. Deliberately
    /// names both transports this build actually has —
    /// `AppDataSource`/`LocalSyncClient` for same-Wi-Fi discovery, the
    /// "Remote Mac" fields in `SettingsTabView` for off-LAN — rather than
    /// just saying "connect your Mac" with no specifics, which is the exact
    /// vagueness the review's caption already had.
    private var connectExplainerPage: some View {
        OnboardingPage(
            systemImage: "laptopcomputer.and.iphone",
            title: "Connect your Mac",
            bodyText: "This app is a companion — it needs Sentry running on your Mac too. On the Mac, open Sentry's Settings ▸ Sync and turn on Local Access (same Wi-Fi) or Remote Access (anywhere).",
            palette: palette
        )
    }

    // MARK: - Page 3: how pairing actually happens

    /// **Camera app, not an in-app scanner — a deliberate choice, not a
    /// shortcut.** `RemotePairing`'s own doc comment
    /// (`SentryKit/LocalSync/RemotePairing.swift`) already explains why this
    /// codebase picked a `sentry://pair` deep link over an in-app
    /// `AVFoundation` scanner: the system Camera app needs no camera
    /// permission prompt, no capture-session lifecycle, and no scanner UI in
    /// this app at all, and the QR it reads is only ever shown on the user's
    /// own Mac screen inside the trust boundary the pairing code already
    /// protects. This screen's job is narrower than "build a scanner" — it's
    /// making that *existing* mechanism discoverable, since today nothing in
    /// the first-run path points at it. A native in-app scanner remains
    /// future work if it's ever wanted; see this file's own header for why
    /// it wasn't built here.
    private var scanToPairPage: some View {
        OnboardingPage(
            systemImage: "qrcode.viewfinder",
            title: "Scan to pair",
            bodyText: "Sentry's Sync settings on the Mac show a QR code once Local or Remote Access is on. Point your iPhone's Camera app at it, then tap the notification that appears — Sentry fills in the connection for you.",
            palette: palette,
            footer: {
                AnyView(
                    Button(action: onFinish) {
                        Text("Get Started")
                            .scaledFont(palette, size: 14, weight: .semibold)
                            .foregroundStyle(palette.background)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, palette.spacingBlock)
                            .background(palette.accent, in: RoundedRectangle(cornerRadius: palette.cornerRadius * 0.6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, palette.spacingPage)
                    .accessibilityHint("Closes this introduction and opens the app. You can find this Mac's QR code again any time in Sentry's Settings on the Mac.")
                )
            }
        )
    }
}

// MARK: - OnboardingPage

/// One screen's worth of icon + headline + one-liner, laid out identically
/// across all three pages so the flow reads as one coherent thing and not
/// three separately designed screens. `footer` is optional — only the last
/// page needs a button; the first two are swipe/dot-navigated by the
/// enclosing `.page`-style `TabView`.
private struct OnboardingPage: View {
    let systemImage: String
    let title: String
    let bodyText: String
    let palette: ThemePalette
    var footer: (() -> AnyView)?

    var body: some View {
        VStack(spacing: palette.spacingSection) {
            Spacer(minLength: 0)

            Image(systemName: systemImage)
                .scaledSystemFont(size: 56, weight: .light)
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)

            // Combined into one VoiceOver stop (headline + body read
            // together) — but scoped to just this `VStack`, not the whole
            // page, so the footer button below (page 3's "Get Started")
            // keeps its own distinct accessibility element instead of being
            // swallowed into one giant unlabeled page-sized control.
            VStack(spacing: palette.spacingRow) {
                Text(title)
                    .scaledFont(palette, size: 22, weight: .semibold)
                    .foregroundStyle(palette.textPrimary)
                    .multilineTextAlignment(.center)

                Text(bodyText)
                    .scaledFont(palette, size: 14)
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, palette.spacingSection)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            if let footer {
                footer()
            }

            // Reserves room for the page-dot indicator `.page(indexDisplayMode:
            // .always)` draws at the bottom of the enclosing `TabView`, so it
            // doesn't overlap the footer button on the last page or sit flush
            // against the safe area on the first two.
            Color.clear.frame(height: palette.spacingSection)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
