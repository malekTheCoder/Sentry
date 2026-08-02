import Foundation

// MARK: - The write seam (fan-control plan §4.2)
//
// This file is the abstraction a real fan-write implementation plugs into.
// It contains no implementation that can write, and — deliberately — no
// *vocabulary* for "writing works", either: see `FanWriteAvailability`,
// which has no `.available` case. That is not an oversight; it is the
// strongest available compile-time statement that this build cannot move a
// fan, and it means Phase 3 cannot half-land. Adding the write path
// requires adding that case, which forces every `switch` over it — the
// Settings pane's disabled-control copy above all — to be revisited in the
// same change rather than silently continuing to say "not available".

/// One fan, as far as the backend can describe it.
///
/// `limits` is optional and stays optional all the way to the UI. The spike
/// read `F{i}Mn`/`F{i}Mx` successfully on an M1 Pro, but a Mac where those
/// keys are missing or malformed still has a readable `F{i}Ac` — reporting
/// the RPM while admitting the range is unknown is strictly better than
/// either dropping the fan entirely or substituting a plausible-looking
/// range nobody measured.
public struct FanDescriptor: Codable, Equatable, Sendable {
    /// SMC fan ordinal — the `i` in `F{i}Ac`. Not a display number; the UI
    /// adds one when it prints "Fan 1".
    public var index: Int
    public var limits: FanHardwareLimits?

    public init(index: Int, limits: FanHardwareLimits? = nil) {
        self.index = index
        self.limits = limits
    }
}

/// What the backend found when it looked for fans.
///
/// **Three outcomes, and the difference between them is the whole point.**
/// A fanless MacBook Air has no `FNum` key at all (measured — see the
/// spike's hardware table): that is `.noFansPresent`, a correct and final
/// answer about the hardware. A Mac whose SMC user client wouldn't open, or
/// whose reply was malformed, is `.unreadable`: an answer about *this
/// attempt*, not about the machine. Collapsing those two into one "no fans"
/// state would tell an Air owner the truth and a user with a transient
/// failure a lie, and the UI copy for the two cases is genuinely different.
public enum FanControlCapability: Equatable, Sendable {
    case supported(fans: [FanDescriptor])
    /// The SMC answered, and the answer is that this Mac has no fans.
    case noFansPresent
    /// The fan keys could not be interrogated. Says nothing about whether
    /// fans exist.
    case unreadable(reason: String)

    public var fans: [FanDescriptor] {
        if case .supported(let fans) = self { return fans }
        return []
    }

    /// Whether live RPM readings can be shown at all. Note this is about
    /// *reading*; nothing in this type is ever about writing.
    public var canReadFanSpeeds: Bool {
        if case .supported(let fans) = self { return !fans.isEmpty }
        return false
    }
}

/// Why a write can't happen.
///
/// There is no `.available` case, on purpose — see this file's header.
public enum FanWriteAvailability: Equatable, Sendable {
    /// The hardware supports it and the SMC keys carry the writable
    /// attribute bit (`F0Tg` attr `0xd4`, `F0Md` attr `0xd0`, measured in
    /// the spike), but SMC writes require root on Apple Silicon and Sentry
    /// runs unprivileged. Closing that gap means an `SMAppService`
    /// LaunchDaemon, which this build does not contain.
    case needsPrivilegedHelper
    /// This Mac has no fans to write to.
    case noFans
    /// The fan keys couldn't be read, so nothing can be said about writing
    /// them either.
    case hardwareUnreadable

    /// The sentence shown next to every disabled control. Kept on the model
    /// rather than in the view so the pane can't drift out of sync with the
    /// reason the backend actually reported.
    public var explanation: String {
        switch self {
        case .needsPrivilegedHelper:
            return "Changing fan speed writes to the SMC, which macOS only allows as root. Sentry would need to install a privileged helper to do it, and this build doesn't include one — so these controls are switched off rather than pretending to work."
        case .noFans:
            return "This Mac has no fans, so there's nothing to control."
        case .hardwareUnreadable:
            return "Sentry couldn't read this Mac's fan hardware, so it won't offer to change something it can't see."
        }
    }

    /// Four words for a badge.
    public var shortLabel: String {
        switch self {
        case .needsPrivilegedHelper: return "Needs a privileged helper"
        case .noFans: return "No fans on this Mac"
        case .hardwareUnreadable: return "Fan hardware unreadable"
        }
    }
}

/// Every way applying a fan target can fail.
public enum FanControlWriteError: Error, LocalizedError, Equatable, Sendable {
    /// The only error any backend in this build can produce.
    case writesUnavailable(FanWriteAvailability)
    case unknownFan(index: Int)
    case rpmOutsideHardwareLimits(requested: Double, limits: FanHardwareLimits)
    /// The policy never produced a request to begin with (no sensor
    /// reading, an empty curve, no fixed speed chosen). Its own case rather
    /// than a `writesUnavailable` variant so a curve with no sensor is
    /// never reported as "the privileged helper is missing" — two
    /// completely different problems with two completely different fixes.
    case policyProducedNoTarget(reason: String)

    public var errorDescription: String? {
        switch self {
        case .writesUnavailable(let availability):
            return availability.explanation
        case .policyProducedNoTarget(let reason):
            return reason
        case .unknownFan(let index):
            return "This Mac has no fan \(index + 1)."
        case .rpmOutsideHardwareLimits(let requested, let limits):
            return "\(Int(requested.rounded())) rpm is outside this fan's \(Int(limits.minRPM.rounded()))–\(Int(limits.maxRPM.rounded())) rpm range."
        }
    }
}

/// The seam plan §4.2 asks for: "keep fan control behind a protocol so the
/// app can support multiple backends."
///
/// **There is no conforming type in this build that can write, and adding
/// one is not in this change's scope.** The two conformers that exist are
/// `SMCReadOnlyFanControlBackend` (`SystemMetricsKit`), which reads real
/// hardware through the already-shipped `SMCFanBridge` and refuses every
/// write, and `UnsupportedFanControlBackend` below, which refuses
/// everything. The plan's `PrivilegedHelperFanControlBackend` is Phase 3.
///
/// **Why the write methods exist at all if nothing implements them.**
/// Because the alternative — a read-only protocol today, plus a second
/// protocol later — would leave the UI and the settings layer written
/// against a shape that has to change when the write path lands, which is
/// exactly what a seam is supposed to prevent (`StatsTransport`'s doc
/// comment makes the same argument about `CloudKitTransport`). The methods
/// are `throws` rather than optional so that "this can fail, and you must
/// handle the failure" is the call site's default assumption from day one,
/// not something retrofitted once failures become possible.
///
/// Not `Sendable`/`actor`: conformers wrap IOKit connections and are
/// consumed from the main actor by `FanControlService`, matching how
/// `SMCFanBridge` is already used from `ThermalCollector`.
public protocol FanControlBackend: AnyObject {

    /// Stable identifier for logs and for the Settings pane's "backend" row
    /// — a user reporting a bug should be able to say which one answered.
    var identifier: String { get }

    /// What this backend found. Re-probed rather than cached by the
    /// protocol; conformers may cache internally.
    func capability() -> FanControlCapability

    /// Live actual RPMs, fan-ordered.
    ///
    /// **A `0` in this array is a real reading, not a placeholder.** Apple
    /// Silicon parks its fans completely at idle (measured: actual and
    /// target both read 0.0), so "0 rpm" means "stopped", and any UI that
    /// renders it as "—" or "unavailable" would be misreporting a
    /// successful read. A fan whose key could not be read is *absent* from
    /// this array, which is how the two are told apart.
    func readActualRPMs() -> [Double]

    /// Why writes can't happen. Every conformer in this build returns a
    /// case; there is no case meaning "they can".
    var writeAvailability: FanWriteAvailability { get }

    /// Requests a fixed target for one fan. Throws in every conformer that
    /// exists today.
    func applyTarget(rpm: Double, toFan index: Int) throws

    /// Hands one fan back to the firmware (`F{i}Md = 0`). Throws in every
    /// conformer that exists today.
    ///
    /// Present in the protocol from the start, unimplemented, because plan
    /// §8 makes "always offer a quick Return to Auto" a safety requirement:
    /// the escape hatch has to be part of the seam's shape before anything
    /// can take a fan out of auto, not bolted on afterwards.
    func revertToAuto(fan index: Int) throws
}

// MARK: - Unsupported backend

/// The `UnsupportedFanControlBackend` from plan §4.2: reports no fans and
/// refuses every operation.
///
/// Used where a real backend can't be constructed at all (a non-macOS
/// build of `MacStatKit`, a unit test that needs the unsupported path). It
/// is not the fallback for "reading failed on a Mac that has fans" — that
/// case is `SMCReadOnlyFanControlBackend` returning `.unreadable`, and
/// substituting this type there would report "no fans" about a machine that
/// may well have two.
public final class UnsupportedFanControlBackend: FanControlBackend {

    public let identifier = "unsupported"

    public init() {}

    public func capability() -> FanControlCapability { .noFansPresent }

    public func readActualRPMs() -> [Double] { [] }

    public var writeAvailability: FanWriteAvailability { .noFans }

    public func applyTarget(rpm: Double, toFan index: Int) throws {
        throw FanControlWriteError.writesUnavailable(writeAvailability)
    }

    public func revertToAuto(fan index: Int) throws {
        throw FanControlWriteError.writesUnavailable(writeAvailability)
    }
}
