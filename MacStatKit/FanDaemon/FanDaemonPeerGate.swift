import Foundation

#if os(macOS)

/// Why a peer's code signature could not be accepted, as a value.
///
/// Split this finely because the four cases mean genuinely different
/// things to whoever is reading the daemon's log after a refusal: a
/// `.staticCodeUnavailable` on a developer's machine usually means the app
/// is ad-hoc signed and this whole feature is inert (the expected state on
/// an unsigned checkout — see `FanDaemonContract`), while a
/// `.requirementNotSatisfied` from a running system means something that is
/// *not* Sentry just tried to drive a root process.
public enum FanDaemonPeerFailure: Equatable, Sendable {
    /// The pid was nonsensical, or was the daemon's own.
    case implausiblePeer(pid: Int32)
    /// `SecCodeCopyGuestWithAttributes` could not produce a code object for
    /// the peer at all — the process may already be gone.
    case staticCodeUnavailable(osStatus: Int32)
    /// A code object exists and its signature does not satisfy the
    /// requirement. This is the interesting one.
    case requirementNotSatisfied(osStatus: Int32)
    /// The requirement string itself would not compile. A programming
    /// error, and one that must fail *closed*.
    case requirementMalformed(osStatus: Int32)

    public var message: String {
        switch self {
        case .implausiblePeer(let pid):
            return "the connecting process id (\(pid)) isn't one it could legitimately have"
        case .staticCodeUnavailable(let status):
            return "the connecting process's code signature couldn't be examined (OSStatus \(status))"
        case .requirementNotSatisfied(let status):
            return "the connecting process isn't a copy of Sentry signed by this developer (OSStatus \(status))"
        case .requirementMalformed(let status):
            return "the helper's own signing requirement wouldn't compile (OSStatus \(status)), so it refused every connection rather than none"
        }
    }
}

public enum FanDaemonPeerDecision: Equatable, Sendable {
    case accept
    case reject(FanDaemonPeerFailure)

    public var isAccepted: Bool {
        if case .accept = self { return true }
        return false
    }
}

/// The Security-framework call the gate makes, behind a protocol so the
/// decision logic can be tested without a signed binary to point it at.
///
/// The production conformer (`SecurityFrameworkPeerEvaluator`, in the
/// daemon target) is four lines of `SecCodeCopyGuestWithAttributes` +
/// `SecRequirementCreateWithString` + `SecCodeCheckValidity`. Everything
/// *around* those four lines — what counts as a plausible pid, what happens
/// when the requirement won't compile, whether a failure is fail-open or
/// fail-closed — is in `FanDaemonPeerGate` below and is fully tested. That
/// split is the only way to get coverage of this logic on a machine with no
/// signing identities, where every real evaluation would fail identically.
public protocol FanDaemonPeerEvaluator {
    /// - Returns: `nil` on success, or the failure that stopped it.
    func evaluate(pid: Int32, requirement: String) -> FanDaemonPeerFailure?
}

/// Safety requirement 3: **XPC peer verification.**
///
/// An `NSXPCListener` published by a root LaunchDaemon is reachable by any
/// process on the machine that can look up its Mach service name. Without
/// this gate, "ask Sentry's helper to spin the fans" is available to every
/// local process, including unprivileged ones — a local privilege
/// escalation, and a fairly generous one, since the daemon's whole purpose
/// is to write hardware registers. `SMAuthorizedClients` in the daemon's
/// launchd plist is the first half of the answer (launchd itself refuses
/// connections from clients that don't match); this gate is the second
/// half, in the daemon's own process, because defense that exists only in a
/// configuration file is defense that a configuration mistake removes
/// silently.
///
/// **The known weakness, named rather than buried: this identifies the peer
/// by pid.** `NSXPCConnection` exposes `processIdentifier`; it does not
/// expose the peer's audit token through any public API. Audit tokens are
/// the correct identifier because they are immune to pid reuse — the
/// classic attack is to get the daemon to sample a pid that belonged to a
/// legitimately-signed Sentry a microsecond ago and belongs to the attacker
/// now. Reaching the audit token requires the undocumented
/// `NSXPCConnection.auditToken` property, which this codebase will not put
/// on the path to a root process's authorization decision: an
/// undocumented property that returns garbage after an OS update fails
/// *open* unless every call site is defensive, and the failure would be
/// invisible. So: pid, plus the `SMAuthorizedClients` check launchd
/// performs before the connection ever reaches this code, plus the
/// deliberately tiny command vocabulary that bounds what a successful
/// attacker could even ask for. This is a real residual risk and it is
/// recorded here so the next reader can weigh it rather than rediscover it.
///
/// **Fail closed, in every branch.** There is no path through `decide`
/// that returns `.accept` without an evaluator having affirmatively
/// succeeded. In particular a malformed requirement string — a
/// programming error, entirely our fault, and the case most likely to be
/// hit first on a machine where signing was never set up — rejects
/// everything rather than waving everything through.
public enum FanDaemonPeerGate {

    /// The designated requirement a connecting client must satisfy.
    ///
    /// Pinned on three things, each of which is doing work:
    ///
    ///   * `identifier "dev.malekswilam.macstat"` — the app's bundle id,
    ///     which is identity rather than branding (see `project.yml`'s note
    ///     on why the bundle id did not change when the app was renamed to
    ///     Sentry). Without this, any binary from the same team could drive
    ///     the daemon.
    ///   * `anchor apple generic` — the signature chains to Apple's root.
    ///     Without this, a self-signed certificate whose OU field merely
    ///     *says* `H7T2D2GL7U` satisfies the leaf check below.
    ///   * `certificate leaf[subject.OU] = "H7T2D2GL7U"` — this developer's
    ///     Team ID, matching `DEVELOPMENT_TEAM` in the `DeveloperIDSigned`
    ///     template. Without this, any notarized app that happened to claim
    ///     the same bundle id would qualify.
    ///
    /// **This string is duplicated, on purpose, in the daemon's launchd
    /// plist under `SMAuthorizedClients`.** It has to be: launchd reads the
    /// plist, not this constant. The two must be kept identical by hand,
    /// and `FanDaemonPeerGateTests` asserts the exact expected text so a
    /// change here fails a test that names the plist rather than silently
    /// diverging from it.
    public static let clientRequirement =
        "identifier \"dev.malekswilam.macstat\" and anchor apple generic and certificate leaf[subject.OU] = \"H7T2D2GL7U\""

    /// Decides whether to accept a connection from `pid`.
    ///
    /// - Parameters:
    ///   - pid: `NSXPCConnection.processIdentifier`.
    ///   - ownPID: the daemon's own pid, rejected outright. A connection
    ///     that appears to come from the daemon itself is either a kernel
    ///     bug or something impersonating one, and neither is a caller
    ///     worth serving.
    ///   - evaluator: the Security-framework call. Injected so tests can
    ///     drive every branch below without a signed client.
    ///   - requirement: overridable only so tests can exercise the
    ///     malformed-requirement path; production always uses
    ///     `clientRequirement`.
    public static func decide(
        pid: Int32,
        ownPID: Int32,
        evaluator: FanDaemonPeerEvaluator,
        requirement: String = FanDaemonPeerGate.clientRequirement
    ) -> FanDaemonPeerDecision {

        // pid 0 is the kernel, pid 1 is launchd, negatives are impossible,
        // and our own pid is covered above. None of them can be a Sentry
        // that wants its fans changed.
        guard pid > 1, pid != ownPID else {
            return .reject(.implausiblePeer(pid: pid))
        }

        if let failure = evaluator.evaluate(pid: pid, requirement: requirement) {
            return .reject(failure)
        }
        return .accept
    }
}

#endif
