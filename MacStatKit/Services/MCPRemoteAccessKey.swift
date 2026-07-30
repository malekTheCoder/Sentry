import Foundation

#if os(macOS)
import Security

/// The bearer-token secret gating `MCPRemoteServer` (`MacStat/App/
/// MCPRemoteServer.swift`) — the in-app HTTP transport that lets an MCP
/// client reach MacStat's tools over the LAN, unlike the local-only stdio
/// `MacStatMCP` binary. Stored in the login Keychain, never in
/// `AppSettings`/`UserDefaults`: everything else this app persists is meant
/// to round-trip in a plain-text `settings.json` a user might read or copy,
/// which is exactly wrong for a secret whose entire job is to not be
/// readable by whatever can read that file.
///
/// **Why no injectable store for tests, unlike `PowerControlService`'s
/// `defaults:` convention.** There's no equivalent of a throwaway
/// `UserDefaults(suiteName:)` for the Keychain — every call goes to the same
/// login keychain regardless of what "suite" you'd want. Tests below
/// exercise the real Keychain against a per-test-run unique account name
/// (see `MCPRemoteAccessKeyTests`) and clean up after themselves, rather
/// than pretending isolation exists where it doesn't.
public enum MCPRemoteAccessKey {

    /// Keychain service string. A generic-password item's (service, account)
    /// pair is its identity; account is fixed per call site below (`"default"`
    /// in production, a unique value per test).
    private static let service = "dev.malekswilam.macstat.mcp.remotekey"

    /// Returns the currently stored key, or `nil` if none has been generated
    /// yet (e.g. Remote Access has never been turned on).
    public static func current(account: String = "default") -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Generates a new key and stores it, replacing any existing one — used
    /// both for first-enable and for an explicit user-initiated "Regenerate."
    /// Old key stops working immediately: any client using it gets a 401 on
    /// its next call, same as if it never had a key at all.
    @discardableResult
    public static func regenerate(account: String = "default") -> String {
        let key = generateKey()
        store(key, account: account)
        return key
    }

    /// Removes the stored key entirely — called when Remote Access is turned
    /// off, so a re-enable later starts from a clean slate rather than
    /// silently resurrecting whatever key was last generated.
    public static func clear(account: String = "default") {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Private

    /// 32 random bytes, hex-encoded (64 characters) — long enough that
    /// guessing isn't a realistic attack, short enough to type/paste without
    /// line-wrap awkwardness in a client's config.
    private static func generateKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // `SecRandomCopyBytes` failing at all means the system CSPRNG is
        // unavailable — not a recoverable condition for a security-relevant
        // key, so this crashes rather than silently handing back a
        // predictable/empty key a caller might mistake for a real one.
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func store(_ key: String, account: String) {
        // Clear first: `SecItemAdd` fails with `errSecDuplicateItem` on an
        // existing (service, account) pair, and using `SecItemUpdate`
        // instead would need its own not-found fallback anyway — delete-then-
        // add is one code path for both "first key ever" and "regenerate."
        clear(account: account)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        precondition(status == errSecSuccess, "SecItemAdd failed with status \(status)")
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
#endif
