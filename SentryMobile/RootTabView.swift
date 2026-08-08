import SwiftUI
import UIKit
import SentryKit

/// The iPhone app's top-level navigation shell (plan §12.1's exact tab
/// order: Dashboard, History, Alerts, Settings). A plain `TabView` — the
/// plan's structure doesn't call for anything more elaborate (no nested
/// `NavigationStack` requirements specified per tab yet), and each tab view
/// owns whatever navigation it needs internally once its real content
/// lands.
///
/// **Theme propagation (plan §12.1's "Theme (shares Theme tokens with the
/// Mac app)," built out by the Settings tab).** Before the Settings tab
/// existed, `DashboardTabView` computed its own `ThemePalette` locally and
/// hardcoded `.terminal` — its own doc comment said outright "No theme
/// picker exists yet on this platform." Now that one does, the selection
/// has to reach every tab, not just Dashboard, so it's read and resolved
/// once here, at the one view that is an ancestor of all four tabs, and
/// pushed down via `.environment(\.themePalette:)`. `PlaceholderCard`
/// (`Dashboard/DashboardTabView.swift`) already reads `\.themePalette` from
/// the environment rather than being passed one explicitly, so this is
/// exactly the mechanism the codebase already expected a theme source to
/// use — it just had nothing upstream setting it to anything but the
/// environment's default (`Theme.terminal`, dark) before now.
///
/// **Why the `@AppStorage` key is duplicated here and in
/// `Settings/SettingsTabView.swift` rather than sharing a constant.** Both
/// need to read/write the exact same `UserDefaults` key (`"selectedThemeID"`)
/// for `@AppStorage` to keep them in sync — SwiftUI's `@AppStorage`
/// resolves by string key against the default suite, not by any shared
/// Swift symbol. A shared constant would be the cleaner fix, but every
/// existing candidate file for it (`Theme/ThemeColor+SwiftUI.swift`,
/// `SentryKit`) sits outside this task's `SentryMobile/Settings/` +
/// `RootTabView.swift`/`SentryMobileApp.swift` boundary with three other
/// agents concurrently building neighboring tabs — introducing a new shared
/// symbol elsewhere is a bigger footprint than this task's theme-plumbing
/// mandate calls for. The literal must simply match in both places; if it
/// ever drifts, the fix is one file, not an architectural one.
///
/// **The demo-data disclosure lives here for the same reason the theme
/// does: this is the one view that is an ancestor of all four tabs.** See
/// `Disclosure/DemoDataBanner.swift` for the full argument, and
/// `SentryKit`'s `DemoDataDisclosure` for the decision and the wording. The
/// short version: the app used to disclose fabricated readings in two tabs,
/// in two different wordings, in two scrollable positions, and not at all in
/// the other two. Mounting it as a `.safeAreaInset(edge: .top)` on the
/// `TabView` makes it un-scrollable, present on every tab including any tab
/// added later, and impossible to word two ways.
struct RootTabView: View {
    /// Persisted locally on this phone only — see `SettingsTabView`'s theme
    /// section doc comment for why this is deliberately not synced to the
    /// Mac (no sync channel exists to carry it). Defaults to One Dark, the
    /// direction the Mac app converged on.
    @AppStorage("selectedThemeID") private var selectedThemeID: String = Theme.oneDark.id

    /// The phone's Celsius/Fahrenheit display preference, read here for the
    /// same reason `selectedThemeID` is: this is the one view that is an
    /// ancestor of all four tabs, so it is where a per-app display choice
    /// gets applied once instead of in each tab.
    ///
    /// The key string is duplicated from `Settings/SettingsTabView.swift`
    /// rather than shared through a constant — see this view's doc comment
    /// above for why that duplication is the accepted arrangement here
    /// (`@AppStorage` resolves by string key against the default suite, not
    /// by a Swift symbol) and what to do if it ever drifts.
    ///
    /// Unlike the theme, this is not pushed down through the SwiftUI
    /// environment: the code that formats a temperature is
    /// `SentryKit.MetricFormatter`, a static function reached from view
    /// bodies, view models, and an App Intent alike, none of which share an
    /// environment. It is published into `TemperatureUnit.display` instead
    /// — see `publishTemperatureUnit()` below, and `TemperatureUnit
    /// .display`'s own doc comment for why that value is ambient at all.
    @AppStorage("temperatureUnit") private var temperatureUnitRaw: String = TemperatureUnit.celsius.rawValue

    @Environment(\.colorScheme) private var systemColorScheme

    /// The live data-source state the disclosure keys off. `@EnvironmentObject`
    /// rather than `AppDataSource.shared` read directly, because this view
    /// has to *re-render* when `transport` swaps from `MockDataSource` to a
    /// real `LocalSyncClient` — the banner disappearing on that exact frame
    /// is the honesty obligation running the other way (see
    /// `DemoDataDisclosure.prominence(isShowingDemoData:isQuieted:)`), and a
    /// plain singleton read would not observe it.
    @EnvironmentObject private var appDataSource: AppDataSource

    /// Whether the user has quieted the banner down to its permanent marker.
    ///
    /// **Deliberately `@State`, not `@AppStorage`.** Every other one-time
    /// flag in this target is persisted (`hasCompletedOnboarding`,
    /// `selectedThemeID`, `remoteSync.*`) and this one is the exception on
    /// purpose: a quieted-forever disclosure is how an app ends up shipping
    /// fabricated readings with nothing on screen admitting it, one launch
    /// after the user tapped a control they have long since forgotten. Plain
    /// view state means the full banner returns on the next launch, without
    /// needing any code to remember to reset anything. Quieting still leaves
    /// `.marker` behind within the session — `DemoDataDisclosure.Prominence`
    /// has no reachable `hidden` case while demo data is on screen, so there
    /// is no state in which the app is silently faking.
    @State private var isDemoBannerQuieted = false

    /// Written by the banner's "How to connect" action. Re-arms the *existing*
    /// `fullScreenCover` in `SentryMobileApp` rather than presenting a second
    /// copy of `OnboardingView` from here — the same mechanism, and the same
    /// reasoning, as `SettingsTabView.walkthroughRow` (see its doc comment on
    /// why there is exactly one presentation of that flow). The walkthrough's
    /// pairing step carries `ConnectionStatusCard`, which is the closest thing
    /// this app has to a pairing/setup flow.
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var demoProminence: DemoDataDisclosure.Prominence {
        DemoDataDisclosure.prominence(
            isShowingDemoData: appDataSource.isShowingDemoData,
            isQuieted: isDemoBannerQuieted
        )
    }

    private var palette: ThemePalette {
        let theme = Theme.builtInPresets.first { $0.id == selectedThemeID } ?? .defaultTheme
        return ThemePalette(theme: theme, scheme: systemColorScheme)
    }

    var body: some View {
        // **A `VStack` above the `TabView`, not `.safeAreaInset(edge: .top)`
        // on it.** The inset version was written first, on the reasoning that
        // it would both pin the banner and tell each tab's `ScrollView` to
        // inset its content. Only the first half turned out to be true: run
        // in the Simulator, the banner pinned correctly but every tab's
        // scroll view kept its full height, so the Dashboard's "Mac" title
        // and connection line sat permanently underneath the banner with no
        // amount of scrolling able to bring them out — a `TabView` does not
        // propagate its own reduced safe area into the tab content. Splitting
        // the screen physically shrinks the `TabView` instead, which no
        // amount of SwiftUI safe-area subtlety can get wrong: the tabs simply
        // have less room. Verified by eye on all four tabs.
        //
        // `spacing: 0` because the banner brings its own padding and its own
        // hairline; a system gap would leave a stripe of window background
        // between the disclosure and the content it is about.
        VStack(spacing: 0) {
            DemoDataBanner(
                prominence: demoProminence,
                onQuiet: { isDemoBannerQuieted = true },
                onExpand: { isDemoBannerQuieted = false },
                onRetry: { Task { await appDataSource.retryConnection() } },
                onSetUp: { hasCompletedOnboarding = false }
            )
            .environment(\.themePalette, palette)
            // The most important thing on the screen, so it is announced
            // first regardless of where it sits in the layout tree. Higher
            // sort priority is traversed earlier; nothing else in this app
            // sets one, so any positive value wins.
            .accessibilitySortPriority(100)

            TabView {
                DashboardTabView()
                    .tabItem { Label("Dashboard", systemImage: "gauge.with.dots.needle.50percent") }

                HistoryTabView()
                    .tabItem { Label("History", systemImage: "chart.xyaxis.line") }

                AlertsTabView()
                    .tabItem { Label("Alerts", systemImage: "bell.badge") }

                SettingsTabView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
        }
        // The strip behind the status bar. Without this the split above
        // leaves the window's own background showing there, which reads as a
        // white (or black) notch bar sitting on top of a themed app.
        .background(palette.background.ignoresSafeArea())
        .animation(ThemePalette.motion(reduceMotion: reduceMotion), value: demoProminence)
        .tint(palette.textPrimary)
        .environment(\.themePalette, palette)
        .onAppear {
            applyTabBarChrome()
            publishAppearanceForWatch()
            publishTemperatureUnit()
        }
        .onChange(of: selectedThemeID) { applyTabBarChrome() }
        // `@AppStorage` re-renders this view when the key changes — which
        // is what makes the Settings tab's picker take effect immediately
        // across every tab, since the tabs re-read their formatted strings
        // on the same update. Without this line the ambient value would only
        // catch up on the next launch.
        .onChange(of: temperatureUnitRaw) { publishTemperatureUnit() }
        .onChange(of: systemColorScheme) {
            applyTabBarChrome()
            publishAppearanceForWatch()
        }
    }

    /// Records which half of the theme's light/dark pair this phone is
    /// currently rendering, so `WatchRelayManager` can put it on the wire
    /// (`WatchRelaySnapshot.themeAppearance`) and the watch can render the
    /// same one.
    ///
    /// **Why `UserDefaults` rather than passing the value to the relay
    /// manager directly.** `WatchRelayManager` is an actor with no SwiftUI
    /// environment to read from — it already reaches for `selectedThemeID`
    /// through exactly this mechanism, and that key is written by
    /// `@AppStorage` from this same view. This mirrors it rather than
    /// inventing a second, differently-shaped channel for the other half of
    /// the same fact.
    ///
    /// Written here rather than computed in the relay manager because
    /// `colorScheme` is a SwiftUI environment value: the equivalent UIKit
    /// read (`UITraitCollection.current`) is only valid on the main thread
    /// during a view update, which is precisely where this already is and
    /// precisely where the actor is not.
    /// Publishes the stored preference into `TemperatureUnit.display`, the
    /// process-wide value `SentryKit.MetricFormatter` (and therefore every
    /// temperature string in this app) formats against.
    ///
    /// This is the iOS half of a pair: on macOS the same job is done by
    /// `SettingsStore`, which owns that platform's preferences. Both are
    /// documented at `TemperatureUnit.display` as the only two writers.
    ///
    /// An unrecognised stored string — a hand-edited `UserDefaults`, or a
    /// value written by a newer build and read by an older one — resolves
    /// to Celsius rather than trapping or leaving a stale unit in place.
    private func publishTemperatureUnit() {
        TemperatureUnit.display = TemperatureUnit(rawValue: temperatureUnitRaw) ?? .celsius
    }

    private func publishAppearanceForWatch() {
        UserDefaults.standard.set(
            systemColorScheme.themeAppearance.rawValue,
            forKey: WatchRelayAppearance.defaultsKey
        )
    }

    /// The handoff's tab bar: flat, hairline top separator, background
    /// token; active item = textPrimary, inactive = textTertiary — no
    /// accent on navigation, no material blur. SwiftUI's TabView styles
    /// through UIKit's appearance proxy, so this is configured there and
    /// reapplied whenever the theme or system appearance changes.
    private func applyTabBarChrome() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(palette.background)
        appearance.shadowColor = UIColor(palette.separator)

        let inactive = UIColor(palette.textTertiary)
        let active = UIColor(palette.textPrimary)
        for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            item.normal.iconColor = inactive
            item.normal.titleTextAttributes = [.foregroundColor: inactive]
            item.selected.iconColor = active
            item.selected.titleTextAttributes = [
                .foregroundColor: active,
                .font: UIFont.systemFont(ofSize: 10, weight: .medium),
            ]
        }

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}

// MARK: - StubTabContent

/// Shared "this tab isn't built yet" content for History/Alerts/Settings —
/// factored out so the three stubs stay visually and texturally identical
/// (one place to change the stub's look, not three) and so whichever agent
/// replaces each stub is working against a small, obviously-temporary file
/// rather than something that could be mistaken for finished UI.
struct StubTabContent: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .scaledSystemFont(size: 40)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
        }
    }
}
