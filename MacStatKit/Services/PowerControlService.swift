import Foundation
import os

#if os(macOS)
import IOKit.pwr_mgt
import AppKit

/// The three sleep-prevention modes exposed to the UI (plan §10.1).
/// `assertionType` maps each case to the real `IOKit.pwr_mgt` assertion-type
/// constant `PowerControlService` passes to `IOPMAssertionCreateWithProperties`.
public enum AwakeMode: String, Codable, CaseIterable, Sendable {
    /// Screen stays on. Implies system stays awake too.
    case displayAndSystem
    /// System stays awake; display may sleep. Good for long downloads/builds.
    case systemOnly
    /// Prevent sleep only while on AC power (Apple's recommended type for this).
    case systemWhileOnAC

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
}

/// Wraps an `IOReturn` failure from `IOPMAssertionCreateWithProperties`.
public enum PowerControlError: Error, LocalizedError, Sendable {
    case assertionFailed(IOReturn)

    public var errorDescription: String? {
        switch self {
        case .assertionFailed(let code):
            return "Couldn't prevent sleep (IOKit error \(code))."
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

    private static let logger = Logger(subsystem: "dev.malekswilam.macstat.kit", category: "PowerControlService")
    private static let defaultsKey = "dev.malekswilam.macstat.powercontrol.state"

    @Published public private(set) var state: SleepAssertionState = .inactive

    private var assertionID: IOPMAssertionID = 0
    private var expiryTimer: Timer?

    /// The conditional trigger (if any) governing the current assertion, so
    /// `evaluate(_:)` and the app-termination observer know what to check,
    /// and so a future UI can ask "is there a pending conditional release
    /// and what is it."
    private var activeCondition: ReleaseCondition?

    /// First moment `.cpuAbovePercent`'s condition was observed true, for
    /// the "sustained" requirement. `nil` whenever the condition is not
    /// currently true (including "no condition set" / "no CPU sample yet").
    private var conditionSustainedSince: Date?

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

        // Sleep/wake destroys any live IOPMAssertion, and an app relaunch
        // starts with none either way — in both cases only our UserDefaults
        // bookkeeping survived, not the actual OS-level assertion. A
        // persisted "I was active" flag is a lie until the real assertion
        // exists again, so both paths re-create it (or clean up) rather than
        // trusting the flag at face value (plan §10.4's reconciliation
        // paragraph, which applies locally even without CloudKit).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconcilePersistedState() }
        }

        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in self?.handleAppTermination(bundleIdentifier: bundleID) }
        }

        reconcilePersistedState()
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
        state = .inactive
        persistState()
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
        }
    }

    // MARK: - Assertion creation (shared by both public entry points)

    private func startAssertionInternal(
        mode: AwakeMode,
        duration: TimeInterval?,
        reason: String,
        condition: ReleaseCondition?
    ) throws {
        releaseAssertion() // only ever one at a time

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
        activeCondition = condition
        conditionSustainedSince = nil

        let expiresAt: Date? = (duration.flatMap { $0 > 0 ? Date().addingTimeInterval($0) : nil })
        state = .active(mode: mode, expiresAt: expiresAt, reason: reason)

        if let duration, duration > 0 {
            // App-level mechanism #2 (see type doc): updates `state`
            // promptly while this process is alive, independent of the
            // OS-level timeout above.
            expiryTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.releaseAssertion() }
            }
        }

        persistState() // so we can restore across app relaunch (plan §10.2)
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
    /// (covers sleep/wake) — both destroy the previous OS-level assertion,
    /// so both need the same "recreate or clean up" handling.
    private func reconcilePersistedState() {
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
