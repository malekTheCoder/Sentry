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
/// (`SentryKit/Models/AwakeMode.swift`) for why the enum had to move out of
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
/// options, later extended with two more — see below) — what elevates this
/// above a plain Caffeine clone. Evaluated one of three ways: by feeding live
/// `SystemSnapshot`s through `evaluate(_:)` (`.batteryBelowPercent`,
/// `.cpuAbovePercent`, `.whileProcessRunning`, `.whileDownloadActive`,
/// `.scheduledWindow` — everything that either rides the snapshot itself or
/// is cheap enough to poll on the same tick); by observing app-termination
/// notifications directly (`.whileAppRunning` — see `PowerControlService`'s
/// `NSWorkspace` observer); there is no third, timer-driven path — see
/// `.scheduledWindow`'s doc comment for why a dedicated `Timer` was
/// considered and rejected for it specifically.
///
/// **What's deliberately absent: "while the display is closed."** A
/// competitive review of keep-awake utilities flagged this as a gap, but
/// it is not one — a clamshell close is one of the two explicit exceptions
/// `PowerControlService`'s own type doc calls out ("none of the assertion
/// types used here override an explicit user Sleep ... or a clamshell
/// close. That's correct, intended OS behavior"). Implementing a trigger
/// whose entire purpose is to fight that OS behavior would mean acquiring a
/// `kIOPMAssertionTypePreventUserIdleDisplaySleep`-style assertion that
/// actively defeats clamshell sleep — the one keep-awake behavior this
/// codebase has already decided, deliberately, not to offer. Do not add it;
/// see the file-level type doc comment above `PowerControlService` before
/// reconsidering.
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

    /// Holds the assertion while `~/Downloads` has been written to within
    /// the last `idleTimeout` seconds — the competitive-parity trigger for
    /// "keep awake while a download is running."
    ///
    /// **Why a polled mtime heuristic, not a real download-completion
    /// signal.** There is no public, cross-browser API for "is a download in
    /// progress" — each browser (and CLI tool: `curl`, `git clone`, `scp`)
    /// tracks its own transfers privately. What every one of them shares is
    /// that a file actively downloading is a file whose modification time
    /// keeps advancing, written into (by convention) `~/Downloads`. So "any
    /// file under `~/Downloads` modified within the last few seconds" is the
    /// closest system-level proxy available, evaluated the same way
    /// `.whileProcessRunning` evaluates its libproc scan: polled per
    /// snapshot tick in `evaluate(_:)` via `PowerControlService.downloadProbe`,
    /// not a separate watcher.
    ///
    /// **Why polling, not `FSEventStream`.** `FSEventStream` would notify
    /// asynchronously on writes under `~/Downloads`, but it reports *paths*,
    /// not *timestamps* — turning an FSEvent into "was this modified in the
    /// last N seconds" still means `stat()`-ing the changed path afterward,
    /// so FSEvents buys asynchronous delivery at the cost of a second API
    /// surface (a dispatch-queue-driven C callback, run-loop scheduling,
    /// careful stream teardown in `deinit`) for a condition that's already
    /// being polled once per snapshot tick regardless, on the same cadence
    /// `.whileProcessRunning`'s full-machine `proc_listallpids` scan already
    /// rides. A `~/Downloads`-sized, non-recursive directory enumeration
    /// plus a handful of `contentModificationDate` reads is negligible next
    /// to that existing scan on the same tick, so there's no performance
    /// case for the heavier mechanism here — see
    /// `PowerControlService.mostRecentDownloadsModification(in:fileManager:)`.
    ///
    /// **The honest caveat.** This cannot distinguish a genuine in-progress
    /// download from a file in `~/Downloads` merely being edited, renamed
    /// into, or re-saved within the timeout window — the same spirit as
    /// `.whileProcessRunning`'s "exact name match, not a real identity
    /// check" caveat above. `~/Downloads` plus a very recent write is a
    /// reasonable proxy, not a certainty.
    ///
    /// Unlike `.whileProcessRunning`, there is no consecutive-miss grace
    /// window here: `idleTimeout` itself is already the slack (a brief pause
    /// between chunks reads as "still active" until the timeout elapses on
    /// its own), so stacking a second grace mechanism on top would only
    /// extend the hold well past the point the heuristic itself considers
    /// the download finished.
    case whileDownloadActive(idleTimeout: TimeInterval)

    /// Holds the assertion during a recurring day-of-week/time-of-day
    /// window — the competitive-parity "scheduled" trigger. `weekdays` uses
    /// `Calendar.Component.weekday`'s 1...7 (Sunday = 1) convention, matching
    /// `Calendar` itself rather than inventing a zero-based one. `startMinute`
    /// and `endMinute` are minutes after local midnight (0...1440), the same
    /// representation `AgentGuardrailSettings.quietHoursStartMinute`/
    /// `quietHoursEndMinute` use (`SentryKit/Services/AgentGuardrails.swift`)
    /// — chosen for the same reason: it's DST-proof (no `DateComponents`
    /// wall-clock-vs-absolute-time ambiguity to resolve) and round-trips
    /// through JSON with no `Calendar`/`TimeZone` riding along in `Codable`.
    /// `endMinute` may be `1440` to mean "through the end of the day" (a
    /// same-day window with no natural minute-1439 boundary to name, e.g. an
    /// all-day weekend schedule) — see
    /// `PowerControlService.isWithinScheduledWindow(weekdays:startMinute:endMinute:date:calendar:)`
    /// for the exact comparison, including midnight-crossing.
    ///
    /// **Why `evaluate(_:)`, not a dedicated `Timer`.** A schedule sounds
    /// timer-shaped — "fire an event at 22:00" — but what this condition
    /// actually needs checked is not an edge, it's a level: "is *now* inside
    /// the window," the same shape `.batteryBelowPercent` already polls off
    /// `snapshot.battery`. Arming a `Timer` for the next boundary would mean
    /// duplicating `expiryTimer`'s generation-guarded stale-fire protection
    /// (see `assertionGeneration`'s doc comment) for a second, independent
    /// timer with its own race between "fires" and "the main-actor task
    /// actually runs" — real complexity purchased for a case `evaluate(_:)`
    /// already handles for free on the tick cadence every other condition
    /// already pays for.
    case scheduledWindow(weekdays: Set<Int>, startMinute: Int, endMinute: Int)
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

    private static let logger = Logger(subsystem: "dev.malekswilam.sentry.kit", category: "PowerControlService")
    private static let defaultsKey = "dev.malekswilam.sentry.powercontrol.state"

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

    /// Injectable for tests — the default scans `~/Downloads` for its most
    /// recently modified file and checks it against `idleTimeout`. Called at
    /// most once per snapshot tick, and only while a `.whileDownloadActive`
    /// condition is armed, mirroring `processProbe`'s convention exactly
    /// (see `ReleaseCondition.whileDownloadActive`'s doc comment for why
    /// this is a poll rather than an `FSEventStream`).
    public var downloadProbe: (TimeInterval) -> Bool = { idleTimeout in
        PowerControlService.isDownloadActive(
            mostRecentModification: PowerControlService.mostRecentDownloadsModification(),
            idleTimeout: idleTimeout
        )
    }

    private var wakeObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    private let defaults: UserDefaults

    /// Small persisted record: everything needed to restore both the visible
    /// state and the conditional trigger across relaunch/wake.
    private struct PersistedRecord: Codable {
        var state: SleepAssertionState
        var condition: ReleaseCondition?

        /// `agentOwnership`'s `clientName`, persisted alongside `state` so a
        /// restore can re-tag the assertion it recreates rather than
        /// silently dropping the tag.
        ///
        /// **Why this field exists.** `agentOwnership` is keyed to
        /// `assertionGeneration`, and `reconcilePersistedState` restores a
        /// timed hold by calling `startAssertionInternal` — which bumps the
        /// generation, same as any other new assertion. Before this field
        /// existed, an agent-held timed hold that survived sleep/wake (or a
        /// cold-start relaunch) came back as a real `IOPMAssertion` with no
        /// owner: `agentAssertionOwner` returned `nil` for it, so the kill
        /// switch and `AgentGuardrails.autoRevocationReason` could no longer
        /// see it, revoke it, or attribute it — an agent hold invisible to
        /// every safety control built to police agent holds. Persisting the
        /// name (not just a "was agent-owned" bool) is what lets the restore
        /// re-tag the *same* owner, the same way `startAgentAssertion` tags
        /// a fresh one. See `reconcilePersistedState` and `adjustAssertion`
        /// for the two call sites that populate `agentOwnership` after a
        /// `startAssertionInternal` call and must re-persist afterward for
        /// this field to be correct — `startAssertionInternal` itself
        /// persists *before* either caller has had a chance to tag the new
        /// generation, so the first `persistState()` call always writes
        /// `nil` here for an agent-started or agent-adjusted assertion.
        var agentOwnerClientName: String?
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

    /// Like `startAssertion(mode:duration:reason:)`, but tags the resulting
    /// `AgentAwakeHold` ledger entry with `owner` — the agent-session ID
    /// (see `AgentSessionIdentity`) when the request came over MCP, so
    /// `AgentSessionReport.awakeSeconds` can attribute the held time to the
    /// session that asked for it. A separate overload rather than a default
    /// parameter on the existing method to keep this shared file's edits
    /// strictly additive for parallel branches.
    public func startAssertion(mode: AwakeMode, duration: TimeInterval?, reason: String, owner: String?) throws {
        try startAssertionInternal(mode: mode, duration: duration, reason: reason, condition: nil, owner: owner)
    }

    /// Conditional assertion — any `ReleaseCondition` (battery threshold,
    /// sustained CPU threshold, while a specific app or process runs, while a
    /// download is active, or on a schedule). Indefinite by construction —
    /// it's released when `condition` is satisfied, not on a timer. Feed live
    /// data via `evaluate(_:)` from the same `StatsCoordinator` stream
    /// everything else already consumes; `.whileAppRunning` is handled
    /// internally via an `NSWorkspace` termination observer instead — see
    /// `ReleaseCondition`'s own doc comment for exactly which conditions go
    /// through which path.
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
        closeOpenAwakeHold()
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
    /// **Ownership note.** `startAssertionInternal` is the plain internal
    /// path — it takes no `owner`/`clientName` and bumps
    /// `assertionGeneration` regardless of who is adjusting. Left alone,
    /// that means extending or truncating an *agent-held* assertion (the
    /// Mac dropdown's own extend button, or `LocalCommandExecutor`'s
    /// `extendAwake`/`truncateAwake`, reachable over MCP) would silently
    /// strip the `agentOwnership` tag: the new, bumped-generation assertion
    /// would have no owner, `agentAssertionOwner` would start returning
    /// `nil` for it, and the kill switch / `AgentGuardrails
    /// .autoRevocationReason` would lose the ability to see or release a
    /// hold that is, in fact, still agent-held — an orphaned hold the
    /// safety controls believe is untagged or user-owned. So the current
    /// owner (if any) is read *before* the adjustment and re-applied to the
    /// new generation after, mirroring what `startAgentAssertion` does for
    /// a fresh hold.
    public func adjustAssertion(bySeconds delta: TimeInterval) throws {
        guard case .active(let mode, let expiresAt, let reason) = state,
              let expiresAt,
              activeCondition == nil else {
            throw PowerControlError.noAdjustableAssertion
        }
        // Read before `startAssertionInternal` runs: it bumps
        // `assertionGeneration`, which would make this read `nil` (a stale
        // tag is "simply ignored", per `agentOwnership`'s doc comment) if
        // taken afterward instead.
        let owner = agentAssertionOwner
        let newRemaining = expiresAt.timeIntervalSinceNow + delta
        guard newRemaining > 0 else {
            releaseAssertion()
            return
        }
        try startAssertionInternal(mode: mode, duration: newRemaining, reason: reason, condition: nil)
        if let owner {
            agentOwnership = (assertionGeneration, owner)
            // `startAssertionInternal` already persisted once, before this
            // line could tag the new generation — see `PersistedRecord
            // .agentOwnerClientName`'s doc comment. Re-persist so a
            // relaunch or wake immediately after an extend/truncate
            // restores the hold *with* its owner instead of racing this
            // method.
            persistState()
        }
    }

    /// Feeds a fresh `SystemSnapshot` from the app's single poll loop (plan
    /// §3.2 P3 — this service doesn't own or create that stream) so every
    /// `ReleaseCondition` except `.whileAppRunning` can be checked —
    /// `.batteryBelowPercent` and `.cpuAbovePercent` read straight off the
    /// snapshot, `.whileProcessRunning` and `.whileDownloadActive` piggyback
    /// on the same tick with their own polls (libproc, `~/Downloads` mtime
    /// scan respectively), and `.scheduledWindow` just checks wall-clock time
    /// against the window on the same cadence. A no-op unless a conditional
    /// assertion is currently active. `.whileAppRunning` isn't evaluated here
    /// — there's nothing on a `SystemSnapshot` to check it against — it's
    /// handled by the `NSWorkspace` termination observer registered in
    /// `init`.
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

        case .whileDownloadActive(let idleTimeout):
            // No miss-count grace, deliberately — see
            // `ReleaseCondition.whileDownloadActive`'s doc comment for why:
            // `idleTimeout` is already the slack this condition gets.
            if !downloadProbe(idleTimeout) {
                releaseAssertion()
            }

        case .scheduledWindow(let weekdays, let startMinute, let endMinute):
            if !Self.isWithinScheduledWindow(
                weekdays: weekdays,
                startMinute: startMinute,
                endMinute: endMinute,
                date: Date(),
                calendar: .current
            ) {
                releaseAssertion()
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

    /// Every distinct executable name currently on the process table, in the
    /// exact spelling `isProcessRunning(named:)` matches against, sorted
    /// case-insensitively. Backs the keep-awake card's Process *picker* — the
    /// list of names a `.whileProcessRunning` hold can actually be armed with.
    ///
    /// **Why this lives next to `isProcessRunning(named:)` rather than being
    /// derived from `ProcessCollector`.** These two functions have to agree or
    /// the UI ships a menu whose items fail their own arm-time validation:
    /// the picker offers a name, `start()` calls `isProcessRunning(named:)` on
    /// it, and a disagreement between the two enumerations reads to the user
    /// as "the dropdown listed it and then said it isn't running." So this is
    /// deliberately the *same* scan — same `proc_listallpids`, same
    /// `proc_name`, same 128-byte name buffer (`ProcessCollector` uses
    /// `MAXCOMLEN * 2 + 1`, which truncates longer names differently), same
    /// case-insensitive identity — with the early-exit-on-match removed and
    /// the names collected instead of compared. Agreement by construction,
    /// not by two implementations happening to line up.
    ///
    /// **Why not `ProcessCollector`/`ProcessMonitor`/`SystemSnapshot
    /// .topProcesses` at all.** All three are ranked and *capped* — top-N by
    /// CPU — and `ProcessCollector`'s own doc comment states the exact reason
    /// that disqualifies them here: "`claude` at 0.2% CPU is exactly the row
    /// that never makes a top-8 cut." The dropdown's instance is capped at
    /// `limit: 3`. A picker built on any of them would omit precisely the
    /// idle-but-long-running agent process this trigger was built for.
    /// `ProcessCollector` additionally lives in SystemMetricsKit, which
    /// depends on SentryKit rather than the other way round, so this file
    /// could not call it even if the cap weren't disqualifying.
    ///
    /// De-duplicated case-insensitively, keeping the first spelling
    /// encountered: a name like `mdworker_shared` can hold a dozen PIDs at
    /// once, and a picker that lists it a dozen times is noise. Returns an
    /// empty array (not an error) when the scan finds nothing — callers are
    /// expected to treat that as "no list available" and fall back, the same
    /// honest-nil posture `mostRecentDownloadsModification` takes.
    public nonisolated static func runningProcessNames() -> [String] {
        let expected = proc_listallpids(nil, 0)
        guard expected > 0 else { return [] }
        // Same headroom-for-races convention as `isProcessRunning(named:)`.
        var pids = [pid_t](repeating: 0, count: Int(expected) + 32)
        let filled = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard filled > 0 else { return [] }

        var seen = Set<String>()
        var names: [String] = []
        var nameBuffer = [CChar](repeating: 0, count: 128)
        for index in 0..<Int(filled) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            let length = nameBuffer.withUnsafeMutableBufferPointer { pointer in
                proc_name(pid, pointer.baseAddress, UInt32(pointer.count))
            }
            guard length > 0 else { continue }
            let name = String(cString: nameBuffer)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Pure comparison: given the most recent modification time found under
    /// `~/Downloads` (or `nil` when the directory is empty, missing, or
    /// unreadable), is a download "active" under `.whileDownloadActive`'s
    /// heuristic? Split out from `mostRecentDownloadsModification(in:fileManager:)`
    /// specifically so this decision — "is `mostRecentModification` within
    /// `idleTimeout` of `now`" — is unit-testable with a fabricated clock and
    /// a fabricated timestamp, with no real filesystem access involved. The
    /// directory scan itself is *not* meaningfully unit-testable — it depends
    /// on real write activity in a real `~/Downloads`, which a test can't
    /// fabricate deterministically — so it's exercised only by the smoke-style
    /// checks `isProcessRunning`'s tests already model for the equivalent
    /// libproc scan, not asserted against here.
    public nonisolated static func isDownloadActive(
        mostRecentModification: Date?,
        idleTimeout: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        guard let mostRecentModification else { return false }
        return now.timeIntervalSince(mostRecentModification) <= idleTimeout
    }

    /// Scans `directory` (default `~/Downloads`) non-recursively for the most
    /// recent `contentModificationDate` among its entries — the mtime feed
    /// for `isDownloadActive(mostRecentModification:idleTimeout:now:)`.
    /// Non-recursive on purpose: a download in progress writes directly into
    /// `~/Downloads`, and chasing every user-configured subfolder would widen
    /// this from "a reasonable proxy" (see `ReleaseCondition
    /// .whileDownloadActive`'s doc comment) toward false positives from
    /// unrelated file activity elsewhere in the tree. Returns `nil` (not an
    /// error) for a missing/unreadable directory or one with no readable
    /// entries — `isDownloadActive` already treats `nil` as "not active,"
    /// which is the correct read of "we couldn't find evidence of a
    /// download," not "assume one is happening."
    public nonisolated static func mostRecentDownloadsModification(
        in directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Date? {
        let downloadsURL = directory ?? fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard let downloadsURL,
              let items = try? fileManager.contentsOfDirectory(
                  at: downloadsURL,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else { return nil }
        return items.compactMap { url -> Date? in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.max()
    }

    /// Whether `date` falls inside a `.scheduledWindow` — see that case's
    /// doc comment for the representation. Start-inclusive, end-exclusive
    /// (`[startMinute, endMinute)`), matching `AgentGuardrails
    /// .isWithinQuietHours`'s convention exactly, extended with a weekday
    /// set that quiet hours didn't need. `nonisolated static` and pure (no
    /// `Date()`/`Calendar.current` defaults) for the same reason
    /// `AgentGuardrailsTests` pins `isWithinQuietHours` down with a fixed
    /// calendar and fabricated dates rather than the real clock — see
    /// `PowerControlServiceTests`' schedule tests, which mirror that pattern.
    ///
    /// **Midnight-crossing weekday handling.** When `startMinute > endMinute`
    /// (the window crosses midnight, e.g. Fri 22:00–Sat 07:00), the tail of
    /// the window on the *following* calendar day still belongs to the
    /// *starting* day's weekday — the window is "Friday night," not
    /// "Friday, then separately, unrelated Saturday morning." So a moment at
    /// 03:00 on Saturday is inside the window only if `weekdays` contains
    /// *Friday* (`date`'s weekday minus one, wrapping 1...7). A same-day
    /// window (`startMinute < endMinute`) has no such ambiguity: `date`'s own
    /// weekday is checked directly. `startMinute == endMinute` is a
    /// zero-length window (never active) and an empty `weekdays` set is
    /// never active either, both mirroring `isWithinQuietHours`'s
    /// `start == end` guard.
    public nonisolated static func isWithinScheduledWindow(
        weekdays: Set<Int>,
        startMinute: Int,
        endMinute: Int,
        date: Date,
        calendar: Calendar
    ) -> Bool {
        guard startMinute != endMinute, !weekdays.isEmpty else { return false }
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday else { return false }
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)

        if startMinute < endMinute {
            return weekdays.contains(weekday) && minute >= startMinute && minute < endMinute
        }
        // Crosses midnight — see the doc comment above.
        let previousWeekday = weekday == 1 ? 7 : weekday - 1
        return (weekdays.contains(weekday) && minute >= startMinute)
            || (weekdays.contains(previousWeekday) && minute < endMinute)
    }

    // MARK: - Assertion creation (shared by both public entry points)

    private func startAssertionInternal(
        mode: AwakeMode,
        duration: TimeInterval?,
        reason: String,
        condition: ReleaseCondition?,
        owner: String? = nil
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
        openAwakeHold(owner: owner)

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
    ///   next launch (and Sentry is a login item, so "next launch" is
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
                // Same drift `adjustAssertion` fixes, on the restore path:
                // `startAssertionInternal` bumped `assertionGeneration`, so
                // without this the restored hold would come back live but
                // untagged even though the record says exactly who owned
                // it. Re-persisting keeps a *second* restore (wake, then a
                // crash before the next real state change) reading the
                // same owner rather than racing this method the way an
                // un-re-persisted `adjustAssertion` would.
                if let owner = record.agentOwnerClientName {
                    agentOwnership = (assertionGeneration, owner)
                    persistState()
                }
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
        let record = PersistedRecord(
            state: state,
            condition: activeCondition,
            agentOwnerClientName: agentAssertionOwner
        )
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

    // MARK: - Awake-hold ledger (agent-session attribution pass)

    /// Every assertion interval this process has held, tagged with the
    /// requesting session when the request came over MCP — the data source
    /// for `AgentSessionReport.awakeSeconds` ("how long did *that* agent
    /// session keep this Mac awake"). At most one entry is open (`end ==
    /// nil`) at a time, mirroring the "at most one live assertion" invariant
    /// this whole type is built around. In-memory only, deliberately — see
    /// `AgentAwakeHold`'s doc comment
    /// (`SentryKit/Services/AgentSessionReport.swift`) for why a durable
    /// ledger would overclaim.
    public private(set) var awakeHolds: [AgentAwakeHold] = []

    /// Closed holds retained before the oldest are dropped — bounds memory
    /// for a machine that toggles keep-awake constantly for months. Far more
    /// than any dashboard window or session report will ever look back at
    /// within one app run.
    private static let maxAwakeHoldEntries = 512

    /// Called from `startAssertionInternal` immediately after `state` flips
    /// to `.active`. The `releaseAssertion()` at the top of
    /// `startAssertionInternal` has already closed any previous hold, so
    /// appending here can never leave two open entries.
    private func openAwakeHold(owner: String?) {
        awakeHolds.append(AgentAwakeHold(owner: owner, start: Date(), end: nil))
        if awakeHolds.count > Self.maxAwakeHoldEntries {
            awakeHolds.removeFirst(awakeHolds.count - Self.maxAwakeHoldEntries)
        }
    }

    /// Called from `releaseAssertion()` — which is the single funnel every
    /// teardown path (manual release, expiry timer, condition satisfied,
    /// reconciliation, replacement by a new assertion) already goes through,
    /// so no separate hook per path is needed. Idempotent, like
    /// `releaseAssertion()` itself: a no-op when no hold is open.
    private func closeOpenAwakeHold() {
        guard let lastIndex = awakeHolds.indices.last, awakeHolds[lastIndex].end == nil else { return }
        let open = awakeHolds[lastIndex]
        awakeHolds[lastIndex] = AgentAwakeHold(owner: open.owner, start: open.start, end: Date())
    }

    // MARK: - Agent-held assertion ownership (additive — see AgentGuardrails)

    /// Which MCP client (self-reported name — a label, not a verified
    /// identity; see `AgentGuardrailSettings`'s trust note) started the
    /// current assertion, tagged with the `assertionGeneration` it belongs
    /// to. The generation tag is what keeps this additive: `releaseAssertion`
    /// and a genuinely new, user-initiated `startAssertion`/
    /// `startConditionalAssertion` stay untouched, because a stale tag is
    /// simply *ignored* — `agentAssertionOwner` below only honors it while
    /// that exact generation's assertion is still the live one.
    ///
    /// **This is not, on its own, enough to keep the tag attached.**
    /// `startAssertionInternal` bumps `assertionGeneration` on *every*
    /// successful call, including the ones `adjustAssertion` and
    /// `reconcilePersistedState` make to extend/truncate or restore an
    /// already-agent-owned hold — calls that are not "a new, user-initiated
    /// start" in the sense above, but that go through the exact same
    /// generation-bumping path. Left alone, that silently detaches the tag
    /// from a hold that never actually changed hands (the bug this file's
    /// history calls "ownership drift"). Both of those call sites now read
    /// the current owner *before* calling `startAssertionInternal` and
    /// re-apply it to the new generation after — the same pattern
    /// `startAgentAssertion` uses for a fresh hold — so an earlier version
    /// of this comment's implication that the generation tag alone
    /// prevents drift was not accurate; the tag prevents a *stale* owner
    /// from sticking to a *different* assertion, but preserving a *live*
    /// owner across an adjustment or a restore is each call site's own
    /// responsibility, done explicitly. See `PersistedRecord
    /// .agentOwnerClientName` for the matching persistence-side fix.
    private var agentOwnership: (generation: UInt64, clientName: String)?

    /// The client name holding the current assertion, or `nil` when no
    /// assertion is active, the active one wasn't started by an agent, or an
    /// agent's assertion has since been replaced by a user-started one
    /// (which bumps `assertionGeneration`, invalidating the tag).
    public var agentAssertionOwner: String? {
        guard let agentOwnership,
              agentOwnership.generation == assertionGeneration,
              state != .inactive else { return nil }
        return agentOwnership.clientName
    }

    /// `startAssertion(mode:duration:reason:)` plus ownership tagging — the
    /// entry point `MCPXPCService.keepAwake` uses so the kill switch and
    /// guardrail auto-revocation can tell an agent's hold from the user's
    /// own. Tags only when an assertion actually came up (a zero-length
    /// request is a documented no-op in `startAssertionInternal`).
    /// `sessionID` additionally tags the awake-hold ledger entry (see
    /// `openAwakeHold`), so the same call feeds both consumers of ownership:
    /// the kill switch / guardrails (by client name, this section) and
    /// `AgentSessionReport`'s held-time attribution (by session, the ledger
    /// section above). One entry point, two tags, no way for them to drift.
    public func startAgentAssertion(
        mode: AwakeMode,
        duration: TimeInterval?,
        reason: String,
        clientName: String,
        sessionID: String? = nil
    ) throws {
        try startAssertion(mode: mode, duration: duration, reason: reason, owner: sessionID)
        if state != .inactive {
            agentOwnership = (assertionGeneration, clientName)
            // `startAssertion` → `startAssertionInternal` already persisted
            // once, before this line existed to tag the new generation —
            // see `PersistedRecord.agentOwnerClientName`'s doc comment.
            // Re-persisting closes the same race `adjustAssertion` and
            // `reconcilePersistedState` close: without it, a crash or
            // relaunch in the instant between those two calls would
            // restore this hold with no owner.
            persistState()
        }
    }

    /// Releases the current assertion only if an agent holds it — and, when
    /// `clientName` is given, only if *that* agent holds it. Returns whether
    /// anything was released, so callers (kill switch, per-agent stop,
    /// guardrail auto-revoke) can decide whether there is a revocation to
    /// announce. A user-started assertion is never touched by this method:
    /// terminating agents must not cost the user their own hold.
    @discardableResult
    public func releaseAgentAssertion(ownedBy clientName: String? = nil) -> Bool {
        guard let owner = agentAssertionOwner else { return false }
        if let clientName, owner != clientName { return false }
        releaseAssertion()
        return true
    }
}
#endif
