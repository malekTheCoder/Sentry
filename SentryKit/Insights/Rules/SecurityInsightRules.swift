import Foundation

// MARK: - Shared helpers

/// Small pieces of "what kind of Mac is this" phrasing that several security
/// rules reuse, so the same fact isn't worded three different ways in one
/// report.
enum SecurityEvidence {

    /// "This is a portable Mac (Mac14,7)." — or the desktop equivalent, or
    /// `nil` when the model identifier couldn't be read.
    static func machineDescription(_ context: InsightContext) -> String? {
        guard let isPortable = context.device.isPortable else { return nil }
        guard let model = context.device.modelIdentifier else {
            return isPortable
                ? String(localized: "This is a portable Mac.")
                : String(localized: "This is a desktop Mac.")
        }
        return isPortable
            ? String(localized: "This is a portable Mac (\(model)) — it leaves the building.")
            : String(localized: "This is a desktop Mac (\(model)).")
    }

    /// "Its startup volume is holding about 412 GB of data." Derived from
    /// the live snapshot's `DiskStats`, which carries both totals.
    static func dataAtRiskDescription(_ context: InsightContext) -> String? {
        guard let disk = context.snapshot?.disk, disk.totalBytes > 0, disk.totalBytes >= disk.freeBytes else {
            return nil
        }
        let usedBytes = Double(disk.totalBytes - disk.freeBytes)
        let usedText = InsightPhrasing.bytes(usedBytes)
        let totalText = InsightPhrasing.bytes(Double(disk.totalBytes))
        return String(localized: "Its startup volume is holding \(usedText) of data on a \(totalText) drive.")
    }

    /// "Sentry's Location Log last placed this Mac somewhere on 3 Jun."
    /// Only ever built when the user has explicitly enabled the Location
    /// Log — this feature never turns it on, prompts for it, or implies it
    /// should be on.
    static func locationDescription(_ context: InsightContext) -> String? {
        guard context.settings.locationLogEnabled,
              let location = context.snapshot?.location
        else { return nil }
        let whenText = location.timestamp.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Sentry's Location Log last recorded a position for this Mac on \(whenText), so it does move around.")
    }

    /// "It's currently on the Wi-Fi network \"Cafe Guest\"."
    static func networkDescription(_ context: InsightContext) -> String? {
        guard let network = context.snapshot?.network, network.isWiFi, let ssid = network.wifiSSID, !ssid.isEmpty else {
            return nil
        }
        return String(localized: "It is currently on the Wi-Fi network “\(ssid)”.")
    }
}

// MARK: - Disk encryption

/// FileVault off. The single highest-impact security finding this app can
/// make, and the reason the score's `criticalSecurity` weight exists.
public struct FileVaultOffRule: ProtectionInsightRule, Sendable {
    public let id = "security.filevault-off"
    public let category: InsightCategory = .security
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.posture.fileVault.isDefinitelyOff else { return nil }

        var evidence = [
            String(localized: "macOS's own “fdesetup status” reports that FileVault is off.")
        ]
        if let machine = SecurityEvidence.machineDescription(context) { evidence.append(machine) }
        if let data = SecurityEvidence.dataAtRiskDescription(context) { evidence.append(data) }
        if let location = SecurityEvidence.locationDescription(context) { evidence.append(location) }

        // A portable Mac that goes places is a materially worse case than a
        // desktop that never leaves a locked room — but both are critical,
        // because "unencrypted disk" is not a severity that has a
        // non-critical version.
        return ProtectionInsight(
            id: id,
            title: String(localized: "The disk is not encrypted"),
            summary: String(localized: "FileVault is off — everything on this Mac is readable by anyone who has it."),
            detail: String(localized: "Without FileVault, a login password protects nothing against physical access: the drive can be read directly, and on Apple silicon that includes booting into recovery with the machine in front of you. Turning FileVault on binds the data to the Secure Enclave, so the same drive is inert to anyone who does not have the password or recovery key.\n\nThere is no meaningful performance cost on Apple silicon — encryption runs in dedicated hardware on the storage path."),
            recommendation: String(localized: "Turn on FileVault in System Settings ▸ Privacy & Security ▸ FileVault, and store the recovery key somewhere that is not this Mac."),
            category: category,
            severity: .critical,
            evidence: evidence,
            action: InsightAction(
                label: String(localized: "Open FileVault settings"),
                target: .systemSettings(urlString: SystemSettingsLink.fileVault),
                fallbackDescription: String(localized: "System Settings ▸ Privacy & Security ▸ FileVault")
            ),
            confidence: 1.0,
            scoreImpact: InsightWeight.criticalSecurity
        )
    }
}

/// The positive counterpart.
public struct FileVaultOnRule: ProtectionInsightRule, Sendable {
    public let id = "security.filevault-on"
    public let category: InsightCategory = .security
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.posture.fileVault.isDefinitelyOn else { return nil }

        var evidence = [
            String(localized: "macOS's own “fdesetup status” reports that FileVault is on.")
        ]
        if let data = SecurityEvidence.dataAtRiskDescription(context) { evidence.append(data) }

        return ProtectionInsight(
            id: id,
            title: String(localized: "The disk is encrypted"),
            summary: String(localized: "FileVault is on."),
            detail: String(localized: "Everything written to this Mac's internal storage is encrypted and bound to its Secure Enclave. If the machine is lost or stolen, the data on it is not readable without the password or the recovery key."),
            recommendation: String(localized: "Make sure the recovery key is stored somewhere other than this Mac. A recovery key that only exists on the encrypted disk is not a recovery key."),
            category: category,
            severity: .good,
            evidence: evidence,
            action: nil,
            confidence: 1.0,
            scoreImpact: InsightWeight.none
        )
    }
}

// MARK: - System integrity

/// SIP disabled — almost always deliberate, and almost always forgotten
/// about afterwards.
public struct SIPDisabledRule: ProtectionInsightRule, Sendable {
    public let id = "security.sip-disabled"
    public let category: InsightCategory = .security
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.posture.systemIntegrityProtection.isDefinitelyOff else { return nil }

        var evidence = [
            String(localized: "macOS's own “csrutil status” reports that System Integrity Protection is disabled.")
        ]
        if let version = context.device.macOSVersion {
            evidence.append(String(localized: "Running macOS \(version)."))
        }
        if let uptime = context.powerHabits?.uptimeDays {
            let uptimeText = InsightPhrasing.days(uptime)
            evidence.append(String(localized: "Uptime is \(uptimeText) — SIP cannot be re-enabled without a reboot into recovery anyway."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "System Integrity Protection is disabled"),
            summary: String(localized: "SIP is off, so system files and processes are modifiable."),
            detail: String(localized: "SIP is what stops even an administrator — and therefore anything running as one — from modifying system files, injecting into Apple's own processes, or loading unsigned kernel extensions. It cannot be turned off by accident: it requires booting into recovery and running a command, so this was a deliberate act at some point. The risk is that it is easy to do for one specific reason and then never undo."),
            recommendation: String(localized: "If you no longer need whatever this was disabled for, re-enable it: boot into recovery, open Terminal, run “csrutil enable”, and restart."),
            category: category,
            severity: .critical,
            evidence: evidence,
            action: InsightAction(
                label: String(localized: "Re-enable from recovery"),
                target: .manual,
                fallbackDescription: String(localized: "Restart holding the power button ▸ Options ▸ Utilities ▸ Terminal ▸ csrutil enable")
            ),
            confidence: 1.0,
            scoreImpact: InsightWeight.criticalSecurity
        )
    }
}

/// Gatekeeper assessments disabled.
public struct GatekeeperDisabledRule: ProtectionInsightRule, Sendable {
    public let id = "security.gatekeeper-disabled"
    public let category: InsightCategory = .security
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.posture.gatekeeper.isDefinitelyOff else { return nil }

        var evidence = [
            String(localized: "macOS's own “spctl --status” reports that assessments are disabled.")
        ]
        if context.posture.systemIntegrityProtection.isDefinitelyOff {
            evidence.append(String(localized: "System Integrity Protection is also disabled on this Mac — the two together remove most of the default barriers to unsigned code."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "Gatekeeper is turned off"),
            summary: String(localized: "Downloaded applications are no longer checked before they run."),
            detail: String(localized: "Gatekeeper verifies that an app is signed by an identified developer and has been notarised by Apple before it is allowed to launch. With assessments disabled, anything that lands on this Mac runs without that check — including something that arrived by a route you did not choose.\n\nDisabling it wholesale is rarely necessary: individual apps can be allowed one at a time from Privacy & Security without lowering the bar for everything else."),
            recommendation: String(localized: "Re-enable it with “sudo spctl --master-enable” in Terminal, then allow the specific app you needed from System Settings ▸ Privacy & Security."),
            category: category,
            severity: .critical,
            evidence: evidence,
            action: InsightAction(
                label: String(localized: "Open Privacy & Security"),
                target: .systemSettings(urlString: SystemSettingsLink.privacyAndSecurity),
                fallbackDescription: String(localized: "System Settings ▸ Privacy & Security")
            ),
            confidence: 1.0,
            scoreImpact: InsightWeight.criticalSecurity
        )
    }
}

// MARK: - Firewall

public struct FirewallOffRule: ProtectionInsightRule, Sendable {
    public let id = "security.firewall-off"
    public let category: InsightCategory = .security
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.posture.firewall.isDefinitelyOff else { return nil }

        var evidence = [
            String(localized: "macOS's own “socketfilterfw --getglobalstate” reports the application firewall is off.")
        ]
        if let machine = SecurityEvidence.machineDescription(context) { evidence.append(machine) }
        if let network = SecurityEvidence.networkDescription(context) { evidence.append(network) }

        // Cross-reference the listening services the collector found, and
        // Sentry's own LAN-reachable server. This is what turns a generic
        // "turn on your firewall" into a statement about this Mac.
        var listeningPorts: [String] = []
        if context.posture.remoteLogin.isDefinitelyOn { listeningPorts.append("\(SharingServicePort.remoteLogin)") }
        if context.posture.screenSharing.isDefinitelyOn { listeningPorts.append("\(SharingServicePort.screenSharing)") }
        if context.posture.fileSharing.isDefinitelyOn { listeningPorts.append("\(SharingServicePort.fileSharing)") }
        if context.posture.remoteManagement.isDefinitelyOn { listeningPorts.append("\(SharingServicePort.remoteManagement)") }
        if !listeningPorts.isEmpty {
            let portText = listeningPorts.joined(separator: ", ")
            evidence.append(String(localized: "There are already processes accepting connections on port \(portText)."))
        }
        if context.settings.mcpRemoteAccessEnabled {
            let portText = "\(context.settings.mcpRemotePort)"
            evidence.append(String(localized: "Sentry's own remote MCP access is enabled on port \(portText), which is reachable from the local network."))
        }

        // A Mac with nothing listening is much less exposed than one with
        // open services, so the severity follows the actual exposure rather
        // than the setting alone.
        let severity: InsightSeverity = (listeningPorts.isEmpty && !context.settings.mcpRemoteAccessEnabled)
            ? .warning
            : .critical

        return ProtectionInsight(
            id: id,
            title: String(localized: "The firewall is off"),
            summary: listeningPorts.isEmpty
                ? String(localized: "Nothing is filtering inbound connections to this Mac.")
                : String(localized: "Inbound connections are unfiltered, and services are already listening."),
            detail: String(localized: "macOS's application firewall decides which programs are allowed to accept incoming connections. With it off, any process that opens a listening socket — deliberately or otherwise — is reachable by anything else on the same network. On a home network that is a modest risk; on a café, hotel, or conference network it is the difference between being a client and being a server."),
            recommendation: String(localized: "Turn the firewall on in System Settings ▸ Network ▸ Firewall. The default settings do not interfere with normal use — outgoing connections are unaffected."),
            category: category,
            severity: severity,
            evidence: evidence,
            action: InsightAction(
                label: String(localized: "Open Firewall settings"),
                target: .systemSettings(urlString: SystemSettingsLink.firewall),
                fallbackDescription: String(localized: "System Settings ▸ Network ▸ Firewall")
            ),
            confidence: 1.0,
            scoreImpact: severity == .critical ? InsightWeight.criticalSecurity : InsightWeight.majorSecurity
        )
    }
}

/// Stealth mode — only meaningful, and only reported, when the firewall it
/// belongs to is actually on.
public struct FirewallStealthModeRule: ProtectionInsightRule, Sendable {
    public let id = "security.stealth-mode-off"
    public let category: InsightCategory = .security
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.posture.firewall.isDefinitelyOn,
              context.posture.firewallStealthMode.isDefinitelyOff
        else { return nil }

        var evidence = [
            String(localized: "The firewall is on, but “socketfilterfw --getstealthmode” reports stealth mode is off.")
        ]
        if let network = SecurityEvidence.networkDescription(context) { evidence.append(network) }
        if context.device.isPortable == true {
            evidence.append(String(localized: "This is a portable Mac, so it joins networks you do not control."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "This Mac answers network probes"),
            summary: String(localized: "Stealth mode is off, so the Mac replies to pings and port scans."),
            detail: String(localized: "With stealth mode off, this Mac responds to ICMP pings and to probes on closed ports, which tells anyone scanning the network that there is a machine here and roughly what it is. Turning it on does not block anything you use — it simply stops the Mac from announcing itself to traffic it did not ask for."),
            recommendation: String(localized: "Turn on stealth mode in System Settings ▸ Network ▸ Firewall ▸ Options."),
            category: category,
            severity: .advice,
            evidence: evidence,
            action: InsightAction(
                label: String(localized: "Open Firewall settings"),
                target: .systemSettings(urlString: SystemSettingsLink.firewall),
                fallbackDescription: String(localized: "System Settings ▸ Network ▸ Firewall ▸ Options")
            ),
            confidence: 1.0,
            scoreImpact: InsightWeight.minorSecurity
        )
    }
}

// MARK: - Updates

public struct AutomaticUpdateChecksOffRule: ProtectionInsightRule, Sendable {
    public let id = "security.auto-update-checks-off"
    public let category: InsightCategory = .security
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.posture.automaticUpdateChecks.isDefinitelyOff else { return nil }

        var evidence = [
            String(localized: "“AutomaticCheckEnabled” is off in this Mac's Software Update preferences.")
        ]
        if let version = context.device.macOSVersion {
            evidence.append(String(localized: "Currently running macOS \(version)."))
        }
        if let uptime = context.powerHabits?.uptimeDays, uptime >= 7 {
            let uptimeText = InsightPhrasing.days(uptime)
            evidence.append(String(localized: "This Mac has been up for \(uptimeText) without a restart."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "This Mac never checks for updates"),
            summary: String(localized: "Automatic update checking is disabled entirely."),
            detail: String(localized: "With automatic checking off, macOS will not tell you that a security update exists — you have to remember to look. In practice that means the gap between a vulnerability becoming public and this machine being patched is however long it takes you to think about it, which for most people is measured in months.\n\nChecking for updates is separate from installing them. Leaving checking on while installation stays manual gives you the notification without surrendering control of when the restart happens."),
            recommendation: String(localized: "At minimum, turn checking back on in System Settings ▸ General ▸ Software Update ▸ Automatic Updates. Install security responses and system files automatically even if you prefer to schedule full macOS updates yourself."),
            category: category,
            severity: .warning,
            evidence: evidence,
            action: InsightAction(
                label: String(localized: "Open Software Update"),
                target: .systemSettings(urlString: SystemSettingsLink.softwareUpdate),
                fallbackDescription: String(localized: "System Settings ▸ General ▸ Software Update")
            ),
            confidence: 1.0,
            scoreImpact: InsightWeight.majorSecurity
        )
    }
}

public struct SecurityResponsesOffRule: ProtectionInsightRule, Sendable {
    public let id = "security.security-responses-off"
    public let category: InsightCategory = .security
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.posture.automaticSecurityResponses.isDefinitelyOff else { return nil }

        var evidence = [
            String(localized: "“CriticalUpdateInstall” is off in this Mac's Software Update preferences — that is the key behind Rapid Security Responses.")
        ]
        if let version = context.device.macOSVersion {
            evidence.append(String(localized: "Currently running macOS \(version)."))
        }
        if context.posture.automaticUpdateChecks.isDefinitelyOff {
            evidence.append(String(localized: "Automatic update checking is off as well, so nothing will prompt you either."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "Rapid Security Responses won't install"),
            summary: String(localized: "The out-of-band security patch channel is disabled."),
            detail: String(localized: "Rapid Security Responses are the small, out-of-band patches Apple ships between full macOS releases, specifically for vulnerabilities being exploited in the wild. They are designed to install with minimal disruption precisely because the time between release and installation is the window that matters. Off is the wrong default for almost everyone."),
            recommendation: String(localized: "Turn on “Install Security Responses and system files” in System Settings ▸ General ▸ Software Update ▸ Automatic Updates."),
            category: category,
            severity: .warning,
            evidence: evidence,
            action: InsightAction(
                label: String(localized: "Open Software Update"),
                target: .systemSettings(urlString: SystemSettingsLink.softwareUpdate),
                fallbackDescription: String(localized: "System Settings ▸ General ▸ Software Update ▸ Automatic Updates")
            ),
            confidence: 1.0,
            scoreImpact: InsightWeight.majorSecurity
        )
    }
}

public struct AutomaticMacOSUpdatesOffRule: ProtectionInsightRule, Sendable {
    public let id = "security.macos-auto-updates-off"
    public let category: InsightCategory = .security
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.posture.automaticMacOSUpdates.isDefinitelyOff,
              // Only worth raising if the checking channel is at least on;
              // otherwise `AutomaticUpdateChecksOffRule` already covers the
              // bigger version of this problem and this would be noise.
              !context.posture.automaticUpdateChecks.isDefinitelyOff
        else { return nil }

        var evidence = [
            String(localized: "“AutomaticallyInstallMacOSUpdates” is off — macOS updates will be offered but never applied on their own.")
        ]
        if let version = context.device.macOSVersion {
            evidence.append(String(localized: "Currently running macOS \(version)."))
        }
        if let uptime = context.powerHabits?.uptimeDays, uptime >= 14 {
            let uptimeText = InsightPhrasing.days(uptime)
            evidence.append(String(localized: "Uptime is \(uptimeText), so any pending update has had time to be noticed."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "macOS updates wait for you"),
            summary: String(localized: "Updates are found but never installed automatically."),
            detail: String(localized: "This is a legitimate choice — a macOS update restarting a machine mid-work is genuinely disruptive, and plenty of people want to pick the moment. It is listed here so the choice stays deliberate rather than forgotten, because the failure mode is a Mac that stays three point releases behind for a year."),
            recommendation: String(localized: "Either turn on automatic installation, or make a habit of checking Software Update monthly. The combination that is not fine is manual installation plus never looking."),
            category: category,
            severity: .advice,
            evidence: evidence,
            action: InsightAction(
                label: String(localized: "Open Software Update"),
                target: .systemSettings(urlString: SystemSettingsLink.softwareUpdate),
                fallbackDescription: String(localized: "System Settings ▸ General ▸ Software Update")
            ),
            confidence: 1.0,
            scoreImpact: InsightWeight.minorSecurity
        )
    }
}

/// Running a macOS major version that has definitively stopped receiving
/// security updates.
///
/// **A lower bound, not an up-to-date check.** This does *not* try to know
/// what the newest macOS is — that list goes stale the day after every WWDC
/// and would need this app to ship an update just to keep a threshold
/// current. What it checks instead is a one-way fact that doesn't expire:
/// once Apple has stopped signing security updates for a major version, that
/// version stays unsupported forever. The constant below only ever needs to
/// move in one direction, and only when a *new* version's predecessor falls
/// off Apple's support window — it is not a "latest OS" tracker.
///
/// **The current cutoff, and why.** Apple's practice for the last several
/// years has been to patch the current release plus the two before it, and
/// macOS Monterey (12) received its last security update in December 2024
/// when Sonoma (14) and Sequoia (15) were the two being patched alongside
/// it. Anything below major version 13 (Ventura) is therefore definitively
/// past its support window as of this cutoff.
///
/// **This needs manual upkeep.** Every time Apple ships a new annual
/// release, the machine two majors back typically ages out a few months
/// later. This constant has to be bumped by hand when that happens — there
/// is no API that answers "is this macOS version still patched," so a
/// human has to notice and update the one number below.
public struct OutdatedMacOSVersionRule: ProtectionInsightRule, Sendable {
    public let id = "security.macos-version-unsupported"
    public let category: InsightCategory = .security
    public init() {}

    /// See the type doc comment for how this number was chosen and what
    /// "revisit this" looks like going forward.
    public static let minimumSupportedMajorVersion = 13

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard let versionString = context.device.macOSVersion,
              let majorComponent = versionString.split(separator: ".").first,
              let major = Int(majorComponent)
        else { return nil }
        guard major < Self.minimumSupportedMajorVersion else { return nil }

        let majorText = "\(major)"
        let minimumText = "\(Self.minimumSupportedMajorVersion)"

        var evidence = [
            String(localized: "This Mac is running macOS \(versionString) — major version \(majorText), which no longer receives security updates from Apple.")
        ]
        if context.posture.automaticMacOSUpdates.isDefinitelyOn || context.posture.automaticUpdateChecks.isDefinitelyOn {
            evidence.append(String(localized: "Automatic update settings are on, but there is nothing left for them to install — this machine is past the last version Apple will patch."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "This macOS version no longer gets security updates"),
            summary: String(localized: "Running macOS \(majorText), which is past Apple's support window."),
            detail: String(localized: "Apple typically patches the current macOS release and the two before it; anything older stops receiving fixes entirely, including for vulnerabilities discovered and actively exploited after that point. Every other finding in this list assumes the operating system underneath it is at least getting patched — on an unsupported version, a perfect security posture everywhere else still runs on a foundation with known, permanently open holes."),
            recommendation: String(localized: "Update to macOS \(minimumText) or later in System Settings ▸ General ▸ Software Update if this Mac supports it. If it doesn't — Apple drops hardware support for older Macs over time — the honest options are to retire this Mac from tasks that touch sensitive data, or to replace it; there is no setting that fixes an unsupported OS."),
            category: category,
            severity: .critical,
            evidence: evidence,
            action: InsightAction(
                label: String(localized: "Open Software Update"),
                target: .systemSettings(urlString: SystemSettingsLink.softwareUpdate),
                fallbackDescription: String(localized: "System Settings ▸ General ▸ Software Update")
            ),
            confidence: 1.0,
            scoreImpact: InsightWeight.criticalSecurity
        )
    }
}

// MARK: - Screen lock

public struct ScreenLockOffRule: ProtectionInsightRule, Sendable {
    public let id = "security.screen-lock-off"
    public let category: InsightCategory = .security
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.posture.screenLockOnSleep.isDefinitelyOff else { return nil }

        var evidence = [
            String(localized: "“askForPassword” is off in this Mac's screen saver preferences.")
        ]
        if let machine = SecurityEvidence.machineDescription(context) { evidence.append(machine) }
        if context.posture.fileVault.isDefinitelyOn {
            evidence.append(String(localized: "FileVault is on, which protects the disk at rest — but not a Mac that is already awake and unlocked on a desk."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "The screen doesn't lock"),
            summary: String(localized: "No password is required after sleep or the screen saver."),
            detail: String(localized: "This is the gap that disk encryption cannot close. FileVault protects a Mac that is off or asleep-and-locked; a machine left awake and unlocked is simply open, and walking up to it is all anyone has to do. On a laptop that goes into a bag between locations, it is also the difference between losing hardware and losing everything on it."),
            recommendation: String(localized: "Turn on “Require password after screen saver begins or display is turned off” in System Settings ▸ Lock Screen, with a short delay."),
            category: category,
            severity: .warning,
            evidence: evidence,
            action: InsightAction(
                label: String(localized: "Open Lock Screen settings"),
                target: .systemSettings(urlString: SystemSettingsLink.lockScreen),
                fallbackDescription: String(localized: "System Settings ▸ Lock Screen")
            ),
            confidence: 1.0,
            scoreImpact: InsightWeight.majorSecurity
        )
    }
}

public struct ScreenLockDelayRule: ProtectionInsightRule, Sendable {
    public let id = "security.screen-lock-delay-long"
    public let category: InsightCategory = .security
    public init() {}

    /// Five minutes. Long enough that someone can sit down at an
    /// unattended Mac and find it still unlocked.
    public static let longDelaySeconds = 300

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.posture.screenLockOnSleep.isDefinitelyOn,
              let delay = context.posture.screenLockDelaySeconds,
              delay >= Self.longDelaySeconds
        else { return nil }

        let delayText = InsightPhrasing.duration(hours: Double(delay) / 3600)
        var evidence = [
            String(localized: "The screen locks, but only \(delayText) after the display sleeps.")
        ]
        if context.device.isPortable == true {
            evidence.append(String(localized: "On a portable Mac that window travels with the machine."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "The lock delay is generous"),
            summary: String(localized: "There is a \(delayText) window where this Mac is asleep but unlocked."),
            detail: String(localized: "The delay exists so a screen that blanks while you are reading does not demand a password the moment you touch the trackpad. Set long, it becomes a standing window in which a sleeping Mac is not actually locked — which is exactly the state it is in when it is left on a desk or slipped into a bag."),
            recommendation: String(localized: "A delay of a minute or less keeps the convenience and closes most of the window. System Settings ▸ Lock Screen."),
            category: category,
            severity: .advice,
            evidence: evidence,
            action: InsightAction(
                label: String(localized: "Open Lock Screen settings"),
                target: .systemSettings(urlString: SystemSettingsLink.lockScreen),
                fallbackDescription: String(localized: "System Settings ▸ Lock Screen")
            ),
            confidence: 1.0,
            scoreImpact: InsightWeight.minorSecurity
        )
    }
}

// MARK: - Sharing services

/// Shared body for the four listening-socket rules, so the honesty caveat
/// about *how* these are detected is written once and cannot drift between
/// them.
struct ListeningServiceRuleBody {
    var id: String
    var state: PostureState
    var port: Int
    var title: String
    var summary: String
    var detail: String
    var recommendation: String
    var severity: InsightSeverity
    var scoreImpact: Int

    func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard state.isDefinitelyOn else { return nil }

        let portText = "\(port)"
        var evidence = [
            String(localized: "A process on this Mac is accepting TCP connections on port \(portText)."),
            String(localized: "Sentry determines this by looking at listening sockets, not by asking launchd — reading a Sharing service's enabled state needs privileges this app does not have and does not ask for. A non-Apple service on the same port would look identical.")
        ]
        if context.posture.firewall.isDefinitelyOff {
            evidence.append(String(localized: "The firewall is also off, so nothing is filtering who can reach it."))
        } else if context.posture.firewall.isDefinitelyOn {
            evidence.append(String(localized: "The firewall is on, so it is at least filtering which applications may accept connections."))
        }
        if let network = SecurityEvidence.networkDescription(context) { evidence.append(network) }

        return ProtectionInsight(
            id: id,
            title: title,
            summary: summary,
            detail: detail,
            recommendation: recommendation,
            category: .security,
            severity: context.posture.firewall.isDefinitelyOff ? .critical : severity,
            evidence: evidence,
            action: InsightAction(
                label: String(localized: "Open Sharing settings"),
                target: .systemSettings(urlString: SystemSettingsLink.sharing),
                fallbackDescription: String(localized: "System Settings ▸ General ▸ Sharing")
            ),
            confidence: 1.0,
            scoreImpact: context.posture.firewall.isDefinitelyOff ? InsightWeight.criticalSecurity : scoreImpact
        )
    }
}

public struct RemoteLoginListeningRule: ProtectionInsightRule, Sendable {
    public let id = "security.remote-login-listening"
    public let category: InsightCategory = .security
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        ListeningServiceRuleBody(
            id: id,
            state: context.posture.remoteLogin,
            port: SharingServicePort.remoteLogin,
            title: String(localized: "Remote Login is reachable"),
            summary: String(localized: "Something is listening for SSH connections on this Mac."),
            detail: String(localized: "SSH gives whoever can authenticate a full command line on this machine. That is exactly what it is for, and it is the right tool when you need it — but it is also the single most-scanned port on the internet, and an SSH server left running from a project six months ago is a standing invitation that nobody remembers issuing.\n\nIf this Mac is ever on a network you do not control, this is the finding on this list that most deserves a second look."),
            recommendation: String(localized: "If you are not using it, turn Remote Login off in System Settings ▸ General ▸ Sharing. If you are, restrict it to specific users and use keys rather than passwords."),
            severity: .warning,
            scoreImpact: InsightWeight.majorSecurity
        ).evaluate(context)
    }
}

public struct ScreenSharingListeningRule: ProtectionInsightRule, Sendable {
    public let id = "security.screen-sharing-listening"
    public let category: InsightCategory = .security
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        ListeningServiceRuleBody(
            id: id,
            state: context.posture.screenSharing,
            port: SharingServicePort.screenSharing,
            title: String(localized: "Screen Sharing is reachable"),
            summary: String(localized: "Something is listening for screen-sharing connections."),
            detail: String(localized: "Screen sharing hands over the actual desktop — everything visible, plus keyboard and mouse. Unlike SSH there is no partial access: a successful connection is the same as sitting in front of the machine."),
            recommendation: String(localized: "Turn Screen Sharing off in System Settings ▸ General ▸ Sharing unless you actively use it, and restrict it to named users rather than all users when you do."),
            severity: .warning,
            scoreImpact: InsightWeight.majorSecurity
        ).evaluate(context)
    }
}

public struct FileSharingListeningRule: ProtectionInsightRule, Sendable {
    public let id = "security.file-sharing-listening"
    public let category: InsightCategory = .security
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        ListeningServiceRuleBody(
            id: id,
            state: context.posture.fileSharing,
            port: SharingServicePort.fileSharing,
            title: String(localized: "File Sharing is reachable"),
            summary: String(localized: "Something is listening for SMB file-sharing connections."),
            detail: String(localized: "File Sharing exposes whichever folders were configured for it to anyone who can authenticate. The usual problem is not the sharing itself but that it long outlives the reason it was turned on, and the shared folder list is rarely revisited."),
            recommendation: String(localized: "Check what is actually shared in System Settings ▸ General ▸ Sharing ▸ File Sharing, and turn it off if the answer is “nothing I still need”."),
            severity: .advice,
            scoreImpact: InsightWeight.minorSecurity
        ).evaluate(context)
    }
}

public struct RemoteManagementListeningRule: ProtectionInsightRule, Sendable {
    public let id = "security.remote-management-listening"
    public let category: InsightCategory = .security
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        ListeningServiceRuleBody(
            id: id,
            state: context.posture.remoteManagement,
            port: SharingServicePort.remoteManagement,
            title: String(localized: "Remote Management is reachable"),
            summary: String(localized: "Something is listening on Apple Remote Desktop's control port."),
            detail: String(localized: "Remote Management is Apple Remote Desktop's agent. It is broader than screen sharing — depending on how it was configured it can also copy files, run commands, and change settings without any prompt on this end. On a managed work Mac this is expected; on a personal one it usually means it was enabled once and never turned off."),
            recommendation: String(localized: "If this Mac is not centrally managed, turn Remote Management off in System Settings ▸ General ▸ Sharing."),
            severity: .warning,
            scoreImpact: InsightWeight.majorSecurity
        ).evaluate(context)
    }
}

// MARK: - Accounts

public struct GuestAccountEnabledRule: ProtectionInsightRule, Sendable {
    public let id = "security.guest-account-enabled"
    public let category: InsightCategory = .security
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.posture.guestAccount.isDefinitelyOn else { return nil }

        var evidence = [
            String(localized: "“GuestEnabled” is set in this Mac's login window preferences.")
        ]
        if context.posture.fileVault.isDefinitelyOff {
            evidence.append(String(localized: "FileVault is off, so a guest session shares a disk that is readable anyway."))
        }
        if context.posture.screenSharing.isDefinitelyOn || context.posture.remoteLogin.isDefinitelyOn {
            evidence.append(String(localized: "Remote access services are also reachable on this Mac."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "The guest account is enabled"),
            summary: String(localized: "Anyone at the keyboard can start a session without a password."),
            detail: String(localized: "A guest session is sandboxed and wiped on logout, so it is not a route to your files directly. What it does provide is an unauthenticated foothold on the machine and on whatever network it is attached to — which is a meaningfully different starting position for anyone who has physical access.\n\nIt has one genuine benefit worth weighing: on a Mac with Find My enabled, a thief logging into the guest account can put the machine online where it can be located."),
            recommendation: String(localized: "If you are not relying on the Find My behaviour, turn the guest account off in System Settings ▸ Users & Groups."),
            category: category,
            severity: .advice,
            evidence: evidence,
            action: InsightAction(
                label: String(localized: "Open Users & Groups"),
                target: .systemSettings(urlString: SystemSettingsLink.usersAndGroups),
                fallbackDescription: String(localized: "System Settings ▸ Users & Groups")
            ),
            confidence: 1.0,
            scoreImpact: InsightWeight.minorSecurity
        )
    }
}

// MARK: - Sentry's own posture (privacy)

/// Sentry's LAN-reachable MCP server. Reported for the same reason as
/// everything else: a finding is not less true because we caused it.
public struct RemoteMCPAccessRule: ProtectionInsightRule, Sendable {
    public let id = "privacy.mcp-remote-access"
    public let category: InsightCategory = .privacy
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.settings.mcpRemoteAccessEnabled else { return nil }

        let portText = "\(context.settings.mcpRemotePort)"
        var evidence = [
            String(localized: "Sentry's remote MCP access is enabled and bound to port \(portText) on all interfaces.")
        ]
        if context.posture.firewall.isDefinitelyOff {
            evidence.append(String(localized: "The firewall is off, so nothing is filtering who on the network can reach it."))
        }
        if context.settings.mcpWriteToolsEnabled {
            evidence.append(String(localized: "Write tools are also enabled, so a connected agent can change this Mac's power state, not just read from it."))
        }
        if let network = SecurityEvidence.networkDescription(context) { evidence.append(network) }

        let severity: InsightSeverity = context.posture.firewall.isDefinitelyOff || context.settings.mcpWriteToolsEnabled
            ? .warning
            : .advice

        return ProtectionInsight(
            id: id,
            title: String(localized: "Sentry is reachable over the network"),
            summary: String(localized: "Remote MCP access is listening on port \(portText)."),
            detail: String(localized: "This is Sentry's own setting, and it is the one switch in this app that genuinely changes this Mac's network posture. When it is on, an authenticated client elsewhere on the local network can query this Mac's telemetry — and, if write tools are enabled, change its sleep behaviour.\n\nIt is off by default and stays off until it is turned on deliberately. It is listed here so that it is not something you have to remember on your own."),
            recommendation: String(localized: "If you are not actively using an AI agent against this Mac from another device, turn it off in Sentry ▸ Settings ▸ AI Access. Leaving write tools off is a meaningful reduction in what a connected client can do."),
            category: category,
            severity: severity,
            evidence: evidence,
            action: InsightAction(
                label: String(localized: "Open Sentry's AI Access settings"),
                target: .appSettings,
                fallbackDescription: String(localized: "Sentry ▸ Settings ▸ AI Access")
            ),
            confidence: 1.0,
            scoreImpact: severity == .warning ? InsightWeight.majorSecurity : InsightWeight.minorSecurity
        )
    }
}

/// Write-capable MCP tools with only *local* access enabled. Milder than
/// the remote case above, and deliberately a separate finding so turning
/// remote access off doesn't silently hide it.
public struct LocalMCPWriteToolsRule: ProtectionInsightRule, Sendable {
    public let id = "privacy.mcp-write-tools"
    public let category: InsightCategory = .privacy
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.settings.mcpWriteToolsEnabled,
              // The remote rule already covers this case, with more severity.
              !context.settings.mcpRemoteAccessEnabled
        else { return nil }

        return ProtectionInsight(
            id: id,
            title: String(localized: "AI agents can change this Mac's power state"),
            summary: String(localized: "Sentry's write tools are enabled for local agents."),
            detail: String(localized: "Read tools let an agent look at this Mac's telemetry. Write tools let it act — creating and releasing keep-awake assertions. Access is local-only right now (remote MCP access is off), so this is limited to agents running on this machine, and every call still goes through Sentry's per-tool permission and rate limits."),
            recommendation: String(localized: "Fine to leave on if you use an agent that needs it. If you don't, turning write tools off in Sentry ▸ Settings ▸ AI Access removes the capability entirely rather than merely rate-limiting it."),
            category: category,
            severity: .advice,
            evidence: [
                String(localized: "Write-capable MCP tools are enabled in Sentry's settings."),
                String(localized: "Remote MCP access is off, so this applies to agents on this Mac only.")
            ],
            action: InsightAction(
                label: String(localized: "Open Sentry's AI Access settings"),
                target: .appSettings,
                fallbackDescription: String(localized: "Sentry ▸ Settings ▸ AI Access")
            ),
            confidence: 1.0,
            scoreImpact: InsightWeight.none
        )
    }
}

// MARK: - Privacy (TCC) permission review

/// Visibility into which apps hold sensitive TCC permissions —
/// Accessibility, Screen Recording, Full Disk Access, Camera, Microphone —
/// reported as counts, never as a judgement about any specific app.
///
/// **This is a visibility feature, not a verdict.** Holding Accessibility or
/// Full Disk Access is completely ordinary for a long list of legitimate
/// software — window managers, backup tools, remote-control apps, and
/// Sentry's own future needs, to name a few. Naming or flagging a specific
/// app here would need this codebase to maintain a list of which apps
/// "deserve" which permission, which is exactly the guessing this codebase
/// avoids everywhere else (see `SecurityPostureParser`'s doc comment on
/// unrecognised command output). What is knowable and worth surfacing
/// without guessing is the count — "N apps can see your screen; go look" —
/// which is the same category as a bank statement transaction list: neutral
/// until you actually look at it.
///
/// **Costs nothing on the score, deliberately.** A nonzero permission count
/// is not the same class of fact as FileVault being off — it doesn't mean
/// something is wrong, so `scoreImpact` is `InsightWeight.none`, matching
/// the same choice `CycleBurnRateRule` and `MemoryCompressionRule` make for
/// their own pure-awareness findings.
public struct TCCPermissionAwarenessRule: ProtectionInsightRule, Sendable {
    public let id = "privacy.tcc-permission-review"
    public let category: InsightCategory = .privacy
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard let counts = context.posture.tccPermissionCounts else { return nil }

        let accessibilityText = "\(counts.accessibility)"
        let screenRecordingText = "\(counts.screenRecording)"
        let fullDiskAccessText = "\(counts.fullDiskAccess)"
        let cameraText = "\(counts.camera)"
        let microphoneText = "\(counts.microphone)"

        let evidence = [
            String(localized: "\(accessibilityText) apps currently hold Accessibility access on this Mac."),
            String(localized: "\(screenRecordingText) apps currently hold Screen Recording access."),
            String(localized: "\(fullDiskAccessText) apps currently hold Full Disk Access."),
            String(localized: "\(cameraText) apps currently hold Camera access."),
            String(localized: "\(microphoneText) apps currently hold Microphone access.")
        ]

        return ProtectionInsight(
            id: id,
            title: String(localized: "Review which apps can see, hear, or control this Mac"),
            summary: String(localized: "Accessibility: \(accessibilityText) · Screen Recording: \(screenRecordingText) · Full Disk Access: \(fullDiskAccessText) · Camera: \(cameraText) · Microphone: \(microphoneText)."),
            detail: String(localized: "These five permissions are the ones macOS gates behind an explicit prompt because of what they let an app do once granted: Accessibility can observe and control input system-wide, Screen Recording can see everything on screen, Full Disk Access can read any file, and Camera and Microphone are what they say. None of these counts is inherently a problem — most Macs accumulate a handful of legitimate grants over time, including to apps exactly like this one. This finding exists so that accumulation stays visible instead of invisible, not to accuse any specific app of anything."),
            recommendation: String(localized: "Open Privacy & Security and skim each of these five lists. Anything you don't recognise, or don't use anymore, is safe to revoke — the app will simply ask again if it's still needed."),
            category: category,
            severity: .advice,
            evidence: evidence,
            action: InsightAction(
                label: String(localized: "Open Privacy & Security"),
                target: .systemSettings(urlString: SystemSettingsLink.privacyAndSecurity),
                fallbackDescription: String(localized: "System Settings ▸ Privacy & Security")
            ),
            confidence: 1.0,
            scoreImpact: InsightWeight.none
        )
    }
}

/// The honest-unknown counterpart to `TCCPermissionAwarenessRule`.
///
/// **Verified empirically, not assumed.** Reading another app's TCC grants
/// needs Full Disk Access. This was tested directly against this feature's
/// own development machine: a read-only `sqlite3` open of the very
/// `TCC.db` this user owns, run as that same user, fails with "authorization
/// denied" — not a POSIX permissions error (the file itself is
/// world-readable), but a macOS-level protection that sits below the
/// filesystem's own rules. Sentry does not request Full Disk Access by
/// default, so on almost every install this rule is the one that fires, and
/// `TCCPermissionAwarenessRule` stays silent.
///
/// **Advice, not a manufactured pass — mirrors `PostureUnknownRule`'s
/// convention exactly.** An inconclusive read is not scored in either
/// direction, and it is shown rather than swallowed, for the same reason
/// every other unknown in this feature is shown: a clean-looking report
/// that quietly omitted the one thing it couldn't check would be a worse
/// failure than admitting the gap.
public struct TCCAccessUnknownRule: ProtectionInsightRule, Sendable {
    public let id = "privacy.tcc-access-unknown"
    public let category: InsightCategory = .privacy
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.posture.tccPermissionCounts == nil else { return nil }

        return ProtectionInsight(
            id: id,
            title: String(localized: "Privacy-permission review is inconclusive"),
            summary: String(localized: "Sentry can't see which apps hold Accessibility, Screen Recording, Full Disk Access, Camera, or Microphone access without Full Disk Access of its own."),
            detail: String(localized: "macOS's privacy database, TCC.db, records every sensitive permission grant on this Mac — which is exactly why reading it is itself gated behind Full Disk Access, a permission Sentry does not request by default. This is not the same as a clean result: it means the question genuinely wasn't answered, not that nothing was found."),
            recommendation: String(localized: "If you'd like this reviewed automatically, grant Sentry Full Disk Access in System Settings ▸ Privacy & Security ▸ Full Disk Access. Otherwise, the five permission lists — Accessibility, Screen Recording, Full Disk Access, Camera, Microphone — are each one tap away in the same settings pane."),
            category: category,
            severity: .advice,
            evidence: [
                String(localized: "A read-only attempt to query TCC.db did not succeed — the database exists but could not be opened without Full Disk Access.")
            ],
            action: InsightAction(
                label: String(localized: "Open Privacy & Security"),
                target: .systemSettings(urlString: SystemSettingsLink.privacyAndSecurity),
                fallbackDescription: String(localized: "System Settings ▸ Privacy & Security ▸ Full Disk Access")
            ),
            confidence: 1.0,
            scoreImpact: InsightWeight.none
        )
    }
}

// MARK: - Honesty and positive findings

/// The rule that exists specifically so unknowns cannot vanish into a
/// clean-looking report.
public struct PostureUnknownRule: ProtectionInsightRule, Sendable {
    public let id = "security.posture-unknown"
    public let category: InsightCategory = .security
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        let unknowns = context.posture.unknownFieldNames
        guard !unknowns.isEmpty else { return nil }

        let listText = unknowns.joined(separator: ", ")
        let countText = "\(unknowns.count)"

        var evidence = [
            String(localized: "Sentry could not determine \(countText) posture facts: \(listText).")
        ]
        evidence.append(contentsOf: context.posture.notes)

        return ProtectionInsight(
            id: id,
            title: String(localized: "Some checks came back inconclusive"),
            summary: String(localized: "\(countText) settings could not be read without elevated privileges."),
            detail: String(localized: "Sentry runs as a normal user process and does not ask for administrator rights, so a handful of system settings are simply not readable from here. Rather than guess — or quietly leave them out and let the report look cleaner than it is — they are listed as unknown.\n\nAn unknown is never counted as a pass or a failure. It does not affect the protection score in either direction."),
            recommendation: String(localized: "Nothing to do. If any of these matter to you, they can be checked directly in System Settings ▸ Privacy & Security."),
            category: category,
            severity: .advice,
            evidence: evidence,
            action: InsightAction(
                label: String(localized: "Open Privacy & Security"),
                target: .systemSettings(urlString: SystemSettingsLink.privacyAndSecurity),
                fallbackDescription: String(localized: "System Settings ▸ Privacy & Security")
            ),
            confidence: 1.0,
            scoreImpact: InsightWeight.none
        )
    }
}

/// All four baseline protections confirmed on.
public struct HardenedBaselineRule: ProtectionInsightRule, Sendable {
    public let id = "security.hardened-baseline"
    public let category: InsightCategory = .security
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        let posture = context.posture
        guard posture.fileVault.isDefinitelyOn,
              posture.systemIntegrityProtection.isDefinitelyOn,
              posture.gatekeeper.isDefinitelyOn,
              posture.firewall.isDefinitelyOn
        else { return nil }

        var evidence = [
            String(localized: "FileVault, System Integrity Protection, Gatekeeper, and the firewall all report as on.")
        ]
        if posture.firewallStealthMode.isDefinitelyOn {
            evidence.append(String(localized: "Stealth mode is on too."))
        }
        if posture.automaticSecurityResponses.isDefinitelyOn {
            evidence.append(String(localized: "Rapid Security Responses will install automatically."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "The security baseline is intact"),
            summary: String(localized: "Encryption, integrity protection, app checking, and the firewall are all on."),
            detail: String(localized: "These four are the defaults that matter, and all four are in place on this Mac. It is worth stating plainly, because the usual way this changes is one of them being turned off for a specific reason and then never turned back on."),
            recommendation: String(localized: "Nothing to do. If you ever disable one of these temporarily, this finding disappearing is your reminder to put it back."),
            category: category,
            severity: .good,
            evidence: evidence,
            action: nil,
            confidence: 1.0,
            scoreImpact: InsightWeight.none
        )
    }
}
