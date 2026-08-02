import AppKit
import SwiftUI
import MacStatKit

// MARK: - Tabs

enum MainTab: String, CaseIterable, Identifiable {
    case dashboard
    /// Protection Insights (`MacStat/Insights/`). Sits between Dashboard and
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
                // A real bar, not a floating overlay: the overlay version
                // let content scroll naked underneath the switcher —
                // headers chopped at the window edge, tiles half-hidden
                // behind the pill. Content now simply starts below it.
                navBar

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
            }
            .ignoresSafeArea()
        }
        .environment(\.themePalette, palette)
        .preferredColorScheme(forcedScheme)
        .frame(minWidth: 860, minHeight: 620)
    }

    /// The fixed top chrome: traffic lights live in the (transparent)
    /// titlebar over its left edge, the themed switcher sits centered, and
    /// a themed hairline closes it off from content.
    private var navBar: some View {
        ZStack {
            navSwitcher
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.navHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.separator)
                .frame(height: 1)
        }
    }

    // MARK: Nav switcher

    private var navSwitcher: some View {
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
    private let onShow: (() -> Void)?
    private let onHide: (() -> Void)?

    init(
        rootView: @escaping () -> AnyView,
        onShow: (() -> Void)? = nil,
        onHide: (() -> Void)? = nil
    ) {
        self.makeRootView = rootView
        self.onShow = onShow
        self.onHide = onHide
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
    }

    func windowWillClose(_ notification: Notification) {
        onHide?()
    }

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


