import Foundation

// MARK: - PostureState

/// A three-state answer to "is this protection turned on?".
///
/// **`.unknown` is a real answer, not a placeholder.** Several of the facts
/// this app would like to know (the launchd enable-state of sharing
/// services, firmware password status, the post-Ventura screen-lock delay)
/// simply cannot be read by an unprivileged process on a modern macOS. The
/// collector maps every one of those — and every command that is missing,
/// times out, exits non-zero, or prints something it doesn't recognize — to
/// `.unknown`, never to a guess. Rules must not treat `.unknown` as `.off`:
/// telling a user their firewall is off when the app couldn't tell would be
/// exactly the fabricated-reading failure this codebase removed a "0.0 W"
/// for.
public enum PostureState: String, Codable, Sendable, CaseIterable, Hashable {
    case on
    case off
    case unknown

    public var displayName: String {
        switch self {
        case .on: return String(localized: "On")
        case .off: return String(localized: "Off")
        case .unknown: return String(localized: "Unknown")
        }
    }

    /// `true` only for a definite reading. Sugar so rules read
    /// `posture.fileVault.isDefinitelyOff` instead of `== .off`, which is
    /// easy to typo into `!= .on` (a bug that silently swallows `.unknown`).
    public var isDefinitelyOn: Bool { self == .on }
    public var isDefinitelyOff: Bool { self == .off }
    public var isUnknown: Bool { self == .unknown }
}

/// The TCP ports macOS's Sharing services listen on, and the single source
/// of truth for both the collector (which looks for listeners on them) and
/// the rules (which quote the number in their evidence).
///
/// Kept here rather than in the collector so the number a rule prints can
/// never drift from the number the collector actually probed — the same
/// "two independent copies is precisely how the promise breaks" reasoning
/// `AppSettings.defaultAlertCooldownMinutes` states for its own constant.
public enum SharingServicePort {
    /// Remote Login (SSH).
    public static let remoteLogin = 22
    /// Screen Sharing / VNC.
    public static let screenSharing = 5900
    /// File Sharing over SMB.
    public static let fileSharing = 445
    /// Apple Remote Desktop's control channel.
    public static let remoteManagement = 3283
}

// MARK: - Drive health

/// `diskutil info -plist <volume>` → `SMARTStatus`.
///
/// Not a `PostureState`: SMART has a genuine third meaning beyond
/// on/off/unknown — "this device does not report SMART data at all", which
/// is common for external, virtual, and some Apple Fabric-attached volumes
/// and is not the same fact as "the read failed". Both collapse to
/// `.unknown` here because neither lets a rule say anything about the
/// drive's health, but the parser test suite keeps them conceptually
/// distinct in its naming even though the type does not.
public enum DriveSMARTState: String, Codable, Sendable, CaseIterable, Hashable {
    /// SMART reports the drive healthy ("Verified").
    case verified
    /// SMART reports a failing or pre-fail condition.
    case failing
    /// Unreadable, missing, or a status string this parser doesn't
    /// recognise — including "Not Supported".
    case unknown

    public var isDefinitelyFailing: Bool { self == .failing }
    public var isDefinitelyVerified: Bool { self == .verified }
}

// MARK: - TCC (privacy permission) visibility

/// How many distinct apps currently hold a *granted* (not merely requested)
/// TCC permission for five sensitive services, read from
/// `~/Library/Application Support/com.apple.TCC/TCC.db`.
///
/// **A single optional on `SecurityPosture`, not five.** All five counts
/// come from one query against one database in one subprocess call, so they
/// succeed or fail together — there is no scenario where Accessibility's
/// count is known but Camera's isn't. Bundling them means a rule either has
/// the whole picture or (honestly) none of it, with one `guard let` instead
/// of five.
///
/// **Why this can be read at all, and why it usually can't.** Reading
/// *another* app's TCC grants needs Full Disk Access — verified empirically
/// against this Mac's own TCC.db: a read-only `sqlite3` open, run as the
/// owning user, fails with "authorization denied" despite ordinary POSIX
/// permissions on the file permitting it. macOS enforces this at a layer
/// POSIX permissions don't reach. Sentry does not request Full Disk Access
/// by default, so on almost every installation this is `nil` and
/// `TCCAccessUnknownRule` is the one that fires, not this type's rule.
public struct TCCPermissionCounts: Codable, Sendable, Equatable {
    /// `kTCCServiceAccessibility`.
    public var accessibility: Int
    /// `kTCCServiceScreenCapture`.
    public var screenRecording: Int
    /// `kTCCServiceSystemPolicyAllFiles`.
    public var fullDiskAccess: Int
    /// `kTCCServiceCamera`.
    public var camera: Int
    /// `kTCCServiceMicrophone`.
    public var microphone: Int

    public init(accessibility: Int, screenRecording: Int, fullDiskAccess: Int, camera: Int, microphone: Int) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.fullDiskAccess = fullDiskAccess
        self.camera = camera
        self.microphone = microphone
    }
}

// MARK: - Login items / persistent background processes

/// `.plist` counts in the three standard locations background processes
/// register themselves for automatic launch.
///
/// **Names, not privileges, are what's missing here — and only sometimes.**
/// Listing a directory's own filenames needs no elevated privilege, even for
/// `/Library/LaunchDaemons`; only *reading the contents* of a daemon plist
/// owned by root would. This type never does that — it counts files, and
/// nothing here inspects what any one of them launches. See
/// `LoginItemsBloatRule`'s doc comment for why no item is ever named or
/// judged individually.
public struct LoginItemCounts: Codable, Sendable, Equatable {
    /// `.plist` files in `~/Library/LaunchAgents`.
    public var userAgents: Int
    /// `.plist` files in `/Library/LaunchAgents`.
    public var systemAgents: Int
    /// `.plist` files in `/Library/LaunchDaemons`.
    public var systemDaemons: Int

    public var total: Int { userAgents + systemAgents + systemDaemons }

    public init(userAgents: Int, systemAgents: Int, systemDaemons: Int) {
        self.userAgents = userAgents
        self.systemAgents = systemAgents
        self.systemDaemons = systemDaemons
    }
}

// MARK: - SecurityPosture

/// A point-in-time reading of this Mac's security and privacy posture.
///
/// Lives in SentryKit (rather than next to the collector in
/// SystemMetricsKit) so `ProtectionInsightsEngine` — which must compile for
/// iOS along with the rest of this module — can reason about it, and so
/// tests can construct one without spawning a single subprocess. The
/// *collection* half is `SystemMetricsKit/Security/SecurityPostureCollector.swift`,
/// macOS-only by construction.
///
/// **On the four sharing fields.** `remoteLogin` / `screenSharing` /
/// `fileSharing` / `remoteManagement` are **not** launchd queries — those
/// need root on modern macOS. They are listening-socket observations: a
/// process is accepting TCP connections on the port macOS's corresponding
/// Sharing service uses. That is a weaker claim than "Remote Login is
/// enabled in System Settings," and every string this app renders for them
/// says so. A third-party SSH server on port 22, or a VNC server that isn't
/// Apple's, produces the same reading — which is fine, because the security
/// question the user actually cares about ("can something reach my Mac on
/// that port?") is the one the observation answers.
public struct SecurityPosture: Codable, Sendable, Equatable {

    /// When this reading was taken. The UI shows it, because a cached
    /// posture from ten minutes ago is a fact about ten minutes ago.
    public var collectedAt: Date

    // MARK: Disk & system integrity

    /// `fdesetup status`. Full-disk encryption.
    public var fileVault: PostureState

    /// `csrutil status`. System Integrity Protection.
    public var systemIntegrityProtection: PostureState

    /// `spctl --status`. Gatekeeper assessment of downloaded apps.
    public var gatekeeper: PostureState

    // MARK: Network

    /// `socketfilterfw --getglobalstate`. The application firewall.
    public var firewall: PostureState

    /// `socketfilterfw --getstealthmode`.
    public var firewallStealthMode: PostureState

    // MARK: Updates

    /// `com.apple.SoftwareUpdate` → `AutomaticCheckEnabled`.
    public var automaticUpdateChecks: PostureState

    /// `com.apple.SoftwareUpdate` → `CriticalUpdateInstall`. Apple's Rapid
    /// Security Responses ride this key.
    public var automaticSecurityResponses: PostureState

    /// `com.apple.SoftwareUpdate` → `AutomaticallyInstallMacOSUpdates`.
    public var automaticMacOSUpdates: PostureState

    // MARK: Screen lock

    /// `com.apple.screensaver` → `askForPassword`. Frequently `.unknown` on
    /// macOS 14+, where this moved behind a managed preference an
    /// unprivileged `defaults read` no longer sees — which is exactly why
    /// this is a `PostureState` and not a `Bool`.
    public var screenLockOnSleep: PostureState

    /// `com.apple.screensaver` → `askForPasswordDelay`, in seconds. `nil`
    /// when unreadable (the common case on recent macOS).
    public var screenLockDelaySeconds: Int?

    // MARK: Sharing services (listening-socket observations — see type doc)

    public var remoteLogin: PostureState
    public var screenSharing: PostureState
    public var fileSharing: PostureState
    public var remoteManagement: PostureState

    // MARK: Accounts

    /// `/Library/Preferences/com.apple.loginwindow` → `GuestEnabled`.
    public var guestAccount: PostureState

    // MARK: Backup & drive health
    //
    // These four live on `SecurityPosture` rather than a separate type for
    // the same reason the sharing-service fields do: they are read by the
    // same unprivileged collector, in the same sweep, and a rule reasoning
    // about "is this Mac protected" needs FileVault and "does this Mac have
    // a backup" in the same context without a second optional to unwrap.

    /// `tmutil destinationinfo`. Whether at least one Time Machine
    /// destination is configured at all — says nothing about whether it has
    /// ever completed a backup, which is `timeMachineLastBackupAt`'s job.
    public var timeMachineDestinationConfigured: PostureState

    /// `tmutil latestbackup -t`. The timestamp of the most recent completed
    /// local backup snapshot, or `nil` when none could be found — which
    /// covers both "this Mac has never completed one" and "the probe
    /// couldn't tell". Only meaningful to read alongside
    /// `timeMachineDestinationConfigured`; see
    /// `TimeMachineBackupStaleRule`'s doc comment for how the two combine.
    public var timeMachineLastBackupAt: Date?

    /// `diskutil info -plist <startup volume>` → `SMARTStatus`.
    public var driveSMARTStatus: DriveSMARTState

    /// `.panic` files under `/Library/Logs/DiagnosticReports` modified
    /// within `SecurityPostureCollector.kernelPanicWindowDays`. `nil` when
    /// the directory couldn't be listed (permissions, or it doesn't exist in
    /// a way `FileManager` can distinguish from "genuinely empty" — see the
    /// collector for how that ambiguity is resolved). A definite `0` means
    /// the directory was listed and nothing in the window matched, which is
    /// a real answer, not an absence of one.
    public var recentKernelPanicCount: Int?

    // MARK: Privacy (TCC) and login items
    //
    // Same "same unprivileged collector, one sweep" reasoning as backup and
    // drive health above.

    /// `nil` when TCC.db could not be read — the expected case; see
    /// `TCCPermissionCounts`'s doc comment.
    public var tccPermissionCounts: TCCPermissionCounts?

    /// `nil` only if one of the three directory listings genuinely failed —
    /// not expected, since none of them need elevated privilege. See
    /// `LoginItemCounts`'s doc comment.
    public var loginItemCounts: LoginItemCounts?

    /// Human-readable notes about *how* this posture was determined and what
    /// couldn't be. Surfaced verbatim in the UI's methodology disclosure —
    /// the user paying for this is entitled to know which findings are
    /// direct readings and which are inferences.
    public var notes: [String]

    /// Every field that came back `.unknown`, as display names. Drives the
    /// honest "here's what Sentry couldn't determine" row rather than
    /// letting unknowns vanish into a clean-looking report.
    public var unknownFieldNames: [String] {
        var names: [String] = []
        func check(_ state: PostureState, _ name: String) {
            if state.isUnknown { names.append(name) }
        }
        check(fileVault, String(localized: "FileVault"))
        check(systemIntegrityProtection, String(localized: "System Integrity Protection"))
        check(gatekeeper, String(localized: "Gatekeeper"))
        check(firewall, String(localized: "Firewall"))
        check(firewallStealthMode, String(localized: "Stealth mode"))
        check(automaticUpdateChecks, String(localized: "Automatic update checks"))
        check(automaticSecurityResponses, String(localized: "Security responses"))
        check(automaticMacOSUpdates, String(localized: "Automatic macOS updates"))
        check(screenLockOnSleep, String(localized: "Screen lock on sleep"))
        check(remoteLogin, String(localized: "Remote Login"))
        check(screenSharing, String(localized: "Screen Sharing"))
        check(fileSharing, String(localized: "File Sharing"))
        check(remoteManagement, String(localized: "Remote Management"))
        check(guestAccount, String(localized: "Guest account"))
        return names
    }

    /// A posture where nothing at all could be determined. The honest value
    /// for "collection hasn't run yet" and for "every probe failed" alike —
    /// both are `.unknown` across the board, and neither should let a rule
    /// claim something is off.
    public static func unknownPosture(collectedAt: Date = Date(), notes: [String] = []) -> SecurityPosture {
        SecurityPosture(
            collectedAt: collectedAt,
            fileVault: .unknown,
            systemIntegrityProtection: .unknown,
            gatekeeper: .unknown,
            firewall: .unknown,
            firewallStealthMode: .unknown,
            automaticUpdateChecks: .unknown,
            automaticSecurityResponses: .unknown,
            automaticMacOSUpdates: .unknown,
            screenLockOnSleep: .unknown,
            screenLockDelaySeconds: nil,
            remoteLogin: .unknown,
            screenSharing: .unknown,
            fileSharing: .unknown,
            remoteManagement: .unknown,
            guestAccount: .unknown,
            timeMachineDestinationConfigured: .unknown,
            timeMachineLastBackupAt: nil,
            driveSMARTStatus: .unknown,
            recentKernelPanicCount: nil,
            tccPermissionCounts: nil,
            loginItemCounts: nil,
            notes: notes
        )
    }

    public init(
        collectedAt: Date = Date(),
        fileVault: PostureState = .unknown,
        systemIntegrityProtection: PostureState = .unknown,
        gatekeeper: PostureState = .unknown,
        firewall: PostureState = .unknown,
        firewallStealthMode: PostureState = .unknown,
        automaticUpdateChecks: PostureState = .unknown,
        automaticSecurityResponses: PostureState = .unknown,
        automaticMacOSUpdates: PostureState = .unknown,
        screenLockOnSleep: PostureState = .unknown,
        screenLockDelaySeconds: Int? = nil,
        remoteLogin: PostureState = .unknown,
        screenSharing: PostureState = .unknown,
        fileSharing: PostureState = .unknown,
        remoteManagement: PostureState = .unknown,
        guestAccount: PostureState = .unknown,
        timeMachineDestinationConfigured: PostureState = .unknown,
        timeMachineLastBackupAt: Date? = nil,
        driveSMARTStatus: DriveSMARTState = .unknown,
        recentKernelPanicCount: Int? = nil,
        tccPermissionCounts: TCCPermissionCounts? = nil,
        loginItemCounts: LoginItemCounts? = nil,
        notes: [String] = []
    ) {
        self.collectedAt = collectedAt
        self.fileVault = fileVault
        self.systemIntegrityProtection = systemIntegrityProtection
        self.gatekeeper = gatekeeper
        self.firewall = firewall
        self.firewallStealthMode = firewallStealthMode
        self.automaticUpdateChecks = automaticUpdateChecks
        self.automaticSecurityResponses = automaticSecurityResponses
        self.automaticMacOSUpdates = automaticMacOSUpdates
        self.screenLockOnSleep = screenLockOnSleep
        self.screenLockDelaySeconds = screenLockDelaySeconds
        self.remoteLogin = remoteLogin
        self.screenSharing = screenSharing
        self.fileSharing = fileSharing
        self.remoteManagement = remoteManagement
        self.guestAccount = guestAccount
        self.timeMachineDestinationConfigured = timeMachineDestinationConfigured
        self.timeMachineLastBackupAt = timeMachineLastBackupAt
        self.driveSMARTStatus = driveSMARTStatus
        self.recentKernelPanicCount = recentKernelPanicCount
        self.tccPermissionCounts = tccPermissionCounts
        self.loginItemCounts = loginItemCounts
        self.notes = notes
    }
}

// MARK: - Provider seam

/// The seam between the pure engine (SentryKit, cross-platform) and the
/// macOS-only collector that shells out to `fdesetup`/`csrutil`/etc.
///
/// Declared here so `InsightsViewModel` can hold "something that can produce
/// a posture" without the app target's view layer importing SystemMetricsKit
/// types into its own signatures, and so tests can inject a canned posture
/// without spawning a process. `SystemMetricsKit.SecurityPostureCollector`
/// is the one production conformer.
public protocol SecurityPostureProviding: Sendable {
    /// Returns the current posture, from cache when it's fresh enough.
    /// Never throws and never blocks the caller's thread — a probe that
    /// fails yields `.unknown` fields, which is a valid answer.
    func currentPosture() async -> SecurityPosture

    /// Drops any cached value so the next `currentPosture()` re-probes.
    /// Wired to the Insights screen's explicit Refresh action, since posture
    /// changes are user-initiated events (they just toggled FileVault) that
    /// a TTL alone would make the UI lie about for minutes.
    func invalidateCache() async
}
