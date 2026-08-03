import Foundation

// MARK: - LocalSyncMessage: the envelope carried by every frame

/// Every message the local-network (Bonjour) transport can carry in either
/// direction. Originally (see git history) this channel only ever carried
/// `SystemSnapshot`s Mac→phone; extending it to also carry `ControlCommand`
/// (phone→Mac) and `ControlStatus` (Mac→phone, the acknowledgement) is what
/// makes `LocalSyncClient.send(command:)` and `KeepAwakeIntent`/
/// `ReleaseAwakeIntent`/`SleepStatusCard`'s buttons stop being documented
/// no-ops and start actually reaching a real Mac — see those types' doc
/// comments for the before/after.
///
/// A `.snapshot` frame flows Mac→phone (the always-on broadcast
/// `LocalSyncServer` already sent). A `.command` frame flows phone→Mac (a
/// `ControlCommand` a Siri intent or `SleepStatusCard` button constructed).
/// A `.status` frame flows Mac→phone in direct reply to a `.command` frame
/// carrying the same `nonce`. Nothing enforces "who's allowed to send
/// which" at this layer — `LocalSyncServer`/`LocalSyncClient` each simply
/// ignore/log frame kinds they don't expect to receive, the same
/// "say plainly what doesn't apply" posture as elsewhere in this file.
public enum LocalSyncMessage: Sendable {
    case snapshot(SystemSnapshot)
    case command(ControlCommand)
    case status(ControlStatus)
}

// MARK: - LocalSyncFraming: the wire protocol for the local-network transport

/// Pure, testable framing logic for the local-network (Bonjour + `Network`
/// framework) transport `StatsTransport.swift`'s doc comment calls "v4" —
/// see that file for the architectural context (CloudKit is v2 and fully
/// blocked on Apple Developer Program enrollment; this transport needs none
/// of that, since it never leaves the local Wi-Fi network).
///
/// **The wire format.** A 1-byte kind tag (`0x01` = snapshot, `0x02` =
/// command, `0x03` = status), then a 4-byte big-endian `UInt32` length
/// prefix, then exactly that many bytes of `JSONEncoder`-produced JSON for
/// the payload the tag identifies. The kind tag is what lets a single
/// receive loop on either end tell a `SystemSnapshot` frame apart from a
/// `ControlCommand`/`ControlStatus` frame without trial-decoding — the
/// wire's only job is "where does this message end and the next begin, and
/// which of the three shapes is it," and a tag byte answers the second
/// question for free instead of needing every reader to try three decoders
/// and see which one didn't throw. No versioning byte beyond that, no
/// compression — `SystemSnapshot.schemaVersion` already exists for payload
/// evolution (see that type's doc comment), so a length-prefixed JSON frame
/// is enough to know where one message ends and the next begins over a byte
/// stream that gives no other message boundaries (`NWConnection.receive`
/// hands back arbitrary chunks, not one call per logical message).
///
/// **Why pure functions, not something bound to `NWConnection`.** Every
/// other testable piece of wire-protocol-shaped logic in this codebase
/// (`GzipPayloadCoder`, `CKMapper`) is a pure encode/decode pair with no
/// networking dependency, specifically so `SentryTests` can exercise it
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
/// every read, and get back zero-or-more complete, decoded messages plus
/// whatever partial bytes are left over to prepend to the next read.
public enum LocalSyncFraming {

    /// Distinguishes what a frame's payload decodes as. Raw values are the
    /// literal wire bytes — changing them breaks the wire protocol between
    /// a Mac and phone running mismatched builds, same caution as any other
    /// wire-level constant in this codebase.
    private enum Kind: UInt8 {
        case snapshot = 0x01
        case command = 0x02
        case status = 0x03
    }

    /// Thrown by `decode(_:)` and `extractFrames(from:)` when a frame's
    /// bytes don't round-trip through `JSONDecoder`, when a claimed frame
    /// length is unreasonable (see `maxFrameLength` below), or when the
    /// kind tag byte isn't one this build recognizes.
    public enum FramingError: Error, Equatable {
        case malformedLengthPrefix(claimedLength: UInt32)
        case decodingFailed(String)
        case unknownKind(UInt8)
    }

    /// A generous ceiling on a single frame's payload size — comfortably
    /// larger than any real `SystemSnapshot` (a few KB of JSON) could ever
    /// be, while still small enough to reject an obviously-bogus length
    /// prefix (e.g. random garbage bytes misread as a length) before it
    /// causes `extractFrames(from:)` to sit forever "waiting" for gigabytes
    /// that will never show up. 4 MiB.
    public static let maxFrameLength: UInt32 = 4 * 1024 * 1024

    private static let kindSize = MemoryLayout<UInt8>.size
    private static let lengthSize = MemoryLayout<UInt32>.size
    private static var headerSize: Int { kindSize + lengthSize }

    // MARK: - Encoding

    /// Encodes any `LocalSyncMessage` as a kind-tagged, length-prefixed JSON
    /// frame, ready to hand straight to `NWConnection.send(content:completion:)`.
    public static func encode(_ message: LocalSyncMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        switch message {
        case .snapshot(let snapshot):
            return try frame(kind: .snapshot, payload: encoder.encode(snapshot))
        case .command(let command):
            return try frame(kind: .command, payload: encoder.encode(command))
        case .status(let status):
            return try frame(kind: .status, payload: encoder.encode(status))
        }
    }

    /// Convenience overload so existing `SystemSnapshot`-only call sites
    /// (`LocalSyncServer.broadcast`) don't need to spell out
    /// `.snapshot(snapshot)` at every call site. Equivalent to
    /// `encode(.snapshot(snapshot))`.
    public static func encode(_ snapshot: SystemSnapshot) throws -> Data {
        try encode(.snapshot(snapshot))
    }

    private static func frame(kind: Kind, payload: Data) -> Data {
        var data = Data([kind.rawValue])
        data.append(contentsOf: lengthPrefixBytes(for: payload.count))
        data.append(payload)
        return data
    }

    /// Wraps an already-encoded JSON payload with its kind tag + 4-byte
    /// big-endian length prefix. Split out from `encode(_:)` so
    /// `extractFrames(from:)`'s tests can build raw frames byte-for-byte
    /// without going through `JSONEncoder`. Defaults to `.snapshot` — the
    /// only kind the pre-existing tests construct raw frames for — but
    /// takes an explicit kind byte for tests exercising the other two.
    /// `0x01` is `Kind.snapshot`'s raw value, duplicated as a literal here
    /// because a `public` default-argument expression can't reference a
    /// `private` type.
    public static func frame(for payload: Data, kindByte: UInt8 = 0x01) -> Data {
        var data = Data([kindByte])
        data.append(contentsOf: lengthPrefixBytes(for: payload.count))
        data.append(payload)
        return data
    }

    private static func lengthPrefixBytes(for count: Int) -> [UInt8] {
        var length = UInt32(count).bigEndian
        return withUnsafeBytes(of: &length) { Array($0) }
    }

    // MARK: - Single-frame decoding

    /// Decodes exactly one complete frame (kind tag + 4-byte length prefix +
    /// that many JSON bytes, and nothing more) into a `LocalSyncMessage`.
    /// For the streaming read side (arbitrary chunk boundaries), use
    /// `extractFrames(from:)` instead — this is the simpler one-shot
    /// counterpart to `encode(_:)`, useful on its own for tests and for any
    /// caller that already knows it has exactly one frame's worth of bytes.
    public static func decode(_ data: Data) throws -> LocalSyncMessage {
        guard data.count >= headerSize else {
            throw FramingError.malformedLengthPrefix(claimedLength: 0)
        }
        let kindByte = data[data.startIndex]
        let lengthPrefix = data.subdata(in: (data.startIndex + kindSize)..<(data.startIndex + headerSize))
        let claimedLength = readLength(lengthPrefix)
        let payloadStart = data.startIndex + headerSize
        let expectedEnd = payloadStart + Int(claimedLength)
        guard claimedLength <= maxFrameLength, expectedEnd == data.endIndex else {
            throw FramingError.malformedLengthPrefix(claimedLength: claimedLength)
        }
        let payload = data[payloadStart..<expectedEnd]
        return try decodePayload(payload, kindByte: kindByte)
    }

    // MARK: - Streaming multi-frame extraction

    /// Given a buffer that has accumulated some number of raw bytes read
    /// off a socket (zero, one, several, or a fractional frame's worth),
    /// extracts every complete frame present and returns both the decoded
    /// messages (in the order their frames appear) and whatever bytes are
    /// left over — a partial frame the caller should prepend to the next
    /// chunk it reads, or an empty `Data` if the buffer ended exactly on a
    /// frame boundary.
    ///
    /// Never throws on a merely-incomplete buffer (not enough bytes yet for
    /// the header, or for the payload the length prefix promises) — that is
    /// the normal, expected state of a streaming read mid-frame, not an
    /// error condition. It only throws `FramingError` when the bytes it
    /// *does* have enough of to interpret are actually malformed: a length
    /// prefix claiming more than `maxFrameLength`, an unrecognized kind
    /// byte, or a payload that fails `JSONDecoder`. All are treated as fatal
    /// for the connection by callers (`LocalSyncClient`/`LocalSyncServer`)
    /// rather than something to skip past and keep reading — a wire
    /// protocol this simple has no resynchronization story for a corrupted
    /// stream.
    public static func extractFrames(from buffer: Data) throws -> (messages: [LocalSyncMessage], remainder: Data) {
        var messages: [LocalSyncMessage] = []
        var remaining = buffer

        while remaining.count >= headerSize {
            let kindByte = remaining[remaining.startIndex]
            let lengthPrefix = remaining.subdata(in: (remaining.startIndex + kindSize)..<(remaining.startIndex + headerSize))
            let claimedLength = readLength(lengthPrefix)
            guard claimedLength <= maxFrameLength else {
                throw FramingError.malformedLengthPrefix(claimedLength: claimedLength)
            }
            let payloadStart = remaining.startIndex + headerSize
            let payloadEnd = payloadStart + Int(claimedLength)
            guard payloadEnd <= remaining.endIndex else {
                // Not enough bytes yet for this frame's full payload — wait
                // for more data. The un-consumed header is kept in
                // `remaining` on purpose, so the next call re-reads (and
                // re-validates) it rather than trusting a value derived from
                // a previous, now-stale call.
                break
            }
            let payload = remaining[payloadStart..<payloadEnd]
            messages.append(try decodePayload(payload, kindByte: kindByte))
            remaining = remaining[payloadEnd...]
        }

        return (messages, Data(remaining))
    }

    // MARK: - Shared helpers

    private static func readLength(_ prefix: Data) -> UInt32 {
        var value: UInt32 = 0
        for byte in prefix {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    private static func decodePayload(_ payload: Data, kindByte: UInt8) throws -> LocalSyncMessage {
        guard let kind = Kind(rawValue: kindByte) else {
            throw FramingError.unknownKind(kindByte)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            switch kind {
            case .snapshot:
                return .snapshot(try decoder.decode(SystemSnapshot.self, from: payload))
            case .command:
                return .command(try decoder.decode(ControlCommand.self, from: payload))
            case .status:
                return .status(try decoder.decode(ControlStatus.self, from: payload))
            }
        } catch let error as FramingError {
            throw error
        } catch {
            throw FramingError.decodingFailed(String(describing: error))
        }
    }
}
