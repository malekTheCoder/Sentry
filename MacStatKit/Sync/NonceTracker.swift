import Foundation

/// Idempotency + expiry gate for `ControlCommand`s (plan §10.4's "Robustness
/// requirements"), used wherever the real push/poll handler eventually lives
/// (not yet built — see `SyncRecords.swift`'s top-level doc comment for why
/// this directory has no live `CKContainer` yet). This type is pure decision
/// logic: it never touches CloudKit, only a `ControlCommand` value and a
/// caller-supplied `now`, so it is fully unit-testable today.
///
/// **Two independent checks, both must pass:**
/// 1. **Not already executed.** A silent push can be redelivered (CloudKit
///    doesn't guarantee exactly-once), and the fallback poller (plan §7.5)
///    can also observe the same still-live `ControlCommand` on a later tick
///    after a push already handled it. Either path re-running
///    `IOPMAssertionCreate…` would "restart the timer" — plan §10.4's exact
///    phrase for the bug this exists to prevent.
/// 2. **Not expired.** "A command that sat in CloudKit for an hour because
///    the Mac was asleep should not fire on wake" (plan §10.4). `expiresAt`
///    is authored by the iPhone at creation time (default +5 min, plan
///    §7.3), so this is a pure comparison against `now` — no clock skew
///    handling beyond what already lives in `ControlCommand.expiresAt`.
///
/// **Eviction policy — FIFO ring buffer of the last 200 nonces.** Plan §10.4
/// says "bounded set (last 200)" without specifying eviction order. FIFO
/// (oldest-first) is the only policy that matches "last 200" read as "the
/// 200 most recently executed": it's simple, and it's the correct choice for
/// this workload because commands are rate-limited by the Mac's own
/// fast-cadence ceiling (plan §7.4 — nothing pushes more than once per
/// 30s), so 200 slots comfortably outlive any duplicate-delivery window
/// (silent push retries and the 60s fallback poll both resolve within
/// seconds to low-single-digit minutes, not the ~100 minutes 200 commands
/// at 30s cadence would take to cycle through). A duplicate arriving after
/// 200 *other, distinct* nonces have executed is not a scenario the real
/// system produces — see `markExecuted`'s doc comment for the accepted edge
/// case this implies.
///
/// **Isolation:** `@MainActor`, matching `PowerControlService`'s established
/// precedent in this codebase for services driven by infrequent
/// user/system-initiated events (here: incoming pushes/poll ticks) rather
/// than a hot polling loop — there's no contention to protect against with a
/// private serial queue the way `StatsCoordinator`/`RollupJob` need one.
@MainActor
public final class NonceTracker {

    /// Ring buffer capacity. Plan §10.4: "bounded set (last 200)."
    public static let capacity = 200

    // Array + Set kept in lockstep: the array preserves insertion order for
    // FIFO eviction, the set makes `shouldExecute`'s membership check O(1)
    // instead of O(200) linear scans on every command.
    private var order: [String] = []
    private var seen: Set<String> = []

    public init() {}

    /// Whether `command` should be executed *right now*, given `now`.
    ///
    /// Returns `false` if either:
    /// - `command.nonce` has already been passed to `markExecuted` and is
    ///   still within the tracked window (not yet evicted), or
    /// - `command.expiresAt` is at or before `now`.
    ///
    /// Does **not** itself record the nonce as executed — callers must call
    /// `markExecuted(_:)` only after the command's side effect (e.g. the
    /// `IOPMAssertionCreate…` call) actually ran, so a command that fails
    /// mid-execution can still be retried on redelivery rather than being
    /// silently swallowed forever.
    public func shouldExecute(_ command: ControlCommand, now: Date = Date()) -> Bool {
        if seen.contains(command.nonce) { return false }
        if command.expiresAt <= now { return false }
        return true
    }

    /// Records `nonce` as executed, evicting the oldest tracked nonce first
    /// if this insertion would exceed `capacity`.
    ///
    /// **Accepted edge case (documented per the task's request):** once a
    /// nonce is evicted, `shouldExecute` can no longer see it and would treat
    /// a resend of that exact command as fresh — i.e. re-execute it. Plan
    /// §10.4's intent is defeating *ordinary* duplicate delivery (a push
    /// redelivered seconds-to-minutes later, or the 60s fallback poll
    /// re-observing a command a push already handled) — not defending
    /// against a duplicate that resurfaces only after 200 other, distinct
    /// commands have executed since. That scenario does not occur in this
    /// system's real traffic pattern (see the type doc's cadence math), so
    /// trading it away is the correct, deliberate choice for a bounded
    /// structure rather than an unbounded set that grows for the app's
    /// entire lifetime.
    public func markExecuted(_ nonce: String) {
        guard !seen.contains(nonce) else { return } // idempotent re-mark, no double-insert into `order`
        seen.insert(nonce)
        order.append(nonce)
        if order.count > Self.capacity {
            let evicted = order.removeFirst()
            seen.remove(evicted)
        }
    }

    /// Test/diagnostic hook: how many nonces are currently tracked.
    public var trackedCount: Int { order.count }
}
