import Foundation

#if os(macOS)

/// What state the command-line bridge's launchd registration is in, as a
/// value — and the single place the words shown for each state are written.
///
/// **This type exists because "registered", "waiting for the user to approve
/// it", and "macOS won't have it" are three different problems with three
/// different fixes, and the old code could express none of them.** Before this
/// change there was no registration at all, and every failure — app not
/// running, app running but unreachable, feature never set up — arrived at the
/// user as the same sentence: "Couldn't reach MacStat.app … Is MacStat
/// running?" That message was *wrong* in the most common case and it sent
/// people to check the one thing that was already fine. Keeping the states
/// distinguishable in the UI **and** in `macstat`'s stderr is a requirement of
/// this feature, not a nicety, so the strings live here rather than being
/// re-improvised at each of the three call sites.
///
/// Pure by construction: no `ServiceManagement` import, no `SMAppService`, no
/// I/O. `MCPEndpointPublisher` maps `SMAppService.Status` onto this and
/// `MacStatXPCClient` reaches the equivalent conclusions from connection
/// failures, so both can be tested exhaustively on a machine where
/// `SMAppService` can only ever report one value. Same technique
/// `FanWriteAvailability` uses for the fan daemon.
public enum MCPBridgeRegistration: Equatable, Sendable {

    /// launchd has the job and will start it on demand. This is the only
    /// state in which `macstat` and the stdio MCP server can work.
    ///
    /// Note what it does **not** promise: that a connection has ever been
    /// made, or that Sentry has published its endpoint. Registration is about
    /// the agent, not about the app.
    case registered

    /// macOS accepted the registration but is waiting for the user to allow
    /// the background item in System Settings ▸ General ▸ Login Items &
    /// Extensions.
    ///
    /// Reachable in normal use — macOS routinely parks a newly registered
    /// agent here — and it is the state most likely to be mistaken for a
    /// failure, because nothing in this app can move it forward. The words
    /// below therefore say where to go rather than offering a button that
    /// would do nothing.
    case awaitingApproval

    /// launchd does not have the job: it was never registered, or it was
    /// removed.
    ///
    /// **This is the expected state on every fresh install, and the permanent
    /// state on any build not signed with a real Developer ID certificate.**
    /// It is not an error condition and is not presented as one.
    case notRegistered

    /// Registration was attempted and macOS refused, or reported a state this
    /// build does not recognise. Carries the reason verbatim.
    case unavailable(reason: String)

    /// Whether command-line access can possibly work right now.
    public var isUsable: Bool {
        if case .registered = self { return true }
        return false
    }

    /// One line, for a status row.
    public var shortLabel: String {
        switch self {
        case .registered:
            return "Command-line access is set up"
        case .awaitingApproval:
            return "Waiting for your approval in System Settings"
        case .notRegistered:
            return "Command-line access isn't set up"
        case .unavailable:
            return "macOS won't set up command-line access"
        }
    }

    /// The paragraph underneath it. Written to be read by somebody who has
    /// just had `macstat` fail on them and does not know what a LaunchAgent
    /// is.
    public var explanation: String {
        switch self {
        case .registered:
            return "macOS will start Sentry's command-line bridge on demand, so the `macstat` tool and the stdio MCP server can reach this app. Sentry itself still has to be running for them to get an answer."
        case .awaitingApproval:
            return "macOS has accepted Sentry's command-line bridge but hasn't allowed it to run yet. Open System Settings ▸ General ▸ Login Items & Extensions and switch Sentry's background item on. Until then, `macstat` and the stdio MCP server can't reach this app."
        case .notRegistered:
            return "The `macstat` command-line tool and the stdio MCP server reach this app through a small background item that macOS starts on demand. It isn't registered yet, so both will fail even while Sentry is running. Setting it up registers one login item and starts no process until something actually connects.\n\nThis is separate from Remote Access above, which does not use it."
        case .unavailable(let reason):
            return "macOS refused to register Sentry's command-line bridge: \(reason)\n\nThe usual cause is a copy of Sentry that wasn't signed with a Developer ID certificate — macOS only registers a background item whose signature matches the app asking for it. Everything else in Sentry works normally; only the `macstat` tool and the stdio MCP server are affected. Remote Access, above, does not go through this path and is unaffected."
        }
    }
}

#endif
