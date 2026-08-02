import Foundation
#if os(macOS)
import ServiceManagement

/// Names for the LaunchAgent that makes `MacStatXPCServiceName.machService`
/// reachable.
///
/// THE FILE NAME IS PART OF THE API, exactly as it is for the fan daemon
/// (see `dev.malekswilam.macstat.fandaemon.plist`'s header):
/// `SMAppService.agent(plistName:)` looks the plist up by basename inside
/// Sentry.app/Contents/Library/LaunchAgents, and launchd requires the
/// plist's `Label` to equal that basename minus ".plist". Here there is a
/// third string that must also match: the `MachServices` key inside the
/// plist must be `MacStatXPCServiceName.machService`, because that is the
/// name `MacStatXPCClient` dials. This project deliberately uses ONE string
/// for all three roles — label, plist basename, Mach service name — so
/// there is only one thing to keep consistent, and
/// `MCPAgentRegistrationTests` pins the exact text so a rename fails a test
/// rather than producing a silently unregistrable agent.
public enum MCPAgentNaming {
    /// launchd job label == Mach service name == plist basename - ".plist".
    public static let label = MacStatXPCServiceName.machService
    /// What `SMAppService.agent(plistName:)` is given.
    public static let plistName = label + ".plist"
}

/// The registration state of the CLI/MCP LaunchAgent, as this app is
/// willing to present it to a user.
///
/// This is a deliberate re-statement of `SMAppService.Status` in the app's
/// own vocabulary, for the same reason `PrivilegedFanControlBackend` keeps
/// `cachedStatus` behind its own availability table: the raw enum is a
/// launchd implementation detail, and two of its cases (`notFound`, and
/// any case added by a future OS) mean things a user cannot act on without
/// an explanation. Every case here either IS actionable or carries the
/// plain-language reason it isn't — the FanControlPane rule ("never a
/// control that silently does nothing") applied to state instead of a
/// button.
public enum MCPAgentRegistrationStatus: Equatable, Sendable {
    /// launchd owns the Mach service name; connections will reach the app.
    case registered
    /// `register()` was called, and macOS is waiting for the user to allow
    /// it in System Settings ▸ General ▸ Login Items & Extensions. The UI
    /// showing this case should offer the deep link
    /// (`SMAppService.openSystemSettingsLoginItems()`), because "go find
    /// the right pane" is where users give up.
    case requiresApproval
    /// Never registered on this Mac (or explicitly unregistered). The
    /// default state of every fresh install.
    case notRegistered
    /// Registration cannot work in this build, with the reason spelled
    /// out. The two known producers: the plist missing from the bundle
    /// (a build predating it, or a mis-generated project — SMAppService's
    /// `.notFound`), and an OS status this build has never heard of, which
    /// is reported as itself rather than guessed at.
    case unavailable(reason: String)
}

/// Maps `SMAppService.Status` into the app's vocabulary. Pure, so the
/// mapping — including the fail-honest branch for future OS cases — is
/// testable on a machine where every real `SMAppService` query answers
/// `.notFound`.
public enum MCPAgentStatusMap {
    public static func status(for raw: SMAppService.Status) -> MCPAgentRegistrationStatus {
        switch raw {
        case .enabled:
            return .registered
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .notRegistered
        case .notFound:
            // Observed producers of `.notFound`, in likelihood order for
            // this codebase: an ad-hoc-signed local build (SMAppService
            // won't attribute an agent it can't tie to a team), an app
            // running from a build directory rather than /Applications,
            // and — the only one that's a packaging bug — the plist
            // genuinely missing from Contents/Library/LaunchAgents. The
            // copy names all three rather than guessing, because the first
            // draft of this message guessed ("this build doesn't contain
            // the agent") and was wrong on a machine where the plist was
            // demonstrably in the bundle.
            return .unavailable(reason: """
                macOS can't attribute the command-line service's launch \
                agent to this copy of Sentry. That usually means an \
                unsigned development build, or Sentry running outside \
                /Applications — and only rarely a build that's actually \
                missing the agent.
                """)
        @unknown default:
            // The same posture as PrivilegedFanControlBackend's status
            // handling: a status this build has never heard of is not a
            // status it should translate into something reassuring.
            return .unavailable(reason: """
                macOS reported a launch-agent state this version of Sentry \
                doesn't recognize (\(String(describing: raw))).
                """)
        }
    }
}

/// Owns registration of the LaunchAgent that publishes the app's Mach
/// service, and the app-side record of its state.
///
/// WHY THIS EXISTS AT ALL — the bug it fixes. `AppDelegate` has always
/// started an `NSXPCListener(machServiceName:)`, but a Mach service is a
/// name *launchd* owns: launchd routes connections only for services
/// declared in a job it registered, and nothing in this project ever
/// registered one. The listener resumed, received nothing, and failed
/// silently — `macstat status` reported "Is MacStat running?" while
/// MacStat was running. The fix is the standard macOS shape, the same one
/// the fan daemon already uses one privilege level up:
/// a launchd plist bundled at Contents/Library/LaunchAgents/ declaring
/// `MachServices`, registered with `SMAppService.agent(plistName:)`.
///
/// Registration is EXPLICIT AND USER-VISIBLE, never silent at launch,
/// for the same reason the fan helper's install lives behind a button in
/// Settings ▸ Fans: registering a login item is a change to the user's
/// Mac that macOS itself surfaces (System Settings lists it, and may
/// toast about it), so it should happen at a moment the user can connect
/// to something they asked for. The one caller of `register()` is the
/// Command-Line Access section in Settings ▸ AI Access.
///
/// Like `PrivilegedFanControlBackend`, the `SMAppService` calls sit
/// behind injectable closures so every state transition below is testable
/// on a machine with no signing identity — where the real calls answer
/// `.notFound` for everything and `register()` always throws.
@MainActor
public final class MCPAgentRegistrar: ObservableObject {

    @Published public private(set) var status: MCPAgentRegistrationStatus

    private let probe: () -> SMAppService.Status
    private let registerAction: () throws -> Void
    private let unregisterAction: () throws -> Void

    /// - Parameters:
    ///   - probe/registerAction/unregisterAction: test seams. Production
    ///     callers pass nothing and get the real `SMAppService.agent`.
    public init(
        probe: (() -> SMAppService.Status)? = nil,
        registerAction: (() throws -> Void)? = nil,
        unregisterAction: (() throws -> Void)? = nil
    ) {
        let service = { SMAppService.agent(plistName: MCPAgentNaming.plistName) }
        self.probe = probe ?? { service().status }
        self.registerAction = registerAction ?? { try service().register() }
        self.unregisterAction = unregisterAction ?? { try service().unregister() }
        self.status = MCPAgentStatusMap.status(for: (probe ?? { service().status })())
    }

    /// Re-reads launchd's answer. Cheap, prompts nothing — safe to call
    /// whenever the Settings pane appears, and necessary after the user
    /// visits System Settings to approve (or revoke) the agent, because
    /// nothing pushes that change to us.
    public func refresh() {
        status = MCPAgentStatusMap.status(for: probe())
    }

    /// Registers the agent. Returns a plain-language failure message, or
    /// nil on success — "success" including `.requiresApproval`, which is
    /// launchd agreeing and macOS asking the user to confirm.
    ///
    /// The known throw on real machines: an ad-hoc-signed build (every
    /// local Debug build without a `DEVELOPMENT_TEAM`) — `SMAppService`
    /// refuses agents whose signature it can't attribute to the app's
    /// team. That is surfaced as the error text says, not swallowed: a
    /// developer running an unsigned build should read *why* the button
    /// didn't work.
    public func register() -> String? {
        defer { refresh() }
        do {
            try registerAction()
            return nil
        } catch {
            return "macOS refused to register the command-line service: \(error.localizedDescription)"
        }
    }

    /// Unregisters the agent. Same contract as `register()`.
    public func unregister() -> String? {
        defer { refresh() }
        do {
            try unregisterAction()
            return nil
        } catch {
            return "macOS couldn't remove the command-line service: \(error.localizedDescription)"
        }
    }

    /// Deep link to the pane where `.requiresApproval` is resolved.
    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The pid launchd is currently running the agent job as, or `nil` if
    /// the job isn't running (or the answer couldn't be read).
    ///
    /// Exists for the single-instance handoff (`AppDelegate`'s
    /// `ensureCanonicalXPCInstance`): once the agent is registered, the
    /// launchd-managed instance is the only one that can own the Mach
    /// service, so any *other* instance needs a way to ask "is that me?".
    /// `launchctl print` is parsed rather than any SM API because
    /// SMAppService exposes registration status but not the running job's
    /// pid — launchd is, again, the ground truth.
    ///
    /// Returns `nil` on any parse uncertainty. The caller treats `nil` as
    /// "don't hand off" when the job might be running — a duplicated menu
    /// bar icon is a wart; a terminate-relaunch loop driven by a
    /// misparsed pid would be a broken app.
    public nonisolated static func canonicalJobPID() -> pid_t? {
        let launchctl = Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["print", "gui/\(getuid())/\(MCPAgentNaming.label)"]
        let stdout = Pipe()
        launchctl.standardOutput = stdout
        launchctl.standardError = FileHandle.nullDevice
        do {
            try launchctl.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        launchctl.waitUntilExit()
        guard launchctl.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        // launchctl's human-readable output has a top-level "pid = N" line
        // for a running job and none otherwise. Anchored to line starts so
        // pid-like text inside endpoint subsections can't match.
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pid = "), let pid = pid_t(trimmed.dropFirst("pid = ".count)) {
                return pid
            }
        }
        return nil
    }
}

#endif
