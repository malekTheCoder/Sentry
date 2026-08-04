import Foundation

#if os(macOS)

/// The complete XPC surface of the privileged fan daemon.
///
/// **Four methods. That is the entire attack surface of a root process,
/// and keeping it four is a safety requirement, not tidiness** (see
/// `FanDaemonCommand`). Note what is not here and must never be: no method
/// takes an SMC key name, a byte payload, a file path, a command line, or a
/// range. `setTarget` takes a fan ordinal and an RPM, both of which the
/// daemon re-validates against limits it read itself
/// (`FanDaemonClamp.resolve`); `returnToFirmware` takes only an ordinal;
/// `describe` and `heartbeat` take nothing at all. There is no way to
/// express "write this value to that key" through this protocol, so a
/// client that fully compromises the connection still cannot reach an
/// arbitrary SMC register.
///
/// **Shape follows `SentryXPCServiceProtocol`, for the same reasons.**
/// `NSXPCConnection` requires an `@objc` protocol, so: no `throws`, no
/// Swift enums or structs across the boundary, and every method replies
/// through a block carrying either a value or a human-readable failure
/// string. `describe` returns JSON `Data` (a `Codable`
/// `FanDaemonDescription`) rather than a pile of `@objc` out-parameters,
/// exactly as the MCP protocol encodes its payloads.
///
/// **The reply strings are for people, not for parsing.** The app renders
/// them; it never branches on their contents. Every decision the app makes
/// about the daemon is encoded in `FanWriteAvailability`, derived from
/// `SMAppService.Status` and from whether a call succeeded — never from the
/// wording of a message. A client that parsed the daemon's prose would be
/// one copy-edit away from a behavior change.
@objc public protocol FanDaemonProtocol {

    /// Reachability plus liveness, in one call.
    ///
    /// **This is the heartbeat** (safety requirement 4), not merely a
    /// handshake: every call resets the daemon's silence timer, and a
    /// client that holds a fan must call it at least every
    /// `FanDaemonTiming.heartbeatInterval` seconds or the daemon hands the
    /// fans back after `FanDaemonTiming.heartbeatTimeout`. Merging the two
    /// is deliberate — a separate `ping` that did not reset the timer would
    /// be a call that proves the app is alive while letting the fail-safe
    /// fire anyway, and the first bug report would be "my fans randomly
    /// revert while Sentry is clearly running."
    ///
    /// - Parameter reply: the daemon's uptime in seconds, purely so a
    ///   support log can distinguish "the daemon restarted under you" from
    ///   "the daemon has been up the whole time."
    func heartbeat(reply: @escaping (Double) -> Void)

    /// Fan count, per-fan hardware range as the *daemon* read it, and which
    /// fans the daemon currently holds. JSON-encoded `FanDaemonDescription`.
    ///
    /// The app already has its own read of the same SMC keys through
    /// `SMCFanBridge`, and deliberately does not replace it with this one:
    /// two surfaces showing two independently-sampled RPMs for one fan is
    /// the disagreement `FanControlService.ingest` was written to prevent.
    /// What this call is *for* is the daemon's view of what it is holding,
    /// which the app cannot know any other way — in particular after an app
    /// relaunch, where the daemon may still be holding fans the new process
    /// has no memory of taking.
    func describe(reply: @escaping (Data?, String?) -> Void)

    /// Requests a fixed target for one fan.
    ///
    /// The daemon clamps `rpm` to its own startup read of `F{i}Mn`/`F{i}Mx`
    /// and reports the value it actually wrote, which may differ from the
    /// request. It is not an error for them to differ; the app surfaces the
    /// difference (`FanTargetResolution.wasClamped` has carried this
    /// concept since Phase 2).
    ///
    /// **`verifiedApplied` is not the same question as "did the call
    /// succeed."** The SMC accepting `WRITE_BYTES` (which is what
    /// `writtenRPM >= 0` and a `nil` `failureMessage` mean) only proves the
    /// write reached the SMC — `thermalmonitord` can silently re-assert
    /// protected mode and override it a moment later, which is the exact
    /// failure four of seven competitor apps' users report most. So the
    /// daemon also polls `F{i}Ac` after the write (`SMCFanWriter
    /// .setTargetRPM`, `FanDaemonReadback`) and reports whether the fan's
    /// actual speed was observed moving toward the target. A call can
    /// succeed (`failureMessage == nil`) with `verifiedApplied == false`;
    /// that combination is the "SMC said yes, thermalmonitord said no"
    /// case, and it is a distinct outcome from either an ordinary success
    /// or an outright refusal — never collapsed into `failureMessage` to
    /// keep it from being treated as one more `helperRefused` string.
    ///
    /// - Parameter reply: `(writtenRPM, wasClamped, verifiedApplied,
    ///   failureMessage)`. `writtenRPM` is `-1` when the call failed, and
    ///   the app checks `failureMessage` first rather than sniffing that
    ///   sentinel — an `@objc` reply block cannot carry an optional
    ///   `Double`, and a sentinel nobody is required to notice is how a
    ///   failure becomes a silently-wrong reading. `verifiedApplied` is
    ///   always `false` when `writtenRPM` is `-1`.
    func setTarget(fanIndex: Int, rpm: Double, reply: @escaping (Double, Bool, Bool, String?) -> Void)

    /// Hands one fan back to the firmware (`F{i}Md = 0`) — plan §8's
    /// mandatory escape hatch, at the layer that can actually perform it.
    ///
    /// Idempotent: reverting a fan the daemon does not hold succeeds and
    /// writes nothing, because the honest answer to "give this fan back to
    /// the firmware" when the firmware already has it is "done", not an
    /// error the UI would have to explain.
    func returnToFirmware(fanIndex: Int, reply: @escaping (Bool, String?) -> Void)
}

/// What `describe` returns. `Codable` and JSON over the wire, matching
/// `MCPPayloads`' convention for everything that crosses this app's XPC
/// boundaries.
public struct FanDaemonDescription: Codable, Equatable, Sendable {

    /// One fan as the daemon sees it. `minRPM`/`maxRPM` are optional
    /// *together and independently* of each other's presence for the same
    /// reason `SMCFanBridge.FanHardwareDescription`'s fields are: a Mac
    /// that answers `F0Ac` but not `F0Mx` is a real possibility, and the
    /// daemon reports what it read rather than filling a gap.
    ///
    /// A fan with no usable range appears here **and** is refused by
    /// `FanDaemonClamp` — visible, and unwritable. Omitting it would hide a
    /// fan the user can see spinning in the same window.
    public struct Fan: Codable, Equatable, Sendable {
        public var index: Int
        public var minRPM: Double?
        public var maxRPM: Double?
        /// Whether the daemon currently holds this fan out of firmware
        /// control.
        public var isHeldByDaemon: Bool

        public init(index: Int, minRPM: Double?, maxRPM: Double?, isHeldByDaemon: Bool) {
            self.index = index
            self.minRPM = minRPM
            self.maxRPM = maxRPM
            self.isHeldByDaemon = isHeldByDaemon
        }
    }

    public var fans: [Fan]
    /// Seconds since the daemon started. See `heartbeat`.
    public var uptimeSeconds: Double

    public init(fans: [Fan], uptimeSeconds: Double) {
        self.fans = fans
        self.uptimeSeconds = uptimeSeconds
    }
}

#endif
