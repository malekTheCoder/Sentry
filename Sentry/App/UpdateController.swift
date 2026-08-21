import AppKit
import Combine
import Sparkle
import SentryKit

// MARK: - UpdateController: Sentry's only update channel, and its refusal to pretend

/// Owns the app's single `SPUStandardUpdaterController` and everything the
/// Settings UI needs to talk about updates honestly.
///
/// **Why Sparkle exists here at all.** Sentry ships outside the Mac App
/// Store — Developer ID signing plus notarization, no App Store receipt, no
/// `storeKit` update path. That leaves exactly one way for an installed copy
/// to become a newer copy without the user hunting down a download page, and
/// this is it. It also means the update channel is security-critical
/// infrastructure rather than a convenience: whatever this code fetches and
/// runs, it runs as the user, from a binary this app chose to trust.
///
/// **Constructed once, for the app's lifetime, in the composition root.**
/// Same shape as `mcpListener`, `localSyncServer`, and `powerControl` in
/// `AppDelegate` — one instance, created at launch, never rebuilt. Sparkle's
/// updater keeps scheduling state (when the last check ran, when the next
/// one is due) in `UserDefaults`, so a second instance would reconcile
/// against — and fight over — the first's record, exactly the reasoning
/// `powerControl`'s doc comment gives for its own singleton-ness.
///
/// **The one thing this type does differently from its siblings: it may
/// decline to exist.** `mcpListener` and `localSyncServer` are started
/// unconditionally and gated internally, because a disabled feature should
/// reject cleanly rather than be unreachable. That reasoning does *not*
/// transfer here, and the difference is worth stating because it looks like
/// an inconsistency:
///
///   - An inert XPC listener costs nothing and lies to nobody. An updater
///     whose configuration is broken does not sit inert — it runs, it
///     fetches, it finds nothing it can verify, and it reports "You're up
///     to date!" That sentence is a claim about the world, and it would be
///     false. A user who reads it stops looking for updates.
///   - So `UpdateController` inspects `UpdateFeedConfiguration`
///     (`SentryKit/Updates/UpdateFeedConfiguration.swift`) *before*
///     constructing anything, and if the answer isn't `.ready` it never
///     creates an `SPUStandardUpdaterController` at all. `availability` then
///     carries the reason, and Settings ▸ General prints it instead of
///     offering a button.
///
/// This is the same rule `SyncPane` was written to — never ship a control
/// that silently does nothing — applied to the one
/// feature where "silently does nothing" and "silently reassures you" are
/// the same failure.
///
/// **What state this build is actually in.** `SUPublicEDKey` in
/// `project.yml` is `UpdateFeedConfiguration.placeholderPublicKey`, so
/// `availability` is `.publicKeyPlaceholder` and no updater is constructed.
/// That is not a bug to be worked around — the private half of that key pair
/// is a secret only the developer may hold, and generating it here would
/// mean the signing key for every future release had passed through a build
/// script. See `docs/sparkle-release-signing.md` for the two commands that
/// change this, and for why the private key must be backed up before the
/// first release rather than after.
///
/// **Signing implications this type creates.** Linking Sparkle puts
/// `Sparkle.framework` inside the app bundle (Xcode embeds SPM binary
/// targets automatically — see `project.yml`'s note on why `embed: false` is
/// correct there), and that framework is not a single Mach-O. Verified
/// contents of the 2.9.4 bundle, under `Versions/B/`: `Autoupdate`,
/// `Updater.app`, `XPCServices/Downloader.xpc`, `XPCServices/Installer.xpc`.
/// Every one of them is nested code that must be signed, inside-out, with
/// the same Developer ID identity and hardened runtime as the app, before
/// notarization — `codesign --deep` is not sufficient and Apple documents it
/// as unsupported. This file does not configure signing (that work is
/// happening separately); it only records that the nested-code shape of the
/// bundle changed here.
@MainActor
final class UpdateController: NSObject, ObservableObject {

    /// Why the updater can or cannot run, resolved once at construction.
    /// `@Published` because `startFailed` is decided during `init` and the
    /// pane reads it live; it does not otherwise change during a run — an
    /// `Info.plist` cannot be edited out from under a running app, and
    /// re-checking on every render would only invent a way for the UI to
    /// flicker between truths.
    @Published private(set) var availability: UpdaterAvailability

    /// `nil` whenever `availability != .ready`. The optionality *is* the
    /// safety property: there is no code path that can ask a misconfigured
    /// build to check for updates, because there is no object to ask.
    private let updaterController: SPUStandardUpdaterController?

    /// Sparkle's own default is a day; `AppSettings.updateCheckDaily` is
    /// named for it, and the settings UI describes it as "once a day," so
    /// the number is spelled out here rather than left to Sparkle's default
    /// changing under us.
    private static let dailyCheckInterval: TimeInterval = 60 * 60 * 24

    /// - Parameter bundle: the bundle whose `Info.plist` carries `SUFeedURL`
    ///   and `SUPublicEDKey`. Defaults to `.main`; injectable so a test can
    ///   drive the misconfigured paths without a rebuilt app.
    init(bundle: Bundle = .main) {
        let configuration = UpdateFeedConfiguration(bundle: bundle)
        let configured = configuration.availability

        guard configured.canCheckForUpdates else {
            // The whole point: no Sparkle object is created, so nothing can
            // schedule a check, hit the network, or display an "up to date"
            // alert derived from a feed it could never have verified.
            self.availability = configured
            self.updaterController = nil
            super.init()
            return
        }

        // `startingUpdater: false` so the failure is catchable. The
        // convenience `true` form swallows a start failure into a modal
        // alert at launch and leaves the controller in a state that reports
        // no error afterwards — for a menu-bar accessory app that can be
        // launched at login before anyone is looking at the screen, an alert
        // nobody sees is indistinguishable from silence.
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = controller
        self.availability = configured
        super.init()

        do {
            // `start()`, not `startUpdater()` — renamed in Sparkle 2.x, and
            // one of the reasons the version floor moved to 2.9.0.
            try controller.updater.start()
        } catch {
            // Downgrade to a stated reason rather than crashing or
            // pretending. `availability` is now `.startFailed`, so
            // `checkForUpdates()` refuses and the pane explains.
            self.availability = .startFailed(error.localizedDescription)
        }
    }

    // MARK: - Settings

    /// The reader `AppSettings.updateCheckDaily` never had.
    ///
    /// Called from `AppDelegate.applicationDidFinishLaunching` and again
    /// from `applySettings` on every emission, matching how
    /// `alertEngine.rateCapPerHour`, `coordinator.setBaseInterval`, and
    /// `rollupJob.setRetention` are kept current — the pane writes to
    /// settings and never touches this object, so this is the single place a
    /// toggle reaches the updater. Idempotent: assigning the same values is
    /// free, so an unrelated settings emission (a slider drag emits one per
    /// frame) costs nothing.
    ///
    /// A no-op when no updater exists. That is not a swallowed failure — the
    /// toggle in Settings ▸ General is disabled and captioned in exactly
    /// that case, so there is no state where the user believes they have
    /// enabled something that isn't running.
    func applySettings(_ settings: AppSettings) {
        guard let updater = updaterController?.updater else { return }
        updater.automaticallyChecksForUpdates = settings.updateCheckDaily
        updater.updateCheckInterval = Self.dailyCheckInterval
    }

    // MARK: - Actions

    /// Runs a user-initiated check, showing Sparkle's own UI (progress,
    /// release notes, install prompt).
    ///
    /// Guarded rather than optional-chained into silence: if this is ever
    /// called while `availability` isn't `.ready`, that's a wiring mistake in
    /// the pane, and it should be visible in the log rather than produce a
    /// button that appears to work. The pane's own `.disabled` state is the
    /// real gate.
    func checkForUpdates() {
        guard let updater = updaterController?.updater, availability.canCheckForUpdates else {
            assertionFailure("checkForUpdates() called while \(availability) — the UI should have disabled this control")
            return
        }
        // An accessory (`LSUIElement`) app's windows open behind everything
        // else otherwise, same reason `togglePopover` activates.
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates()
    }
}
