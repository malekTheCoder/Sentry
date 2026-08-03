import Compression
import Foundation

/// Compresses/decompresses `SnapshotRecord.payload` (plan §7.3's rationale:
/// "the widget and dashboard's first paint should not have to gunzip and
/// decode a full snapshot. Query the scalars for the fast path; decode
/// payload only when the user opens a detail view.").
///
/// Uses Apple's `Compression` framework in zlib mode (`COMPRESSION_ZLIB`).
/// This is a pure in-memory transform with no CloudKit or network
/// involvement — safe to build and test today even without an enrolled
/// developer account (see `SyncRecords.swift`'s top-level doc comment).
public enum GzipPayloadCoder {

    public enum CoderError: Error {
        case encodeFailed
        case decodeFailed
    }

    /// JSON-encodes `snapshot`, then zlib-compresses the result.
    public static func encode(_ snapshot: SystemSnapshot, encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        let json = try encoder.encode(snapshot)
        return try compress(json)
    }

    /// Inverse of `encode(_:encoder:)`: zlib-decompresses, then JSON-decodes.
    public static func decode(_ payload: Data, decoder: JSONDecoder = JSONDecoder()) throws -> SystemSnapshot {
        let json = try decompress(payload)
        return try decoder.decode(SystemSnapshot.self, from: json)
    }

    // MARK: - Raw compress/decompress (exposed for direct round-trip tests)

    public static func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        let capacity = max(data.count, 64)
        let result: Data? = data.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Data? in
            guard let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let destBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { destBuffer.deallocate() }
            var destCapacity = capacity
            var actualCount = compression_encode_buffer(
                destBuffer, destCapacity,
                srcBase, data.count,
                nil, COMPRESSION_ZLIB
            )
            // If the destination buffer was too small, grow and retry once
            // with a generous multiple — compressed output can legitimately
            // exceed the input for tiny/incompressible payloads.
            if actualCount == 0 {
                destCapacity = data.count * 2 + 1024
                let biggerBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destCapacity)
                defer { biggerBuffer.deallocate() }
                actualCount = compression_encode_buffer(
                    biggerBuffer, destCapacity,
                    srcBase, data.count,
                    nil, COMPRESSION_ZLIB
                )
                guard actualCount > 0 else { return nil }
                return Data(bytes: biggerBuffer, count: actualCount)
            }
            return Data(bytes: destBuffer, count: actualCount)
        }
        guard let compressed = result else { throw CoderError.encodeFailed }
        return compressed
    }

    public static func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        // Decompressed size is unknown up front, so grow geometrically
        // until `compression_decode_buffer` stops filling the buffer
        // exactly to capacity (our signal that more output space may be
        // needed — a real edge case where the decoded size lands exactly
        // on a capacity boundary just costs one extra retry, not
        // correctness).
        var capacity = max(data.count * 4, 4096)
        while capacity <= 1_073_741_824 { // 1 GB safety cap
            let outcome: Data?? = data.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Data?? in
                guard let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return .some(nil) }
                let destBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
                defer { destBuffer.deallocate() }
                let actualCount = compression_decode_buffer(
                    destBuffer, capacity,
                    srcBase, data.count,
                    nil, COMPRESSION_ZLIB
                )
                guard actualCount > 0 else { return .some(nil) }
                if actualCount == capacity {
                    return nil // ambiguous: might be truncated, ask caller to retry bigger
                }
                return .some(Data(bytes: destBuffer, count: actualCount))
            }
            switch outcome {
            case .some(.some(let data)):
                return data
            case .some(.none):
                throw CoderError.decodeFailed
            case nil:
                capacity *= 4
                continue
            }
        }
        throw CoderError.decodeFailed
    }
}
