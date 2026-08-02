import Foundation

#if os(macOS)

/// One fan's RPM range as the *daemon* knows it, read from the SMC's own
/// `F{i}Mn`/`F{i}Mx` keys at daemon start.
///
/// **Why this is not `FanHardwareLimits`.** It is the same two numbers, and
/// duplicating a type is normally the wrong instinct. Two reasons override
/// that here. First, compile surface: `FanHardwareLimits` lives in
/// `MacStatKit/Models/FanControl.swift` alongside `FanControlResolver`,
/// which references `ThermalStats`, which pulls a large part of the model
/// layer into whatever compiles it — and the thing that would be compiling
/// it is a process running as root (see `FanDaemonContract`'s header on
/// keeping the daemon's compile surface tiny). Second, and more
/// importantly, provenance: a `FanHardwareLimits` in the app may have come
/// from a `settings.json` a user hand-edited, from a decoded snapshot, or
/// from hardware. A `FanRPMRange` only ever comes from an SMC read
/// performed by the daemon itself, in the daemon's own process, at daemon
/// start. Keeping the types distinct is what makes "the daemon clamps
/// against hardware, never against a number a client sent" a statement the
/// type system helps enforce rather than a comment.
public struct FanRPMRange: Equatable, Sendable {
    public var minRPM: Double
    public var maxRPM: Double

    public init(minRPM: Double, maxRPM: Double) {
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }

    /// Deliberately strict, and deliberately *not* self-repairing.
    ///
    /// An inverted pair (`min > max`) is rejected rather than swapped. A
    /// swap would turn a malfunctioning or misdecoded SMC read into a
    /// plausible-looking range that the daemon would then clamp real writes
    /// against — precisely the "fabricated number aimed at the hardware"
    /// the rest of this feature refuses. `minRPM == maxRPM` *is* valid: a
    /// single-speed fan is a real thing and clamps to exactly one value.
    ///
    /// The upper bound matches `SMCFanBridge.plausibleRPM`. A range whose
    /// ceiling decodes as 4 × 10³⁸ is a misread float, not a discovery.
    public var isUsable: Bool {
        minRPM.isFinite
            && maxRPM.isFinite
            && minRPM >= 0
            && minRPM <= maxRPM
            && maxRPM <= FanRPMRange.plausibleCeiling
    }

    /// No Mac fan has ever run at 20 000 rpm; anything above it is a
    /// decoding error. Same constant, same reasoning, as the read-only
    /// bridge's own plausibility filter.
    public static let plausibleCeiling: Double = 20_000
}

/// What the daemon decided to do with one client request.
public enum FanClampOutcome: Equatable, Sendable {
    /// Write this RPM. `wasClamped` is reported (and logged, and returned
    /// to the client) rather than swallowed: a user who asked for 8 000 rpm
    /// on a fan that tops out at 6 241 must be told, not left believing the
    /// number they typed is in effect.
    case write(rpm: Double, wasClamped: Bool)
    /// Write nothing. There is no "write something sensible instead" branch
    /// — every path that cannot produce a hardware-bounded number refuses.
    case refuse(FanDaemonRefusal)
}

/// Safety requirement 1: **the clamp lives in the daemon.**
///
/// The app clamps too — `FanControlResolver.applyLimits` has since Phase 2,
/// and `FanControlPane` will not let a slider past the hardware range. That
/// is a usability measure, and it is worth exactly nothing as a safety
/// measure. App-side clamping asks the caller to police itself; if the app
/// is compromised, or replaced, or simply wrong, an unclamped RPM arrives
/// at a root process that writes it to hardware. So the daemon re-derives
/// the bound from its *own* SMC read, performed in its own process at
/// startup, and applies it to every request regardless of what the client
/// claims the limits are. A client cannot send limits; there is no
/// parameter for them anywhere in `FanDaemonProtocol`.
///
/// **Why refusing beats clamping when the range is unknown.** The obvious
/// alternative — "no readable limits, so write the request through
/// unchanged" — is the single most dangerous line this feature could
/// contain: it makes an unreadable SMC into a bypass for the entire clamp.
/// `FanHardwareLimits.clamp(_:)` in the app layer *does* pass the value
/// through when limits are invalid, and that is correct *there*, because
/// nothing in the app can write. Here the same behavior would be a hole,
/// which is why this is a separate function and not a call into that one.
public enum FanDaemonClamp {

    /// Resolves one `setTarget` request against the daemon's own measured
    /// ranges.
    ///
    /// - Parameters:
    ///   - rpm: exactly what the client asked for, unmodified.
    ///   - index: the SMC fan ordinal the client named.
    ///   - ranges: the daemon's startup read of `F{i}Mn`/`F{i}Mx`, keyed by
    ///     ordinal. A fan the daemon never successfully read is *absent*
    ///     from this dictionary, which is how "no such fan" and "that fan's
    ///     range wouldn't read" stay distinguishable — see `refusal` below.
    ///   - knownFanCount: how many fans the SMC reported (`FNum`). Needed
    ///     because a fan can exist and still have no usable range, and the
    ///     two produce different refusals and different user-facing copy.
    public static func resolve(
        rpm: Double,
        forFan index: Int,
        ranges: [Int: FanRPMRange],
        knownFanCount: Int
    ) -> FanClampOutcome {

        guard index >= 0, index < knownFanCount else {
            return .refuse(.unknownFan(index: index))
        }
        // Checked before the range lookup so a NaN request against an
        // unreadable fan reports the client's bad input rather than the
        // hardware's — the client can fix one of those and not the other.
        guard rpm.isFinite else {
            return .refuse(.requestNotFinite)
        }
        guard let range = ranges[index] else {
            return .refuse(.limitsUnreadable(index: index))
        }
        guard range.isUsable else {
            return .refuse(
                .limitsNonsensical(index: index, minRPM: range.minRPM, maxRPM: range.maxRPM)
            )
        }

        let clamped = Swift.min(Swift.max(rpm, range.minRPM), range.maxRPM)
        return .write(rpm: clamped, wasClamped: clamped != rpm)
    }
}

#endif
