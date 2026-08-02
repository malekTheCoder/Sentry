import Foundation

#if os(macOS)

/// Why the app refused a Mach-service connection, as a value — the
/// `FanDaemonPeerFailure` idea one privilege level down, with one extra
/// case (`hostUnsigned`) the daemon never needs, because a daemon that
/// launchd started is by definition running from a signed registration
/// while this gate can find itself hosted by an ad-hoc Debug build.
public enum MCPPeerFailure: Equatable, Sendable {
    /// The pid was nonsensical, or the app's own.
    case implausiblePeer(pid: Int32)
    /// This copy of Sentry has no Team ID in its own signature (ad-hoc
    /// Debug build). There is no team to pin a requirement to, so every
    /// connection is refused rather than none. In practice this case is
    /// unreachable-by-construction — an ad-hoc build can't register the
    /// LaunchAgent, so no connection ever arrives to be refused — but
    /// "unreachable" is an argument, not a guarantee, and this branch
    /// fails closed if the argument is ever wrong.
    case hostUnsigned
    /// `SecCodeCopyGuestWithAttributes` could not produce a code object
    /// for the peer at all — the process may already be gone.
    case staticCodeUnavailable(osStatus: Int32)
    /// A code object exists and its signature does not satisfy the
    /// requirement: the peer is not one of Sentry's own bundled clients.
    case requirementNotSatisfied(osStatus: Int32)
    /// The requirement string itself would not compile. A programming
    /// error, and one that must fail *closed*.
    case requirementMalformed(osStatus: Int32)

    public var message: String {
        switch self {
        case .implausiblePeer(let pid):
            return "the connecting process id (\(pid)) isn't one it could legitimately have"
        case .hostUnsigned:
            return "this build of Sentry has no signing team, so it can't verify who's connecting and refuses everyone"
        case .staticCodeUnavailable(let status):
            return "the connecting process's code signature couldn't be examined (OSStatus \(status))"
        case .requirementNotSatisfied(let status):
            return "the connecting process isn't one of Sentry's own command-line tools (OSStatus \(status))"
        case .requirementMalformed(let status):
            return "Sentry's own signing requirement wouldn't compile (OSStatus \(status)), so it refused every connection rather than none"
        }
    }
}

public enum MCPPeerDecision: Equatable, Sendable {
    case accept
    case reject(MCPPeerFailure)

    public var isAccepted: Bool {
        if case .accept = self { return true }
        return false
    }
}

/// Peer verification for the app's own Mach service — who may talk to
/// `MCPXPCService` over `MacStatXPCServiceName.machService`.
///
/// WHY A GATE AT ALL, when the old listener accepted everyone. Before the
/// LaunchAgent existed the acceptance policy was moot: the service name was
/// never registered, so nobody could connect and "accept unconditionally"
/// gated nothing. The moment launchd starts routing the name, the listener
/// is reachable by every process on this Mac — and unlike the fan daemon's
/// deliberately tiny vocabulary, `MacStatXPCServiceProtocol` includes write
/// calls (power state, alert rules) whose only other guard is the
/// per-method `MCPAccessController`. Those per-method checks remain the
/// authorization layer; this gate is the *identity* layer in front of it,
/// and it exists for the same reason `FanDaemonPeerGate` does: the two
/// legitimate clients are binaries this app ships inside its own bundle,
/// so "signed by this developer, and is one of those two binaries" is a
/// requirement that costs nothing honest and excludes everything else.
///
/// THE TEAM ID IS THE HOST'S OWN, NOT A COMPILED-IN CONSTANT — the one
/// deliberate departure from `FanDaemonPeerGate`, which pins the literal
/// team string. The daemon must pin: it runs as root and its whole job is
/// to distrust its caller, including a re-signed impostor app. This gate
/// protects an unprivileged app from *other* processes, and its clients
/// are built, signed, and shipped in the same bundle-signing pass as the
/// app itself — so "the peer's team equals my own team" is exactly the
/// invariant, and it holds under every legitimate signing: a Developer ID
/// release (both sides H7T2D2GL7U, identical to pinning), and a personal-
/// team development build (both sides that team, which a pinned constant
/// would wrongly refuse — making the feature untestable end to end on any
/// machine but the owner's). A re-signed app accepts a re-signed CLI, and
/// that is not an escalation: whoever re-signs the app owns the listener
/// they'd be "attacking". No team — ad-hoc — accepts nobody, above.
///
/// Fail closed, in every branch: no path returns `.accept` without the
/// evaluator affirmatively succeeding, and the pid-reuse weakness of
/// pid-based identification is inherited from — and documented at length
/// in — `FanDaemonPeerGate`, which is also where the evaluator protocol
/// this gate reuses lives.
public enum MCPPeerGate {

    /// The bundle ids of the only two legitimate clients, pinned per
    /// `project.yml` (`MacStatCLI` / `MacStatMCP` targets). Tests assert
    /// the built requirement text verbatim, so a bundle-id change there
    /// fails a test here that names this file.
    public static let allowedClientIdentifiers = [
        "dev.malekswilam.macstat.cli",
        "dev.malekswilam.macstat.mcp",
    ]

    /// Builds the designated requirement for a host signed by `teamID`.
    /// Same three-part anatomy as `FanDaemonPeerGate.clientRequirement`,
    /// and each part does the same work: identifiers exclude the rest of
    /// the team's binaries, `anchor apple generic` excludes self-signed
    /// certificates whose OU merely *claims* the team, and the leaf OU is
    /// the team itself.
    public static func requirement(teamID: String) -> String {
        let identifiers = allowedClientIdentifiers
            .map { "identifier \"\($0)\"" }
            .joined(separator: " or ")
        return "(\(identifiers)) and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Decides whether to accept a connection from `pid`.
    ///
    /// - Parameters:
    ///   - pid: `NSXPCConnection.processIdentifier`.
    ///   - ownPID: the app's own pid, rejected outright.
    ///   - teamID: the host app's own Team ID, read from its signature at
    ///     launch (`nil` when ad-hoc — rejects everything, see
    ///     `MCPPeerFailure.hostUnsigned`).
    ///   - evaluator: the Security-framework call, injected so tests can
    ///     drive every branch without a signed client. The protocol is
    ///     `FanDaemonPeerEvaluator`, reused rather than duplicated — its
    ///     failure vocabulary maps 1:1 onto this gate's.
    public static func decide(
        pid: Int32,
        ownPID: Int32,
        teamID: String?,
        evaluator: FanDaemonPeerEvaluator
    ) -> MCPPeerDecision {

        guard pid > 1, pid != ownPID else {
            return .reject(.implausiblePeer(pid: pid))
        }

        guard let teamID, !teamID.isEmpty else {
            return .reject(.hostUnsigned)
        }

        if let failure = evaluator.evaluate(pid: pid, requirement: requirement(teamID: teamID)) {
            switch failure {
            case .implausiblePeer(let p):
                return .reject(.implausiblePeer(pid: p))
            case .staticCodeUnavailable(let s):
                return .reject(.staticCodeUnavailable(osStatus: s))
            case .requirementNotSatisfied(let s):
                return .reject(.requirementNotSatisfied(osStatus: s))
            case .requirementMalformed(let s):
                return .reject(.requirementMalformed(osStatus: s))
            }
        }
        return .accept
    }
}

#endif
