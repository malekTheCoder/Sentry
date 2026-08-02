import Foundation
import os

/// The root daemon's implementation of `FanDaemonProtocol`, plus the
/// `NSXPCListener` delegate that decides who may speak to it.
///
/// **Everything this type does that could be dangerous is decided
/// elsewhere.** The clamp is `FanDaemonClamp.resolve`; the accept/reject
/// verdict is `FanDaemonPeerGate.decide`; when and what to revert is
/// `FanDaemonFailSafe`. All three are pure, live in `MacStatKit/FanDaemon/`,
/// and are unit-tested exhaustively. What is left here is the wiring: hold
/// the state, call the pure function, do what it said, log it. That is
/// deliberate — the wiring is the part that cannot be tested on a machine
/// where the daemon cannot be registered, so the wiring is kept as thin as
/// it can be made.
///
/// **Concurrency.** `NSXPCListener` delivers connections and messages on
/// queues of its own choosing, and the tick timer fires on another. All
/// mutable state (`failSafe`, `ranges`, `fanCount`) is confined to one
/// private serial queue and every entry point hops onto it first. This is
/// `StatsCoordinator`'s queue-confinement pattern rather than
/// `MCPXPCService`'s main-actor hop, because this process has no main actor
/// worth speaking of — it is a `dispatchMain()` daemon with no UI.
///
/// **One client at a time, and the newest wins.** `NSXPCListener` will
/// happily accept several connections. Two clients independently driving
/// one fan is a state nobody can reason about, and the fail-safe's
/// "everything held gets reverted" rule would make one client's disconnect
/// silently undo the other's settings. So a second accepted connection
/// invalidates the first. In practice there is only ever one Sentry.
final class FanDaemonService: NSObject, FanDaemonProtocol {

    private static let log = Logger(
        subsystem: FanDaemonNaming.label,
        category: "FanDaemonService"
    )

    private let queue = DispatchQueue(label: "\(FanDaemonNaming.label).state")
    private let writer: SMCFanWriter
    private let evaluator: FanDaemonPeerEvaluator
    private let startedAt: Date

    /// Read **once, at daemon start**, and never refreshed.
    ///
    /// Safety requirement 1 says the clamp bounds come from the SMC's own
    /// `F{i}Mn`/`F{i}Mx` read at daemon start, and "at start" is doing real
    /// work: re-reading them per request would mean a request could be
    /// clamped against a range that a *previous request from the same
    /// client* had influenced. The SMC's reported limits are not supposed
    /// to move, but "not supposed to" is not a property to hand a root
    /// process's only safety bound.
    private var ranges: [Int: FanRPMRange] = [:]
    private var fanCount: Int = 0

    private var failSafe: FanDaemonFailSafe

    private var activeConnection: NSXPCConnection?

    /// Set by `main.swift` so the tick timer's fail-safe can terminate the
    /// process. Injected rather than calling `exit()` directly so the exit
    /// path is visible at the top level of the program rather than buried
    /// in a method that mostly does other things.
    var onExitRequested: (() -> Void)?

    init(writer: SMCFanWriter, evaluator: FanDaemonPeerEvaluator, startedAt: Date = Date()) {
        self.writer = writer
        self.evaluator = evaluator
        self.startedAt = startedAt
        self.failSafe = FanDaemonFailSafe(startedAt: startedAt)
        super.init()
    }

    /// Reads `FNum` and the per-fan ranges. Called once before the listener
    /// is resumed, so no request can arrive before the clamp bounds exist —
    /// a request that arrived first would be refused with
    /// `.limitsUnreadable`, which would be a lie about the hardware.
    func probeHardware() {
        queue.sync {
            fanCount = writer.readFanCount() ?? 0
            ranges = writer.readRanges(fanCount: fanCount)
            Self.log.notice("Probed \(self.fanCount, privacy: .public) fan(s); usable ranges for \(self.ranges.keys.sorted().map(String.init).joined(separator: ", "), privacy: .public)")
        }
    }

    // MARK: - Periodic tick (heartbeat expiry / idle exit)

    /// Called on a timer from `main.swift`. The only thing that turns the
    /// passage of time into a revert.
    func tick(now: Date = Date()) {
        queue.async { [self] in
            guard let trigger = failSafe.dueTrigger(now: now) else { return }
            performRevert(for: trigger)
        }
    }

    // MARK: - FanDaemonProtocol

    func heartbeat(reply: @escaping (Double) -> Void) {
        let now = Date()
        queue.async { [self] in
            failSafe.heartbeat(at: now)
            reply(now.timeIntervalSince(startedAt))
        }
    }

    func describe(reply: @escaping (Data?, String?) -> Void) {
        let now = Date()
        queue.async { [self] in
            let fans = (0..<fanCount).map { index in
                FanDaemonDescription.Fan(
                    index: index,
                    minRPM: ranges[index]?.minRPM,
                    maxRPM: ranges[index]?.maxRPM,
                    isHeldByDaemon: failSafe.heldFans.contains(index)
                )
            }
            let description = FanDaemonDescription(
                fans: fans,
                uptimeSeconds: now.timeIntervalSince(startedAt)
            )
            do {
                reply(try JSONEncoder().encode(description), nil)
            } catch {
                // Encoding a struct of Ints and Doubles cannot realistically
                // fail, but replying `(nil, nil)` would leave the app unable
                // to tell "no fans" from "no answer" — the exact distinction
                // `FanControlCapability` exists to preserve.
                reply(nil, "The fan helper couldn't encode its reply: \(error.localizedDescription)")
            }
        }
    }

    func setTarget(fanIndex: Int, rpm: Double, reply: @escaping (Double, Bool, String?) -> Void) {
        let now = Date()
        queue.async { [self] in
            // A message is proof the client is alive, and the client is
            // required to send `heartbeat` anyway — but treating a real
            // command as a beat too closes a small window where a busy app
            // that is plainly working gets its fans taken away.
            failSafe.heartbeat(at: now)

            let outcome = FanDaemonClamp.resolve(
                rpm: rpm,
                forFan: fanIndex,
                ranges: ranges,
                knownFanCount: fanCount
            )

            switch outcome {
            case .refuse(let refusal):
                Self.log.error("Refused \(FanDaemonCommand.setTarget(fanIndex: fanIndex, requestedRPM: rpm).logSummary, privacy: .public): \(refusal.message, privacy: .public)")
                reply(-1, false, refusal.message)

            case .write(let clampedRPM, let wasClamped):
                // Order matters and is the reverse of the intuitive one.
                // `F{i}Md = 1` is recorded as held *before* the target
                // write is attempted, because a mode write that succeeds
                // followed by a target write that fails leaves the fan out
                // of firmware control — and a fan out of firmware control
                // that the fail-safe does not know about is the leak this
                // whole design exists to prevent. Reverting a fan we never
                // really took is harmless; failing to revert one we did is
                // not. See `FanDaemonFailSafe.heldFans`.
                if !failSafe.heldFans.contains(fanIndex) {
                    guard writer.setForcedMode(true, fan: fanIndex) else {
                        reply(-1, false, FanDaemonRefusal.smcWriteFailed(key: "F\(fanIndex)Md").message)
                        return
                    }
                    failSafe.noteHoldingFan(fanIndex)
                }

                guard writer.setTargetRPM(clampedRPM, fan: fanIndex) else {
                    // The target write failed while the fan is already out
                    // of firmware control. Do not leave it there: put it
                    // straight back and report the failure. This is the one
                    // place the daemon reverts without a trigger.
                    if writer.setForcedMode(false, fan: fanIndex) {
                        failSafe.noteReleasedFan(fanIndex)
                    }
                    reply(-1, false, FanDaemonRefusal.smcWriteFailed(key: "F\(fanIndex)Tg").message)
                    return
                }

                Self.log.notice("Applied \(Int(clampedRPM.rounded()), privacy: .public) rpm to fan \(fanIndex, privacy: .public)\(wasClamped ? " (clamped)" : "", privacy: .public)")
                reply(clampedRPM, wasClamped, nil)
            }
        }
    }

    func returnToFirmware(fanIndex: Int, reply: @escaping (Bool, String?) -> Void) {
        let now = Date()
        queue.async { [self] in
            failSafe.heartbeat(at: now)

            guard fanIndex >= 0, fanIndex < fanCount else {
                reply(false, FanDaemonRefusal.unknownFan(index: fanIndex).message)
                return
            }
            guard failSafe.heldFans.contains(fanIndex) else {
                // Idempotent by contract (see `FanDaemonProtocol`): the
                // firmware already has it, so "done" is the honest answer.
                reply(true, nil)
                return
            }
            guard writer.setForcedMode(false, fan: fanIndex) else {
                reply(false, FanDaemonRefusal.smcWriteFailed(key: "F\(fanIndex)Md").message)
                return
            }
            failSafe.noteReleasedFan(fanIndex)
            reply(true, nil)
        }
    }

    // MARK: - Reverting

    /// Writes `F{i}Md = 0` to every fan the trigger calls for, then exits
    /// if the trigger says to.
    ///
    /// **Must be called on `queue`** — it mutates `failSafe`. The one
    /// exception is `revertEverythingSynchronously`, below, which is the
    /// signal path and cannot use the queue at all.
    private func performRevert(for trigger: FanDaemonRevertTrigger) {
        let fans = failSafe.fansToRevert(on: trigger)
        Self.log.notice("\(FanDaemonFailSafe.logLine(for: trigger, fans: fans), privacy: .public)")

        for index in fans {
            if writer.setForcedMode(false, fan: index) {
                failSafe.noteReleasedFan(index)
            } else {
                // Logged loudly and *not* forgotten: the fan stays in
                // `heldFans`, so the next trigger tries again. Dropping it
                // would turn a transient SMC failure into a permanent leak.
                Self.log.fault("Failed to return fan \(index, privacy: .public) to firmware control; will retry on the next trigger.")
            }
        }

        if failSafe.shouldExit(after: trigger) {
            onExitRequested?()
        }
    }

    /// The signal path (`SIGTERM`, `SIGINT`, `SIGHUP`) and the `atexit`
    /// path.
    ///
    /// **Deliberately does not touch `queue`.** Dispatching work and then
    /// exiting is how a revert-on-quit silently never runs — the same
    /// failure `PowerControlService.deinit` documents refusing (a
    /// `queue.async` made as the process dies is a no-op that leaks the
    /// thing it was supposed to release). So this reads a snapshot of what
    /// is held and issues the writes inline on whatever thread called it.
    /// The race that buys — a concurrent `setTarget` could add a fan
    /// microseconds later — is real and is the lesser evil: the worst case
    /// is one fan left held by a process that is about to die, versus the
    /// alternative's guaranteed no-op.
    ///
    /// Note the dispatch-source caveat in `main.swift`: this runs from a
    /// `DispatchSourceSignal` handler, which is ordinary code on an
    /// ordinary thread, *not* a `signal(2)` handler — so it is allowed to
    /// allocate, log, and call IOKit. A raw `sa_handler` could do none of
    /// those, which is exactly why the daemon uses dispatch sources.
    func revertEverythingSynchronously(signal: Int32?) {
        let held = failSafe.heldFans.sorted()
        Self.log.notice("\(FanDaemonFailSafe.logLine(for: .daemonTerminating(signal: signal), fans: held), privacy: .public)")
        for index in held {
            _ = writer.setForcedMode(false, fan: index)
        }
    }
}

// MARK: - Listener delegate (safety requirement 3)

extension FanDaemonService: NSXPCListenerDelegate {

    /// The gate. Every connection to this root process passes through here
    /// and through `FanDaemonPeerGate.decide` before it is given an
    /// exported object.
    ///
    /// `SMAuthorizedClients` in the launchd plist means launchd has
    /// *already* filtered on the same requirement string before we see the
    /// connection. This check is the second half deliberately: a plist is
    /// data that can be edited, and a daemon whose only authorization lives
    /// in its configuration is one bad install away from accepting
    /// everything.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {

        let decision = FanDaemonPeerGate.decide(
            pid: newConnection.processIdentifier,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            evaluator: evaluator
        )

        guard case .accept = decision else {
            if case .reject(let failure) = decision {
                Self.log.fault("Refused an XPC connection from pid \(newConnection.processIdentifier, privacy: .public): \(failure.message, privacy: .public)")
            }
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: FanDaemonProtocol.self)
        newConnection.exportedObject = self

        let now = Date()
        newConnection.invalidationHandler = { [weak self] in
            self?.handleClientGone()
        }
        newConnection.interruptionHandler = { [weak self] in
            // Interruption means the client process died without a clean
            // teardown — the crash case. Treated identically to invalidation
            // rather than optimistically waiting for a reconnect: a crashed
            // app is precisely when the fans must go back.
            self?.handleClientGone()
        }

        queue.async { [self] in
            if let existing = activeConnection, existing !== newConnection {
                Self.log.notice("A second client connected; invalidating the previous one (see the type doc).")
                existing.invalidate()
            }
            activeConnection = newConnection
            failSafe.clientConnected(at: now)
        }

        newConnection.resume()
        Self.log.notice("Accepted a verified client connection from pid \(newConnection.processIdentifier, privacy: .public).")
        return true
    }

    private func handleClientGone() {
        let now = Date()
        queue.async { [self] in
            activeConnection = nil
            failSafe.clientDisconnected(at: now)
            performRevert(for: .clientDisconnected)
        }
    }
}
