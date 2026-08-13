import XCTest
@testable import Sentry
import SentryKit

/// Coverage for `LocalSyncFraming` (`SentryKit/LocalSync/LocalSyncFraming.swift`),
/// the wire protocol behind the local-network (Bonjour) transport. Pure
/// in-memory byte-buffer logic — no `NWConnection`/socket involvement,
/// for the encode/decode half and the streaming multi-read half alike,
/// since nothing else in this codebase has to reassemble frames across
/// arbitrary chunk boundaries the way a real socket read would deliver
/// them.
///
/// Covers all three `LocalSyncMessage` cases (snapshot/command/status) now
/// that the wire format carries a 1-byte kind tag ahead of each frame's
/// length prefix — see that enum's doc comment for why the tag exists.
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

    private func sampleCommand(nonce: String = "nonce-1") -> ControlCommand {
        ControlCommand(
            deviceID: "test-device",
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            commandType: "keepAwake",
            parametersJSON: #"{"durationSeconds":3600,"mode":"systemOnly"}"#,
            nonce: nonce,
            expiresAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
    }

    private func sampleStatus(respondsToNonce: String = "nonce-1") -> ControlStatus {
        ControlStatus(
            deviceID: "test-device",
            respondsToNonce: respondsToNonce,
            state: "completed",
            message: "Your Mac will stay awake.",
            assertionActive: true,
            assertionExpiresAt: Date(timeIntervalSince1970: 1_700_003_600),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - encode/decode round trip — all three message kinds

    func testEncodeDecodeRoundTripSnapshot() throws {
        let original = sampleSnapshot()
        let framed = try LocalSyncFraming.encode(.snapshot(original))
        guard case .snapshot(let decoded) = try LocalSyncFraming.decode(framed) else {
            return XCTFail("expected .snapshot")
        }
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.deviceID, original.deviceID)
        XCTAssertEqual(decoded.cpu?.totalPercent, original.cpu?.totalPercent)
    }

    /// The convenience `encode(_ snapshot:)` overload existing call sites
    /// (`LocalSyncServer.broadcast`) use — must decode to the same content
    /// as spelling out `.snapshot(_:)` explicitly. Compares *decoded*
    /// values rather than raw encoded `Data`: `JSONEncoder` does not
    /// guarantee stable key ordering across separate `.encode()` calls of
    /// an identical value (confirmed independently — two back-to-back
    /// encodes of the same struct can emit keys in a different order each
    /// time), so a byte-for-byte `Data` comparison here would be a flaky
    /// test asserting something the wire format never actually promises;
    /// `extractFrames(from:)`'s own length-prefix parsing is what actually
    /// needs a specific *frame structure*, not the JSON payload's key order.
    func testSnapshotConvenienceOverloadMatchesExplicitEnvelope() throws {
        let snapshot = sampleSnapshot()
        let viaConvenience = try LocalSyncFraming.encode(snapshot)
        let viaEnvelope = try LocalSyncFraming.encode(.snapshot(snapshot))

        guard case .snapshot(let decodedConvenience) = try LocalSyncFraming.decode(viaConvenience),
              case .snapshot(let decodedEnvelope) = try LocalSyncFraming.decode(viaEnvelope)
        else {
            return XCTFail("expected both to decode as .snapshot")
        }
        XCTAssertEqual(decodedConvenience.id, decodedEnvelope.id)
        XCTAssertEqual(decodedConvenience.deviceID, decodedEnvelope.deviceID)
        XCTAssertEqual(decodedConvenience.cpu?.totalPercent, decodedEnvelope.cpu?.totalPercent)
    }

    func testEncodeDecodeRoundTripCommand() throws {
        let original = sampleCommand()
        let framed = try LocalSyncFraming.encode(.command(original))
        guard case .command(let decoded) = try LocalSyncFraming.decode(framed) else {
            return XCTFail("expected .command")
        }
        XCTAssertEqual(decoded, original)
    }

    func testEncodeDecodeRoundTripStatus() throws {
        let original = sampleStatus()
        let framed = try LocalSyncFraming.encode(.status(original))
        guard case .status(let decoded) = try LocalSyncFraming.decode(framed) else {
            return XCTFail("expected .status")
        }
        XCTAssertEqual(decoded, original)
    }

    func testEncodedFrameStartsWithKindTagThenCorrectBigEndianLengthPrefix() throws {
        let framed = try LocalSyncFraming.encode(.snapshot(sampleSnapshot()))
        XCTAssertEqual(framed.first, 0x01) // snapshot kind tag
        let prefix = framed.dropFirst().prefix(4)
        var claimedLength: UInt32 = 0
        for byte in prefix { claimedLength = (claimedLength << 8) | UInt32(byte) }
        XCTAssertEqual(Int(claimedLength), framed.count - 5)
    }

    func testCommandAndStatusFramesUseDistinctKindTags() throws {
        let commandFramed = try LocalSyncFraming.encode(.command(sampleCommand()))
        let statusFramed = try LocalSyncFraming.encode(.status(sampleStatus()))
        XCTAssertEqual(commandFramed.first, 0x02)
        XCTAssertEqual(statusFramed.first, 0x03)
    }

    func testDecodeRejectsTruncatedData() {
        // Fewer than 5 bytes total: not even a full kind-tag + length prefix.
        XCTAssertThrowsError(try LocalSyncFraming.decode(Data([1, 2]))) { error in
            guard case LocalSyncFraming.FramingError.malformedLengthPrefix = error else {
                return XCTFail("expected malformedLengthPrefix, got \(error)")
            }
        }
    }

    func testDecodeRejectsLengthPrefixThatOverclaimsAvailableBytes() {
        // Claims a 100-byte payload but supplies none.
        var length = UInt32(100).bigEndian
        var prefix = Data([0x01])
        prefix.append(Data(bytes: &length, count: 4))
        XCTAssertThrowsError(try LocalSyncFraming.decode(prefix)) { error in
            guard case LocalSyncFraming.FramingError.malformedLengthPrefix = error else {
                return XCTFail("expected malformedLengthPrefix, got \(error)")
            }
        }
    }

    func testDecodeRejectsLengthPrefixAboveMaxFrameLength() {
        var length = (LocalSyncFraming.maxFrameLength + 1).bigEndian
        var bogus = Data([0x01])
        bogus.append(Data(bytes: &length, count: 4))
        XCTAssertThrowsError(try LocalSyncFraming.decode(bogus)) { error in
            guard case LocalSyncFraming.FramingError.malformedLengthPrefix(let claimed) = error else {
                return XCTFail("expected malformedLengthPrefix, got \(error)")
            }
            XCTAssertEqual(claimed, LocalSyncFraming.maxFrameLength + 1)
        }
    }

    func testDecodeRejectsUnknownKindTag() {
        let garbage = Data("{}".utf8)
        let framed = LocalSyncFraming.frame(for: garbage, kindByte: 0xFF)
        XCTAssertThrowsError(try LocalSyncFraming.decode(framed)) { error in
            guard case LocalSyncFraming.FramingError.unknownKind(let byte) = error else {
                return XCTFail("expected unknownKind, got \(error)")
            }
            XCTAssertEqual(byte, 0xFF)
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
        let (messages, remainder) = try LocalSyncFraming.extractFrames(from: Data())
        XCTAssertTrue(messages.isEmpty)
        XCTAssertTrue(remainder.isEmpty)
    }

    func testExtractFramesHandlesPartialHeader() throws {
        // Only 2 of the 5 header bytes (1 kind + 4 length) have arrived.
        let partial = Data([0x01, 0])
        let (messages, remainder) = try LocalSyncFraming.extractFrames(from: partial)
        XCTAssertTrue(messages.isEmpty)
        XCTAssertEqual(remainder, partial)
    }

    func testExtractFramesHandlesPartialPayload() throws {
        let full = try LocalSyncFraming.encode(.snapshot(sampleSnapshot()))
        // Simulate a read that only delivered the header plus a few payload
        // bytes, not the whole frame.
        let partial = full.prefix(full.count - 5)
        let (messages, remainder) = try LocalSyncFraming.extractFrames(from: partial)
        XCTAssertTrue(messages.isEmpty)
        XCTAssertEqual(remainder, partial)
    }

    func testExtractFramesReturnsOneCompleteFrameAndEmptyRemainder() throws {
        let framed = try LocalSyncFraming.encode(.snapshot(sampleSnapshot()))
        let (messages, remainder) = try LocalSyncFraming.extractFrames(from: framed)
        XCTAssertEqual(messages.count, 1)
        guard case .snapshot(let snapshot) = messages.first else {
            return XCTFail("expected .snapshot")
        }
        XCTAssertEqual(snapshot.deviceID, "test-device")
        XCTAssertTrue(remainder.isEmpty)
    }

    /// The core "several frames concatenated, plus a trailing partial frame"
    /// case a real streaming socket read regularly produces — e.g. the
    /// sender wrote three snapshots back-to-back before the receiver's next
    /// `receive` call, and the fourth is still mid-flight. Mixed kinds too,
    /// since a real connection interleaves snapshot/command/status frames.
    func testExtractFramesHandlesMultipleCompleteFramesOfMixedKindsPlusTrailingPartial() throws {
        let first = try LocalSyncFraming.encode(.snapshot(sampleSnapshot(deviceID: "device-1", cpuPercent: 10)))
        let second = try LocalSyncFraming.encode(.command(sampleCommand(nonce: "nonce-2")))
        let third = try LocalSyncFraming.encode(.status(sampleStatus(respondsToNonce: "nonce-3")))
        let trailingPartial = third.prefix(6)

        var buffer = Data()
        buffer.append(first)
        buffer.append(second)
        // Only part of the third frame "arrived."
        buffer.append(trailingPartial)

        let (messages, remainder) = try LocalSyncFraming.extractFrames(from: buffer)
        XCTAssertEqual(messages.count, 2)
        guard case .snapshot(let snapshot) = messages[0] else { return XCTFail("expected .snapshot first") }
        XCTAssertEqual(snapshot.deviceID, "device-1")
        guard case .command(let command) = messages[1] else { return XCTFail("expected .command second") }
        XCTAssertEqual(command.nonce, "nonce-2")
        XCTAssertEqual(remainder, trailingPartial)
    }

    /// Feeding the leftover remainder back in on a subsequent "read" (as a
    /// real caller's accumulation loop would) must recover the rest of the
    /// split frame plus anything appended after it — this is the scenario
    /// `extractFrames(from:)`'s doc comment describes as its whole reason
    /// for existing.
    func testExtractFramesAcrossSimulatedMultipleReads() throws {
        let one = try LocalSyncFraming.encode(.snapshot(sampleSnapshot(deviceID: "device-A")))
        let two = try LocalSyncFraming.encode(.status(sampleStatus(respondsToNonce: "nonce-B")))

        let splitPoint = one.count + 3 // land partway into frame two
        var wholeStream = Data()
        wholeStream.append(one)
        wholeStream.append(two)

        let firstReadChunk = wholeStream.prefix(splitPoint)
        let secondReadChunk = wholeStream.suffix(from: splitPoint)

        let (firstBatch, remainderAfterFirstRead) = try LocalSyncFraming.extractFrames(from: firstReadChunk)
        XCTAssertEqual(firstBatch.count, 1)
        guard case .snapshot(let snapshot) = firstBatch.first else { return XCTFail("expected .snapshot") }
        XCTAssertEqual(snapshot.deviceID, "device-A")

        var accumulated = remainderAfterFirstRead
        accumulated.append(secondReadChunk)
        let (secondBatch, remainderAfterSecondRead) = try LocalSyncFraming.extractFrames(from: accumulated)
        XCTAssertEqual(secondBatch.count, 1)
        guard case .status(let status) = secondBatch.first else { return XCTFail("expected .status") }
        XCTAssertEqual(status.respondsToNonce, "nonce-B")
        XCTAssertTrue(remainderAfterSecondRead.isEmpty)
    }

    func testExtractFramesThrowsOnMalformedLengthPrefixMidStream() {
        var bogusLength = (LocalSyncFraming.maxFrameLength + 100).bigEndian
        var bogus = Data([0x01])
        bogus.append(Data(bytes: &bogusLength, count: 4))
        XCTAssertThrowsError(try LocalSyncFraming.extractFrames(from: bogus)) { error in
            guard case LocalSyncFraming.FramingError.malformedLengthPrefix = error else {
                return XCTFail("expected malformedLengthPrefix, got \(error)")
            }
        }
    }

    func testExtractFramesThrowsOnUnknownKindTagMidStream() {
        let payload = Data("{}".utf8)
        let framed = LocalSyncFraming.frame(for: payload, kindByte: 0xFF)
        XCTAssertThrowsError(try LocalSyncFraming.extractFrames(from: framed)) { error in
            guard case LocalSyncFraming.FramingError.unknownKind(let byte) = error else {
                return XCTFail("expected unknownKind, got \(error)")
            }
            XCTAssertEqual(byte, 0xFF)
        }
    }
}
