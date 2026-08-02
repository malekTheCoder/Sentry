#if os(macOS)
import Foundation
import IOKit

// MARK: - LocalCommandExecutor: the Mac-side handler for a ControlCommand arriving over local sync

/// Executes a `ControlCommand` that arrived over `LocalSyncServer`
/// (`MacStatKit/LocalSync/LocalSyncServer.swift`) against the real
/// `PowerControlService`, and produces the `ControlStatus` reply the server
/// sends back. This is the piece that turns `KeepAwakeIntent`/
/// `ReleaseAwakeIntent`/`SleepStatusCard`'s buttons from "constructs a
/// command and passes it to a transport that throws" into "actually starts
/// or releases a real `IOPMAssertion` on this Mac."
///
/// **Pure decision/dispatch logic, no networking.** Same testing posture as
/// `NonceTracker` (`MacStatKit/Sync/NonceTracker.swift`) and
/// `LocalSyncFraming`: `execute(_:now:)` takes a `ControlCommand` and a
/// clock, and returns a `ControlStatus` — `LocalSyncServer` is the only
/// caller that touches an actual `NWConnection`. `#if os(macOS)`-gated
/// because it holds a live `PowerControlService`, exactly like that type
/// itself.
///
/// **Reuses `NonceTracker` and `PowerControlService` rather than
/// reinventing idempotency/expiry checking.** `MCPXPCService.keepAwake`/
/// `releaseAwake` (`MacStat/App/MCPXPCService.swift`) already call
/// `PowerControlService` directly for the MCP write-tool path, but that path
/// has no redelivery risk (an MCP client calls once, gets one reply, done) —
/// it never needed `NonceTracker`. A `ControlCommand` arriving over a TCP
/// connection that can itself flap (the phone's Wi-Fi drops mid-flight,
/// `LocalSyncClient` reconnects and, in a future revision, retries) is
/// exactly the redelivery-prone shape plan §10.4 (and `NonceTracker`'s own
/// doc comment) describes, so this type gates every command through it
/// before touching `PowerControlService` at all.
///
/// **Known scope simplification: no separate consent/permission gate.**
/// `MCPXPCService`'s write tools sit behind `MCPAccessController` (a
/// per-tool, user-configured allow/deny list) because an MCP client is an
/// arbitrary, potentially-untrusted local process. A `ControlCommand`
/// arriving over this channel can only come from a phone that already
/// discovered this Mac's `_macstat._tcp` Bonjour advertisement and completed
/// a TCP handshake on the same local Wi-Fi network — the same trust
/// boundary `LocalSyncServer` already accepts unconditionally for the
/// snapshot broadcast direction (see that type's doc comment: "an
/// inert, harmless listener" the Mac advertises regardless of settings).
/// Extending that same boundary to also accept sleep-control commands is a
/// deliberate, documented scope decision, not an oversight — a dedicated
/// "accept remote commands from my iPhone" settings toggle (mirroring
/// `mcpRemoteAccessEnabled`'s pattern) is reasonable future work if a
/// household's trust model ever needs it to be narrower than "anyone on my
/// LAN who already has the app."
@MainActor
public final class LocalCommandExecutor {

    private let powerControl: PowerControlService
    private let nonceTracker: NonceTracker
    private let deviceID: String

    /// - Parameters:
    ///   - powerControl: the live service this executor drives. Shared with
    ///     the rest of the app (`AppDelegate.powerControl`), not a private
    ///     instance — a `keepAwake` issued via Siri and one issued via the
    ///     Mac's own dropdown must contend for the same single assertion,
    ///     the same way `MCPXPCService` already shares this instance.
    ///   - nonceTracker: defaults to a fresh tracker (constructed inside the
    ///     initializer body, not as a default-argument expression — a
    ///     default argument is evaluated in the caller's isolation context,
    ///     which need not be `@MainActor`, and `NonceTracker.init()` is);
    ///     overridable for tests.
    ///   - deviceID: stamped into every `ControlStatus` this executor
    ///     produces — `AppDelegate` passes `coordinator.deviceID`, the same
    ///     identity every `SystemSnapshot` this Mac emits already carries.
    public init(powerControl: PowerControlService, nonceTracker: NonceTracker? = nil, deviceID: String) {
        self.powerControl = powerControl
        self.nonceTracker = nonceTracker ?? NonceTracker()
        self.deviceID = deviceID
    }

    /// Executes `command` if it passes `NonceTracker`'s idempotency/expiry
    /// gate, and always returns a `ControlStatus` describing the outcome —
    /// `rejected`/`expired` for a command that gate stops, `completed` for
    /// one that actually ran (including a duplicate redelivery of an
    /// already-executed nonce, which is reported as `completed` again
    /// rather than `rejected`, since from the sender's point of view the
    /// command *did* succeed — just possibly on an earlier delivery).
    public func execute(_ command: ControlCommand, now: Date = Date()) -> ControlStatus {
        guard command.expiresAt > now else {
            return status(for: command, state: "expired", message: "This command arrived too late and was ignored.")
        }
        guard nonceTracker.shouldExecute(command, now: now) else {
            // Either already executed (a harmless redelivery — report success
            // again) or expired (already handled above, but `shouldExecute`
            // re-checks it too; the guard above is what actually produces the
            // "expired" message users see, this branch only remains reachable
            // for the "already executed" case in practice).
            return status(for: command, state: "completed", message: "Already handled.")
        }

        let parameters = Self.parseParameters(command.parametersJSON)

        do {
            switch command.commandType {
            case "keepAwake":
                try executeKeepAwake(parameters: parameters, reason: "Requested from iPhone")
            case "releaseAwake":
                powerControl.releaseAssertion()
            case "extendAwake":
                try powerControl.adjustAssertion(bySeconds: parameters.deltaSeconds ?? 0)
            case "truncateAwake":
                try powerControl.adjustAssertion(bySeconds: -abs(parameters.deltaSeconds ?? 0))
            default:
                return status(for: command, state: "rejected", message: "Unknown command type '\(command.commandType)'.")
            }
        } catch {
            return status(for: command, state: "rejected", message: error.localizedDescription)
        }

        nonceTracker.markExecuted(command.nonce)
        return status(for: command, state: "completed", message: successMessage(for: command.commandType))
    }

    private func executeKeepAwake(parameters: Parameters, reason: String) throws {
        guard let modeRaw = parameters.mode, let mode = AwakeMode(rawValue: modeRaw) else {
            throw PowerControlError.assertionFailed(kIOReturnBadArgument)
        }
        let duration = (parameters.durationSeconds ?? 0) > 0 ? parameters.durationSeconds : nil
        try powerControl.startAssertion(mode: mode, duration: duration, reason: reason)
    }

    private func successMessage(for commandType: String) -> String {
        switch commandType {
        case "keepAwake": return "Your Mac will stay awake."
        case "releaseAwake": return "Your Mac's sleep assertion was released."
        case "extendAwake": return "Extended."
        case "truncateAwake": return "Shortened."
        default: return "Done."
        }
    }

    private func status(for command: ControlCommand, state: String, message: String) -> ControlStatus {
        let (active, expiresAt) = currentAssertionSummary()
        return ControlStatus(
            deviceID: deviceID,
            respondsToNonce: command.nonce,
            state: state,
            message: message,
            assertionActive: active,
            assertionExpiresAt: expiresAt,
            updatedAt: Date()
        )
    }

    private func currentAssertionSummary() -> (active: Bool, expiresAt: Date?) {
        switch powerControl.state {
        case .inactive:
            return (false, nil)
        case .active(_, let expiresAt, _):
            return (true, expiresAt)
        }
    }

    // MARK: - parametersJSON parsing

    /// The handful of fields any `commandType` this executor understands
    /// might carry — see `ControlCommand.parametersJSON`'s doc comment for
    /// the exact shapes (`{"durationSeconds":3600,"mode":"systemOnly"}` for
    /// `keepAwake`, `{"deltaSeconds":900}` for `extendAwake`/`truncateAwake`).
    private struct Parameters {
        var durationSeconds: TimeInterval?
        var mode: String?
        var deltaSeconds: TimeInterval?
    }

    private static func parseParameters(_ json: String) -> Parameters {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Parameters()
        }
        return Parameters(
            durationSeconds: (object["durationSeconds"] as? NSNumber)?.doubleValue,
            mode: object["mode"] as? String,
            deltaSeconds: (object["deltaSeconds"] as? NSNumber)?.doubleValue
        )
    }
}
#endif
