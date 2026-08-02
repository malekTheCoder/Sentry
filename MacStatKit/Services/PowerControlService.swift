import Foundation
import os

#if os(macOS)
import IOKit.pwr_mgt
import AppKit
import Darwin

/// Maps each `AwakeMode` case to the real `IOKit.pwr_mgt` assertion-type
/// constant `PowerControlService` passes to `IOPMAssertionCreateWithProperties`.
/// A computed extension, not a member of the enum itself, because
/// `IOKit.pwr_mgt` only exists on macOS — see `AwakeMode`'s own doc comment
/// (`MacStatKit/Models/AwakeMode.swift`) for why the enum had to move out of
/// this `#if os(macOS)` block in the first place.
extension AwakeMode {
    var assertionType: String {
        switch self {
        case .displayAndSystem: return kIOPMAssertionTypeNoDisplaySleep
        case .systemOnly: return kIOPMAssertionTypePreventUserIdleSystemSleep
        case .systemWhileOnAC: return kIOPMAssertionTypePreventSystemSleep
        }
    }
}

/// A condition-based release trigger (plan §10.3's "last three" duration
/// options) — what elevates this above a plain Caffeine clone. Evaluated
/// either by feeding live `SystemSnapshot`s through `evaluate(_:)` (for the
/// two numeric conditions) or by observing app-termination notifications
/// directly (for `.whileAppRunning` — see `PowerControlService`'s
/// `NSWorkspace` observer).
public enum ReleaseCondition: Codable, Equatable, Sendable {
    case batteryBelowPercent(Double)
    /// Sustained: the CPU must stay above `Double`% for at least
    /// `TimeInterval` seconds continuously. Dropping below the threshold at
    /// any point resets the sustained-duration clock.
    case cpuAbovePercent(Double, for: TimeInterval)
    case whileAppRunning(bundleIdentifier: String)
    /// Holds the assertion while a *process* with this executable name is
    /// running — `claude`, `codex`, `xcodebuild`, `node` — and releases when
    /// it exits. The agent-ops sibling of `.whileAppRunning`: CLI tools and
    /// build daemons never appear in `NSWorkspace`'s app lifecycle
    /// notifications, so this one is polled per snapshot tick in
    /// `evaluate(_:)` via a libproc scan instead. Name matching is
    /// case-insensitive and exact (no substring matching — "node" must not
    /// hold the machine awake because "com.apple.noded" exists).
    case whileProcessRunning(name: String)
}

/// Wraps an `IOReturn` failure from `IOPMAssertionCreateWithProperties`.
public enum PowerControlError: Error, LocalizedError, Sendable, Equatable {
    case assertionFailed(IOReturn)
    /// Thrown by `adjustAssertion(bySeconds:)` when there's nothing to
    /// adjust — see that method's doc comment for the three cases this covers.
    case noAdjustableAssertion

    public var errorDescription: String? {
        switch self {
        case .assertionFailed(let code):
            return "Couldn't prevent sleep (IOKit error \(code))."
        case .noAdjustableAssertion:
            return "No timed keep-awake session is running to adjust."
        }
    }
}

/// Sleep-prevention service (plan §10). Owns at most one live
/// `IOPMAssertionID` at a time and mirrors it into `state` for the UI.
///
/// **Why `IOPMAssertionCreateWithProperties`, not the simpler
/// `IOPMAssertionCreateWithName`:** only the properties variant accepts
/// `kIOPMAssertionTimeoutKey`/`kIOPMAssertionTimeoutActionKey`, which arm an
/// OS-level timeout that releases the assertion even if this process is
/// killed outright (force-quit, crash, `kill -9`). That's belt-and-braces
/// alongside the app-level `Timer` below: the `Timer` only fires while this
/// process is alive and updates `state` promptly; the OS timeout is what
/// still protects the machine if it isn't. A leaked assertion is close to
/// the worst failure mode this feature has — the Mac silently never
/// sleeps again until reboot — so both mechanisms exist deliberately, not
/// redundantly.
///
/// **What this does *not* do:** per plan §10.1, none of the assertion types
/// used here override an explicit user Sleep (Apple menu → Sleep) or a
/// clamshell close. That's correct, intended OS behavior — do not "fix" it
/// into overriding the user's explicit choice.
///
/// `@MainActor`-isolated rather than queue-confined like `StatsCoordinator`:
/// this service is driven by user-initiated UI actions and infrequent system
/// notifications (wake, app termination), not a hot polling loop, so there's
/// no contention to protect against with a private serial queue.
@MainActor
public final class PowerControlService: ObservableObject {

    private static let logger = Logger(subsystem: "com.sentry.macstat.kit", category: "PowerControlService")
    private static let defaultsKey = "com.sentry.macstat.powercontrol.state"

    @Published public private(set) var state: SleepAssertionState = .inactive

    private var assertionID: IOPMAssertionID = 0
    private var expiryTimer: Timer?

    /// Bumped once per successfully created assertion. Exists to close a
    /// stale-expiry race the `expiryTimer` alone cannot: the timer's block
    /// hops onto the main actor via `Task { @MainActor ... }`, so there is a
    /// window between the timer *firing* and that task *running* in which
    /// other main-actor work — a user starting a fresh assertion, an
    /// `adjustAssertion` extension — can replace the assertion the timer was
    /// armed for. `expiryTimer?.invalidate()` prevents future fires but
    /// cannot recall a fire that already happened, so without this guard the
    /// stale task would call `releaseAssertion()` and silently tear down the
    /// *new* assertion seconds after the user created it (e.g. extend a
    /// 60-second hold to 8 hours in the last instant of the old window, and
    /// the Mac sleeps 8 hours early anyway). Each timer captures the
    /// generation it was armed for; `timedAssertionExpired(generation:)`
    /// releases only if that generation is still current.
    /// `internal private(set)` rather than `private` so tests can exercise
    /// the stale-generation guard deterministically.
    private(set) var assertionGeneration: UInt64 = 0

    /// The conditional trigger (if any) governing the current assertion, so
    /// `evaluate(_:)` and the app-termination observer know what to check,
    /// and so a future UI can ask "is there a pending conditional release
    /// and what is it."
    private var activeCondition: ReleaseCondition?

    /// First moment `.cpuAbovePercent`'s condition was observed true, for
    /// the "sustained" requirement. `nil` whenever the condition is not
    /// currently true (including "no condition set" / "no CPU sample yet").
    private var conditionSustainedSince: Date?

    /// Consecutive `evaluate(_:)` ticks on which `.whileProcessRunning`'s
    /// process was *not* found. Released only after two consecutive misses,
    /// so a single glitchy `proc_listallpids` enumeration (or a process
    /// observed mid-exec) can't drop a multi-hour hold spuriously.
    private var processMissCount = 0

    /// Injectable for tests — the default scans the live process table.
    /// Called at most once per snapshot tick, and only while a
    /// `.whileProcessRunning` condition is armed.
    public var processProbe: (String) -> Bool = PowerControlService.isProcessRunning(named:)

    private var wakeObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    private let defaults: UserDefaults

    /// Small persisted record: everything needed to restore both the visible
    /// state and the conditional trigger across relaunch/wake.
    private struct PersistedRecord: Codable {
        var state: SleepAssertionState
        var condition: ReleaseCondition?
    }

    /// - Parameter defaults: override for tests; defaults to `.standard`,
    ///   matching `RollupJob`'s injectable-`UserDefaults` convention for
    ///   small persisted key-value state (as opposed to `HistoryStore`'s
    ///   GRDB-backed time series, which this state is not).
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Reconciliation exists because our UserDefaults bookkeeping can
        // outlive the thing it describes: a persisted "I was active" flag is
        // a claim about an OS-level assertion that may no longer exist, and
        // P5 says we must not render a claim we haven't verified (plan
        // §10.4's reconciliation paragraph, which applies locally even
        // without CloudKit).
        //
        // The two entry points are deliberately *not* equivalent, hence
        // `isColdStart` — see `reconcilePersistedState(isColdStart:)`. On
        // wake the process never died, so a restored assertion is still the
        // user's standing intent; on launch it is not.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconcilePersistedState(isColdStart: false) }
        }

        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in self?.handleAppTermination(bundleIdentifier: bundleID) }
        }

        reconcilePersistedState(isColdStart: true)
    }

    /// `deinit` is `nonisolated` on a `@MainActor` class — it cannot hop
    /// back onto the main actor to call `releaseAssertion()`, the same
    /// constraint `StatsCoordinator.deinit` documents and works around.
    /// Stored-property access and plain C/Foundation calls (the
    /// `IOPMAssertionRelease` call itself has no actor isolation of its
    /// own — only this class's Swift-side bookkeeping does) are fine to do
    /// directly here; only *calling another `@MainActor` method* would not
    /// be. Doing the minimal safe release/cleanup directly, rather than
    /// trying to dispatch `releaseAssertion()` asynchronously, also avoids
    /// `StatsCoordinator`'s documented `deinit` + `queue.async([weak self])`
    /// bug: a dispatch made after `self` is already gone would silently
    /// no-op and leak the assertion — exactly the failure mode this method
    /// exists to prevent.
    deinit {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
        expiryTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
        }
    }

    // MARK: - Public API

    /// Fixed-duration or indefinite assertion (plan §10.2/§10.3).
    /// - Parameter duration: `nil` means indefinite (until `releaseAssertion()`).
    public func startAssertion(mode: AwakeMode, duration: TimeInterval?, reason: String) throws {
        try startAssertionInternal(mode: mode, duration: duration, reason: reason, condition: nil)
    }

    /// Conditional assertion (plan §10.3's "last three": battery threshold,
    /// sustained CPU threshold, or while a specific app runs). Indefinite by
    /// construction — it's released when `condition` is satisfied, not on a
    /// timer. Feed live data via `evaluate(_:)` (for the two numeric
    /// conditions) from the same `StatsCoordinator` stream everything else
    /// already consumes; `.whileAppRunning` is handled internally via an
    /// `NSWorkspace` termination observer instead.
    public func startConditionalAssertion(mode: AwakeMode, condition: ReleaseCondition, reason: String) throws {
        try startAssertionInternal(mode: mode, duration: nil, reason: reason, condition: condition)
    }

    /// Releases any live assertion, invalidates the app-level timer, clears
    /// any armed conditional trigger, and updates/persists `.inactive`.
    /// Idempotent — safe to call with nothing active.
    public func releaseAssertion() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        expiryTimer?.invalidate()
        expiryTimer = nil
        activeCondition = nil
        conditionSustainedSince = nil
        processMissCount = 0
        state = .inactive
        persistState()
    }

    /// Extends (positive `delta`) or truncates (negative `delta`) the
    /// remaining duration of the currently active assertion, preserving its
    /// mode and reason. Throws `.noAdjustableAssertion` when there's nothing
    /// to adjust: no assertion is active, the active one is indefinite (no
    /// `expiresAt` for "remaining time" to mean anything), or it's a
    /// conditional trigger (governed by `activeCondition`/`evaluate(_:)`, not
    /// a clock — see `ReleaseCondition`). A truncation that lands at or
    /// before now releases the assertion immediately rather than starting a
    /// new one with a zero-or-negative duration.
    public func adjustAssertion(bySeconds delta: TimeInterval) throws {
        guard case .active(let mode, let expiresAt, let reason) = state,
              let expiresAt,
              activeCondition == nil else {
            throw PowerControlError.noAdjustableAssertion
        }
        let newRemaining = expiresAt.timeIntervalSinceNow + delta
        guard newRemaining > 0 else {
            releaseAssertion()
            return
        }
        try startAssertionInternal(mode: mode, duration: newRemaining, reason: reason, condition: nil)
    }

    /// Feeds a fresh `SystemSnapshot` from the app's single poll loop (plan
    /// §3.2 P3 — this service doesn't own or create that stream) so the two
    /// numeric `ReleaseCondition`s can be checked. A no-op unless a
    /// conditional assertion is currently active. `.whileAppRunning` isn't
    /// evaluated here — there's nothing on a `SystemSnapshot` to check it
    /// against — it's handled by the `NSWorkspace` termination observer
    /// registered in `init`.
    public func evaluate(_ snapshot: SystemSnapshot) {
        guard let condition = activeCondition else { return }

        switch condition {
        case .batteryBelowPercent(let threshold):
            guard let percent = snapshot.battery?.chargePercent else { return }
            if percent < threshold {
                releaseAssertion()
            }

        case .cpuAbovePercent(let threshold, let sustainedFor):
            guard let percent = snapshot.cpu?.totalPercent else {
                // No sample this tick — don't let a transient gap masquerade
                // as "condition held the whole time."
                conditionSustainedSince = nil
                return
            }
            if percent > threshold {
                let startedAt = conditionSustainedSince ?? Date()
                conditionSustainedSince = startedAt
                if Date().timeIntervalSince(startedAt) >= sustainedFor {
                    releaseAssertion()
                }
            } else {
                // "Sustained" means continuously true — any dip resets the clock.
                conditionSustainedSince = nil
            }

        case .whileAppRunning:
            break

        case .whileProcessRunning(let name):
            if processProbe(name) {
                processMissCount = 0
            } else {
                processMissCount += 1
                if processMissCount >= 2 {
                    releaseAssertion()
                }
            }
        }
    }

    /// Whether any running process's executable name matches `target`
    /// (case-insensitive, exact). Public so the UI can validate "is that
    /// process even running?" at arm time and warn instead of arming a hold
    /// that releases two ticks later.
    ///
    /// `proc_listallpids`/`proc_name` are the same public libproc APIs
    /// `ProcessCollector` already uses; a full scan is a few hundred
    /// microseconds and only runs while a `.whileProcessRunning` hold is
    /// armed, not on every tick of the app's life.
    public nonisolated static func isProcessRunning(named target: String) -> Bool {
        let wanted = target.lowercased()
        guard !wanted.isEmpty else { return false }

        let expected = proc_listallpids(nil, 0)
        guard expected > 0 else { return false }
        // Headroom for processes spawned between the two calls, matching
        // ProcessCollector's convention.
        var pids = [pid_t](repeating: 0, count: Int(expected) + 32)
        let filled = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard filled > 0 else { return false }

        var nameBuffer = [CChar](repeating: 0, count: 128)
        for index in 0..<Int(filled) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            let length = nameBuffer.withUnsafeMutableBufferPointer { pointer in
                proc_name(pid, pointer.baseAddress, UInt32(pointer.count))
            }
            guard length > 0 else { continue }
            if String(cString: nameBuffer).lowercased() == wanted {
                return true
            }
        }
        return false
    }

    // MARK: - Assertion creation (shared by both public entry points)

    private func startAssertionInternal(
        mode: AwakeMode,
        duration: TimeInterval?,
        reason: String,
        condition: ReleaseCondition?
    ) throws {
        releaseAssertion() // only ever one at a time

        // "Keep awake for zero (or negative) seconds" must not silently
        // become "keep awake forever": below, a non-positive duration is
        // skipped when building the timeout properties and when computing
        // `expiresAt`, so without this guard it would fall through to an
        // *indefinite* assertion — the exact battery-draining failure mode
        // the cold-start reconciliation guard exists to prevent, minted
        // fresh from a degenerate input instead of a stale record. The
        // release above has already run, so the net effect is "nothing
        // held," which is the only honest reading of a zero-length request.
        if let duration, duration <= 0 {
            return
        }

        var props: [String: Any] = [
            kIOPMAssertionTypeKey as String: mode.assertionType,
            kIOPMAssertionNameKey as String: reason,
            kIOPMAssertionLevelKey as String: kIOPMAssertionLevelOn
        ]
        // Belt and braces (plan §10.2) — see the type doc comment for why
        // this is the properties API rather than `...CreateWithName`.
        if let duration, duration > 0 {
            props[kIOPMAssertionTimeoutKey as String] = duration
            props[kIOPMAssertionTimeoutActionKey as String] = kIOPMAssertionTimeoutActionRelease
        }

        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithProperties(props as CFDictionary, &id)
        guard result == kIOReturnSuccess else {
            throw PowerControlError.assertionFailed(result)
        }

        assertionID = id
        assertionGeneration &+= 1
        activeCondition = condition
        conditionSustainedSince = nil
        processMissCount = 0

        let expiresAt: Date? = (duration.flatMap { $0 > 0 ? Date().addingTimeInterval($0) : nil })
        state = .active(mode: mode, expiresAt: expiresAt, reason: reason)

        if let duration, duration > 0 {
            // App-level mechanism #2 (see type doc): updates `state`
            // promptly while this process is alive, independent of the
            // OS-level timeout above. The captured generation is what makes
            // an already-fired-but-not-yet-run expiry harmless if a newer
            // assertion has replaced this one in the meantime — see
            // `assertionGeneration`'s doc comment for the race.
            let generation = assertionGeneration
            expiryTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.timedAssertionExpired(generation: generation) }
            }
        }

        persistState() // so we can restore across app relaunch (plan §10.2)
    }

    /// Landing point for the app-level expiry timer. Releases only when
    /// `generation` still identifies the *current* assertion — a stale fire
    /// (timer went off for assertion N, but assertion N+1 was started before
    /// this ran on the main actor) is a no-op rather than a silent teardown
    /// of the newer assertion. See `assertionGeneration`'s doc comment.
    /// `internal` rather than `private` so tests can drive the stale case
    /// deterministically; not part of the public API.
    func timedAssertionExpired(generation: UInt64) {
        guard generation == assertionGeneration else { return }
        releaseAssertion()
    }

    // MARK: - Notification handlers

    private func handleAppTermination(bundleIdentifier: String?) {
        guard let bundleIdentifier,
              case .whileAppRunning(let watched) = activeCondition,
              watched == bundleIdentifier else { return }
        releaseAssertion()
    }

    /// Re-reads persisted state and either re-creates the real assertion (if
    /// still within its window) or cleans up to `.inactive`. Called from
    /// `init` (covers app relaunch) and the `didWakeNotification` observer
    /// (covers sleep/wake).
    ///
    /// An earlier version of this comment claimed both paths "destroy the
    /// previous OS-level assertion." That is true of process exit — `powerd`
    /// tracks assertions per-PID and drops them when the owner dies — but
    /// **not** of sleep/wake, where an assertion survives untouched. The wake
    /// path therefore releases and re-creates something that was already
    /// live. That's wasteful rather than wrong (it opens a brief window with
    /// no assertion, and flaps `state` through `.inactive`), and is left
    /// as-is here only because narrowing it is a behavioral change worth
    /// making deliberately rather than as a drive-by. Recorded so the next
    /// reader doesn't re-derive the false premise.
    ///
    /// - Parameter isColdStart: `true` when called from `init` (the process
    ///   just started), `false` from the wake observer (the process has been
    ///   running throughout). This distinction exists to avoid a genuinely
    ///   nasty failure mode: an **indefinite** assertion has no `expiresAt`,
    ///   so it can never fail the expiry check below and would otherwise be
    ///   re-created on *every* launch, forever, with no user action —
    ///   turn it on once, quit, and the Mac is silently held awake again on
    ///   next launch (and MacStat is a login item, so "next launch" is
    ///   every boot). `IOPMAssertion`s are released by the OS when their
    ///   owning process exits, so after a quit there is nothing left to
    ///   "restore" — only our own stale bookkeeping claiming otherwise.
    ///   Plan §10.4 authorizes restoring a record only "if its expiry is
    ///   still in the future," which an indefinite assertion has no way to
    ///   satisfy. Timed assertions still restore across a cold start: they
    ///   carry a bounded, self-releasing window the user explicitly chose.
    ///   On the wake path all of this is moot — the process never died, so
    ///   restoring is continuing the user's standing intent, not resurrecting
    ///   it.
    private func reconcilePersistedState(isColdStart: Bool) {
        guard let record = loadPersistedRecord() else {
            // No persisted record to trust, but `assertionID` may still hold
            // a stale value from before this method ran (e.g. sleep/wake
            // destroys the real OS-level assertion without ever notifying
            // Swift-side bookkeeping, or the persisted key vanished out from
            // under a still-live assertion). Route through the idempotent
            // `releaseAssertion()` rather than only setting `state = .inactive`
            // directly, so stale id/timer/condition bookkeeping can never
            // survive this call — leaving it behind is exactly the "leaked
            // assertion, Mac never sleeps again" failure mode the type doc
            // warns about.
            releaseAssertion()
            return
        }

        switch record.state {
        case .inactive:
            releaseAssertion()

        case .active(let mode, let expiresAt, let reason):
            if isColdStart, expiresAt == nil {
                // Indefinite hold from a previous run of the app — see the
                // `isColdStart` parameter doc. Deliberately dropped rather
                // than silently re-asserted.
                Self.logger.notice("Discarding persisted indefinite sleep assertion from a previous launch rather than silently re-asserting it.")
                releaseAssertion()
                clearPersistedRecord()
                return
            }
            if let expiresAt, expiresAt <= Date() {
                // Expired while we were asleep / not running — nothing to
                // restore, and definitely don't fire a fresh assertion for a
                // window that already passed. `releaseAssertion()` also
                // clears any stale `assertionID` left over from before sleep
                // (see the no-record branch above for why that matters).
                releaseAssertion()
                clearPersistedRecord()
                return
            }

            let remaining = expiresAt.map { $0.timeIntervalSince(Date()) }
            do {
                try startAssertionInternal(mode: mode, duration: remaining, reason: reason, condition: record.condition)
            } catch {
                // Best-effort restore (P5) — if IOKit itself refuses, don't
                // leave `state` claiming an assertion exists that doesn't.
                Self.logger.error("Failed to restore sleep assertion: \(error.localizedDescription, privacy: .public)")
                releaseAssertion()
                clearPersistedRecord()
            }
        }
    }

    // MARK: - Persistence (UserDefaults — small key-value state, not time series)

    private func persistState() {
        let record = PersistedRecord(state: state, condition: activeCondition)
        do {
            let data = try JSONEncoder().encode(record)
            defaults.set(data, forKey: Self.defaultsKey)
        } catch {
            // Losing the persisted flag only costs us the relaunch/wake
            // restore — never worth throwing out of a method the UI calls
            // freely (P5).
            Self.logger.error("Failed to persist sleep-assertion state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadPersistedRecord() -> PersistedRecord? {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return nil }
        return try? JSONDecoder().decode(PersistedRecord.self, from: data)
    }

    private func clearPersistedRecord() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
#endif
