import Foundation

#if os(macOS)

/// Thin async wrapper around an `NSXPCConnection` to `MacStat.app`. Every
/// call gets a *fresh* `remoteObjectProxyWithErrorHandler` rather than one
/// cached proxy, so a connection interruption between calls (MacStat quit,
/// crashed, or hasn't launched yet) surfaces as a clear per-call error
/// instead of every subsequent call silently hanging.
///
/// Originally private to `MacStatMCP/main.swift`; moved here so the
/// standalone `macstat` CLI (see `MacStatCLI/main.swift`) can reuse the same
/// connection/reply-race handling instead of duplicating it — both binaries
/// are thin XPC clients with no direct access to
/// `StatsCoordinator`/`HistoryStore`/etc., per `MacStatXPCServiceProtocol`'s
/// doc comment.
public final class MacStatXPCClient: MCPServiceCalling, @unchecked Sendable {
    private let connection: NSXPCConnection

    /// What a connection failure most likely *means*, decided by asking
    /// launchd rather than guessing. The old text here was "Is MacStat
    /// running?" — which was wrong in the common case: for years the Mach
    /// service was never registered with launchd at all, so the connection
    /// failed identically whether the app was running or not, and the
    /// message sent every reader to check the wrong thing.
    ///
    /// WHY `launchctl` AND NOT `SMAppService`: the obvious implementation
    /// — `SMAppService.agent(plistName:).status` — answers for *this
    /// process's* bundle identity, and this code runs in the `macstat` /
    /// `MacStatMCP` binaries, whose main bundle is not the app. Observed
    /// empirically on a signed build in /Applications with the service
    /// genuinely registrable: the query returned `.notFound` from the CLI
    /// no matter what launchd actually thought. launchd itself is the
    /// ground truth the app-side registrar is merely reflecting, so the
    /// CLI asks launchd: `launchctl print gui/<uid>/<label>` exits 0 iff
    /// the job is registered in this login session. The one nuance lost is
    /// distinguishing "off" from "awaiting approval in System Settings" —
    /// both print as not-registered here, so the advice names both.
    ///
    /// Kept `static` and computed per-failure, not cached: the user can
    /// flip registration in Settings between two CLI invocations.
    static func connectionFailureAdvice() -> String {
        // Packaging truth first: the agent plist ships two directories up
        // from this executable. If it's genuinely absent, no amount of
        // Settings-clicking will help, and the advice should say so
        // instead of sending the user to a button that can't work.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let appContents = executable          // …/Sentry.app/Contents/MacOS/macstat
            .deletingLastPathComponent()      // …/Contents/MacOS
            .deletingLastPathComponent()      // …/Contents
        let plist = appContents
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent(MCPAgentNaming.plistName)
        guard FileManager.default.fileExists(atPath: plist.path) else {
            return "This copy of Sentry doesn't include the command-line service's launch agent (looked for \(plist.path))."
        }

        let launchctl = Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["print", "gui/\(getuid())/\(MCPAgentNaming.label)"]
        launchctl.standardOutput = FileHandle.nullDevice
        launchctl.standardError = FileHandle.nullDevice
        do {
            try launchctl.run()
            launchctl.waitUntilExit()
        } catch {
            // launchctl not runnable is not a state this advice can
            // diagnose past; fall back to the actionable default.
            return "Command-line access may be turned off. Check Sentry ▸ Settings ▸ AI Access ▸ Command-Line Access."
        }
        if launchctl.terminationStatus == 0 {
            // launchd owns the name and routes to the app (starting it if
            // needed) — so a failure despite that is something rarer: a
            // crash mid-call, or the app's peer gate refusing this binary
            // (re-signed, or copied out of the bundle). The refusal, if
            // that's what it was, is named in the app's log.
            return "Command-line access is enabled, so this usually means Sentry crashed mid-call — or refused this binary. Check Console for Sentry's XPCListener log."
        }
        return "Command-line access is turned off (or awaiting your approval under System Settings ▸ General ▸ Login Items). Turn it on in Sentry ▸ Settings ▸ AI Access ▸ Command-Line Access."
    }

    public init() {
        connection = NSXPCConnection(machServiceName: MacStatXPCServiceName.machService, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: MacStatXPCServiceProtocol.self)
        connection.resume()
    }

    /// Resolves exactly once, from whichever of `body`'s reply closure or the
    /// XPC error handler fires first — guarded by `ResumeOnce` since both
    /// *can* legitimately race (a connection interruption arriving just as
    /// the app-side reply is in flight).
    public func readCall(_ body: @escaping (MacStatXPCServiceProtocol, @escaping (Data?, String?) -> Void) -> Void) async -> (Data?, String?) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(Data?, String?), Never>) in
            let box = ResumeOnce(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                box.resume((nil, "Couldn't reach Sentry: \(error.localizedDescription). \(Self.connectionFailureAdvice())"))
            }) as? MacStatXPCServiceProtocol else {
                box.resume((nil, "Couldn't create an XPC proxy to MacStat.app."))
                return
            }
            body(proxy) { data, message in box.resume((data, message)) }
        }
    }

    public func writeCall(_ body: @escaping (MacStatXPCServiceProtocol, @escaping (Bool, String?) -> Void) -> Void) async -> (Bool, String?) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, String?), Never>) in
            let box = ResumeOnce(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                box.resume((false, "Couldn't reach Sentry: \(error.localizedDescription). \(Self.connectionFailureAdvice())"))
            }) as? MacStatXPCServiceProtocol else {
                box.resume((false, "Couldn't create an XPC proxy to MacStat.app."))
                return
            }
            body(proxy) { ok, message in box.resume((ok, message)) }
        }
    }
}

/// Resumes a `CheckedContinuation` at most once, guarded by a lock. Needed
/// because `remoteObjectProxyWithErrorHandler`'s error handler and the XPC
/// reply block are two independent completion paths that a real connection
/// failure mid-call can race between — `NSXPCConnection`'s own contract only
/// promises *one* of them fires per call, not which, and calling
/// `continuation.resume` twice is a Swift Concurrency crash, not a warning.
final class ResumeOnce<T>: @unchecked Sendable {
    private let continuation: CheckedContinuation<T, Never>
    private let lock = NSLock()
    private var didResume = false

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let alreadyResumed = didResume
        didResume = true
        lock.unlock()
        guard !alreadyResumed else { return }
        continuation.resume(returning: value)
    }
}

#endif
