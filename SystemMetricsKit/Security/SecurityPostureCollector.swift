import Foundation
import SentryKit
import os

// MARK: - Command runner

/// The one thing `SecurityPostureCollector` does that isn't arithmetic:
/// run a short command and hand back its stdout.
///
/// A protocol so tests can drive the whole collector — cache behaviour,
/// note generation, every field mapping — with canned output and no
/// subprocess at all.
public protocol PostureCommandRunning: Sendable {
    /// Returns stdout on a clean exit, or `nil` for **any** other outcome:
    /// missing executable, launch failure, non-zero exit, or timeout.
    /// Collapsing every failure into `nil` is deliberate — the caller's only
    /// correct response to all of them is `.unknown`, so distinguishing them
    /// would create branches with nothing different to do.
    func run(_ executablePath: String, arguments: [String], timeout: TimeInterval) -> String?
}

/// Real subprocess execution.
///
/// **This app is unsandboxed by design** (`APP_SANDBOX: NO` in
/// `project.yml`, the same posture that lets `SentryMCP` and the XPC
/// service work), so spawning `/usr/bin/fdesetup` is a legitimate,
/// entitlement-free operation here. Nothing below asks for elevated
/// privileges, prompts for a password, or touches the network.
///
/// **Defensive shape, mirroring `IOReportBridge`'s posture:** the
/// executable's existence is checked before launching, stdin is
/// `/dev/null` so a command that unexpectedly prompts can never block
/// forever, stdout is drained on a separate thread *before* waiting (a
/// command whose output exceeds the pipe buffer would otherwise deadlock —
/// `netstat -an` on a busy Mac genuinely can), stderr is discarded, and a
/// hard timeout terminates anything that overstays.
public struct SubprocessPostureCommandRunner: PostureCommandRunning, Sendable {

    private static let logger = Logger(
        subsystem: "dev.malekswilam.sentry.systemmetricskit",
        category: "SecurityPosture"
    )

    /// How often the wait loop checks whether the child has exited.
    private static let pollInterval: TimeInterval = 0.02

    /// Grace period between `SIGTERM` and giving up on a clean exit.
    private static let terminationGrace: TimeInterval = 0.5

    public init() {}

    public func run(_ executablePath: String, arguments: [String], timeout: TimeInterval) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            // Not an error worth logging as one: several of these tools have
            // moved or been removed across macOS releases, and "absent"
            // legitimately means `.unknown` rather than a failure.
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            Self.logger.error("Failed to launch \(executablePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // Drain first, wait second. Reversing these deadlocks on any output
        // larger than the pipe buffer.
        let box = OutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.store(pipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        // The timeout is enforced by polling on *this* thread rather than by
        // a scheduled work item on another one, so `terminate()` is only
        // ever called from the same thread that observed the process still
        // running. That removes the terminate-versus-exit race entirely
        // rather than narrowing it.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            let graceDeadline = Date().addingTimeInterval(Self.terminationGrace)
            while process.isRunning, Date() < graceDeadline {
                Thread.sleep(forTimeInterval: Self.pollInterval)
            }
        }

        process.waitUntilExit()
        // Terminating the child closes its stdout, so the drain finishes;
        // the bounded wait is belt-and-braces against a grandchild holding
        // the write end open.
        _ = group.wait(timeout: .now() + 1)

        if timedOut {
            Self.logger.error("Timed out running \(executablePath, privacy: .public)")
            return nil
        }
        guard process.terminationStatus == 0, let data = box.value else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Lock-guarded box so the draining thread's result can be read back on
    /// the calling thread without a data race on a captured `var`.
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Data?

        func store(_ data: Data) {
            lock.lock()
            storage = data
            lock.unlock()
        }

        var value: Data? {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}

// MARK: - Collector

/// Reads this Mac's security posture using only what an unprivileged
/// process can honestly determine.
///
/// **Never blocks the caller's thread.** Every probe runs on this type's own
/// private serial queue; `currentPosture()` bridges to it with a
/// continuation. The whole sweep is a dozen short subprocesses, which is far
/// too much to do on a UI thread and roughly nothing to do on a background
/// one every few minutes.
///
/// **Cached with a TTL**, because posture does not change second to second —
/// and because a user who *just* toggled FileVault deserves to see it, the
/// Insights screen's explicit Refresh calls `invalidateCache()` first.
///
/// **Nothing slow or network-bound runs automatically.** In particular
/// `softwareupdate -l` — the only way to answer "are there pending
/// updates?" — is deliberately not called anywhere in this type: it talks to
/// Apple's servers and can take tens of seconds. The update-related findings
/// are about *configuration* (`AutomaticCheckEnabled` and friends), which is
/// a local preference read.
///
/// **What it cannot determine, and says so.** Sharing services are inferred
/// from listening sockets rather than from launchd (which needs root), the
/// screen-lock preference is frequently unreadable on macOS 14+, and
/// firmware-password state is not attempted at all. All of those become
/// `.unknown`, which `PostureUnknownRule` then surfaces to the user by name
/// instead of letting them vanish into a clean-looking report.
public final class SecurityPostureCollector: SecurityPostureProviding, @unchecked Sendable {

    /// Five minutes. Long enough that opening the Insights tab repeatedly
    /// costs nothing, short enough that a stale reading is never
    /// meaningfully old — and irrelevant to the case that matters, since an
    /// explicit Refresh invalidates it.
    public static let defaultCacheTTL: TimeInterval = 300

    /// Per-command ceiling. Every one of these normally returns in tens of
    /// milliseconds; two seconds is a generous ceiling for a machine under
    /// heavy load, and twelve of them in the worst case is still a
    /// background sweep nobody is waiting on.
    public static let defaultCommandTimeout: TimeInterval = 2.0

    /// World-readable — panic reports are written here by the kernel itself
    /// before any user session exists, so they cannot be restricted to an
    /// admin-only ACL the way `/Library/Logs` sometimes is elsewhere.
    private static let kernelPanicDirectory = "/Library/Logs/DiagnosticReports"

    private let queue = DispatchQueue(label: "dev.malekswilam.sentry.securityposture", qos: .utility)
    private let runner: PostureCommandRunning
    private let cacheTTL: TimeInterval
    private let commandTimeout: TimeInterval

    /// Only ever touched on `queue` — the reason this type is
    /// `@unchecked Sendable` rather than an actor (see the type doc comment
    /// on why blocking work wants a real queue, not the cooperative pool).
    private var cached: SecurityPosture?

    public init(
        runner: PostureCommandRunning = SubprocessPostureCommandRunner(),
        cacheTTL: TimeInterval = SecurityPostureCollector.defaultCacheTTL,
        commandTimeout: TimeInterval = SecurityPostureCollector.defaultCommandTimeout
    ) {
        self.runner = runner
        self.cacheTTL = cacheTTL
        self.commandTimeout = commandTimeout
    }

    public func currentPosture() async -> SecurityPosture {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.collectLocked(now: Date()))
            }
        }
    }

    public func invalidateCache() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.cached = nil
                continuation.resume()
            }
        }
    }

    /// Must only be called on `queue`.
    private func collectLocked(now: Date) -> SecurityPosture {
        if let cached, now.timeIntervalSince(cached.collectedAt) < cacheTTL {
            return cached
        }
        let fresh = probe(now: now)
        cached = fresh
        return fresh
    }

    // MARK: - Probes

    private enum Tool {
        static let fdesetup = "/usr/bin/fdesetup"
        static let csrutil = "/usr/bin/csrutil"
        static let spctl = "/usr/sbin/spctl"
        static let socketfilterfw = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        static let defaultsRead = "/usr/bin/defaults"
        static let netstat = "/usr/sbin/netstat"
        /// `destinationinfo` and `latestbackup` are both unprivileged reads —
        /// unlike `startbackup`/`stopbackup`, nothing here mutates state or
        /// needs Full Disk Access.
        static let tmutil = "/usr/bin/tmutil"
        /// `diskutil info -plist` is a read-only query; nothing here touches
        /// `eraseDisk`, `partitionDisk`, or any other mutating verb.
        static let diskutil = "/usr/sbin/diskutil"
        /// Always invoked with `-readonly` against TCC.db. Never used to
        /// write anywhere — there is no code path in this file that opens
        /// `sqlite3` without that flag.
        static let sqlite3 = "/usr/bin/sqlite3"
    }

    private enum Domain {
        static let softwareUpdate = "/Library/Preferences/com.apple.SoftwareUpdate"
        static let loginWindow = "/Library/Preferences/com.apple.loginwindow"
        static let screenSaver = "com.apple.screensaver"
    }

    private func probe(now: Date) -> SecurityPosture {
        func run(_ path: String, _ arguments: [String]) -> String? {
            runner.run(path, arguments: arguments, timeout: commandTimeout)
        }
        func readDefault(_ domain: String, _ key: String) -> String? {
            run(Tool.defaultsRead, ["read", domain, key])
        }

        let fileVault = SecurityPostureParser.fileVault(run(Tool.fdesetup, ["status"]))
        let sip = SecurityPostureParser.systemIntegrityProtection(run(Tool.csrutil, ["status"]))
        let gatekeeper = SecurityPostureParser.gatekeeper(run(Tool.spctl, ["--status"]))
        let firewall = SecurityPostureParser.firewallGlobalState(run(Tool.socketfilterfw, ["--getglobalstate"]))
        let stealth = SecurityPostureParser.firewallStealthMode(run(Tool.socketfilterfw, ["--getstealthmode"]))

        let updateChecks = SecurityPostureParser.booleanDefault(
            readDefault(Domain.softwareUpdate, "AutomaticCheckEnabled")
        )
        let securityResponses = SecurityPostureParser.booleanDefault(
            readDefault(Domain.softwareUpdate, "CriticalUpdateInstall")
        )
        let macOSUpdates = SecurityPostureParser.booleanDefault(
            readDefault(Domain.softwareUpdate, "AutomaticallyInstallMacOSUpdates")
        )

        let screenLock = SecurityPostureParser.booleanDefault(
            readDefault(Domain.screenSaver, "askForPassword")
        )
        let screenLockDelay = SecurityPostureParser.integerDefault(
            readDefault(Domain.screenSaver, "askForPasswordDelay")
        )

        let guest = SecurityPostureParser.booleanDefault(
            readDefault(Domain.loginWindow, "GuestEnabled")
        )

        let listeningPorts = SecurityPostureParser.listeningPorts(
            netstatOutput: run(Tool.netstat, ["-an", "-p", "tcp"])
        )

        let timeMachineDestination = SecurityPostureParser.timeMachineDestinationConfigured(
            run(Tool.tmutil, ["destinationinfo"])
        )
        let timeMachineLastBackup = SecurityPostureParser.timeMachineLastBackupDate(
            run(Tool.tmutil, ["latestbackup", "-t"])
        )
        let smartStatus = SecurityPostureParser.driveSMARTStatus(
            run(Tool.diskutil, ["info", "-plist", "/"])
        )
        let kernelPanicCount = recentKernelPanicCount(now: now)

        let tccCounts = SecurityPostureParser.tccPermissionCounts(
            run(Tool.sqlite3, ["-readonly", Self.tccDatabasePath, SecurityPostureParser.tccPermissionQuery])
        )
        let loginItems = collectLoginItemCounts()

        var notes = [
            String(localized: "Sharing services are inferred from listening TCP sockets, not from launchd — reading a Sharing service's enabled state needs privileges Sentry does not request."),
            String(localized: "Only sockets bound to a network-reachable address are counted; a service listening on the loopback interface alone is not treated as reachable.")
        ]
        if listeningPorts == nil {
            notes.append(String(localized: "The listening-socket scan did not complete, so all four Sharing findings are unknown rather than clear."))
        }
        if screenLock.isUnknown {
            notes.append(String(localized: "macOS 14 and later no longer expose the screen-lock preference to an unprivileged read, so it is reported as unknown rather than guessed."))
        }
        notes.append(String(localized: "Sentry never checks for pending updates here — that requires a network round-trip to Apple. The update findings describe this Mac's update settings, not its update backlog."))
        if smartStatus == .unknown {
            notes.append(String(localized: "SMART status could not be read for the startup volume — some external, virtual, and Apple Fabric-attached volumes don't report it at all, which reads the same as a failed probe."))
        }
        if kernelPanicCount == nil {
            notes.append(String(localized: "The kernel panic log directory could not be listed, so recent panic history is unknown rather than assumed clean."))
        }
        if tccCounts == nil {
            notes.append(String(localized: "TCC.db — this Mac's privacy-permission database — could not be read, so per-app Accessibility/Screen Recording/Full Disk Access/Camera/Microphone counts are unknown rather than assumed clean. Reading it requires Full Disk Access, which Sentry does not request by default."))
        }
        if loginItems == nil {
            notes.append(String(localized: "One of the LaunchAgents/LaunchDaemons directories could not be listed, so the persistent background item count is unknown."))
        }

        return SecurityPosture(
            collectedAt: now,
            fileVault: fileVault,
            systemIntegrityProtection: sip,
            gatekeeper: gatekeeper,
            firewall: firewall,
            firewallStealthMode: stealth,
            automaticUpdateChecks: updateChecks,
            automaticSecurityResponses: securityResponses,
            automaticMacOSUpdates: macOSUpdates,
            screenLockOnSleep: screenLock,
            screenLockDelaySeconds: screenLockDelay,
            remoteLogin: SecurityPostureParser.listenerState(
                port: SharingServicePort.remoteLogin, in: listeningPorts
            ),
            screenSharing: SecurityPostureParser.listenerState(
                port: SharingServicePort.screenSharing, in: listeningPorts
            ),
            fileSharing: SecurityPostureParser.listenerState(
                port: SharingServicePort.fileSharing, in: listeningPorts
            ),
            remoteManagement: SecurityPostureParser.listenerState(
                port: SharingServicePort.remoteManagement, in: listeningPorts
            ),
            guestAccount: guest,
            timeMachineDestinationConfigured: timeMachineDestination,
            timeMachineLastBackupAt: timeMachineLastBackup,
            driveSMARTStatus: smartStatus,
            recentKernelPanicCount: kernelPanicCount,
            tccPermissionCounts: tccCounts,
            loginItemCounts: loginItems,
            notes: notes
        )
    }

    /// `~/Library/Application Support/com.apple.TCC/TCC.db` — the per-user
    /// privacy database. There is also a system-wide one at
    /// `/Library/Application Support/com.apple.TCC/TCC.db`, but that path
    /// requires root to even `stat`, let alone open, so it is not attempted
    /// here; the per-user database already covers every permission grant a
    /// normal (non-managed, non-MDM) user makes through the Privacy &
    /// Security prompts this feature cares about.
    private static let tccDatabasePath = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"

    /// Lists `/Library/Logs/DiagnosticReports` and hands the filenames and
    /// modification dates to `SecurityPostureParser.kernelPanicCount` for
    /// the actual counting. The only impure step; deliberately not run
    /// through `PostureCommandRunning`, because there's a native, no-shell-out
    /// way to answer this one.
    ///
    /// `nil` when the directory can't be listed. A directory that doesn't
    /// exist counts as zero rather than unknown: on a Mac that has never
    /// panicked, macOS never creates it, and that is itself the honest
    /// "nothing to report" case — different from a listing that fails
    /// because of a permissions problem this app can't explain.
    private func recentKernelPanicCount(now: Date) -> Int? {
        let directory = URL(fileURLWithPath: Self.kernelPanicDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return 0
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let entries: [(filename: String, modifiedAt: Date)] = contents.compactMap { url in
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
                return nil
            }
            return (url.lastPathComponent, modified)
        }

        // The window itself is defined on `KernelPanicHistoryRule` in
        // SentryKit — see that constant's doc comment for why the source of
        // truth lives on the rule side of the module boundary rather than
        // here.
        let windowStart = now.addingTimeInterval(-Double(KernelPanicHistoryRule.windowDays) * 86_400)
        return SecurityPostureParser.kernelPanicCount(entries: entries, windowStart: windowStart)
    }

    /// `.plist` counts in `~/Library/LaunchAgents`, `/Library/LaunchAgents`,
    /// and `/Library/LaunchDaemons`.
    ///
    /// **Foundation directory listings only — no `launchctl`, no root.**
    /// Unlike the Sharing-service probes above, listing what's *in* these
    /// three directories needs no elevated privilege at all: `FileManager`
    /// can enumerate `/Library/LaunchDaemons`'s filenames as an ordinary
    /// user even though the plists themselves are root-owned, because
    /// directory listing and file reading are different permission checks.
    /// This deliberately stops at the filename: nothing here opens a single
    /// plist to read what it launches, which would need root for the
    /// LaunchDaemons case and would tempt a per-item allowlist this codebase
    /// avoids (see `LoginItemsBloatRule`'s doc comment).
    ///
    /// **`SMAppService` was considered and left out.** Newer macOS versions
    /// (`ServiceManagement.SMAppService`, 13+) let an app query and manage
    /// *its own* registered helpers and login items, but there is no public
    /// API to enumerate every login item registered by every app on the
    /// system the way System Settings' Login Items pane does — that list is
    /// assembled by `System Settings` itself from private state. So this
    /// probe is deliberately limited to what `FileManager` can honestly see:
    /// the three standard LaunchAgents/LaunchDaemons directories.
    ///
    /// Returns `nil` only if one of the three listings itself fails (not
    /// expected in practice) — all three succeed or the whole reading is
    /// treated as unknown, the same "succeed together or fail together"
    /// choice `TCCPermissionCounts` makes for its five fields.
    private func collectLoginItemCounts() -> LoginItemCounts? {
        func plistCount(at path: String) -> Int? {
            let directory = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                // Doesn't exist: a real, legitimate zero — the same
                // reasoning `recentKernelPanicCount` uses for a Mac that has
                // never panicked and so never created its log directory.
                return 0
            }
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                return nil
            }
            return contents.filter { $0.pathExtension.lowercased() == "plist" }.count
        }

        guard let userAgents = plistCount(at: NSHomeDirectory() + "/Library/LaunchAgents"),
              let systemAgents = plistCount(at: "/Library/LaunchAgents"),
              let systemDaemons = plistCount(at: "/Library/LaunchDaemons")
        else { return nil }

        return LoginItemCounts(userAgents: userAgents, systemAgents: systemAgents, systemDaemons: systemDaemons)
    }
}
