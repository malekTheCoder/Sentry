import XCTest
@testable import MacStat
import MacStatKit

/// Coverage for `LocalSyncFraming` (`MacStatKit/LocalSync/LocalSyncFraming.swift`),
/// the wire protocol behind the local-network (Bonjour) transport
/// `StatsTransport.swift`'s doc comment calls "v4." Pure in-memory
/// byte-buffer logic — no `NWConnection`/socket involvement, same testing
/// posture as `GzipPayloadCoderTests` for the encode/decode half and
/// entirely new for the streaming multi-read half, since nothing else in
/// this codebase has to reassemble frames across arbitrary chunk
/// boundaries the way a real socket read would deliver them.
final class LocalSyncFramingTests: XCTestCase {

    // MARK: - Fixtures

    private func sampleSnapshot(deviceID: String = "test-device", cpuPercent: Double = 12.5) -> SystemSnapshot {
        SystemSnapshot(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            deviceID: deviceID,
            cpu: CPUStats(totalPercent: cpuPercent)
        )
    }

    // MARK: - encode/decode round trip

    func testEncodeDecodeRoundTrip() throws {
        let original = sampleSnapshot()
        let framed = try LocalSyncFraming.encode(original)
        let decoded = try LocalSyncFraming.decode(framed)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.deviceID, original.deviceID)
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970, original.timestamp.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.cpu?.totalPercent, original.cpu?.totalPercent)
    }

    func testEncodedFrameStartsWithCorrectBigEndianLengthPrefix() throws {
        let framed = try LocalSyncFraming.encode(sampleSnapshot())
        let prefix = framed.prefix(4)
        var claimedLength: UInt32 = 0
        for byte in prefix { claimedLength = (claimedLength << 8) | UInt32(byte) }
        XCTAssertEqual(Int(claimedLength), framed.count - 4)
    }

    func testDecodeRejectsTruncatedData() {
        // Fewer than 4 bytes total: not even a full length prefix.
        XCTAssertThrowsError(try LocalSyncFraming.decode(Data([1, 2]))) { error in
            guard case LocalSyncFraming.FramingError.malformedLengthPrefix = error else {
                return XCTFail("expected malformedLengthPrefix, got \(error)")
            }
        }
    }

    func testDecodeRejectsLengthPrefixThatOverclaimsAvailableBytes() {
        // Claims a 100-byte payload but supplies none.
        var length = UInt32(100).bigEndian
        let prefix = Data(bytes: &length, count: 4)
        XCTAssertThrowsError(try LocalSyncFraming.decode(prefix)) { error in
            guard case LocalSyncFraming.FramingError.malformedLengthPrefix = error else {
                return XCTFail("expected malformedLengthPrefix, got \(error)")
            }
        }
    }

    func testDecodeRejectsLengthPrefixAboveMaxFrameLength() {
        var length = (LocalSyncFraming.maxFrameLength + 1).bigEndian
        let bogus = Data(bytes: &length, count: 4)
        XCTAssertThrowsError(try LocalSyncFraming.decode(bogus)) { error in
            guard case LocalSyncFraming.FramingError.malformedLengthPrefix(let claimed) = error else {
                return XCTFail("expected malformedLengthPrefix, got \(error)")
            }
            XCTAssertEqual(claimed, LocalSyncFraming.maxFrameLength + 1)
        }
    }

    func testDecodeRejectsMalformedJSONPayload() {
        let garbage = Data("not json".utf8)
        let framed = LocalSyncFraming.frame(for: garbage)
        XCTAssertThrowsError(try LocalSyncFraming.decode(framed)) { error in
            guard case LocalSyncFraming.FramingError.decodingFailed = error else {
                return XCTFail("expected decodingFailed, got \(error)")
            }
        }
    }

    // MARK: - extractFrames: the streaming read side

    func testExtractFramesReturnsEmptyForEmptyBuffer() throws {
        let (snapshots, remainder) = try LocalSyncFraming.extractFrames(from: Data())
        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertTrue(remainder.isEmpty)
    }

    func testExtractFramesHandlesPartialLengthPrefix() throws {
        // Only 2 of the 4 length-prefix bytes have arrived.
        let partial = Data([0, 0])
        let (snapshots, remainder) = try LocalSyncFraming.extractFrames(from: partial)
        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertEqual(remainder, partial)
    }

    func testExtractFramesHandlesPartialPayload() throws {
        let full = try LocalSyncFraming.encode(sampleSnapshot())
        // Simulate a read that only delivered the length prefix plus a few
        // payload bytes, not the whole frame.
        let partial = full.prefix(full.count - 5)
        let (snapshots, remainder) = try LocalSyncFraming.extractFrames(from: partial)
        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertEqual(remainder, partial)
    }

    func testExtractFramesReturnsOneCompleteFrameAndEmptyRemainder() throws {
        let framed = try LocalSyncFraming.encode(sampleSnapshot())
        let (snapshots, remainder) = try LocalSyncFraming.extractFrames(from: framed)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.deviceID, "test-device")
        XCTAssertTrue(remainder.isEmpty)
    }

    /// The core "several frames concatenated, plus a trailing partial frame"
    /// case a real streaming socket read regularly produces — e.g. the
    /// sender wrote three snapshots back-to-back before the receiver's next
    /// `receive` call, and the fourth is still mid-flight.
    func testExtractFramesHandlesMultipleCompleteFramesPlusTrailingPartial() throws {
        let first = try LocalSyncFraming.encode(sampleSnapshot(deviceID: "device-1", cpuPercent: 10))
        let second = try LocalSyncFraming.encode(sampleSnapshot(deviceID: "device-2", cpuPercent: 20))
        let third = try LocalSyncFraming.encode(sampleSnapshot(deviceID: "device-3", cpuPercent: 30))
        let trailingPartial = third.prefix(6)

        var buffer = Data()
        buffer.append(first)
        buffer.append(second)
        // Only part of the third frame "arrived."
        buffer.append(trailingPartial)

        let (snapshots, remainder) = try LocalSyncFraming.extractFrames(from: buffer)
        XCTAssertEqual(snapshots.map(\.deviceID), ["device-1", "device-2"])
        XCTAssertEqual(snapshots.map { $0.cpu?.totalPercent }, [10, 20])
        XCTAssertEqual(remainder, trailingPartial)
    }

    /// Feeding the leftover remainder back in on a subsequent "read" (as a
    /// real caller's accumulation loop would) must recover the rest of the
    /// split frame plus anything appended after it — this is the scenario
    /// `extractFrames(from:)`'s doc comment describes as its whole reason
    /// for existing.
    func testExtractFramesAcrossSimulatedMultipleReads() throws {
        let one = try LocalSyncFraming.encode(sampleSnapshot(deviceID: "device-A"))
        let two = try LocalSyncFraming.encode(sampleSnapshot(deviceID: "device-B"))

        let splitPoint = one.count + 3 // land partway into frame two
        var wholeStream = Data()
        wholeStream.append(one)
        wholeStream.append(two)

        let firstReadChunk = wholeStream.prefix(splitPoint)
        let secondReadChunk = wholeStream.suffix(from: splitPoint)

        let (firstBatch, remainderAfterFirstRead) = try LocalSyncFraming.extractFrames(from: firstReadChunk)
        XCTAssertEqual(firstBatch.map(\.deviceID), ["device-A"])

        var accumulated = remainderAfterFirstRead
        accumulated.append(secondReadChunk)
        let (secondBatch, remainderAfterSecondRead) = try LocalSyncFraming.extractFrames(from: accumulated)
        XCTAssertEqual(secondBatch.map(\.deviceID), ["device-B"])
        XCTAssertTrue(remainderAfterSecondRead.isEmpty)
    }

    func testExtractFramesThrowsOnMalformedLengthPrefixMidStream() {
        var bogusLength = (LocalSyncFraming.maxFrameLength + 100).bigEndian
        let bogus = Data(bytes: &bogusLength, count: 4)
        XCTAssertThrowsError(try LocalSyncFraming.extractFrames(from: bogus)) { error in
            guard case LocalSyncFraming.FramingError.malformedLengthPrefix = error else {
                return XCTFail("expected malformedLengthPrefix, got \(error)")
            }
        }
    }
}
