import Foundation

/// Guarantees the newline-delimited-JSON invariant for `macstat watch`:
/// every emitted record is exactly one line, so `macstat watch | jq -c .`
/// and `while read -r line` both work without a streaming JSON parser.
///
/// **Why this exists when the app already encodes compactly.**
/// `MCPXPCService.encodeAndReply` uses a plain `JSONEncoder` with no
/// `.prettyPrinted`, so today's payloads are already newline-free (JSON
/// string escapes turn embedded newlines into `\n`, so only *formatting*
/// whitespace can produce a literal 0x0A). But `watch`'s stdout is a
/// documented machine interface — "one JSON object per line" is a contract
/// consumers script against — and contracts shouldn't hang off an encoder
/// option in a different process that nothing type-checks. This helper makes
/// the invariant local and testable: the fast path is a byte scan (no parse,
/// no allocation) for the overwhelmingly common already-compact case, and
/// the slow path re-serializes through `JSONSerialization` so that even a
/// future pretty-printing app version streams valid NDJSON instead of
/// corrupting every consumer's line-based reader.
///
/// **Why `JSONSerialization` for the fallback rather than decoding
/// `SystemSnapshot` and re-encoding.** Round-tripping through the model
/// type silently drops any field the CLI's linked (possibly older)
/// MacStatKit doesn't know about — a skew between app and CLI versions
/// would quietly truncate the stream's schema. `JSONSerialization`
/// re-serializes whatever the app actually sent, fields and all; `watch` is
/// a pipe, not an interpreter.
public enum NDJSONLine {

    /// Returns `payload` as a single line of JSON (no trailing newline —
    /// the caller owns the delimiter), or `nil` when `payload` contains
    /// line breaks but isn't parseable JSON, which the caller must treat
    /// as a hard error rather than emitting a malformed line: on a data
    /// interface, no output beats wrong output.
    public static func make(from payload: Data) -> Data? {
        // 0x0A (\n) and 0x0D (\r): the only bytes that can break the
        // one-object-per-line framing. Inside JSON *strings* both are
        // mandatorily escaped, so their literal presence always means
        // inter-token formatting whitespace.
        guard payload.contains(0x0A) || payload.contains(0x0D) else { return payload }
        guard let object = try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed]),
              let compact = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        else { return nil }
        return compact
    }
}
