import Foundation
import ServiceManagement
import os
import SentryKit

/// Sentry's half of the command-line bridge: an **anonymous** XPC listener
/// that any signed Sentry tool can be introduced to, plus the `SMAppService`
/// registration of the LaunchAgent that does the introducing.
///
/// **Read `SentryKit/MCPBridge/MCPBridgeContract.swift` first.** In one
/// paragraph: `AppDelegate` used to publish a Mach service name that nothing
/// had registered with launchd, so `sentryctl` and the stdio MCP server could
/// never reach this app; and the fix could not simply be "register the name",
/// because only the process launchd starts as the job may vend it, and Sentry
/// is started by the user. So Sentry vends an anonymous listener — which needs
/// no registration by design — and a tiny on-demand agent hands its endpoint
/// out.
///
/// **Inert by default, and inert when unregistered. This is the property that
/// makes the change safe to merge before certificates exist.** Constructing
/// this type does exactly two things: it creates an anonymous
/// `NSXPCListener` (a process-local object; it opens nothing, registers
/// nothing, and is unreachable by anyone who has not been handed its
/// endpoint), and it asks `SMAppService` for a *status*, which is a local read
/// that prompts nothing and launches nothing. There is no path from app launch
/// to `SMAppService.register()`; the only caller is `register()`, and its only
/// caller is a button in Settings ▸ AI Access. On a machine where the agent was
/// never set up — every fresh install, and every build made without a
/// Developer ID certificate, where registration cannot succeed at all — the
/// status is `.notRegistered`, no connection to the bridge is ever attempted,
/// and the app behaves exactly as it did before this type existed.
///
/// **The HTTP MCP transport does not go through here and must not start to.**
/// `MCPRemoteServer` is handed a `LocalXPCServiceCaller`, which — despite the
/// name — calls `MCPXPCService` directly in this process with no XPC transport
/// at all. It never touched the broken Mach service and it does not touch this
/// one. That path was working before this change and is deliberately untouched
/// by it; see `LocalXPCServiceCaller`'s doc comment for why calling an object
/// in your own address space through Mach IPC was a bad idea in the first
/// place.
///
/// **Why registration is explicit and user-visible rather than silent at
/// launch.** Registering a LaunchAgent adds an entry to the user's Login Items
/// & Extensions. Doing that unannounced, on first launch, for a feature most
/// users will never use, would be the app quietly installing a background item
/// on their behalf — and the first they would hear of it is finding it in
/// System Settings. The standard this follows is the one every action in
/// Sentry that changes something outside the app is held to: the
/// consequences are spelled out next to the button, the button exists on
/// exactly one screen, and the result of pressing it is reported verbatim
/// including the failure.
@MainActor
final class MCPEndpointPublisher: ObservableObject {

    private static let logger = Logger(
        subsystem: "dev.malekswilam.sentry",
        category: "MCPEndpointPublisher"
    )

    /// What launchd thinks of our agent, as of the last `refresh()`.
    ///
    /// Cached rather than recomputed per redraw, because asking
    /// `SMAppService` for a status is a round trip to `smd` and a SwiftUI
    /// `body` may run many times a second: reading it from a view would turn
    /// a property access that looks free into per-frame IPC. Refreshed
    /// instead at the three moments it can actually change: construction,
    /// either side of a register/unregister, and whenever the pane appears —
    /// that last one
    /// matters because `.awaitingApproval` becomes `.registered` entirely
    /// outside this app, when the user flips a switch in System Settings, and
    /// nothing notifies us.
    @Published private(set) var registration: MCPBridgeRegistration

    /// Whether Sentry's endpoint is currently sitting in the bridge's table.
    ///
    /// Distinct from `registration` and shown separately, because they fail
    /// for different reasons and a user who conflates them will fix the wrong
    /// thing: the agent can be perfectly registered while this is `false`
    /// (bridge not yet contacted, or contacted and refused because this build
    /// is unsigned).
    @Published private(set) var isPublished = false

    /// The last publish failure, verbatim. `nil` when nothing has been tried
    /// or the last attempt succeeded.
    @Published private(set) var lastPublishFailure: String?

    private let endpointVendor: MCPAppEndpointVendor
    private var bridgeConnection: NSXPCConnection?

    /// Injectable so tests can drive the whole state table without
    /// `SMAppService` — which, on a machine with no signing identities, can
    /// only ever report one value, making every other branch untestable.
    /// Production passes `nil` and the real service is consulted.
    private let statusProbe: (() -> SMAppService.Status)?

    init(
        service: SentryXPCServiceProtocol,
        statusProbe: (() -> SMAppService.Status)? = nil
    ) {
        self.statusProbe = statusProbe
        self.endpointVendor = MCPAppEndpointVendor(
            service: service,
            evaluator: MCPBridgeSecurityEvaluator()
        )
        self.registration = Self.map(
            statusProbe?() ?? SMAppService.agent(plistName: MCPBridgeNaming.plistName).status
        )
    }

    /// Maps `SMAppService.Status` onto the pure state the UI and the CLI both
    /// speak. Deliberately total, including the `@unknown default` — a status
    /// this build has never heard of is not one it should treat as "command
    /// line access works", because the only way to find out it was wrong is a
    /// user reporting that a tool we told them was ready does not work.
    private static func map(_ status: SMAppService.Status) -> MCPBridgeRegistration {
        switch status {
        case .enabled:
            return .registered
        case .requiresApproval:
            return .awaitingApproval
        case .notRegistered, .notFound:
            return .notRegistered
        @unknown default:
            return .unavailable(
                reason: "macOS reported a state Sentry doesn't recognise, so it isn't assuming command-line access works."
            )
        }
    }

    /// Cheap, prompts nothing, launches nothing. Safe to call on every
    /// appearance of the pane.
    func refresh() {
        let fresh = Self.map(
            statusProbe?() ?? SMAppService.agent(plistName: MCPBridgeNaming.plistName).status
        )
        registration = fresh
        if !fresh.isUsable {
            // A registration that is no longer usable cannot also be
            // "published but failing for a specific reason" — the reason is
            // now the registration state itself, and keeping the stale string
            // would print a connection error underneath a panel telling the
            // user to set the bridge up.
            isPublished = false
            lastPublishFailure = nil
        }
    }

    // MARK: - Registration (user-initiated only)

    func register() throws {
        let service = SMAppService.agent(plistName: MCPBridgeNaming.plistName)
        do {
            try service.register()
            Self.logger.notice("Registered the command-line bridge; status is now \(String(describing: service.status), privacy: .public)")
        } catch {
            // Rethrown, not swallowed. On a build without a Developer ID
            // certificate this is the *expected* outcome and the pane prints it
            // verbatim — a setup button that failed silently and left the
            // feature dead would be indistinguishable from one that did
            // nothing.
            Self.logger.error("Command-line bridge registration failed: \(error.localizedDescription, privacy: .public)")
            registration = .unavailable(reason: error.localizedDescription)
            throw error
        }
        refresh()
        publishIfRegistered()
    }

    func unregister() throws {
        withdraw()
        let service = SMAppService.agent(plistName: MCPBridgeNaming.plistName)
        defer { refresh() }
        try service.unregister()
        Self.logger.notice("Unregistered the command-line bridge.")
    }

    // MARK: - Publishing

    /// Hands the bridge our anonymous endpoint, if — and only if — the agent
    /// is registered.
    ///
    /// **Gated on `registration.isUsable` rather than attempted
    /// optimistically.** Connecting to an unregistered Mach service is not
    /// harmful, but it produces a connection that fails asynchronously with a
    /// generic error, and doing that on every launch of every unconfigured
    /// install would put a recurring, meaningless failure in the log of every
    /// user who never wanted this feature. The status read that avoids it is
    /// free.
    func publishIfRegistered() {
        guard registration.isUsable else { return }

        let connection = NSXPCConnection(machServiceName: MCPBridgeNaming.machService)
        connection.remoteObjectInterface = NSXPCInterface(with: MCPBridgeProtocol.self)

        // Interruption, not invalidation, is the recoverable one: launchd
        // retired an idle bridge (which it is designed to do — see
        // `BridgeService.armIdleTimerLocked`) and will start a fresh one whose
        // table is empty. Nobody but this app can refill it, so re-publishing
        // here is not an optimisation, it is the only thing keeping the
        // feature working past the first five idle minutes.
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                Self.logger.notice("Bridge connection interrupted; re-publishing.")
                self.isPublished = false
                self.bridgeConnection = nil
                self.publishIfRegistered()
            }
        }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isPublished = false
                self.bridgeConnection = nil
            }
        }
        connection.resume()
        bridgeConnection = connection

        let endpoint = endpointVendor.listener.endpoint
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.isPublished = false
                self.lastPublishFailure = error.localizedDescription
                Self.logger.error("Couldn't publish to the bridge: \(error.localizedDescription, privacy: .public)")
            }
        } as? MCPBridgeProtocol

        guard let proxy else {
            lastPublishFailure = "The bridge answered with something Sentry doesn't recognise as the bridge interface."
            return
        }

        proxy.publish(endpoint) { [weak self] ok, message in
            Task { @MainActor in
                guard let self else { return }
                self.isPublished = ok
                self.lastPublishFailure = ok ? nil : (message ?? "The bridge refused Sentry's connection point without saying why.")
                if ok { Self.logger.notice("Published Sentry's connection point to the bridge.") }
            }
        }
    }

    /// Best-effort withdrawal on orderly quit.
    ///
    /// Best-effort is the honest word and the reason is on the other side of
    /// the boundary: `BridgeService` also drops the endpoint when the
    /// publishing connection invalidates, which is what actually covers a
    /// crash or a force-quit. This method only makes the common case — the
    /// user chooses Quit — retire the entry immediately, so a `sentryctl` run a
    /// second later says "Sentry isn't running" rather than failing to reach a
    /// stale endpoint with a vaguer message.
    func withdraw() {
        guard let bridgeConnection else { return }
        let proxy = bridgeConnection.remoteObjectProxyWithErrorHandler { _ in } as? MCPBridgeProtocol
        proxy?.withdraw { _ in }
        isPublished = false
    }
}

/// Owns the anonymous listener and gates who may connect to it.
///
/// **Why gate at all, when an anonymous endpoint is already an unguessable
/// capability?** Because "unguessable" describes how it is *found*, not who
/// may use it once found, and the bridge that hands it out applies only the
/// looser consumer requirement (see `MCPBridgePeerGate` for why it cannot
/// apply a tighter one). Checking again here costs three Security-framework
/// calls per connection — connections, not calls — and means a mistake in the
/// bridge's gate is not by itself sufficient to reach this app. Defence that
/// exists in only one process is defence that one bug removes.
///
/// A separate `NSObject` rather than a method on `MCPEndpointPublisher`
/// because `NSXPCListener` delivers these callbacks on queues of its own
/// choosing, and the publisher is `@MainActor`. Hopping to the main actor to
/// answer `shouldAcceptNewConnection` would mean a busy main thread could
/// stall an incoming connection — and the whole point of `sentryctl statusline`
/// is that it does not stall.
private final class MCPAppEndpointVendor: NSObject, NSXPCListenerDelegate {

    private static let logger = Logger(
        subsystem: "dev.malekswilam.sentry",
        category: "MCPAppEndpointVendor"
    )

    /// Anonymous: reachable only by a process that has been handed this
    /// endpoint, and needing no launchd registration whatsoever. That second
    /// property is the one that makes this whole design work — see
    /// `MCPBridgeContract`.
    let listener = NSXPCListener.anonymous()

    private let service: SentryXPCServiceProtocol
    private let evaluator: MCPBridgePeerEvaluator
    private let ownPID = getpid()

    init(service: SentryXPCServiceProtocol, evaluator: MCPBridgePeerEvaluator) {
        self.service = service
        self.evaluator = evaluator
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let decision = MCPBridgePeerGate.decide(
            pid: connection.processIdentifier,
            ownPID: ownPID,
            requirement: MCPBridgePeerGate.consumerRequirement,
            evaluator: evaluator
        )
        guard case .accept = decision else {
            if case .reject(let failure) = decision {
                Self.logger.error("Refused an MCP connection from pid \(connection.processIdentifier, privacy: .public): \(failure.message, privacy: .public)")
            }
            return false
        }

        // Per-connection, the standard `NSXPCListener` pattern, and cheap:
        // `service` is one shared `MCPXPCService`, not a per-client instance.
        // Every actual authorization decision still happens per method call
        // inside it, against live settings — see `SentryXPCServiceProtocol`'s
        // doc comment. This gate answers "may you connect", never "may you do
        // this".
        connection.exportedInterface = NSXPCInterface(with: SentryXPCServiceProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
