import Foundation

#if os(macOS)

/// Why the daemon is about to hand fans back to the firmware.
///
/// Every case here is a *failure* path except `.clientAskedForFirmware`.
/// That ratio is the point: the daemon's normal state is "not controlling
/// anything", and holding a fan is a lease that expires by default rather
/// than a mode that persists until revoked.
public enum FanDaemonRevertTrigger: Equatable, Sendable {
    /// The XPC connection went away — the app quit, crashed, was killed, or
    /// the machine logged out. `NSXPCConnection`'s `invalidationHandler`
    /// fires for all of those.
    case clientDisconnected
    /// A client is still connected but has not sent a heartbeat inside
    /// `FanDaemonTiming.heartbeatTimeout`. Covers the case a disconnect
    /// does not: an app that is alive, connected, and wedged.
    case heartbeatExpired(silentFor: TimeInterval)
    /// The daemon itself is going away — `SIGTERM` from launchd on
    /// `bootout`, on shutdown, or on `SMAppService.unregister`.
    case daemonTerminating(signal: Int32?)
    /// No client has been connected at all for `idleExitAfter`. The daemon
    /// reverts and then exits. See this type's uninstall note.
    case idleWithNoClient(idleFor: TimeInterval)
    /// The ordinary, non-failure path: the user pressed Return to Auto.
    case clientAskedForFirmware
}

/// Safety requirement 4: **fail safe on every exit path.**
///
/// The pure state machine behind that requirement — which fans the daemon
/// currently holds, when it last heard from its client, and what it must
/// revert given a trigger and a clock. No IOKit, no XPC, no `Date()` it
/// wasn't handed, so every branch below is exercisable in a unit test on a
/// machine where the daemon cannot even be registered.
///
/// **The app-side watchdog is the weaker mechanism, and this is the
/// stronger one.** `PowerControlService`'s doc comment makes exactly this
/// argument about `IOPMAssertion`s: the app-level `Timer` only fires while
/// the app is alive, so the OS-level `kIOPMAssertionTimeoutKey` exists to
/// still protect the machine when it isn't. Fan control has the same shape
/// and a worse failure mode — a leaked sleep assertion means a Mac that
/// won't sleep; a leaked fan override means a Mac whose fans are pinned
/// (loud, or worse, pinned *low* while it heats up) with no process left
/// that knows it did that. So the revert logic lives in the process that
/// owns the hardware, and every one of the triggers above is wired to it in
/// `FanDaemonService`/`main.swift`. The app also asks politely on quit;
/// that is a courtesy, not the guarantee.
///
/// **What this cannot protect against, stated plainly.** `SIGKILL`. A
/// `kill -9` of the daemon, or a hard power loss, runs no handler of any
/// kind, and the fans stay wherever they were last written until something
/// else moves them. Two things bound the damage rather than eliminate it:
/// the SMC's own firmware takes back over on a power cycle (the `F{i}Md`
/// override does not survive one), and the daemon never writes a target
/// below the SMC's own `F{i}Mn`, so even a stuck override cannot park a fan
/// under the floor the firmware itself considers safe. Neither of those has
/// been observed on hardware from this branch — see `FanDaemonContract`.
///
/// **The uninstall story, which this type is most of.** `SMAppService
/// .unregister()` is only reached if the user removes the helper from
/// Sentry's Settings. A drag-to-Trash uninstall never calls it. What
/// actually happens then: launchd keeps the job registered but its program
/// path no longer exists, so it cannot be *started* again; a copy that
/// happened to be *running* at the moment of deletion keeps running as
/// root. That copy is exactly the leak this state machine bounds — with the
/// app gone, its client disconnects, `.clientDisconnected` reverts every
/// held fan, and `.idleWithNoClient` then exits the process after
/// `FanDaemonTiming.idleExitAfter`. The residue is a launchd job record
/// pointing at a missing binary, and a Login Items entry the user can
/// switch off. That is a real, honest residue and this branch does not
/// claim to remove it: see `docs/fan-control-spike.md` for the
/// `launchctl bootout` incantation that does.
public struct FanDaemonFailSafe: Equatable, Sendable {

    /// SMC ordinals the daemon has written `F{i}Md = 1` to and has not yet
    /// written `F{i}Md = 0` back on.
    ///
    /// A `Set`, and the daemon's *only* record of what it owes the machine.
    /// It is updated when a write succeeds, never when one is attempted:
    /// recording a fan as held after a failed `F{i}Md` write would make the
    /// daemon revert something it never took, which is harmless, while the
    /// reverse — recording only after both writes succeed, so a fan taken
    /// out of firmware control by a successful `F{i}Md` write but a failed
    /// `F{i}Tg` write goes unrecorded — is the one that leaks. Hence
    /// `noteHoldingFan` is called by the daemon immediately after the mode
    /// write lands, before the target write is attempted.
    public private(set) var heldFans: Set<Int> = []

    /// When the connected client last proved it was alive. `nil` means no
    /// client has ever checked in during this connection.
    public private(set) var lastHeartbeat: Date?

    /// When the last client disconnected (or the daemon started, if none
    /// ever connected). Drives `.idleWithNoClient`.
    public private(set) var clientAbsentSince: Date?

    /// Whether a client is currently connected. Tracked separately from
    /// `lastHeartbeat` because a freshly-connected client that has not yet
    /// sent its first beat must not immediately look expired.
    public private(set) var hasConnectedClient: Bool = false

    /// - Parameter startedAt: the daemon's own start time. Seeds
    ///   `clientAbsentSince` so a daemon that launches and is never dialed —
    ///   the shape a leaked daemon takes after the app is deleted — still
    ///   exits on schedule rather than living until reboot.
    public init(startedAt: Date) {
        self.clientAbsentSince = startedAt
    }

    // MARK: - Transitions

    public mutating func clientConnected(at now: Date) {
        hasConnectedClient = true
        clientAbsentSince = nil
        // A connection is itself proof of life; without this a client that
        // connects and takes 6 seconds to send its first heartbeat would be
        // judged against a `nil` last-beat.
        lastHeartbeat = now
    }

    public mutating func heartbeat(at now: Date) {
        // Deliberately accepted even with no recorded connection: the
        // daemon's `NSXPCListener` accepts a connection and the exported
        // object can receive a message before `clientConnected` has been
        // observed on some orderings. Treating an unexpected heartbeat as
        // proof of life is safe; ignoring one is not.
        lastHeartbeat = now
    }

    public mutating func clientDisconnected(at now: Date) {
        hasConnectedClient = false
        lastHeartbeat = nil
        clientAbsentSince = now
    }

    /// Records that `F{i}Md = 1` landed for this fan.
    public mutating func noteHoldingFan(_ index: Int) {
        heldFans.insert(index)
    }

    /// Records that `F{i}Md = 0` landed for this fan.
    public mutating func noteReleasedFan(_ index: Int) {
        heldFans.remove(index)
    }

    // MARK: - Decisions

    /// The trigger that fires *now*, if any, given only the passage of
    /// time. Called from the daemon's periodic tick.
    ///
    /// Ordered deliberately. Heartbeat expiry is checked before idle exit
    /// because a wedged-but-connected client must have its fans released
    /// promptly (15 s) rather than waiting out the 60 s idle window, and
    /// because the two are not mutually exclusive on a client that
    /// disconnects mid-tick.
    public func dueTrigger(
        now: Date,
        heartbeatTimeout: TimeInterval = FanDaemonTiming.heartbeatTimeout,
        idleExitAfter: TimeInterval = FanDaemonTiming.idleExitAfter
    ) -> FanDaemonRevertTrigger? {

        if hasConnectedClient, let lastHeartbeat {
            let silence = now.timeIntervalSince(lastHeartbeat)
            if silence >= heartbeatTimeout {
                return .heartbeatExpired(silentFor: silence)
            }
        }

        if !hasConnectedClient, let clientAbsentSince {
            let idle = now.timeIntervalSince(clientAbsentSince)
            if idle >= idleExitAfter {
                return .idleWithNoClient(idleFor: idle)
            }
        }

        return nil
    }

    /// Which fans must be written back to `F{i}Md = 0` for this trigger.
    ///
    /// Every trigger reverts **everything held**, not a subset, with one
    /// exception: `.clientAskedForFirmware` is the user's explicit,
    /// per-fan Return to Auto and is handled by the caller passing the one
    /// ordinal it means. There is no partial-revert failure path — a
    /// trigger that reverted "the fans this client took" would need to
    /// trust a client-supplied list on exactly the code path where the
    /// client has already proven unreliable.
    public func fansToRevert(on trigger: FanDaemonRevertTrigger) -> [Int] {
        switch trigger {
        case .clientDisconnected,
             .heartbeatExpired,
             .daemonTerminating,
             .idleWithNoClient:
            return heldFans.sorted()
        case .clientAskedForFirmware:
            return heldFans.sorted()
        }
    }

    /// Whether the daemon should terminate after acting on this trigger.
    ///
    /// Only `.idleWithNoClient` and `.daemonTerminating` exit. A heartbeat
    /// expiry or a disconnect reverts and keeps listening: the app may be
    /// relaunching, and a daemon that quit on every disconnect would be
    /// re-spawned by launchd on the next connection anyway — with a fresh
    /// SMC limits read each time, which is churn for no safety gain.
    public func shouldExit(after trigger: FanDaemonRevertTrigger) -> Bool {
        switch trigger {
        case .idleWithNoClient, .daemonTerminating:
            return true
        case .clientDisconnected, .heartbeatExpired, .clientAskedForFirmware:
            return false
        }
    }

    /// One line for the daemon's log, written *before* the reverts are
    /// attempted so a daemon that dies mid-revert still leaves evidence of
    /// what it was trying to do.
    public static func logLine(for trigger: FanDaemonRevertTrigger, fans: [Int]) -> String {
        let list = fans.isEmpty ? "no fans" : "fan(s) \(fans.map(String.init).joined(separator: ", "))"
        switch trigger {
        case .clientDisconnected:
            return "Client disconnected — returning \(list) to firmware control."
        case .heartbeatExpired(let silence):
            return "No heartbeat for \(String(format: "%.1f", silence))s — returning \(list) to firmware control."
        case .daemonTerminating(let signal):
            let cause = signal.map { "signal \($0)" } ?? "termination"
            return "Daemon exiting on \(cause) — returning \(list) to firmware control."
        case .idleWithNoClient(let idle):
            return "No client for \(String(format: "%.0f", idle))s — returning \(list) to firmware control and exiting."
        case .clientAskedForFirmware:
            return "Client asked for firmware control — returning \(list)."
        }
    }
}

#endif
