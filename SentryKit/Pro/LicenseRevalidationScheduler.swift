import Foundation

/// The periodic "is this license still in good standing?" check, owned by
/// the composition root for the app's lifetime the way `UpdateController`
/// owns Sparkle's daily check.
///
/// **What this is modeled on, and why.** Sparkle is the one other
/// background check Sentry runs on a calendar rather than on the snapshot
/// stream: constructed once in `AppDelegate`, told its cadence, and left
/// alone. This follows that shape rather than joining `StatsCoordinator`'s
/// tick — an entitlement check has nothing to do with sampling cadence, and
/// a user who sets a 0.5 s refresh interval should not be asking a
/// licensing server twice a second. Once a day, like the update check, is
/// the right order of magnitude: `LicenseRevalidationPolicy.standard`
/// trusts a successful answer for fourteen days, so a daily attempt gives
/// an offline Mac two weeks of missed tries before anything lapses.
///
/// **It may decline to run, and in this build it does.** The same rule
/// `UpdateController` applies to a placeholder Sparkle key: a check that
/// cannot succeed must not be scheduled, because a scheduled-but-doomed
/// check is a control that silently does nothing. `start()` consults
/// `LicenseProEntitlementStore.isOnlineRevalidationArmed` — true only when
/// a real `LicenseActivationClient` *and* a grace-window policy were both
/// injected — and otherwise records `.inert` with the reason and never
/// creates a task. The composition root passes neither today (see the
/// store's initializer doc comment for why the two must flip together), so
/// this object exists, is started, and does nothing — which is exactly the
/// truthful state, and the reason it is safe to wire now.
///
/// **Errors are absorbed, deliberately.** A transport failure is not a
/// negative answer (the store's `revalidate` doc comment makes the same
/// point), and the grace window is the mechanism that handles it; a
/// scheduler that surfaced every offline tick as an error would nag a
/// laptop on a plane. The last error is kept on `lastError` for the
/// settings pane to show if it wants, never pushed anywhere.
@MainActor
public final class LicenseRevalidationScheduler {

    /// What the scheduler is doing, for the pane and for tests.
    public enum State: Equatable, Sendable {
        /// `start()` was called but the store is not armed for online
        /// revalidation. Carries the plain-language reason.
        case inert(reason: String)
        /// A repeating check is running at this interval.
        case scheduled(interval: TimeInterval)
        /// `start()` has not been called, or `stop()` was.
        case stopped
    }

    /// Once a day — the same cadence `UpdateController.dailyCheckInterval`
    /// gives Sparkle, for the same reason the doc comment gives above.
    public static let dailyInterval: TimeInterval = 60 * 60 * 24

    public private(set) var state: State = .stopped

    /// When the last attempt ran, and what it said if it failed. Both nil
    /// until the first attempt.
    public private(set) var lastAttemptAt: Date?
    public private(set) var lastError: String?

    private let store: LicenseProEntitlementStore
    private let interval: TimeInterval
    private let now: () -> Date
    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - store: the entitlement store whose `revalidate()` this drives.
    ///   - interval: seconds between attempts. `dailyInterval` in
    ///     production; tests pass something tiny.
    ///   - now: injected clock for `lastAttemptAt`, same quarantine as the
    ///     store's own.
    public init(
        store: LicenseProEntitlementStore,
        interval: TimeInterval = LicenseRevalidationScheduler.dailyInterval,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.interval = interval
        self.now = now
    }

    /// Begins the repeating check if — and only if — the store is armed.
    /// Idempotent: calling it while scheduled changes nothing. The first
    /// attempt runs immediately, so a Mac that was asleep through its last
    /// scheduled tick catches up at launch rather than a day later.
    public func start() {
        if case .scheduled = state { return }

        guard store.isOnlineRevalidationArmed else {
            state = .inert(reason: Self.inertReason(for: store))
            return
        }

        state = .scheduled(interval: interval)
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runOnce()
                // A cancelled sleep throws; the loop condition handles it.
                try? await Task.sleep(for: .seconds(self.interval))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        state = .stopped
    }

    /// One attempt, on demand. Public so a "confirm now" button and the
    /// timer share exactly one code path.
    public func runOnce() async {
        lastAttemptAt = now()
        do {
            try await store.revalidate()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Why an unarmed store is unarmed, in words. Both halves are named
    /// separately because they have different owners: the client is Part
    /// 5b's, the policy flip is the composition root's.
    static func inertReason(for store: LicenseProEntitlementStore) -> String {
        if !store.hasActivationBackend {
            return "No activation client is wired in this build, so there is no licensing server to ask."
        }
        return "The revalidation policy is set to never require an online check, so there is nothing to refresh."
    }
}
