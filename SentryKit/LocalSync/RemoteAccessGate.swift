import Foundation
import Network

// MARK: - RemoteAccessGate: when the TLS-PSK listener should be open

/// Whether Sentry's TLS-PSK Remote Access listener should be running, as a
/// pure function of plain values — the `ProGate.apply` /
/// `WalkthroughGate.completedFlag` convention: the composition root asks,
/// nothing here holds state or reads settings.
///
/// **This type used to be a paywall and is now a switch.** Sentry Pro sold
/// *reachability from outside the local network*, and this file carried the
/// machinery to enforce that: `permitsAuthenticatedPeer` refused any
/// authenticated peer whose source address wasn't on this Mac's own
/// network, `visibleHostCandidates` stripped tunnel addresses out of the
/// pairing QR, and a pile of RFC 1918 / CGNAT / IPv6-ULA classification
/// existed to tell "here" from "elsewhere". All of it is gone, because all
/// of it existed to answer a question — *has this user paid?* — that no
/// longer has a locked answer. What survives is the one decision that was
/// never about entitlement in the first place.
///
/// The classification code is not worth keeping "in case we need to know
/// where a peer is": nothing asks, and address classification that nothing
/// consults is exactly the inert vocabulary this codebase strips elsewhere.
/// `RemotePairing.HostCandidate.Kind` still distinguishes LAN from tunnel
/// addresses for the pairing UI, which is where that distinction is
/// genuinely load-bearing.
public enum RemoteAccessGate {

    /// Whether the TLS-PSK listener should be open at all — the same
    /// enabled + code-nonempty + port-fits conjunction
    /// `AppDelegate.applySettings` wires to
    /// `LocalSyncServer.enableRemote`/`disableRemote`, extracted so the
    /// axes are pinnable in a unit test.
    ///
    /// Three plain axes and nothing else: the user asked for it, there is
    /// a code to authenticate with, and the port number is expressible.
    public static func shouldOpenListener(
        remoteSyncEnabled: Bool,
        pairingCode: String,
        port: Int
    ) -> Bool {
        remoteSyncEnabled
            && !pairingCode.isEmpty
            && UInt16(exactly: port) != nil
    }
}
