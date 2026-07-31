import AppKit
import SwiftUI
import MacStatKit

// MARK: - Tabs

enum MainTab: String, CaseIterable, Identifiable {
    case dashboard
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .settings: return "gearshape"
        }
    }
}

/// The selected tab, observable from both directions: the nav switcher
/// writes it on click, and `AppDelegate` writes it when the dropdown's
/// "Open Dashboard"/"Settings" actions open the window onto a specific tab.
@MainActor
final class MainWindowState: ObservableObject {
    @Published var tab: MainTab = .dashboard
}

// MARK: - Root view

/// Sentry's one window: Dashboard and Settings behind a floating glass
/// nav switcher, replacing the two separate windows (and their two sets of
/// chrome). The switcher is a capsule of real within-window material
/// centered at the top; content runs full-bleed underneath it, so the
/// window reads as a single surface with one control floating over it.
struct MainWindowView: View {
    @ObservedObject var state: MainWindowState

    /// Pre-built by the composition root (they carry observable models and
    /// injected stores); this view only decides which one is on screen.
    let dashboard: AnyView
    let settings: AnyView

    /// Height reserved for the floating switcher — the content views pad
    /// their own tops by this so headers clear it.
    static let navHeight: CGFloat = 60

    var body: some View {
        ZStack(alignment: .top) {
            // Both stay alive; the hidden one keeps its scroll position,
            // disclosure state, and in-progress edits. `zIndex`/opacity
            // rather than `if` so switching tabs never rebuilds a tree.
            dashboard
                .opacity(state.tab == .dashboard ? 1 : 0)
                .allowsHitTesting(state.tab == .dashboard)
            settings
                .opacity(state.tab == .settings ? 1 : 0)
                .allowsHitTesting(state.tab == .settings)

            navSwitcher
        }
        .frame(minWidth: 860, minHeight: 620)
    }

    // MARK: Nav switcher

    private var navSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(MainTab.allCases) { tab in
                segment(for: tab)
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
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
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    // The selected pill is a second, brighter pane of glass
                    // rather than an accent fill — the switcher stays
                    // chrome, not content.
                    Capsule(style: .continuous)
                        .fill(.regularMaterial)
                        .overlay(Capsule(style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
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
