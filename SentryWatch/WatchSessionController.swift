import Foundation
import SentryKit
import WatchConnectivity
import WidgetKit

// MARK: - WatchSessionController: the Watch's half of WCSession

/// Receives whatever `WatchRelayManager` (`SentryMobile/Watch/WatchRelayManager.swift`)
/// sends from the phone, persists it to `WatchRelayStore` so it survives
/// this process not being alive the next time it's needed, and asks
/// WidgetKit to reload the complication's timeline so it picks the new
/// value up promptly rather than waiting for its own next scheduled poll.
///
/// **Why this writes to `WatchRelayStore` instead of just publishing
/// `latestSnapshot` in-memory.** `ContentView` (this app's own screen) can
/// read the `@Published` property directly, but
/// `SentryWatchWidgetExtension`'s `Provider` runs in a *different*
/// process — one that may not even be running when `WCSession` delivers a
/// payload to this one. `WatchRelayStore`'s App Group write is what makes
/// the data reach that process at all; the in-memory `@Published` value
/// here exists purely for this app's own live UI, not as the source of
/// truth for the complication.
///
/// **Why both `didReceiveApplicationContext` and `didReceiveUserInfo` write
/// the same way.** `WatchRelayManager` sends the same payload shape through
/// two different `WCSession` APIs for two different delivery guarantees
/// (see that type's doc comment) — this side doesn't need to distinguish
/// which one a given payload arrived through, since either one means "here
/// is the latest known state," so both delegate callbacks funnel into the
/// same `store(_:)` helper.
@MainActor
final class WatchSessionController: NSObject, ObservableObject {
    @Published private(set) var latestSnapshot: WatchRelaySnapshot?

    override init() {
        super.init()
        latestSnapshot = WatchRelayStore.read()
    }

    #if DEBUG
    /// Preview-only seam: builds a controller holding a fixed snapshot
    /// instead of reading `WatchRelayStore`.
    ///
    /// **Why this exists rather than previewing the pages directly.**
    /// `ContentView` is now a three-page shell whose whole job is deciding
    /// which page gets real data and which gets `UnavailablePage` — that
    /// routing is the part most likely to be got wrong, and it can only be
    /// seen by previewing the shell, which means previewing something that
    /// owns a `WatchSessionController`. A preview cannot seed the App Group
    /// (Xcode's preview host has no relay and no phone), so without this the
    /// only previewable state would be "nothing relayed yet."
    ///
    /// `#if DEBUG` because this is the one initialiser that can produce a
    /// `latestSnapshot` no Mac ever sent. It must not exist in a shipping
    /// build, where every value on screen has to be traceable to a real
    /// relay — the same reason `sourceIsDemoData` travels with the payload at
    /// all. Both fixtures below set `sourceIsDemoData: true` so even inside a
    /// preview the screen discloses that its numbers are fabricated.
    /// `themeID` overrides the fixture's own, so one fixture can be
    /// inspected under every built-in palette from the command line — see
    /// `SentryWatchApp.makeController()` for the launch-argument plumbing.
    init(preview: PreviewFixture, themeID: String? = nil, appearance: String? = nil) {
        super.init()
        var snapshot = preview.snapshot
        if let themeID { snapshot.themeID = themeID }
        if let appearance { snapshot.themeAppearance = appearance }

        // **Populate the relayed palette too, not just the id.** In
        // production the Mac always sends `themePalette` and the watch
        // prefers it (see `WatchPalette.relayed`), so a fixture that set only
        // an id would exercise the *fallback* path and leave the one that
        // actually ships unverified — including the custom-theme case, which
        // has no id to resolve at all.
        //
        // `custom.*` is a deliberate escape hatch for eyeballing that case:
        // it resolves to nothing in `builtInPresets`, exactly like a real
        // theme forked in the Mac's editor, so what reaches the screen can
        // only have come through the palette.
        let resolved = snapshot.resolvedTheme
        let base = (themeID?.hasPrefix("custom.") == true) ? Self.demoCustomTheme(from: resolved) : resolved
        snapshot.themePalette = RelayedPalette(theme: base, appearance: snapshot.resolvedAppearance)
        latestSnapshot = snapshot
    }

    /// A recognisably-not-a-preset palette, for proving the custom-theme path
    /// end to end on a simulator. Deliberately garish relative to any
    /// built-in so a screenshot cannot be mistaken for a preset.
    private static func demoCustomTheme(from base: Theme) -> Theme {
        var theme = base
        theme.id = "custom.demo"
        theme.isBuiltIn = false
        theme.background = ThemeColor(hex: "#101820")
        theme.surface = ThemeColor(hex: "#1B2A33")
        theme.surfaceElevated = ThemeColor(hex: "#24404D")
        theme.textPrimary = ThemeColor(hex: "#F2E8CF")
        theme.textSecondary = ThemeColor(hex: "#A9BFA8")
        theme.textTertiary = ThemeColor(hex: "#6E8A7E")
        theme.accent = ThemeColor(hex: "#F76C5E")
        theme.success = ThemeColor(hex: "#8AC926")
        theme.warning = ThemeColor(hex: "#FFCA3A")
        theme.danger = ThemeColor(hex: "#FF595E")
        theme.separator = ThemeColor(hex: "#33505C")
        theme.metricColors = [
            "cpu.total_percent": ThemeColor(hex: "#4CC9F0"),
            "memory.used_bytes": ThemeColor(hex: "#B5179E"),
            "disk.read_bytes_per_sec": ThemeColor(hex: "#80ED99"),
        ]
        return theme
    }

    /// Two fixtures, chosen to cover the two states worth eyeballing: a Mac
    /// that reported everything, and one that reported only what a v1 phone
    /// would have sent — which is also exactly what an old phone paired with
    /// a new watch produces, and therefore the case where every "—" and every
    /// missing bar has to look deliberate rather than broken.
    /// `String`-backed so `SentryWatchApp`'s `-SentryWatchDemo <case>` launch
    /// argument can name one without a second lookup table to keep in sync.
    enum PreviewFixture: String {
        case fullyPopulated
        case batteryOnly
        /// The worst case the Overview page can render — hot, throttling and
        /// memory-critical at once, which is three status pills — plus a
        /// paused kill switch on the Agent page. This is the fixture that
        /// actually tests whether the layout holds, and the one every
        /// "does it still fit" check should be run against.
        case underPressure

        var snapshot: WatchRelaySnapshot {
            let now = Date()
            switch self {
            case .fullyPopulated:
                return WatchRelaySnapshot(
                    deviceName: "Malek's MacBook Pro",
                    lastSeen: now.addingTimeInterval(-45),
                    relayedAt: now.addingTimeInterval(-40),
                    sourceIsDemoData: true,
                    batteryPercent: 68,
                    isCharging: false,
                    isPluggedIn: false,
                    thermalPressure: .fair,
                    batteryIsReported: true,
                    cpuPercent: 37,
                    memoryUsedPercent: 71,
                    memoryPressure: .normal,
                    diskUsedPercent: 59,
                    batteryTimeRemainingMinutes: 220,
                    isThrottling: false,
                    awakeIsActive: true,
                    awakeExpiresAt: now.addingTimeInterval(42 * 60),
                    awakeModeLabel: "System only",
                    agentToolCallCount: 14,
                    agentLastActivityAt: now.addingTimeInterval(-90),
                    agentRecentToolNames: ["get_system_snapshot", "keep_awake", "preflight_check"],
                    agentAccessPaused: false
                )
            case .underPressure:
                return WatchRelaySnapshot(
                    deviceName: "Malek's MacBook Pro",
                    lastSeen: now.addingTimeInterval(-12),
                    relayedAt: now.addingTimeInterval(-10),
                    sourceIsDemoData: true,
                    batteryPercent: 8,
                    isCharging: false,
                    isPluggedIn: false,
                    thermalPressure: .critical,
                    batteryIsReported: true,
                    cpuPercent: 97,
                    memoryUsedPercent: 96,
                    memoryPressure: .critical,
                    diskUsedPercent: 97,
                    batteryTimeRemainingMinutes: 11,
                    isThrottling: true,
                    awakeIsActive: false,
                    agentToolCallCount: 128,
                    agentLastActivityAt: now.addingTimeInterval(-30),
                    agentRecentToolNames: ["get_system_snapshot", "preflight_check", "keep_awake"],
                    agentAccessPaused: true
                )
            case .batteryOnly:
                return WatchRelaySnapshot(
                    deviceName: "Mac mini",
                    lastSeen: now.addingTimeInterval(-9 * 60),
                    relayedAt: now.addingTimeInterval(-9 * 60),
                    sourceIsDemoData: true,
                    batteryPercent: 0,
                    isCharging: false,
                    isPluggedIn: true,
                    thermalPressure: .unknown
                )
            }
        }
    }
    #endif

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    private func store(_ dictionary: [String: Any]) {
        guard let snapshot = WatchRelaySnapshot.from(wcSessionPayload: dictionary) else { return }
        WatchRelayStore.write(snapshot)
        latestSnapshot = snapshot
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionController: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    /// `updateApplicationContext`'s receiving half — delivered whenever the
    /// system can manage it, even if this app wasn't running at send time
    /// (it gets woken briefly to handle this).
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            store(applicationContext)
        }
    }

    /// `transferCurrentComplicationUserInfo`'s receiving half — the
    /// budgeted, complication-prioritized channel. Handled identically to
    /// the context callback above; see this type's doc comment for why
    /// there's no need to special-case which API a given payload arrived
    /// through.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            store(userInfo)
        }
    }
}
