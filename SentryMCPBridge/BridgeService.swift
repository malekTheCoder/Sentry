import Foundation
import os

/// The bridge's whole implementation: one endpoint, two gates, an idle timer.
///
/// **Read `MacStatKit/MCPBridge/MCPBridgeContract.swift` first.** It carries
/// the measurement that forced this design (only the process launchd started
/// as the job may vend the job's Mach service), the reason this is a
/// rendezvous broker rather than a relay, and the list of what has never been
/// observed on an unsigned machine.
///
/// **State is one optional endpoint.** Not a dictionary keyed by anything, not
/// a history, not a log of who asked. There is exactly one Sentry, it
/// publishes once per launch, and a second publisher would be an impostor the
/// gate already refused. Keeping the state this small is the reason this file
/// is short enough to audit in one sitting, which is the same argument
/// `FanDaemonContract` makes for the daemon's three-case command vocabulary.
///
/// **Queue-confined, not actor-isolated.** `NSXPCListener` delivers
/// connections and calls on queues of its own choosing, so every access to
/// `published` goes through `queue`. An actor would have forced every
/// `@objc` reply block into an unstructured `Task`, which buys nothing here —
/// there is no `await` in any of these methods.
final class BridgeService: NSObject, MCPBridgeProtocol, NSXPCListenerDelegate {

    private static let logger = Logger(
        subsystem: MCPBridgeNaming.label,
        category: "BridgeService"
    )

    private let queue = DispatchQueue(label: "\(MCPBridgeNaming.label).state")
    private let evaluator: MCPBridgePeerEvaluator
    private let ownPID: Int32

    /// Sentry's anonymous listener endpoint, if Sentry has published one this
    /// launch. `nil` is a meaningful, common, non-error state — see
    /// `resolveAppEndpoint`.
    private var published: NSXPCListenerEndpoint?

    /// The connection the endpoint arrived on, kept solely so its invalidation
    /// can clear `published`. This is the path that actually covers Sentry
    /// crashing or being force-quit; `withdraw` covers only the orderly case.
    private var publisherConnection: NSXPCConnection?

    /// Fires when nothing has happened for `MCPBridgeTiming.idleExitAfter`.
    /// See `armIdleTimerLocked` for why a broker exits at all.
    private var idleTimer: DispatchSourceTimer?

    init(evaluator: MCPBridgePeerEvaluator, ownPID: Int32 = getpid()) {
        self.evaluator = evaluator
        self.ownPID = ownPID
        super.init()
        queue.async { [self] in armIdleTimerLocked() }
    }

    // MARK: - NSXPCListenerDelegate

    /// **Admission is the looser of the two checks.** Both Sentry and the
    /// command-line tools arrive here, and only the consumer requirement can
    /// describe both (see `MCPBridgePeerGate` for why the tools cannot be
    /// named by an `identifier` clause). Anything that fails it never gets as
    /// far as having an exported object.
    ///
    /// The stricter publisher check is *not* made here and cached on the
    /// connection. `NSXPCConnection` has no place to hang that, and the
    /// alternative — a side table keyed by connection — would be state whose
    /// only purpose is to let an authorization decision go stale. It is made
    /// instead at the moment `publish`/`withdraw` are actually called, against
    /// the connection currently being served, which is both simpler and
    /// strictly fresher.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier

        let decision = MCPBridgePeerGate.decide(
            pid: pid,
            ownPID: ownPID,
            requirement: MCPBridgePeerGate.consumerRequirement,
            evaluator: evaluator
        )

        guard decision.isAccepted else {
            // On an unsigned build this line fires for every connection and
            // says so in as many words — which is the intended, inert state,
            // not a mystery to be debugged.
            if case .reject(let failure) = decision {
                Self.logger.error("Refused a connection from pid \(pid, privacy: .public): \(failure.message, privacy: .public)")
            }
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: MCPBridgeProtocol.self)
        connection.exportedObject = self
        connection.resume()

        Self.logger.notice("Accepted a connection from pid \(pid, privacy: .public)")
        queue.async { [self] in armIdleTimerLocked() }
        return true
    }

    /// Whether the call currently being served comes from Sentry itself.
    ///
    /// `NSXPCConnection.current()` is the documented way to reach the
    /// connection from inside an exported method, and returns `nil` when
    /// called from anywhere else. **`nil` is treated as "not the publisher"** —
    /// fail closed, the same rule `MCPBridgePeerGate` follows throughout: a
    /// call whose provenance cannot be established does not get the privileged
    /// half of this interface.
    private func callerIsPublisher() -> Bool {
        guard let connection = NSXPCConnection.current() else { return false }
        return MCPBridgePeerGate.decide(
            pid: connection.processIdentifier,
            ownPID: ownPID,
            requirement: MCPBridgePeerGate.publisherRequirement,
            evaluator: evaluator
        ).isAccepted
    }

    // MARK: - MCPBridgeProtocol

    func publish(_ endpoint: NSXPCListenerEndpoint, reply: @escaping (Bool, String?) -> Void) {
        guard callerIsPublisher() else {
            Self.logger.error("Refused a publish from a connection that wasn't admitted as Sentry.")
            reply(false, "Only Sentry itself can publish a connection point to the bridge.")
            return
        }

        let connection = NSXPCConnection.current()
        queue.async { [self] in
            published = endpoint
            publisherConnection = connection

            // Invalidation, not interruption, is what clears the table. An
            // interruption is recoverable and Sentry re-publishes on its own
            // (see `MCPEndpointPublisher`); dropping the endpoint on one would
            // create a window where a `macstat` call is told Sentry isn't
            // running while Sentry is very much running and reconnecting.
            connection?.invalidationHandler = { [weak self] in
                self?.clearPublishedEndpoint(reason: "Sentry's connection to the bridge was invalidated")
            }

            armIdleTimerLocked()
            Self.logger.notice("Sentry published its connection point.")
            reply(true, nil)
        }
    }

    func withdraw(reply: @escaping (Bool) -> Void) {
        guard callerIsPublisher() else {
            // Deliberately not an error the caller can distinguish: a consumer
            // asking to withdraw is either confused or hostile, and telling it
            // which check it failed teaches it something. The publisher path
            // is the only one that can observe a meaningful result anyway.
            reply(false)
            return
        }
        clearPublishedEndpoint(reason: "Sentry withdrew its connection point")
        reply(true)
    }

    func resolveAppEndpoint(reply: @escaping (NSXPCListenerEndpoint?, String?) -> Void) {
        queue.async { [self] in
            armIdleTimerLocked()
            guard let published else {
                // The single most valuable message this whole change adds.
                // Reaching this line proves the bridge is registered, running,
                // and reachable — so the only remaining explanation is that
                // Sentry is not running, and the client can say exactly that
                // instead of the old catch-all.
                reply(nil, "Sentry's command-line bridge is running, but Sentry hasn't connected to it. Sentry is probably not running.")
                return
            }
            reply(published, nil)
        }
    }

    // MARK: - Lifetime

    private func clearPublishedEndpoint(reason: String) {
        queue.async { [self] in
            guard published != nil else { return }
            published = nil
            publisherConnection = nil
            armIdleTimerLocked()
            Self.logger.notice("Cleared the published connection point: \(reason, privacy: .public)")
        }
    }

    /// Restarts the idle countdown. Called on every connection and every call.
    ///
    /// **Why a broker exits at all.** Same reasoning as
    /// `FanDaemonTiming.idleExitAfter`, minus the root process: a user who
    /// drags Sentry to the Trash without unregistering leaves a launchd job
    /// that can never start again, and a copy that happens to be running
    /// should retire rather than linger indefinitely holding a stale endpoint.
    /// Exiting is free here — launchd starts a fresh one the next time a
    /// client connects, and the only state lost is an endpoint that Sentry
    /// re-publishes on its next launch anyway.
    ///
    /// Deliberately **not** `KeepAlive` in the plist, for the same reason: a
    /// process that cannot stay dead cannot be its own cleanup mechanism.
    private func armIdleTimerLocked() {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + MCPBridgeTiming.idleExitAfter)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Self.logger.notice("Idle for \(Int(MCPBridgeTiming.idleExitAfter), privacy: .public)s; exiting. launchd will start a new one on demand.")
            exit(EXIT_SUCCESS)
        }
        timer.resume()
        idleTimer = timer
    }
}
