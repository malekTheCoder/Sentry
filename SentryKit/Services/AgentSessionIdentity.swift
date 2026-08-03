import Foundation

/// Encodes a per-connection session ID into the `clientName` string that
/// already crosses every `SentryXPCServiceProtocol` method (agent-session
/// attribution pass).
///
/// **Why piggyback on `clientName` instead of widening the XPC protocol:**
/// `SentryXPCServiceProtocol` has 20 methods, every one of which already
/// carries `clientName` — adding a `sessionID` parameter to each would touch
/// every method, every call site in `MCPToolCatalog`, and every conformance
/// (`SentryXPCClient`, `LocalXPCServiceCaller`), for a value that, exactly
/// like `clientName` itself, is a self-reported label, not an auth boundary
/// (see `SentryXPCServiceProtocol`'s doc comment). Composing the two into
/// one wire string keeps the protocol, the bridge, and both transports
/// untouched, and old callers that send a plain name keep working — `parse`
/// just reports `sessionID: nil` for them.
///
/// **Format:** `"<name>\u{1F}<uuid>"` — U+001F (unit separator) never occurs
/// in a legitimate MCP client name and is stripped by `MCPXPCService`'s
/// dialog sanitizer anyway, so it can't leak into UI. `parse` only accepts a
/// well-formed UUID after the *last* separator; anything else is treated as
/// part of the name, so a client that embeds U+001F in its self-reported
/// name can garble its own label but cannot make a non-UUID masquerade as a
/// session ID. (Spoofing a *valid* UUID is possible and accepted — the ID is
/// a correlation label with exactly `clientName`'s trust level, and a client
/// lying about its own session only mis-attributes its own activity.)
public enum AgentSessionIdentity {

    /// U+001F UNIT SEPARATOR — see the type doc comment for why this
    /// character specifically.
    public static let separator: Character = "\u{1F}"

    /// Composes the wire-format `clientName` carrying `sessionID`.
    public static func encode(clientName: String, sessionID: String) -> String {
        "\(clientName)\(separator)\(sessionID)"
    }

    /// Splits a wire-format name back into display name and session ID.
    /// A plain name (no separator, or a last component that isn't a valid
    /// UUID string) comes back unchanged with `sessionID: nil`.
    public static func parse(_ wireName: String) -> (clientName: String, sessionID: String?) {
        guard let lastSeparator = wireName.lastIndex(of: separator) else {
            return (wireName, nil)
        }
        let candidate = String(wireName[wireName.index(after: lastSeparator)...])
        guard UUID(uuidString: candidate) != nil else {
            return (wireName, nil)
        }
        return (String(wireName[..<lastSeparator]), candidate)
    }
}
