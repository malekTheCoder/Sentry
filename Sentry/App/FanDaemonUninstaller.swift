import Foundation
import ServiceManagement
import os

/// Removes the root fan daemon that older builds of Sentry could install.
///
/// **This file is a tombstone, and it is deliberately the last thing left
/// standing from the fan-control feature.** Sentry no longer sets fan
/// speeds — the whole write path (`SentryFanDaemon`, `FanControlService`,
/// `PrivilegedFanControlBackend`, Settings ▸ Fans) is gone, and fan RPM is
/// now purely something the app reads and displays. But a user who pressed
/// "Install" in the old Fans pane has a `LaunchDaemon` registered on their
/// Mac *right now*, running as uid 0, and deleting the code that created it
/// does not delete it. It would sit in System Settings ▸ Login Items &
/// Extensions forever, attributed to an app that no longer has a single
/// screen capable of removing it: a privileged process with no owner.
///
/// Shipping the removal without shipping this would not be a cleanup, it
/// would be a security regression. So the one capability that survives the
/// removal of fan control is the capability to *undo* it.
///
/// **How it decides, and why it can't just always call `unregister()`.**
/// `SMAppService.daemon(plistName:)` reports one of four statuses, and the
/// distinction between them is the entire safety argument:
///
///   * `.enabled` / `.requiresApproval` — this Mac has the daemon
///     registered (approved, or waiting for the user to approve it in
///     System Settings). These are the users who pressed Install. Remove
///     it.
///   * `.notRegistered` — the plist is in the bundle, nothing is
///     registered. **This is every user who never turned fan control on,
///     which is the overwhelming majority**, and this type does nothing at
///     all for them: no `unregister()` call, no authorization prompt, no
///     log line beyond a debug trace.
///   * `.notFound` — the plist is missing from the bundle. Also a no-op;
///     see the note on the plist below for why it is still there.
///
/// Calling `unregister()` unconditionally would be simpler and wrong.
/// Removing a daemon is a privileged operation, and the honest assumption
/// is that macOS may put an authorization prompt in front of it. A prompt
/// shown to a user who never installed anything is an app accusing itself
/// of something it didn't do, on a launch where nothing happened.
///
/// **Idempotent by construction, with nothing persisted.** The status read
/// *is* the memory. Once the daemon is gone the status is `.notRegistered`
/// and every subsequent launch takes the no-op branch, so this needs no
/// "already migrated" flag in `AppSettings` — which is fortunate, because
/// such a flag would be a second piece of fan-control residue to remove
/// later, and the migration would then depend on a settings file that a
/// corrupt-file fallback can legitimately reset.
///
/// **Why the launchd plist is still in the app bundle.** `Uninstall/dev
/// .malekswilam.sentry.fandaemon.plist` is copied into
/// `Contents/Library/LaunchDaemons/` by the app target, exactly as before,
/// even though the binary it names no longer exists. That is not an
/// oversight. `SMAppService.daemon(plistName:)` resolves a service *by
/// looking that file up in that directory*; with the file removed, every
/// Mac reports `.notFound` and this type can no longer tell "was never
/// installed" from "is installed and I can't see it any more" — and the
/// documented way to remove a service is to call `unregister()` while its
/// plist is still present. Deleting the plist first is how an orphaned
/// daemon becomes permanent. The plist is inert on its own: a launchd job
/// description installs nothing until something registers it, and nothing
/// in this build registers anything.
///
/// **When this whole file can be deleted.** When no install in the field
/// can still predate the fan-control removal — practically, a couple of
/// releases after the one that carries it. Deleting it means deleting
/// three things together: this type, its call from `AppDelegate`, and
/// `Uninstall/dev.malekswilam.sentry.fandaemon.plist` along with the copy
/// phase in `project.yml` that installs it. Any subset leaves either a
/// plist nothing can act on or a remover with nothing to find.
///
/// **What has never been observed, stated plainly.** The machine this was
/// written on has the daemon registered nowhere (`/Library/LaunchDaemons`
/// holds no Sentry entry; `launchctl print system/dev.malekswilam.sentry
/// .fandaemon` reports it not found), and it has no code-signing
/// identities, so `register()` could never have succeeded here in the first
/// place. Every branch except `.notRegistered` is therefore untested
/// against real macOS. That is precisely why the branches are expressed as
/// a pure function over `SMAppService.Status` (`decide(for:)`, exercised
/// exhaustively by `FanDaemonUninstallerTests`) and why the failure
/// posture is "log it and move on": a removal that throws on some machine
/// this could not be tried on must not be able to stop the app from
/// launching.
enum FanDaemonUninstaller {

    private static let logger = Logger(
        subsystem: "dev.malekswilam.sentry",
        category: "FanDaemonUninstaller"
    )

    /// The basename of the launchd job description in
    /// `Sentry.app/Contents/Library/LaunchDaemons/`, passed verbatim to
    /// `SMAppService.daemon(plistName:)`.
    ///
    /// Frozen. This used to be derived from `FanDaemonNaming.label` in
    /// `SentryKit/FanDaemon/FanDaemonContract.swift`, which is deleted — but
    /// the string itself cannot change, because it names something already
    /// registered on other people's Macs. A typo here is not a build error,
    /// it is a daemon that never gets removed, so
    /// `FanDaemonUninstallerTests` pins it against the shipped plist's
    /// `Label`.
    static let plistName = "dev.malekswilam.sentry.fandaemon.plist"

    /// What to do about a given registration status. Pure, so the three
    /// branches this machine cannot produce are still testable.
    enum Action: Equatable {
        /// Registered (approved or pending approval) — remove it.
        case unregister
        /// Nothing registered under this name, or no plist to register.
        /// Leave the machine alone and say nothing to the user.
        case doNothing
    }

    static func decide(for status: SMAppService.Status) -> Action {
        switch status {
        case .enabled, .requiresApproval:
            return .unregister
        case .notRegistered, .notFound:
            return .doNothing
        @unknown default:
            // A status this build has never heard of is not grounds for
            // firing a privileged operation at it. The old
            // `PrivilegedFanControlBackend` took the same line in the other
            // direction — an unrecognised status was never treated as
            // permission to write to the SMC — and the principle is the
            // same one: unknown means don't act.
            return .doNothing
        }
    }

    /// Runs the removal. Safe to call on every launch; safe to call when
    /// nothing is installed; safe to call twice.
    ///
    /// The two closures exist for the reason `PrivilegedFanControlBackend`
    /// and `MCPEndpointPublisher` both inject their `SMAppService` probes:
    /// on a machine with no signing identities the real API can only ever
    /// report one value, which would leave the branch that actually matters
    /// permanently unexercised. Production passes neither and the real
    /// service is used.
    ///
    /// - Returns: `true` when a registered daemon was found and
    ///   `unregister()` did not throw. Used by tests and by the log line;
    ///   no caller in the app branches on it.
    @discardableResult
    static func removeIfInstalled(
        statusProbe: (() -> SMAppService.Status)? = nil,
        unregister: (() throws -> Void)? = nil
    ) -> Bool {
        let service = SMAppService.daemon(plistName: plistName)
        let status = statusProbe?() ?? service.status

        guard decide(for: status) == .unregister else {
            logger.debug(
                "No fan daemon to remove (status \(String(describing: status), privacy: .public))."
            )
            return false
        }

        logger.notice(
            "Found a registered fan daemon (status \(String(describing: status), privacy: .public)); removing it — Sentry no longer sets fan speeds."
        )

        do {
            try unregister?() ?? service.unregister()
        } catch {
            // Logged, never surfaced, never fatal. The user did not ask for
            // this and cannot act on it: there is no fan UI left to send
            // them to, and the manual fallback (System Settings ▸ Login
            // Items & Extensions, where the daemon appears attributed to
            // Sentry thanks to `AssociatedBundleIdentifiers` in the plist)
            // is somewhere they can reach without being told. Retrying next
            // launch is free, because the status check makes this
            // idempotent.
            logger.error(
                "Removing the fan daemon failed: \(error.localizedDescription, privacy: .public). It can also be turned off in System Settings ▸ General ▸ Login Items & Extensions."
            )
            return false
        }

        // Verify rather than assume. `unregister()` returning without
        // throwing is not the same claim as "it's gone" — and if it is
        // still there, the next launch will try again, so the useful thing
        // to do here is leave evidence in the log rather than pretend.
        let after = statusProbe?() ?? SMAppService.daemon(plistName: plistName).status
        if decide(for: after) == .doNothing {
            logger.notice("Fan daemon removed; nothing of it is registered any more.")
            return true
        } else {
            logger.error(
                "Asked macOS to remove the fan daemon but it still reports \(String(describing: after), privacy: .public). Will try again next launch."
            )
            return false
        }
    }
}
