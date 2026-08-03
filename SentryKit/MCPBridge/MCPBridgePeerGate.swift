import Foundation

#if os(macOS)

/// Why a peer's code signature could not be accepted, as a value.
///
/// Split as finely as `FanDaemonPeerFailure` and for the same reason: the
/// cases mean genuinely different things to whoever reads the log after a
/// refusal. On an unsigned developer checkout `.requirementNotSatisfied` is
/// the *expected* state and means this whole feature is inert; on a shipped,
/// signed copy the same case means something that is not Sentry just asked
/// where Sentry lives.
public enum MCPBridgePeerFailure: Equatable, Sendable {
    /// The pid was nonsensical, or was the bridge's own.
    case implausiblePeer(pid: Int32)
    /// `SecCodeCopyGuestWithAttributes` could not produce a code object for
    /// the peer at all — the process may already be gone.
    case staticCodeUnavailable(osStatus: Int32)
    /// A code object exists and its signature does not satisfy the
    /// requirement.
    case requirementNotSatisfied(osStatus: Int32)
    /// The requirement string itself would not compile. A programming error,
    /// and one that must fail *closed*.
    case requirementMalformed(osStatus: Int32)

    /// Written for a person reading `sentryctl`'s stderr or Settings, not for a
    /// log parser. Every string names the *unsigned build* possibility
    /// explicitly, because on this project that is overwhelmingly the reason
    /// a reader will ever see one of these.
    public var message: String {
        switch self {
        case .implausiblePeer(let pid):
            return "the connecting process id (\(pid)) isn't one it could legitimately have"
        case .staticCodeUnavailable(let status):
            return "the connecting process's code signature couldn't be examined (OSStatus \(status)); the process may have exited already"
        case .requirementNotSatisfied(let status):
            return "the connecting process isn't signed by this developer (OSStatus \(status)). On a build that wasn't signed with a real Developer ID certificate this is expected, and command-line access cannot work"
        case .requirementMalformed(let status):
            return "Sentry's own signing requirement wouldn't compile (OSStatus \(status)), so the bridge refused every connection rather than none"
        }
    }
}

public enum MCPBridgePeerDecision: Equatable, Sendable {
    case accept
    case reject(MCPBridgePeerFailure)

    public var isAccepted: Bool {
        if case .accept = self { return true }
        return false
    }
}

/// The Security-framework call the gate makes, behind a protocol so the
/// decision logic can be tested without a signed binary to point it at.
///
/// Identical in shape to `FanDaemonPeerEvaluator`, and deliberately a
/// separate protocol rather than a shared one: merging them would put the
/// root daemon's authorization seam and a user-level agent's on the same
/// type, so that a change made for one reaches the other by default. For a
/// pair of four-line protocols that is a bad trade — the duplication is
/// visible and cheap, the coupling would not be.
public protocol MCPBridgePeerEvaluator {
    /// - Returns: `nil` on success, or the failure that stopped it.
    func evaluate(pid: Int32, requirement: String) -> MCPBridgePeerFailure?
}

/// Who is allowed to talk to the bridge, and to Sentry's anonymous listener.
///
/// **Two requirements, because the two roles genuinely differ**, and the
/// difference is forced by how the binaries are signed rather than chosen:
///
///   * The **publisher** is Sentry itself, one known app bundle, so its
///     requirement pins the bundle identifier as well as the anchor and the
///     Team ID — the same three-clause shape `FanDaemonPeerGate` uses, and
///     for the same reasons (see that type's doc comment for what each clause
///     prevents).
///
///   * The **consumers** are `sentryctl` and `SentryMCP`, which are bare
///     Mach-O tools nested in `Sentry.app/Contents/MacOS`. They have no
///     embedded `Info.plist`, so `codesign` derives their signing identifier
///     from the file name plus a hash of the signing certificate. Checked on
///     a real build of this project, they come out as
///     `sentry-55554944088f6f87…` and `SentryMCP-55554944c6320317…` — the
///     suffix changes with the identity, so **no `identifier` clause can be
///     written for them that survives a change of certificate.** Giving them
///     stable identifiers would mean adding `CREATE_INFOPLIST_SECTION_IN_
///     BINARY` to both tool targets; that is a real option and was not taken
///     here, because it changes how two shipping binaries are built in a
///     change whose job is to fix a launchd registration, and because the
///     honest requirement below is already the one that matters.
///
///     So the consumer requirement pins the anchor and the Team ID and
///     nothing else. **Name the consequence rather than let it be
///     discovered: any binary signed by this Team ID can ask the bridge
///     where Sentry is, not only these two tools.** What that buys an
///     attacker who already has code signed by this developer's certificate
///     running on the user's Mac is essentially nothing, and the boundary
///     that actually governs what a connected client may *do* is
///     `MCPAccessController` inside Sentry — per tool, per call, from live
///     settings — exactly as `SentryXPCServiceProtocol`'s doc comment has
///     always said. This gate keeps unrelated local software from resolving
///     the endpoint at all; it was never going to be the authorization
///     boundary, and is not being asked to be one.
///
/// **Fail closed, in every branch.** There is no path through `decide` that
/// returns `.accept` without an evaluator having affirmatively succeeded. A
/// malformed requirement string — our own bug, and the case most likely to be
/// hit first on a machine where signing was never set up — rejects everything
/// rather than waving everything through.
///
/// **The peer is identified by pid, and that has a known weakness.**
/// `NSXPCConnection` exposes `processIdentifier` and does not expose the
/// peer's audit token through any public API. Audit tokens are the correct
/// identifier because they are immune to pid reuse. Reaching one requires the
/// undocumented `NSXPCConnection.auditToken` property, and this codebase
/// already weighed and rejected that for the root daemon — see
/// `FanDaemonPeerGate`'s doc comment for the full argument (an undocumented
/// property that starts returning garbage after an OS update fails *open*).
/// The same reasoning is applied here for consistency, and the residual risk
/// is smaller: winning a pid-reuse race against this gate yields an
/// `NSXPCListenerEndpoint` for a process that will independently gate the
/// resulting connection and then gate every individual tool call against live
/// user settings. It is recorded here so the next reader can weigh it rather
/// than rediscover it.
public enum MCPBridgePeerGate {

    /// Who may call `publish` / `withdraw`: Sentry itself.
    ///
    /// **Duplicated on purpose in `SentryMCPBridge/Info.plist` under
    /// `SMAuthorizedClients`** (via `project.yml`), because launchd reads a
    /// plist and cannot read Swift. `MCPBridgePeerGateTests` asserts the exact
    /// text so a change here fails a test that names the plist rather than
    /// silently diverging from it — the same arrangement
    /// `FanDaemonPeerGate.clientRequirement` has.
    public static let publisherRequirement =
        "identifier \"dev.malekswilam.sentry\" and anchor apple generic and certificate leaf[subject.OU] = \"H7T2D2GL7U\""

    /// Who may call `resolveAppEndpoint`, and who Sentry's anonymous listener
    /// will accept a connection from. See the type doc comment for why this
    /// one carries no `identifier` clause and what that deliberately permits.
    public static let consumerRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"H7T2D2GL7U\""

    /// Decides whether to accept a connection from `pid`.
    ///
    /// - Parameters:
    ///   - pid: `NSXPCConnection.processIdentifier`.
    ///   - ownPID: the gating process's own pid, rejected outright. A
    ///     connection that appears to come from this process itself is either
    ///     a kernel bug or something impersonating one.
    ///   - requirement: `publisherRequirement` or `consumerRequirement`. No
    ///     default: at every call site the role is known, and a default would
    ///     make "which requirement is this?" answerable only by reading two
    ///     files.
    ///   - evaluator: the Security-framework call. Injected so tests can drive
    ///     every branch below without a signed client — the only way to get
    ///     coverage of this logic on a machine where every real evaluation
    ///     fails identically.
    public static func decide(
        pid: Int32,
        ownPID: Int32,
        requirement: String,
        evaluator: MCPBridgePeerEvaluator
    ) -> MCPBridgePeerDecision {

        // pid 0 is the kernel, pid 1 is launchd, negatives are impossible,
        // and our own pid is covered too. None of them is a caller worth
        // serving.
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
