import Foundation
import os

#if os(macOS)
import ServiceManagement

/// Plan §4.2's `PrivilegedHelperFanControlBackend`: the app-side client of
/// the root fan daemon.
///
/// **Inert by default, and inert when unregistered. This is the property
/// that makes the branch safe to merge.** Constructing this type performs
/// exactly one privileged-adjacent operation: it asks `SMAppService` what
/// the *status* of the daemon registration is, which is a local read that
/// prompts nothing, launches nothing, and connects to nothing. On a machine
/// where the helper was never installed — every fresh install, and every
/// build made on a Mac without signing certificates, where registration
/// cannot succeed at all — the answer is `.notRegistered`, and from that
/// moment this type behaves exactly like `SMCReadOnlyFanControlBackend`:
/// live RPM from the SMC, every write refused with a printed reason, no
/// XPC connection ever created. There is no code path from app launch to
/// `SMAppService.register()`; the only caller is
/// `installPrivilegedHelper()`, and its only caller is a button.
///
/// **Reads never travel through the privileged path.** `capability()` and
/// `readActualRPMs()` forward, unchanged, to the read-only backend this
/// type wraps. So a broken, missing, refused, or crashed helper cannot make
/// the Fans pane say anything different about what this Mac's fans are
/// doing. The two halves fail independently on purpose: the worst version
/// of this feature is one where installing a background service is a
/// precondition for seeing a number the app could already read.
///
/// **Synchronous XPC, deliberately.** `FanControlBackend` has been a
/// synchronous throwing seam since Phase 2 and the Settings pane is written
/// against it, so this type uses
/// `synchronousRemoteObjectProxyWithErrorHandler` rather than restructuring
/// the seam around `async`. The cost is real and worth naming: a call made
/// on the main actor blocks it until the daemon replies, and if launchd has
/// to *launch* the daemon first that can be a noticeable fraction of a
/// second. It is bounded (XPC surfaces its own timeout as an error through
/// the same handler), it happens only on explicit user actions — never on a
/// snapshot tick, never on the heartbeat, which runs on this type's own
/// queue — and the alternative was an async seam that would have rewritten
/// every Phase 2 call site in a change that already touches a root process.
///
/// **What has never been observed, and cannot be from this branch.**
/// Registration succeeding. A connection being established. The peer gate
/// on the far side returning `.accept`. Any SMC write. See
/// `SentryKit/FanDaemon/FanDaemonContract.swift` for why (zero signing
/// identities on the machine this was written on) and
/// `docs/fan-control-spike.md` for the first-run checklist that must be
/// walked once real certificates exist.
public final class PrivilegedFanControlBackend: FanControlBackend {

    private static let logger = Logger(
        subsystem: "dev.malekswilam.sentry.kit",
        category: "PrivilegedFanControlBackend"
    )

    public let identifier = "privileged-helper"

    /// Everything about *this Mac's fans* comes from here, always. See the
    /// type doc comment.
    private let reading: FanControlBackend

    /// Serialises the connection, the heartbeat timer, and `heldFans`.
    /// Queue-confined rather than main-actor-isolated because the heartbeat
    /// must keep firing while the main actor is busy — a fan handed back
    /// because the app was drawing a sheet would be a spectacular bug.
    private let queue = DispatchQueue(label: "dev.malekswilam.sentry.fanhelper")

    private var connection: NSXPCConnection?
    private var heartbeatTimer: DispatchSourceTimer?

    /// Fan ordinals this *app* believes it has taken out of firmware
    /// control. The daemon keeps its own authoritative set
    /// (`FanDaemonFailSafe.heldFans`) and the two can legitimately
    /// disagree — after an app relaunch this one is empty while the
    /// daemon's may not be. It is used only to decide whether the heartbeat
    /// needs to run; every actual revert decision is the daemon's.
    private var heldFans: Set<Int> = []

    /// Cached so the UI can ask on every redraw without hitting
    /// `SMAppService` each time. Refreshed at construction, after an
    /// install or removal, and whenever a connection fails — the three
    /// moments it can actually change.
    private var cachedStatus: SMAppService.Status

    /// The last connection-level failure, kept so
    /// `.helperUnreachable(reason:)` can say something specific instead of
    /// "it didn't work". Cleared on a successful call.
    private var lastFailureReason: String?

    /// Injectable so tests can drive `writeAvailability`'s whole decision
    /// table without `SMAppService` — which on a machine with no signing
    /// identities can only ever report one value, making every branch but
    /// that one untestable. Production passes `nil` and the real service is
    /// consulted.
    private let statusProbe: (() -> SMAppService.Status)?

    public init(
        reading: FanControlBackend,
        statusProbe: (() -> SMAppService.Status)? = nil
    ) {
        self.reading = reading
        self.statusProbe = statusProbe
        self.cachedStatus = statusProbe?() ?? SMAppService.daemon(
            plistName: FanDaemonNaming.plistName
        ).status
    }

    deinit {
        // Best-effort only, and named as such. `deinit` on a type the app
        // holds for its whole lifetime realistically runs at process exit,
        // where the connection is about to be torn down by the kernel
        // anyway — at which point the *daemon's* `invalidationHandler`
        // fires and reverts. That is the mechanism that matters, and it is
        // on the other side of the boundary on purpose: see
        // `FanDaemonFailSafe`'s note on why the app-side watchdog is the
        // weaker of the two.
        heartbeatTimer?.cancel()
        connection?.invalidate()
    }

    // MARK: - Reads (forwarded, always)

    public func capability() -> FanControlCapability { reading.capability() }

    public func readActualRPMs() -> [Double] { reading.readActualRPMs() }

    // MARK: - Availability

    public var writeAvailability: FanWriteAvailability {
        // Hardware facts outrank helper facts. A fanless Air with a
        // perfectly healthy helper installed still has nothing to write to,
        // and telling its owner to go approve a background item would be
        // sending them to fix the wrong thing.
        switch reading.capability() {
        case .noFansPresent:
            return .noFans
        case .unreadable:
            return .hardwareUnreadable
        case .supported:
            break
        }

        let status = queue.sync { cachedStatus }
        switch status {
        case .enabled:
            if let reason = queue.sync(execute: { lastFailureReason }) {
                return .helperUnreachable(reason: reason)
            }
            return .available
        case .requiresApproval:
            return .helperAwaitingApproval
        case .notRegistered, .notFound:
            return .needsPrivilegedHelper
        @unknown default:
            // A status this build has never heard of is not a status this
            // build should treat as permission to write to the SMC as root.
            return .helperUnreachable(
                reason: "macOS reported a helper state Sentry doesn't recognise, so it isn't assuming the helper is usable."
            )
        }
    }

    public var supportsPrivilegedHelper: Bool {
        // Offered only where it could do something. On hardware with no
        // readable fans an install button is a button whose best possible
        // outcome is a root process with nothing to do.
        reading.capability().canReadFanSpeeds
    }

    /// Re-reads `SMAppService.Status`. Cheap, prompts nothing. Called by
    /// the pane when it appears and after the user returns from System
    /// Settings, which is the one moment `.requiresApproval` becomes
    /// `.enabled` without anything happening inside this app.
    public func refreshWriteAvailability() { refreshHelperStatus() }

    public func refreshHelperStatus() {
        let fresh = statusProbe?() ?? SMAppService.daemon(
            plistName: FanDaemonNaming.plistName
        ).status
        queue.sync {
            cachedStatus = fresh
            if fresh != .enabled {
                // A helper that is no longer enabled cannot be "unreachable
                // for a reason" — the reason is now the status itself, and
                // keeping the stale string would show the user a specific
                // connection error underneath a screen telling them to
                // install the helper.
                lastFailureReason = nil
            }
        }
    }

    // MARK: - Helper lifecycle (user-initiated only)

    public func installPrivilegedHelper() throws {
        let service = SMAppService.daemon(plistName: FanDaemonNaming.plistName)
        do {
            try service.register()
            Self.logger.notice("Registered the fan helper; status is now \(String(describing: service.status), privacy: .public)")
        } catch {
            // Rethrown, not swallowed. On a machine with no signing
            // identities this is the *expected* outcome and the pane prints
            // it verbatim — an install button that failed silently and left
            // the controls disabled would be indistinguishable from one
            // that did nothing at all.
            Self.logger.error("Fan helper registration failed: \(error.localizedDescription, privacy: .public)")
            refreshHelperStatus()
            throw error
        }
        refreshHelperStatus()
    }

    public func removePrivilegedHelper() throws {
        // Hand every fan back *before* unregistering. Reversing these two
        // would tear down the daemon while it still holds fans and rely
        // entirely on its `SIGTERM` handler to clean up — which does work,
        // and which should not be the primary mechanism for the one path
        // where the app is standing right there and can ask nicely.
        returnEveryFanToFirmware()

        let service = SMAppService.daemon(plistName: FanDaemonNaming.plistName)
        defer { refreshHelperStatus() }
        try service.unregister()
        queue.sync {
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
            connection?.invalidate()
            connection = nil
            heldFans.removeAll()
            lastFailureReason = nil
        }
        Self.logger.notice("Unregistered the fan helper.")
    }

    // MARK: - Writes

    public func applyTarget(rpm: Double, toFan index: Int) throws {
        let availability = writeAvailability
        guard availability.canWrite else {
            throw FanControlWriteError.writesUnavailable(availability)
        }

        var thrown: Error?
        var applied: Double = -1
        var failureMessage: String?

        try withProxy { proxy, connectionError in
            if let connectionError {
                thrown = connectionError
                return
            }
            proxy?.setTarget(fanIndex: index, rpm: rpm) { appliedRPM, _, message in
                applied = appliedRPM
                failureMessage = message
            }
        }

        if let thrown { throw thrown }
        if let failureMessage {
            throw FanControlWriteError.helperRefused(reason: failureMessage)
        }
        // The sentinel is checked *after* the message, per
        // `FanDaemonProtocol.setTarget`'s contract — a failure that
        // produced a message must be reported with that message, and this
        // branch only catches a daemon that replied with neither.
        guard applied >= 0 else {
            throw FanControlWriteError.helperRefused(
                reason: "The fan helper replied without applying a speed and without saying why."
            )
        }

        queue.sync {
            heldFans.insert(index)
            lastFailureReason = nil
            startHeartbeatIfNeededLocked()
        }
    }

    public func revertToAuto(fan index: Int) throws {
        let availability = writeAvailability
        guard availability.canWrite else {
            throw FanControlWriteError.writesUnavailable(availability)
        }

        var thrown: Error?
        var succeeded = false
        var failureMessage: String?

        try withProxy { proxy, connectionError in
            if let connectionError {
                thrown = connectionError
                return
            }
            proxy?.returnToFirmware(fanIndex: index) { ok, message in
                succeeded = ok
                failureMessage = message
            }
        }

        if let thrown { throw thrown }
        guard succeeded else {
            throw FanControlWriteError.helperRefused(
                reason: failureMessage ?? "The fan helper wouldn't hand this fan back and didn't say why."
            )
        }

        queue.sync {
            heldFans.remove(index)
            lastFailureReason = nil
            stopHeartbeatIfIdleLocked()
        }
    }

    /// Best-effort revert of everything this app took. Used by
    /// `removePrivilegedHelper` and available to the app's own quit path.
    ///
    /// Swallows errors on purpose — it runs on teardown paths where there
    /// is nothing useful to do with a thrown error and nobody to show it
    /// to, and where the daemon's own disconnect handler is the guarantee
    /// regardless. That reasoning does *not* extend to `revertToAuto`,
    /// which is a user pressing a button and must report what happened.
    public func returnEveryFanToFirmware() {
        let fans = queue.sync { heldFans.sorted() }
        for index in fans {
            try? revertToAuto(fan: index)
        }
    }

    // MARK: - Connection

    /// Runs `body` with a synchronous proxy, creating the connection on
    /// first use.
    ///
    /// The connection is created lazily and *only* from here, so the
    /// inert path never opens one — see the type doc comment. Any XPC-level
    /// error is recorded in `lastFailureReason`, which flips
    /// `writeAvailability` from `.available` to `.helperUnreachable`, so a
    /// helper that stops answering disables the controls with a specific
    /// explanation rather than leaving them live and failing on every use.
    private func withProxy(
        _ body: (FanDaemonProtocol?, Error?) -> Void
    ) throws {
        let connection = queue.sync { () -> NSXPCConnection in
            if let existing = self.connection { return existing }
            let fresh = NSXPCConnection(
                machServiceName: FanDaemonNaming.machService,
                options: .privileged
            )
            fresh.remoteObjectInterface = NSXPCInterface(with: FanDaemonProtocol.self)
            fresh.invalidationHandler = { [weak self] in
                self?.handleConnectionLost(
                    reason: "The connection to the fan helper was closed. It may not be installed, or macOS may not have allowed it to start."
                )
            }
            fresh.interruptionHandler = { [weak self] in
                self?.handleConnectionLost(
                    reason: "The fan helper stopped responding. Any fans Sentry was holding have been handed back to your Mac's firmware."
                )
            }
            fresh.resume()
            self.connection = fresh
            return fresh
        }

        var capturedError: Error?
        let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { error in
            capturedError = error
        } as? FanDaemonProtocol

        if let capturedError {
            recordFailure(capturedError.localizedDescription)
            body(nil, FanControlWriteError.helperRefused(reason: capturedError.localizedDescription))
            return
        }
        guard let proxy else {
            let reason = "The fan helper answered with something Sentry doesn't recognise as the fan-control interface."
            recordFailure(reason)
            body(nil, FanControlWriteError.helperRefused(reason: reason))
            return
        }
        body(proxy, nil)
    }

    private func handleConnectionLost(reason: String) {
        queue.async { [self] in
            connection = nil
            heldFans.removeAll()
            lastFailureReason = reason
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
        }
        Self.logger.error("Fan helper connection lost: \(reason, privacy: .public)")
    }

    private func recordFailure(_ reason: String) {
        queue.sync { lastFailureReason = reason }
        Self.logger.error("Fan helper call failed: \(reason, privacy: .public)")
    }

    // MARK: - Heartbeat

    /// Arms the heartbeat while this app holds at least one fan.
    ///
    /// **This is the weaker half of safety requirement 4 and is written to
    /// look like it.** Its job is not to protect the machine — the daemon's
    /// own expiry timer does that, and does it precisely when this timer
    /// has stopped running because the app is wedged or dead. Its job is
    /// the opposite: to keep the daemon's expiry from firing while Sentry
    /// is genuinely fine. `PowerControlService` makes the same split
    /// between its app-level `Timer` and `kIOPMAssertionTimeoutKey`, and
    /// names the OS-level one as the mechanism that still works when the
    /// process doesn't.
    ///
    /// Runs on `queue`, not the main actor, so a busy or modal main thread
    /// cannot starve it.
    private func startHeartbeatIfNeededLocked() {
        guard heartbeatTimer == nil, !heldFans.isEmpty else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + FanDaemonTiming.heartbeatInterval,
            repeating: FanDaemonTiming.heartbeatInterval
        )
        timer.setEventHandler { [weak self] in
            self?.sendHeartbeat()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func stopHeartbeatIfIdleLocked() {
        guard heldFans.isEmpty else { return }
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    /// Asynchronous — unlike every other call in this type. The heartbeat
    /// must never block anything, and a beat that is late is exactly the
    /// signal the daemon is watching for, so there is nothing to wait on.
    private func sendHeartbeat() {
        guard let connection = queue.sync(execute: { self.connection }) else { return }
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.handleConnectionLost(reason: error.localizedDescription)
        } as? FanDaemonProtocol
        proxy?.heartbeat { _ in }
    }
}

#endif
