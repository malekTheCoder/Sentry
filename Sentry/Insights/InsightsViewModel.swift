import AppKit
import Foundation
import SentryKit

/// Feeds the Insights tab.
///
/// **Same two-path shape as `DashboardViewModel`, for the same reasons.**
/// `ingest(_:)` is called from `AppDelegate`'s single snapshot loop on every
/// tick and is a struct assignment — nothing more. `refresh()` is the
/// expensive path (a security-posture sweep plus fifteen `HistoryStore`
/// reads plus forty-odd rule evaluations) and is **never** called from
/// `ingest`. Its call sites are: the window appearing on this tab, and the
/// user pressing Refresh.
///
/// **Nothing is left running.** The one long-lived piece of work is
/// `refreshTask`; it is cancelled before a new one starts and by
/// `cancelRefresh()`, which `AppDelegate` wires to the window's `onHide`.
/// There are no timers here — deliberately. A protection report that
/// silently re-computed every minute would spend real CPU on a screen nobody
/// is looking at, for findings that move over days.
///
/// **No retain cycles.** `refreshTask`'s closure captures `self` weakly and
/// captures the pure collaborators (`builder`, `engine`, and the plain
/// values it needs) strongly by value, so the heavy work can run on a
/// detached task without touching this object at all until it's time to
/// publish.
@MainActor
final class InsightsViewModel: ObservableObject {

    // MARK: - Published state

    /// `nil` until the first `refresh()` completes. Distinct from "an empty
    /// report": one means not computed yet, the other means computed and
    /// nothing fired. The view renders those differently.
    @Published private(set) var report: ProtectionInsightsReport?

    /// `report.insights` after the Pro cut. `nil` alongside `report`.
    @Published private(set) var gated: ProGate.GatedInsights?

    @Published private(set) var isRefreshing = false

    /// How old a report may be before simply opening the tab recomputes it.
    ///
    /// Fifteen minutes is chosen against what the findings actually measure,
    /// not as a round number: the security half reads settings a user changes
    /// deliberately (and would then re-open Insights to check), while the
    /// hardware half moves over days. Anything shorter re-runs the posture
    /// probes for no new information; anything much longer and a user who
    /// just switched the firewall on comes back to a report that still says
    /// it's off.
    static let stalenessThreshold: TimeInterval = 15 * 60

    /// `true` when there is no report yet, or the one we have is older than
    /// `stalenessThreshold`. Drives the view's `.task`; the Refresh button
    /// stays for a deliberate re-check that ignores this entirely.
    var reportIsStale: Bool {
        guard let generatedAt = report?.generatedAt else { return true }
        return Date().timeIntervalSince(generatedAt) >= Self.stalenessThreshold
    }

    @Published private(set) var isProUnlocked: Bool
    @Published private(set) var unlockSource: ProUnlockSource

    /// Live theme, pushed by `AppDelegate` — same reasoning as
    /// `DashboardViewModel.theme`: this view's hosting controller is built
    /// once for the app's lifetime, so a theme captured at construction
    /// would freeze forever.
    @Published var theme: Theme

    /// The user's dismissals and snoozes, mirrored from settings so the view
    /// can render "3 hidden" without reaching into the store.
    @Published private(set) var suppressions: [InsightSuppression] = []

    // MARK: - Collaborators

    private let settingsStore: SettingsStore
    private let entitlements: any ProEntitlementProviding
    private let postureProvider: any SecurityPostureProviding
    private let builder: InsightContextBuilder
    private let engine: ProtectionInsightsEngine

    /// Switches Sentry's own window to its Settings tab, for the two
    /// findings that are about Sentry's own configuration. Injected rather
    /// than reached for, so this type never touches `MainWindowState`.
    private let onOpenAppSettings: () -> Void

    private var snapshot: SystemSnapshot?
    private var settingsSnapshot: InsightSettingsSnapshot
    private var refreshTask: Task<Void, Never>?

    init(
        historyStore: HistoryStore,
        settingsStore: SettingsStore,
        entitlements: any ProEntitlementProviding,
        postureProvider: any SecurityPostureProviding,
        theme: Theme = .defaultTheme,
        engine: ProtectionInsightsEngine = ProtectionInsightsEngine(),
        onOpenAppSettings: @escaping () -> Void = {}
    ) {
        self.settingsStore = settingsStore
        self.entitlements = entitlements
        self.postureProvider = postureProvider
        self.builder = InsightContextBuilder(historyStore: historyStore)
        self.engine = engine
        self.theme = theme
        self.onOpenAppSettings = onOpenAppSettings
        self.settingsSnapshot = InsightSettingsSnapshot(settingsStore.settings)
        self.suppressions = settingsStore.settings.protectionInsightSuppressions
        self.isProUnlocked = entitlements.isUnlocked(.protectionInsights)
        self.unlockSource = entitlements.unlockSource
        // Deliberately no `refresh()` here — constructing this as an
        // `AppDelegate` property must stay cheap, exactly as
        // `DashboardViewModel`'s initializer documents. The view calls
        // `refresh()` on first appearance.
    }

    // MARK: - Live path

    /// Called on every snapshot tick. Cheap by construction: it retains one
    /// struct and does not touch the database, the posture collector, or the
    /// rules.
    func ingest(_ snapshot: SystemSnapshot) {
        self.snapshot = snapshot
    }

    /// Called from `AppDelegate`'s settings subscription with the delivered
    /// value — see `ProEntitlementProviding.applySettings` for why the
    /// delivered value matters rather than re-reading the store.
    func applySettings(_ settings: AppSettings) {
        settingsSnapshot = InsightSettingsSnapshot(settings)

        let newSuppressions = settings.protectionInsightSuppressions
        let suppressionsChanged = newSuppressions != suppressions
        suppressions = newSuppressions

        let wasUnlocked = isProUnlocked
        isProUnlocked = entitlements.isUnlocked(.protectionInsights)
        unlockSource = entitlements.unlockSource

        if wasUnlocked != isProUnlocked, let report {
            // Re-gate without re-evaluating: the findings haven't changed,
            // only how many of them the user is allowed to read.
            gated = ProGate.apply(isUnlocked: isProUnlocked, to: report.insights)
        }
        if suppressionsChanged, report != nil {
            // A dismissal changes both the visible list and the score, so
            // this one does need a real re-evaluation.
            refresh()
        }
    }

    // MARK: - Refresh

    /// - Parameter reloadPosture: `true` for the explicit Refresh button.
    ///   The posture collector caches for five minutes, which is right for
    ///   an incidental re-appearance and wrong for a user who just came back
    ///   from turning FileVault on.
    func refresh(reloadPosture: Bool = false) {
        refreshTask?.cancel()
        isRefreshing = true

        // Everything the heavy work needs, captured by value so the detached
        // task never touches `self`.
        let snapshot = self.snapshot
        let settingsSnapshot = self.settingsSnapshot
        let suppressions = self.suppressions
        let builder = self.builder
        let engine = self.engine
        let provider = self.postureProvider

        refreshTask = Task { [weak self] in
            if reloadPosture {
                await provider.invalidateCache()
            }
            let posture = await provider.currentPosture()
            if Task.isCancelled { return }

            // `HistoryStore` reads and rule evaluation are synchronous and
            // measurably not free; a detached task keeps them off the main
            // actor entirely rather than merely off the current runloop turn.
            let report = await Task.detached(priority: .userInitiated) {
                let context = builder.build(
                    snapshot: snapshot,
                    posture: posture,
                    settings: settingsSnapshot
                )
                return engine.evaluate(context, suppressions: suppressions)
            }.value

            if Task.isCancelled { return }
            self?.apply(report)
        }
    }

    /// Wired to the window's `onHide`. A report in flight for a window the
    /// user just closed is pure waste.
    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    private func apply(_ report: ProtectionInsightsReport) {
        self.report = report
        self.gated = ProGate.apply(isUnlocked: isProUnlocked, to: report.insights)
        self.isRefreshing = false
    }

    // MARK: - Suppression

    func dismiss(insightID: String) {
        write(InsightSuppression.dismiss(insightID: insightID))
    }

    func snooze(insightID: String, for duration: SnoozeDuration) {
        write(InsightSuppression.snooze(insightID: insightID, for: duration))
    }

    /// Brings a dismissed or snoozed finding back.
    func restore(insightID: String) {
        let updated = InsightSuppression.removing(
            insightID: insightID,
            from: settingsStore.settings.protectionInsightSuppressions
        )
        persist(updated)
    }

    private func write(_ suppression: InsightSuppression) {
        let updated = InsightSuppression.upserting(
            suppression,
            into: settingsStore.settings.protectionInsightSuppressions
        )
        persist(updated)
    }

    private func persist(_ updated: [InsightSuppression]) {
        // Pruned on every write so lapsed snoozes can't accumulate in
        // settings.json forever — see `InsightSuppression.pruned`.
        let pruned = InsightSuppression.pruned(updated, at: Date())
        // Local state first, store second. `@Published` emits in `willSet`,
        // so writing the store first would re-enter `applySettings` while
        // `suppressions` still held the old value — it would see a change,
        // kick off a refresh, and this method would immediately cancel it
        // and start another. Assigning locally first makes that re-entry a
        // no-op.
        suppressions = pruned
        settingsStore.settings.protectionInsightSuppressions = pruned
        refresh()
    }

    /// The active suppression for a finding, so the UI can show its horizon.
    func activeSuppression(for insightID: String) -> InsightSuppression? {
        InsightSuppression.active(forInsightID: insightID, in: suppressions, at: Date())
    }

    // MARK: - Actions

    /// Carries out an insight's action.
    ///
    /// - Returns: `true` when something actually happened. `false` means the
    ///   deep link didn't resolve — the System Settings URL scheme is
    ///   undocumented and Apple has changed these identifiers before (see
    ///   `SystemSettingsLink`). The view uses the result to reveal the
    ///   written-out path instead of leaving the user with a button that
    ///   silently did nothing, which is precisely the inert-control failure
    ///   this codebase has removed before.
    @discardableResult
    func perform(_ action: InsightAction) -> Bool {
        switch action.target {
        case .systemSettings(let urlString):
            guard let url = URL(string: urlString) else { return false }
            return NSWorkspace.shared.open(url)
        case .appSettings:
            onOpenAppSettings()
            return true
        case .manual:
            // Nothing to launch by design. The view never renders a button
            // for this case; it renders `fallbackDescription` as text.
            return false
        }
    }
}
