import Foundation
import MacStatKit
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
/// `project.yml`, the same posture that lets `MacStatMCP` and the XPC
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
        subsystem: "dev.malekswilam.macstat.systemmetricskit",
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

    private let queue = DispatchQueue(label: "dev.malekswilam.macstat.securityposture", qos: .utility)
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
            notes: notes
        )
    }
}
