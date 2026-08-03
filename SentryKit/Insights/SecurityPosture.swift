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
