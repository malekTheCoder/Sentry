import Foundation

#if os(macOS)

// MARK: - Readback verification (fan-control plan, bug fix)
//
// The spike (`docs/fan-control-spike.md`, item 4) named the fix and never
// implemented it: "Readback verification is straightforward: write
// `F{i}Tg`, poll `F{i}Ac`." Before this file existed, `SMCFanWriter
// .setTargetRPM` reported success purely from the SMC *accepting* the
// write command (`callSMC(request) != nil`) — never from the fan's actual
// speed moving. Four of seven competitor apps' top user complaint is
// exactly the gap that leaves open: `thermalmonitord` can re-assert
// protected mode and silently override a fan-control write a moment after
// the SMC accepted it, and an app that only checks acceptance reports
// success to the user regardless. This is a root-daemon, safety-relevant
// feature, so the two questions — "did the SMC take the write" and "did
// the fan's speed actually respond" — are kept as two distinct booleans
// all the way up, not merged into one.
//
// **Why this is a separate pure file rather than logic inlined in
// `SMCFanWriter`.** `SMCFanWriter` cannot be unit tested — every method
// that touches `connection` needs a real, opened SMC user client, which a
// test host does not have (see that file's header). The *decision* of
// whether a sequence of readback samples counts as "the fan moved" is,
// however, pure arithmetic over `Double`s, exactly like `FanDaemonClamp`'s
// clamp decision one file over — so it is factored out here where it can
// be exercised exhaustively without hardware, and `SMCFanWriter` becomes a
// thin caller that supplies real samples to it.

/// The outcome of one `setTargetRPM` write, reported as two independent
/// facts rather than one collapsed boolean.
///
/// **Why two booleans and not one.** `accepted` answers "did the SMC take
/// the write" — the only thing the pre-fix code checked. `applied`
/// answers "did the fan's actual RPM subsequently move toward the
/// target" — the thing a user actually cares about, and the thing
/// `thermalmonitord` can defeat *after* a write is accepted. Collapsing
/// them would make `accepted && !applied` — the exact "silently
/// overridden" failure mode market research named — indistinguishable
/// from either a clean success or an outright SMC refusal. Both matter and
/// both are reported.
public struct FanWriteVerification: Equatable, Sendable {
    /// Whether the SMC's `WRITE_BYTES` round trip for `F{i}Tg` succeeded.
    /// `false` means no readback was even attempted — there is nothing to
    /// verify a write that never happened.
    public var accepted: Bool

    /// Whether a bounded poll of `F{i}Ac` after the write saw the fan's
    /// actual RPM land within tolerance of the target, or move meaningfully
    /// toward it. Always `false` when `accepted` is `false`.
    ///
    /// **This is the bit that did not exist before this fix.** `accepted
    /// && !applied` is the "SMC said yes, thermalmonitord said no" case —
    /// see `FanDaemonService.setTarget`'s handling of it, which logs at
    /// fault level and reports the distinction to the client rather than
    /// letting it read as an ordinary success.
    public var applied: Bool

    /// The last readback sample taken during the poll window, if any. `nil`
    /// when `accepted` is `false`, or when every readback in the window
    /// failed to decode (a distinct, rarer failure from "read back a value
    /// far from target").
    public var finalRPM: Double?

    public init(accepted: Bool, applied: Bool, finalRPM: Double?) {
        self.accepted = accepted
        self.applied = applied
        self.finalRPM = finalRPM
    }

    /// The write never reached the SMC at all — the pre-fix failure path,
    /// still reachable when `writeKey` itself fails (keyinfo mismatch,
    /// closed connection, `WRITE_BYTES` refused).
    public static let notAccepted = FanWriteVerification(accepted: false, applied: false, finalRPM: nil)
}

/// Turns a target RPM plus a handful of post-write `F{i}Ac` samples into
/// the `applied` half of `FanWriteVerification`.
public enum FanDaemonReadback {

    /// How many samples `SMCFanWriter.setTargetRPM` takes after a write,
    /// and how far apart. Four samples 350 ms apart is ~1.05 s of polling
    /// after the initial (synchronous, effectively instant) write — inside
    /// the "a few reads across 1-2 seconds" window the spike's fix
    /// description calls for, long enough that a fan spinning from idle to
    /// a few thousand RPM has time to move, short enough that a client
    /// blocked on `setTarget`'s synchronous XPC call (see
    /// `PrivilegedFanControlBackend`'s "Synchronous XPC, deliberately" note)
    /// isn't left waiting on the main actor for many seconds over one
    /// slider drag.
    public static let sampleCount = 4

    /// Same units as `sampleCount`'s doc comment.
    public static let sampleInterval: TimeInterval = 0.35

    /// Tolerance band, in RPM, for "close enough to the target to count as
    /// applied." Fans don't hit an exact target instantly — the SMC's own
    /// actual-RPM reporting has quantization and sampling noise even at
    /// steady state — so an exact-equality check would report `applied:
    /// false` for every ordinary successful write. 150 rpm is small next to
    /// the spike's measured per-fan ranges (roughly 1200-6000 rpm) but
    /// comfortably above the noise floor a `flt ` SMC read exhibits in
    /// practice.
    public static let toleranceRPM: Double = 150

    /// Minimum movement, in RPM, toward the target required to count a
    /// readback that never entered the tolerance band as "applied anyway"
    /// (see `applied(target:initialRPM:samples:)`). Deliberately larger
    /// than `toleranceRPM` alone would allow as noise: half the tolerance
    /// band is the threshold below which a wobble in either direction could
    /// otherwise be read as forward progress.
    public static let minimumMovementRPM: Double = toleranceRPM / 2

    /// Whether a write to `target` counts as applied, given the fan's
    /// actual RPM immediately before the write (`initialRPM`, `nil` if
    /// unreadable) and the samples taken during the poll window afterward.
    ///
    /// Two ways to succeed:
    /// 1. **Any sample lands within `toleranceRPM` of `target`.** The
    ///    ordinary case — the fan reached (approximately) where it was
    ///    asked to go, at some point during the window.
    /// 2. **The last sample is meaningfully closer to `target` than
    ///    `initialRPM` was**, even if it never entered the tolerance band.
    ///    Apple Silicon fans ramp gradually (measured in the spike: 0 rpm
    ///    at idle), so a large jump — say 1200 -> 6000 — may still be
    ///    climbing when the poll window ends; refusing to credit visible
    ///    progress as "applied" would make every large request look like a
    ///    `thermalmonitord` override even when nothing is wrong. This path
    ///    requires `initialRPM` to be known, because "moved" is meaningless
    ///    without a baseline to move from.
    ///
    /// Anything else — no samples at all, or samples that neither reached
    /// the band nor moved meaningfully — is `false`, which is exactly the
    /// "accepted but not applied" signal `FanDaemonService.setTarget`
    /// surfaces distinctly rather than folding into a generic failure.
    public static func applied(target: Double, initialRPM: Double?, samples: [Double]) -> Bool {
        guard target.isFinite, !samples.isEmpty else { return false }

        if samples.contains(where: { abs($0 - target) <= toleranceRPM }) {
            return true
        }

        guard let initialRPM, initialRPM.isFinite, let lastSample = samples.last else {
            return false
        }
        let initialDistance = abs(initialRPM - target)
        let finalDistance = abs(lastSample - target)
        return (initialDistance - finalDistance) >= minimumMovementRPM
    }
}

#endif
