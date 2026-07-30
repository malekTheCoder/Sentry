import Foundation

// MARK: - LocalSyncFraming: the wire protocol for the local-network transport

/// Pure, testable framing logic for the local-network (Bonjour + `Network`
/// framework) transport `StatsTransport.swift`'s doc comment calls "v4" —
/// see that file for the architectural context (CloudKit is v2 and fully
/// blocked on Apple Developer Program enrollment; this transport needs none
/// of that, since it never leaves the local Wi-Fi network).
///
/// **The wire format.** Deliberately the simplest thing that works: a 4-byte
/// big-endian `UInt32` length prefix, followed by exactly that many bytes of
/// `JSONEncoder`-produced JSON representing one `SystemSnapshot`. No
/// versioning byte, no compression, no framing beyond the length prefix —
/// `SystemSnapshot.schemaVersion` already exists for payload evolution (see
/// that type's doc comment), so a length-prefixed JSON frame is enough to
/// know where one message ends and the next begins over a byte stream that
/// gives no other message boundaries (`NWConnection.receive` hands back
/// arbitrary chunks, not one call per logical message).
///
/// **Why pure functions, not something bound to `NWConnection`.** Every
/// other testable piece of wire-protocol-shaped logic in this codebase
/// (`GzipPayloadCoder`, `CKMapper`) is a pure encode/decode pair with no
/// networking dependency, specifically so `MacStatTests` can exercise it
/// without standing up a real socket. This is the one genuinely new
/// wire-protocol in the whole codebase, so it gets the same treatment:
/// `LocalSyncServer`/`LocalSyncClient` (the two concrete `Network`-framework
/// users) call into these functions, but the functions themselves know
/// nothing about `NWConnection`.
///
/// **The streaming-read function specifically
/// (`extractFrames(from:)`).** `NWConnection.receive` delivers whatever
/// bytes happened to arrive in one read — that might be less than one frame
/// (a length prefix split across two reads), exactly one frame, or several
/// frames concatenated together (the sender wrote three snapshots before the
/// receiver's next read). A decoder that assumes "one read == one message"
/// silently drops or misparses data under those conditions — this function
/// is the fix: callers accumulate raw bytes into a buffer, call this after
/// every read, and get back zero-or-more complete, decoded snapshots plus
/// whatever partial bytes are left over to prepend to the next read.
public enum LocalSyncFraming {

    /// Thrown by `decode(_:)` and `extractFrames(from:)` when a frame's
    /// bytes don't round-trip through `JSONDecoder`, or when a claimed
    /// frame length is unreasonable (see `maxFrameLength` below) — the
    /// latter guards against a corrupted/malicious length prefix causing an
    /// unbounded in-memory buffer allocation while genuinely waiting for
    /// bytes that will never arrive.
    public enum FramingError: Error, Equatable {
        case malformedLengthPrefix(claimedLength: UInt32)
        case decodingFailed(String)
    }

    /// A generous ceiling on a single frame's payload size — comfortably
    /// larger than any real `SystemSnapshot` (a few KB of JSON) could ever
    /// be, while still small enough to reject an obviously-bogus length
    /// prefix (e.g. random garbage bytes misread as a length) before it
    /// causes `extractFrames(from:)` to sit forever "waiting" for gigabytes
    /// that will never show up. 4 MiB.
    public static let maxFrameLength: UInt32 = 4 * 1024 * 1024

    // MARK: - Encoding

    /// Encodes one `SystemSnapshot` as a length-prefixed JSON frame, ready
    /// to hand straight to `NWConnection.send(content:completion:)`.
    /// `dateEncodingStrategy = .iso8601` matches `MCPXPCService
    /// .encodeAndReply`'s exact convention (`MacStat/App/MCPXPCService.swift`)
    /// — the one other place in this codebase that serializes `MacStatKit`
    /// model types to JSON for transport, so a `SystemSnapshot` looks
    /// identical over MCP and over this transport.
    public static func encode(_ snapshot: SystemSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(snapshot)
        return frame(for: payload)
    }

    /// Wraps an already-encoded JSON payload with its 4-byte big-endian
    /// length prefix. Split out from `encode(_:)` so `extractFrames(from:)`'s
    /// tests can build raw frames byte-for-byte without going through
    /// `JSONEncoder`.
    public static func frame(for payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var data = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        data.append(payload)
        return data
    }

    // MARK: - Single-frame decoding

    /// Decodes exactly one complete frame (4-byte length prefix + that many
    /// JSON bytes, and nothing more) into a `SystemSnapshot`. For the
    /// streaming read side (arbitrary chunk boundaries), use
    /// `extractFrames(from:)` instead — this is the simpler one-shot
    /// counterpart to `encode(_:)`, useful on its own for tests and for any
    /// caller that already knows it has exactly one frame's worth of bytes.
    public static func decode(_ data: Data) throws -> SystemSnapshot {
        guard data.count >= MemoryLayout<UInt32>.size else {
            throw FramingError.malformedLengthPrefix(claimedLength: 0)
        }
        let lengthPrefix = data.prefix(MemoryLayout<UInt32>.size)
        let claimedLength = readLength(lengthPrefix)
        let payloadStart = data.startIndex + MemoryLayout<UInt32>.size
        let expectedEnd = payloadStart + Int(claimedLength)
        guard claimedLength <= maxFrameLength, expectedEnd == data.endIndex else {
            throw FramingError.malformedLengthPrefix(claimedLength: claimedLength)
        }
        let payload = data[payloadStart..<expectedEnd]
        return try decodePayload(payload)
    }

    // MARK: - Streaming multi-frame extraction

    /// Given a buffer that has accumulated some number of raw bytes read
    /// off a socket (zero, one, several, or a fractional frame's worth),
    /// extracts every complete frame present and returns both the decoded
    /// snapshots (in the order their frames appear) and whatever bytes are
    /// left over — a partial frame the caller should prepend to the next
    /// chunk it reads, or an empty `Data` if the buffer ended exactly on a
    /// frame boundary.
    ///
    /// Never throws on a merely-incomplete buffer (not enough bytes yet for
    /// the length prefix, or for the payload the length prefix promises) —
    /// that is the normal, expected state of a streaming read mid-frame, not
    /// an error condition. It only throws `FramingError` when the bytes it
    /// *does* have enough of to interpret are actually malformed: a length
    /// prefix claiming more than `maxFrameLength`, or a payload that fails
    /// `JSONDecoder`. Both are treated as fatal for the connection by
    /// callers (`LocalSyncClient`) rather than something to skip past and
    /// keep reading — a wire protocol this simple has no resynchronization
    /// story for a corrupted stream.
    public static func extractFrames(from buffer: Data) throws -> (snapshots: [SystemSnapshot], remainder: Data) {
        var snapshots: [SystemSnapshot] = []
        var remaining = buffer
        let prefixSize = MemoryLayout<UInt32>.size

        while remaining.count >= prefixSize {
            let lengthPrefix = remaining.prefix(prefixSize)
            let claimedLength = readLength(lengthPrefix)
            guard claimedLength <= maxFrameLength else {
                throw FramingError.malformedLengthPrefix(claimedLength: claimedLength)
            }
            let payloadStart = remaining.startIndex + prefixSize
            let payloadEnd = payloadStart + Int(claimedLength)
            guard payloadEnd <= remaining.endIndex else {
                // Not enough bytes yet for this frame's full payload — wait
                // for more data. The un-consumed length prefix is kept in
                // `remaining` on purpose, so the next call re-reads (and
                // re-validates) it rather than trusting a value derived from
                // a previous, now-stale call.
                break
            }
            let payload = remaining[payloadStart..<payloadEnd]
            snapshots.append(try decodePayload(payload))
            remaining = remaining[payloadEnd...]
        }

        return (snapshots, Data(remaining))
    }

    // MARK: - Shared helpers

    private static func readLength(_ prefix: Data) -> UInt32 {
        var value: UInt32 = 0
        for byte in prefix {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    private static func decodePayload(_ payload: Data) throws -> SystemSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(SystemSnapshot.self, from: payload)
        } catch {
            throw FramingError.decodingFailed(String(describing: error))
        }
    }
}
