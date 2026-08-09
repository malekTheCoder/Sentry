import AppKit
import SwiftUI
import SentryKit

// MARK: - Tabs

enum MainTab: String, CaseIterable, Identifiable {
    case dashboard
    /// Protection Insights (`Sentry/Insights/`). Sits between Dashboard and
    /// Settings deliberately: it reads the same telemetry the Dashboard
    /// shows and turns it into things to *do*, so it belongs next to the
    /// data rather than filed away with the preferences.
    case insights
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return String(localized: "Dashboard")
        case .insights: return String(localized: "Insights")
        case .settings: return String(localized: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .insights: return "checkmark.shield"
        case .settings: return "gearshape"
        }
    }
}

/// The selected tab, observable from both directions: the nav switcher
/// writes it on click, and `AppDelegate` writes it when the dropdown's
/// "Open Dashboard"/"Settings" actions open the window onto a specific tab.
///
/// Also carries the live theme for the window's own chrome: the nav bar
/// used to render on system material regardless of theme, which made the
/// top strip read as a different app the moment an opaque theme (One Dark,
/// Paper, Ivory) painted the content below it. `AppDelegate` pushes theme
/// changes here the same way it pushes them to the view models.
@MainActor
final class MainWindowState: ObservableObject {
    @Published var tab: MainTab = .dashboard
    @Published var theme: Theme = .defaultTheme

    /// Height of the window's own chrome band — titlebar plus the unified
    /// toolbar row that holds the nav pill — as AppKit actually reports it,
    /// pushed here by `MainWindowController`. Seeded with the compiled-in
    /// default so the very first frame, drawn before the window has been
    /// laid out and can be measured, reserves the right space anyway.
    ///
    /// This is a *measurement*, not a preference: `MainWindowView` clips its
    /// tab content to everything below this line, so if the number were
    /// wrong in either direction the clip would land in the wrong place —
    /// too small and scrolled content still surfaces under the traffic
    /// lights, too large and there's a dead strip of background nothing can
    /// ever draw into. See `mainWindowChromeInset`.
    @Published var chromeInset: CGFloat = MainWindowView.navHeight
}

/// The height of the band at the top of the main window that the system's
/// own chrome owns, given what AppKit reports about the window.
///
/// **Why this is measured rather than assumed.** The reserved band used to
/// be a flat 52pt — "per the redesign handoff's titlebar spec" — and on the
/// current OS that constant happens to be exactly right (a `.unified`
/// toolbar holding a 33pt pill measures 52.0pt of chrome, confirmed at
/// runtime). But `MainWindowView` now *clips* its tab content to the region
/// below this line, which turns a decorative constant into a load-bearing
/// one: the clip and the chrome have to be the same line, or the bug this
/// was written to fix comes back a few points lower. Anything that changes
/// the toolbar's height — a taller pill, a system metrics change, a future
/// macOS restyling the unified titlebar — silently breaks a constant and is
/// silently absorbed by a measurement.
///
/// **Why full screen is zero and not `fallback`.** In full screen macOS
/// takes the traffic lights away and auto-hides the toolbar; there is
/// genuinely no chrome for content to hide under, and reserving 52pt anyway
/// would leave a permanent dead strip of background at the top of a
/// deliberately full-bleed presentation. It is passed in rather than
/// inferred from a zero measurement because "zero" is also what a window
/// that hasn't been laid out yet reports, and those two cases want opposite
/// answers.
///
/// **Why two candidate measurements.** `safeAreaInsets.top` is the number
/// SwiftUI itself lays out against, so preferring it keeps the clip and the
/// content in agreement by construction. `frame.height -
/// contentLayoutRect.height` is the AppKit-level statement of the same fact
/// and covers the window states where the content view hasn't been given
/// its safe area yet. Neither is trusted blindly: a value above `maximum`
/// means we have read a window mid-teardown or mid-transition, and
/// reserving a fifth of the window on the strength of a bad reading would
/// be a worse failure than falling back to the constant that has shipped
/// all along.
///
/// A free function, not a method, for exactly the reason
/// `processMonitorShouldRun` above gives: it is the whole of the decision,
/// and it is worth testing without a window on screen.
func mainWindowChromeInset(
    safeAreaTop: CGFloat,
    contentLayoutInset: CGFloat,
    isFullScreen: Bool,
    fallback: CGFloat,
    maximum: CGFloat = 200
) -> CGFloat {
    if isFullScreen { return 0 }
    for candidate in [safeAreaTop, contentLayoutInset]
    where candidate.isFinite && candidate > 0 && candidate <= maximum {
        return candidate
    }
    return fallback
}

/// The pure rule behind `AppDelegate.updateProcessMonitorState()`: whether
/// `ProcessMonitor` — the app's most expensive collector, per-process
/// enumeration on a 5s timer — should be running right now.
///
/// Pulled out as a free function, rather than left inline in
/// `AppDelegate`, purely so it's independently testable without spinning up
/// the composition root — same reasoning `DashboardViewModel.downsample`'s
/// doc comment gives for keeping that logic static.
///
/// Two conditions, both required, neither sufficient alone:
///   - `windowVisible`: the existing outer bound (`MainWindowController`'s
///     `onShow`/`onHide`) — the monitor must never run with the window
///     closed, regardless of tab.
///   - `selectedTab == .dashboard`: the narrower gate this task adds.
///     `MainWindowView` keeps Dashboard/Insights/Settings all alive at once
///     via `.opacity` (see its doc comment) so sitting on Insights or
///     Settings previously still paid for full process enumeration every
///     5s for a card that wasn't even being drawn.
func processMonitorShouldRun(windowVisible: Bool, selectedTab: MainTab) -> Bool {
    windowVisible && selectedTab == .dashboard
}

// MARK: - Root view

/// Sentry's one window: Dashboard and Settings behind a floating glass
/// nav switcher, replacing the two separate windows (and their two sets of
/// chrome). The switcher is a capsule of real within-window material
/// centered at the top; content runs full-bleed underneath it, so the
/// window reads as a single surface with one control floating over it.
struct MainWindowView: View {
    @ObservedObject var state: MainWindowState
    @Environment(\.colorScheme) private var systemColorScheme

    /// Pre-built by the composition root (they carry observable models and
    /// injected stores); this view only decides which one is on screen.
    let dashboard: AnyView
    let insights: AnyView
    let settings: AnyView

    /// Height reserved for the floating switcher — the content views pad
    /// their own tops by this so headers clear it. 52pt per the redesign
    /// handoff's titlebar spec.
    static let navHeight: CGFloat = 52

    private var palette: ThemePalette {
        ThemePalette(theme: state.theme, scheme: systemColorScheme)
    }

    /// Fixed-appearance themes (same hex for light and dark — One Dark,
    /// Paper, Ivory) force the native controls inside every tab to match
    /// the theme's own brightness, judged by the background's luminance;
    /// adaptive themes (Notion, System) keep following macOS. Without
    /// this, Paper on a dark Mac renders dark system controls on a white
    /// page — exactly the "not part of the app" seam being removed here.
    private var forcedScheme: ColorScheme? {
        let background = state.theme.background
        guard background.light == background.dark else { return nil }
        guard let rgb = ThemeColor.components(fromHex: background.light) else { return nil }
        let luminance = 0.299 * rgb.red + 0.587 * rgb.green + 0.114 * rgb.blue
        return luminance > 0.5 ? .light : .dark
    }

    var body: some View {
        ZStack {
            // The always-painted base. Material themes get behind-window
            // glass; opaque themes paint their own background wall to
            // wall — including behind the titlebar, which is what makes
            // the nav bar read as part of the app instead of a strip of
            // system chrome floating above it.
            if state.theme.useMaterialBackground {
                VisualEffect(material: .underWindowBackground)
                    .ignoresSafeArea()
                palette.background.ignoresSafeArea()
            } else {
                palette.background.ignoresSafeArea()
            }

            VStack(spacing: 0) {
                // The switcher itself lives in the window's toolbar (see
                // `NavSwitcherPill`); content just reserves its height so
                // headers clear the title region. Measured rather than
                // assumed — see `MainWindowState.chromeInset`.
                Color.clear.frame(height: state.chromeInset)

                ZStack {
                    // Both stay alive; the hidden one keeps its scroll
                    // position, disclosure state, and in-progress edits.
                    // Opacity rather than `if` so switching tabs never
                    // rebuilds a tree.
                    dashboard
                        .opacity(state.tab == .dashboard ? 1 : 0)
                        .allowsHitTesting(state.tab == .dashboard)
                    insights
                        .opacity(state.tab == .insights ? 1 : 0)
                        .allowsHitTesting(state.tab == .insights)
                    settings
                        .opacity(state.tab == .settings ? 1 : 0)
                        .allowsHitTesting(state.tab == .settings)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // **The one line that keeps content out of the titlebar.**
                //
                // Reserving the band above (the `Color.clear` spacer) is not
                // enough, and the reason is specific to how SwiftUI bridges
                // a `ScrollView` to AppKit on macOS. Dashboard and Insights
                // are each a `ScrollView` at their root; SwiftUI backs those
                // with an `NSScrollView` and then deliberately *promotes* it
                // to cover the window's safe area — the backing scroll view
                // is laid out over the full 700pt window, not the 648pt
                // content band, and a `contentInsets.top` equal to the
                // safe-area inset is what makes resting content still start
                // below the chrome. That is the standard macOS "content
                // scrolls under the translucent toolbar" effect, and it is
                // the whole bug: this window's toolbar is not translucent
                // glass over a blur, it is a themed opaque strip with the
                // traffic lights and the nav pill sitting on it, so content
                // sliding under it is not a depth cue, it is two things
                // printed on top of each other. Measured before this fix:
                // the first non-background pixel row of a scrolled Dashboard
                // was row 0 — the very top of the window.
                //
                // Settings was never affected, and its immunity is the clue
                // that named the mechanism: `SettingsView` is an `HStack` of
                // two static columns, and its only `ScrollView` is the
                // grouped form *inside* the detail column, whose backing
                // `NSScrollView` measures out at 124pt down from the window
                // top. It has nothing to promote into — it never touches the
                // safe area, so AppKit never extends it. Settings isn't
                // doing something extra; it is structurally unable to reach
                // the titlebar. Clipping here gives every other tab that
                // same structural guarantee.
                //
                // **Rejected: painting an opaque strip over the top.** The
                // obvious alternative — draw the window backdrop again as
                // the last child of the root `ZStack`, hiding whatever
                // scrolled underneath — was rejected because it only works
                // as long as the strip is a perfect copy of the backdrop
                // beneath it. Material themes (`useMaterialBackground`) put
                // a real behind-window `NSVisualEffectView` there, so the
                // cover would have to be a second visual-effect view kept in
                // sync with the first, and any drift between them shows up
                // as a visible seam across the top of the window in exactly
                // the themes whose whole point is that there is no seam.
                // Clipping removes the content instead of hiding it, so the
                // one backdrop that was always there is what shows through,
                // in every theme, for free.
                //
                // **Rejected: per-tab fixes.** Adding a top inset or a clip
                // inside `DashboardView` and `InsightsView` would fix the
                // two tabs that exist and none of the ones that don't yet;
                // the nav pill's own history (see `NavSwitcherPill`) is a
                // record of what happens when window chrome is negotiated
                // per-surface rather than owned by the shell.
                .clipped()
            }
            .ignoresSafeArea()
        }
        .environment(\.themePalette, palette)
        .preferredColorScheme(forcedScheme)
        .frame(minWidth: 860, minHeight: 620)
    }

}

// MARK: - Nav switcher pill

/// The Dashboard / Insights / Settings pill. Hosted as a **centered
/// NSToolbarItem** (see `MainWindowController`), not drawn inside the
/// SwiftUI content — the third home this control has had, and each move
/// was forced by an observed failure: as a floating overlay it let content
/// scroll naked underneath; as an in-content bar it needed a fake-toolbar
/// trick to inset the traffic lights, and that trick's empty toolbar
/// swallowed every click ("now the 3 pages arent accessible"). In a real
/// toolbar item the system owns the geometry — tall title region, properly
/// inset traffic lights — and the pill is genuinely clickable because it
/// IS toolbar content rather than content trapped under toolbar glass.
struct NavSwitcherPill: View {
    @ObservedObject var state: MainWindowState
    @Environment(\.colorScheme) private var systemColorScheme

    private var palette: ThemePalette {
        ThemePalette(theme: state.theme, scheme: systemColorScheme)
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MainTab.allCases) { tab in
                segment(for: tab)
            }
        }
        .padding(3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View switcher")
    }

    private func segment(for tab: MainTab) -> some View {
        let isSelected = state.tab == tab
        return Button {
            state.tab = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(tab.title)
                    .font(palette.font(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? palette.textPrimary : palette.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    // Selection is a state, not a CTA — a quiet themed
                    // fill, never accent (handoff accent rules).
                    Capsule(style: .continuous)
                        .fill(palette.surfaceElevated)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Window controller

/// The single app window, replacing `SettingsWindowController` and
/// `HistoryWindowController`. Same lazy-singleton discipline: built on first
/// `show()`, reused forever, never released on close, so scroll position,
/// selected pane, and in-progress edits all survive the red button.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {

    private let makeRootView: () -> AnyView
    private let makeNavSwitcher: () -> AnyView
    private let onShow: (() -> Void)?
    private let onHide: (() -> Void)?

    /// Reports the measured height of the window's own chrome band, so the
    /// root view can reserve exactly that much and clip to it. A callback
    /// rather than a `MainWindowState` reference, to keep this controller
    /// ignorant of the view layer for the same reason `rootView` and
    /// `navSwitcher` are closures: it owns a window, not a screen.
    private let onChromeInset: ((CGFloat) -> Void)?

    /// Last value handed to `onChromeInset`, so a live resize doesn't
    /// republish the same number sixty times a second.
    private var lastPublishedChromeInset: CGFloat?

    init(
        rootView: @escaping () -> AnyView,
        navSwitcher: @escaping () -> AnyView,
        onShow: (() -> Void)? = nil,
        onHide: (() -> Void)? = nil,
        onChromeInset: ((CGFloat) -> Void)? = nil
    ) {
        self.makeRootView = rootView
        self.makeNavSwitcher = navSwitcher
        self.onShow = onShow
        self.onHide = onHide
        self.onChromeInset = onChromeInset
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController is created in code only")
    }

    func show() {
        let mainWindow = window ?? makeWindow()
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)
        // An LSUIElement app doesn't reliably win activation on modern
        // macOS (cooperative activation), and a window that orders in
        // *behind* the frontmost app reads as "the button did nothing" —
        // which is exactly how this bug was reported. `orderFrontRegardless`
        // fronts the window even when activation was denied.
        mainWindow.orderFrontRegardless()
        onShow?()
        // The window's chrome band isn't measurable until AppKit has laid
        // the window out; one turn of the run loop after ordering front is
        // the first moment `contentLayoutRect` is truthful.
        DispatchQueue.main.async { [weak self] in self?.publishChromeInset() }
    }

    /// Re-measures the window's own chrome band and pushes it to the root
    /// view. Called on every event that can change it — see
    /// `mainWindowChromeInset` for what "it" is and why the view needs to
    /// know. Idempotent and guarded on change, because the value it
    /// publishes drives a SwiftUI relayout and an unguarded write on
    /// `windowDidResize` would republish an identical number on every frame
    /// of a live resize.
    private func publishChromeInset() {
        guard let window else { return }
        let inset = mainWindowChromeInset(
            safeAreaTop: window.contentView?.safeAreaInsets.top ?? 0,
            contentLayoutInset: window.frame.height - window.contentLayoutRect.height,
            isFullScreen: window.styleMask.contains(.fullScreen),
            fallback: MainWindowView.navHeight
        )
        guard inset != lastPublishedChromeInset else { return }
        lastPublishedChromeInset = inset
        onChromeInset?(inset)
    }

    func windowWillClose(_ notification: Notification) {
        onHide?()
    }

    // Every event that can change the height of the chrome band. Resize is
    // in the list because entering/leaving a display with a different
    // backing scale, and the full-screen transitions themselves, arrive as
    // resizes before the dedicated notifications do; `publishChromeInset`
    // is guarded on change, so over-calling it is free.
    func windowDidResize(_ notification: Notification) { publishChromeInset() }
    func windowDidEnterFullScreen(_ notification: Notification) { publishChromeInset() }
    func windowDidExitFullScreen(_ notification: Notification) { publishChromeInset() }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: makeRootView())

        let mainWindow = NSWindow(contentViewController: hosting)
        // Title kept for Mission Control / the Window menu / accessibility
        // but not drawn — the glass switcher is the only top chrome.
        // Non-opaque + clear so material themes' behind-window glass (see
        // `VisualEffect`) samples the desktop; opaque themes paint over it.
        mainWindow.title = "Sentry"
        mainWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        mainWindow.titlebarAppearsTransparent = true
        mainWindow.titleVisibility = .hidden
        // A real toolbar, holding exactly one centered item: the nav
        // switcher pill. This does two jobs at once. The tall unified
        // title region insets the traffic lights generously (a bare
        // titlebar pins them into the corner — reported as cramped), and
        // hosting the pill AS a toolbar item is what keeps it clickable:
        // an earlier attempt used an *empty* toolbar purely for the
        // geometry, and its glass swallowed every click headed for the
        // pill drawn in content underneath ("the 3 pages arent
        // accessible"). Toolbar content receives clicks; content under
        // toolbar glass does not.
        let toolbar = NSToolbar(identifier: "MainWindowToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [Self.navSwitcherItemID]
        mainWindow.toolbar = toolbar
        mainWindow.toolbarStyle = .unified
        mainWindow.isOpaque = false
        mainWindow.backgroundColor = .clear
        mainWindow.setContentSize(NSSize(width: 960, height: 700))
        mainWindow.contentMinSize = NSSize(width: 860, height: 620)
        mainWindow.isReleasedWhenClosed = false
        mainWindow.delegate = self
        mainWindow.center()

        self.window = mainWindow
        return mainWindow
    }
}

// MARK: - Toolbar delegate

extension MainWindowController: NSToolbarDelegate {

    static let navSwitcherItemID = NSToolbarItem.Identifier("dev.malekswilam.sentry.navswitcher")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.navSwitcherItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.navSwitcherItemID]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.navSwitcherItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let hosting = NSHostingView(rootView: makeNavSwitcher())
        hosting.setFrameSize(hosting.fittingSize)
        item.view = hosting
        return item
    }
}


