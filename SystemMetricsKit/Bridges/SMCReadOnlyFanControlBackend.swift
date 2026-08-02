import Foundation
import MacStatKit

/// The real-hardware `FanControlBackend` for macOS: capability detection
/// and live RPM over the already-shipped, read-only `SMCFanBridge` — and a
/// flat refusal for every write.
///
/// **This is the honest backend, not a stub.** Its read side talks to the
/// same SMC user client `ThermalCollector` has been using since the Phase 1
/// spike, on the same keys measured on real hardware (`FNum`, `F{i}Ac`,
/// `F{i}Mn`, `F{i}Mx`). What it reports about this Mac's fans is true. Its
/// write side throws `FanControlWriteError.writesUnavailable(
/// .needsPrivilegedHelper)` unconditionally, which is *also* true: SMC key
/// writes require root on Apple Silicon, Sentry runs unprivileged, and the
/// `SMAppService` LaunchDaemon that would close that gap does not exist in
/// this build (see `docs/fan-control-spike.md`, and note the spike's own
/// warning that daemon registration under this project's ad-hoc signing is
/// the *actual* risk in that work, not the SMC protocol).
///
/// **Why not name it `SMCFanControlBackend`, as the plan's §4.2 sketch
/// does.** Because that name would claim the SMC write backend exists.
/// `SMCReadOnly…` says what it is; when Phase 3 lands a real writer, it
/// gets the unqualified name and this type either goes away or stays as
/// the fallback for a Mac where the helper isn't installed. Naming the
/// read-only one as though it were the write one would make that future
/// change look like a rename instead of the security-relevant addition it
/// is.
///
/// **What is deliberately absent:** any use of `SMCFanBridge`'s `F{i}Tg`
/// reading as a "current target" the user could adjust. `readFanHardware()`
/// does read it, and it would be easy to surface a target-RPM stepper
/// pre-filled with it — which would be a control that looks live, reads a
/// real number, and does nothing. That is the exact failure mode this
/// codebase keeps removing.
public final class SMCReadOnlyFanControlBackend: FanControlBackend {

    public let identifier = "smc-read-only"

    /// Capability is stable for a machine's lifetime, and probing it costs
    /// three SMC round trips per fan. Cached after the first successful
    /// probe; a failed probe is *not* cached, so a transient `.unreadable`
    /// can be retried by `FanControlService.refreshCapability()` rather
    /// than being latched for the process lifetime.
    private var cachedCapability: FanControlCapability?

    public init() {}

    public func capability() -> FanControlCapability {
        if let cachedCapability { return cachedCapability }

        guard let count = SMCFanBridge.shared.readFanCount() else {
            // Two situations reach here and they are genuinely different,
            // but the SMC gives us the same silence for both: a fanless Mac
            // (the spike measured `FNum` simply absent on a MacBook Air)
            // and a Mac whose SMC user client wouldn't open. `SMCFanBridge`
            // does not distinguish them either — it returns `nil` for both
            // — so rather than guess, this reports `.unreadable` with a
            // sentence that names both possibilities. Claiming
            // `.noFansPresent` would be asserting a hardware fact we did
            // not establish.
            return .unreadable(
                reason: "The SMC didn't report a fan count. Either this Mac has no fans, or its fan keys couldn't be read."
            )
        }

        guard count > 0 else {
            // An explicit `FNum` of 0 *is* a hardware fact: the SMC
            // answered, and the answer is "none".
            let capability = FanControlCapability.noFansPresent
            cachedCapability = capability
            return capability
        }

        let descriptors = SMCFanBridge.shared.readFanHardware().map { hardware -> FanDescriptor in
            // Limits only exist when *both* ends read plausibly. A range
            // with one known end can't clamp anything and would only
            // invite a UI to invent the other end.
            let limits: FanHardwareLimits? = {
                guard let minRPM = hardware.minRPM, let maxRPM = hardware.maxRPM else { return nil }
                let candidate = FanHardwareLimits(minRPM: minRPM, maxRPM: maxRPM)
                return candidate.isValid ? candidate : nil
            }()
            return FanDescriptor(index: hardware.index, limits: limits)
        }

        guard !descriptors.isEmpty else {
            return .unreadable(
                reason: "The SMC reported \(count) fan\(count == 1 ? "" : "s") but none of their keys could be read."
            )
        }

        let capability = FanControlCapability.supported(fans: descriptors)
        cachedCapability = capability
        return capability
    }

    public func readActualRPMs() -> [Double] {
        SMCFanBridge.shared.readFanRPMs()
    }

    /// Constant, and constant for a reason that is about macOS rather than
    /// about this type: no unprivileged process can write an SMC key. A
    /// future helper-backed backend returns a different value; this one
    /// never can.
    public var writeAvailability: FanWriteAvailability {
        switch capability() {
        case .supported: return .needsPrivilegedHelper
        case .noFansPresent: return .noFans
        case .unreadable: return .hardwareUnreadable
        }
    }

    public func applyTarget(rpm: Double, toFan index: Int) throws {
        throw FanControlWriteError.writesUnavailable(writeAvailability)
    }

    public func revertToAuto(fan index: Int) throws {
        throw FanControlWriteError.writesUnavailable(writeAvailability)
    }
}
