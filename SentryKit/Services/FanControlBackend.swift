import Foundation

// MARK: - The write seam (fan-control plan §4.2)
//
// This file is the abstraction a real fan-write implementation plugs into.
//
// **`FanWriteAvailability.available` exists as of Phase 3, and its arrival
// is the point.** Through Phase 2 this enum deliberately had no case
// meaning "writing works" — the strongest compile-time statement available
// that the build could not move a fan, and a tripwire ensuring Phase 3
// could not half-land: adding the case breaks every `switch` over it and
// forces each one to be revisited in the same change. That is what
// happened. The Settings pane's disabled-control copy, the pane's
// `canChangeMode` gate, and the tests that asserted "no case means writes
// work" were all rewritten here rather than left to keep saying "not
// available" while a daemon quietly wrote SMC keys behind them.
//
// **What `.available` does and does not claim.** It claims: a privileged
// helper is registered with launchd, an XPC connection to it was
// established, and the peer gate on the far side accepted this app. It
// does not claim any write has ever succeeded — `applyTarget` still
// `throws`, the daemon still refuses requests it cannot clamp, and the UI
// still reports failures verbatim. "The path is open" and "the write
// worked" stay separate, because on the machine this was written on the
// former can be reasoned about and the latter cannot be observed at all
// (see `SentryKit/FanDaemon/FanDaemonContract.swift`).

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

/// Whether a write can happen, and if not, why not.
///
/// Exactly one case says yes. The rest are all the ways the answer is
/// no, kept distinct because the *fix* differs for every one of them: one
/// needs a click, one needs a trip to System Settings, one needs a bug
/// report, one is a permanent fact about the hardware, one is a
/// transient read failure worth retrying, and one needs a Pro license.
/// Collapsing any pair would produce a screen that tells at least one
/// user the wrong thing to do next.
public enum FanWriteAvailability: Equatable, Sendable {

    /// The privileged helper is registered, reachable, and has accepted
    /// this app's code signature. Write controls are live.
    ///
    /// See this file's header for the boundary this case does *not* cross:
    /// it is a statement about the path, not a promise about any individual
    /// write, all of which can still fail and all of which still surface
    /// their failure verbatim.
    case available

    /// The hardware supports it and the SMC keys carry the writable
    /// attribute bit (`F0Tg` attr `0xd4`, `F0Md` attr `0xd0`, measured in
    /// the spike), but SMC writes require root and Sentry runs
    /// unprivileged. The helper ships in the bundle and has not been
    /// installed. **This is the default state of every fresh install**, and
    /// it stays the state until the user asks for the helper by name.
    case needsPrivilegedHelper

    /// The helper was registered, and macOS is waiting for the user to
    /// approve it in System Settings ▸ General ▸ Login Items & Extensions.
    /// A genuinely different situation from `.needsPrivilegedHelper`:
    /// nothing more will happen here until the user visits a different app,
    /// and a screen that said "install the helper" would be telling them to
    /// redo something they already did.
    case helperAwaitingApproval

    /// The helper is registered and approved, and talking to it failed:
    /// the connection dropped, the peer gate on the far side refused this
    /// binary, or the daemon is not running and would not start.
    ///
    /// Carries the reason because these are the failures a user cannot
    /// diagnose and a maintainer must — including the one that will be most
    /// common in practice, a signature mismatch between the app and the
    /// helper's `SMAuthorizedClients` requirement.
    case helperUnreachable(reason: String)

    /// This Mac has no fans to write to.
    case noFans

    /// The fan keys couldn't be read, so nothing can be said about writing
    /// them either.
    case hardwareUnreadable

    /// The hardware could write, but fan control is a Sentry Pro feature
    /// and this copy isn't entitled. Produced by `FanControlService`'s
    /// entitlement interception, never by a backend — backends state
    /// hardware and helper facts only, and the two hardware cases above
    /// deliberately keep outranking this one (a Mac with no fans has
    /// nothing to sell). Its own case, not a flavor of unavailable,
    /// because the fix is different from every other "no": not a click,
    /// not System Settings — a license.
    case requiresPro

    /// Whether write controls should be live. The single place the UI asks
    /// this question, so a future case cannot accidentally default to
    /// "enabled" by being forgotten in a view.
    public var canWrite: Bool {
        if case .available = self { return true }
        return false
    }

    /// The sentence shown next to every write control — live or disabled.
    /// Kept on the model rather than in the view so the pane can't drift
    /// out of sync with the reason the backend actually reported.
    public var explanation: String {
        switch self {
        case .available:
            return "Sentry's fan helper is installed and running as a background service, so the controls below really do change fan speed. The helper hands every fan back to your Mac's firmware if Sentry quits, crashes, or stops checking in — and it clamps every request to the speed range your Mac's own SMC reports, so it can't be asked for a speed the hardware doesn't allow."
        case .needsPrivilegedHelper:
            return "Changing fan speed writes to the SMC, which macOS only allows as root. Sentry can install a small background helper to do it — it runs only while it's needed, only accepts the three commands this feature uses, and hands the fans straight back to your Mac's firmware if Sentry goes away. Until you install it, these controls stay switched off rather than pretending to work."
        case .helperAwaitingApproval:
            return "The fan helper is installed but macOS is waiting for you to allow it. Open System Settings ▸ General ▸ Login Items & Extensions, find Sentry under “Allow in the Background,” and switch it on. Nothing here will work until you do — and nothing here will pretend to."
        case .helperUnreachable(let reason):
            return "Sentry couldn't talk to its fan helper, so every control that would change a fan is switched off. \(reason)"
        case .noFans:
            return "This Mac has no fans, so there's nothing to control."
        case .hardwareUnreadable:
            return "Sentry couldn't read this Mac's fan hardware, so it won't offer to change something it can't see."
        case .requiresPro:
            return "Changing fan speed is part of Sentry Pro. Fan readouts stay free — every RPM you see here is real — but installing the helper and holding a fan at a fixed speed need a Pro license."
        }
    }

    /// A few words for a badge.
    public var shortLabel: String {
        switch self {
        case .available: return "Fan control active"
        case .needsPrivilegedHelper: return "Needs a privileged helper"
        case .helperAwaitingApproval: return "Waiting for your approval"
        case .helperUnreachable: return "Helper unreachable"
        case .noFans: return "No fans on this Mac"
        case .hardwareUnreadable: return "Fan hardware unreadable"
        case .requiresPro: return "Part of Sentry Pro"
        }
    }
}

/// Every way applying a fan target can fail.
public enum FanControlWriteError: Error, LocalizedError, Equatable, Sendable {
    /// No write could even be attempted — see the availability case for
    /// which of the five reasons applies.
    case writesUnavailable(FanWriteAvailability)
    /// A write *was* attempted: the privileged helper was reachable, the
    /// request reached it, and it declined or failed.
    ///
    /// Its own case rather than a `writesUnavailable` variant because the
    /// two are opposite diagnoses. `writesUnavailable` means the path is
    /// shut; this means the path is open and the far end said no — because
    /// the SMC refused the write, because the fan's limits were unreadable
    /// so the daemon would not clamp, or because the connection died
    /// mid-call. Folding them together would put "install the helper" in
    /// front of a user whose helper is installed and working.
    ///
    /// `reason` is the daemon's own sentence, rendered verbatim and never
    /// parsed — see `FanDaemonProtocol`'s note on why the app branches on
    /// `FanWriteAvailability` rather than on the daemon's prose.
    case helperRefused(reason: String)
    case unknownFan(index: Int)
    case rpmOutsideHardwareLimits(requested: Double, limits: FanHardwareLimits)
    /// The policy never produced a request to begin with (no sensor
    /// reading, an empty curve, no fixed speed chosen). Its own case rather
    /// than a `writesUnavailable` variant so a curve with no sensor is
    /// never reported as "the privileged helper is missing" — two
    /// completely different problems with two completely different fixes.
    case policyProducedNoTarget(reason: String)
    /// The daemon accepted the write — the SMC took `F{i}Tg`, the far end
    /// did not refuse anything, `helperRefused` does not apply — but a
    /// several-sample readback poll of `F{i}Ac` never saw the fan's actual
    /// RPM move to (or meaningfully toward) the requested target. See
    /// `FanDaemonReadback` and `FanDaemonService.setTarget`'s handling of
    /// `verifiedApplied == false`.
    ///
    /// **Why this is not `helperRefused`.** `helperRefused` means the path
    /// is open and the far end said no; this means the far end said yes and
    /// the hardware disagreed anyway — the exact "SMC accepted the write,
    /// `thermalmonitord` silently overrode it" failure mode that four of
    /// seven competitor fan-control apps' users report as their top
    /// complaint. Folding the two together would hide the one case an
    /// operator most needs to be able to tell apart from an ordinary
    /// refusal, because the fix is different: a refusal means try again or
    /// report a bug; this means something else on the system is actively
    /// fighting the request.
    case writeNotVerified(requestedRPM: Double, fanIndex: Int)

    public var errorDescription: String? {
        switch self {
        case .writesUnavailable(let availability):
            return availability.explanation
        case .helperRefused(let reason):
            return reason
        case .policyProducedNoTarget(let reason):
            return reason
        case .unknownFan(let index):
            return "This Mac has no fan \(index + 1)."
        case .rpmOutsideHardwareLimits(let requested, let limits):
            return "\(Int(requested.rounded())) rpm is outside this fan's \(Int(limits.minRPM.rounded()))–\(Int(limits.maxRPM.rounded())) rpm range."
        case .writeNotVerified(let requestedRPM, let fanIndex):
            return "Sentry's fan helper wrote \(Int(requestedRPM.rounded())) rpm to fan \(fanIndex + 1), but couldn't confirm the fan actually moved. Something else on this Mac — most likely thermalmonitord reasserting control — may be overriding it."
        }
    }
}

/// The seam plan §4.2 asks for: "keep fan control behind a protocol so the
/// app can support multiple backends."
///
/// **Three conformers now, one of which can write.**
/// `SMCReadOnlyFanControlBackend` (`SystemMetricsKit`) reads real hardware
/// through the already-shipped `SMCFanBridge` and refuses every write;
/// `UnsupportedFanControlBackend` below refuses everything; and
/// `PrivilegedFanControlBackend` — the plan's
/// `PrivilegedHelperFanControlBackend` — wraps the read-only one for
/// capability and readings and routes writes to the root daemon over XPC.
/// The wrapping is not incidental: it is what guarantees that **installing,
/// breaking, or removing the helper cannot affect what the pane reports
/// about this Mac's fans.** Reads never travel through the privileged path.
///
/// **Why the write methods exist at all if nothing implements them.**
/// Because the alternative — a read-only protocol today, plus a second
/// protocol later — would leave the UI and the settings layer written
/// against a shape that has to change when the write path lands, which is
/// exactly what a seam is supposed to prevent (`StatsTransport` makes the
/// same argument about swappable transports). The methods
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

    // MARK: - Helper lifecycle
    //
    // These three exist on the protocol rather than on
    // `PrivilegedFanControlBackend` alone so `FanControlPane` is written
    // against one type and the *backend* decides whether installing a
    // helper is a meaningful thing to offer. A pane that had to downcast
    // would be a pane that could forget to, and the failure mode of
    // forgetting is an install button on a fanless Mac.

    /// Whether this backend has a privileged helper to install at all.
    /// `false` for both read-only conformers, which is what keeps the
    /// install affordance off screens where it could only ever fail.
    var supportsPrivilegedHelper: Bool { get }

    /// Asks macOS to register the helper. **User-initiated only** — never
    /// called at launch, never called from `applyTarget` as a
    /// convenience. Registering a root LaunchDaemon is a decision a person
    /// makes, and an app that did it lazily on first slider drag would be
    /// installing a privileged service as a side effect of curiosity.
    func installPrivilegedHelper() throws

    /// Re-reads whatever the backend's `writeAvailability` derives from.
    ///
    /// Exists for one specific transition that happens entirely outside
    /// this app: the user goes to System Settings ▸ Login Items and
    /// approves the helper, turning `.helperAwaitingApproval` into
    /// `.available`. No notification arrives; the pane calls this when it
    /// appears. A no-op for backends whose availability is a fixed fact.
    func refreshWriteAvailability()

    /// Unregisters the helper. See `PrivilegedFanControlBackend`'s doc
    /// comment for what this does *not* cover — a drag-to-Trash uninstall
    /// never reaches it, and that residue is documented rather than
    /// papered over.
    func removePrivilegedHelper() throws
}

/// Defaults so the two read-only conformers say "no helper here" without
/// three lines of boilerplate each, and so a future backend cannot
/// accidentally advertise an install button by omission.
public extension FanControlBackend {
    var supportsPrivilegedHelper: Bool { false }
    func refreshWriteAvailability() {}
    func installPrivilegedHelper() throws {
        throw FanControlWriteError.writesUnavailable(writeAvailability)
    }
    func removePrivilegedHelper() throws {
        throw FanControlWriteError.writesUnavailable(writeAvailability)
    }
}

// MARK: - Unsupported backend

/// The `UnsupportedFanControlBackend` from plan §4.2: reports no fans and
/// refuses every operation.
///
/// Used where a real backend can't be constructed at all (a non-macOS
/// build of `SentryKit`, a unit test that needs the unsupported path). It
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
