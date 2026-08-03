import Foundation

#if os(macOS)
import MCP

/// The real security boundary for `MCPRemoteServer`'s LAN-bound HTTP
/// transport — everything else in the validation pipeline (content-type,
/// protocol version) is about well-formedness, not who's allowed to ask.
/// `OriginValidator` is deliberately not relied on here (see
/// `MCPRemoteServer`'s doc comment): this bearer-token check is what stands
/// in for it.
///
/// A pure, dependency-injected `HTTPRequestValidator` (the expected key is
/// passed in, not read from `MCPRemoteAccessKey` directly) so it's testable
/// without touching the real Keychain — `MCPRemoteServer` is the only real
/// caller, and it supplies `MCPRemoteAccessKey.current()` at request time so
/// a key rotated mid-flight takes effect on the very next request.
public struct APIKeyValidator: HTTPRequestValidator {
    /// Resolves the currently-valid key *per request*, rather than capturing
    /// one string for the lifetime of the server.
    ///
    /// **Why a provider and not a stored `String?`.** "Regenerate" in
    /// Settings → AI Access exists for exactly one purpose: revoking a key
    /// that leaked. A validator holding a snapshot taken at
    /// `MCPRemoteServer.start(port:serviceCaller:)` time keeps honouring the
    /// leaked key until the server is restarted (and rejects the new one the
    /// UI just showed the user) — the revocation silently does nothing,
    /// which is the worst possible failure mode for this control. Resolving
    /// through a closure on every request makes rotation take effect on the
    /// very next call, matching what the pane's copy promises.
    ///
    /// Returning `nil` means no key has ever been generated — every request
    /// is rejected rather than treating "no key configured" as "no key
    /// required." `MCPRemoteServer` only starts listening once a key exists
    /// (see its doc comment), so this should be unreachable in practice, but
    /// the validator itself never assumes that.
    private let keyProvider: @Sendable () -> String?

    /// Fixed-key convenience (tests, and any caller that genuinely has one
    /// immutable key). Prefer `init(keyProvider:)` in the app, so a rotated
    /// key takes effect without a restart.
    public init(expectedKey: String?) {
        self.init(keyProvider: { expectedKey })
    }

    public init(keyProvider: @escaping @Sendable () -> String?) {
        self.keyProvider = keyProvider
    }

    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard let expectedKey = keyProvider() else {
            return .error(statusCode: 401, .invalidRequest("Remote access is not configured."))
        }
        guard let authorization = request.header(HTTPHeaderName.authorization),
              authorization.hasPrefix("Bearer ") else {
            return .error(
                statusCode: 401,
                .invalidRequest("Missing bearer token."),
                extraHeaders: [HTTPHeaderName.wwwAuthenticate: "Bearer"]
            )
        }
        let providedKey = String(authorization.dropFirst("Bearer ".count))
        // Constant-time comparison: a key check that short-circuits on the
        // first mismatched byte leaks how many leading characters an
        // attacker guessed correctly via response-time differences.
        guard constantTimeEquals(providedKey, expectedKey) else {
            return .error(
                statusCode: 401,
                .invalidRequest("Invalid bearer token."),
                extraHeaders: [HTTPHeaderName.wwwAuthenticate: "Bearer"]
            )
        }
        return nil
    }

    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var diff: UInt8 = 0
        for (l, r) in zip(lhsBytes, rhsBytes) {
            diff |= l ^ r
        }
        return diff == 0
    }
}
#endif
