import Foundation
import IOKit

/// The only code in this project that can write an SMC key.
///
/// **It lives here, in the daemon target, and nowhere else.** It is a
/// near-copy of `SystemMetricsKit/Bridges/SMCFanBridge.swift`'s protocol
/// layer, and copying it was the deliberate choice over extending that type
/// with a write method or hoisting the shared parts into a framework both
/// binaries link. The reason is a property worth more than the ~90 lines of
/// duplication it costs: **`Sentry.app`'s own binaries contain no code path
/// that can write to the SMC.** `SMCFanBridge` can emit exactly two
/// commands, `READ_KEYINFO` (9) and `READ_BYTES` (5), and that remains true
/// after this change — its doc comment's "read-only by construction" claim
/// is still literally true, which it would not be if a write command had
/// been added there behind a privilege check. An auditor can verify that
/// claim by grepping the app's sources for the write command byte, and the
/// only hit is in a separate 4-file target that runs as a different process
/// with a different lifetime.
///
/// If the two protocol layers ever need to diverge — a new macOS changing
/// the `SMCParamStruct` geometry, say — they must be changed together, and
/// `SMCFanWriterTests`/`SMCFanBridgeTests` both pin the layout constants so
/// a one-sided edit fails.
///
/// **What is unverified here.** Every read path below is the same code
/// `SMCFanBridge` runs on real hardware today. Every *write* path
/// (`WRITE_BYTES`, command 6, against `F{i}Tg` and `F{i}Md`) has **never
/// been executed** — it needs root, and a root daemon needs registration,
/// and registration needs signing identities this machine does not have.
/// The byte layout it builds is the one the spike measured the SMC
/// answering reads on, with the command byte changed and a payload written
/// into the same `bytes` offset the reader decodes from; that is a strong
/// inference and it is not an observation. See `docs/fan-control-spike.md`.
final class SMCFanWriter {

    /// `SMCParamStruct` geometry — identical to `SMCFanBridge.Layout`, and
    /// pinned by tests on both sides so they cannot drift apart silently.
    enum Layout {
        static let structSize = 80
        static let key = 0
        static let keyInfoDataSize = 28
        static let keyInfoDataType = 32
        static let result = 40
        static let data8 = 42
        static let bytes = 48
    }

    enum Command: UInt8 {
        case readBytes = 5
        /// **The one byte that separates this file from every other SMC
        /// caller in the project.** Nothing in `Sentry.app` emits it.
        case writeBytes = 6
        case readKeyInfo = 9
    }

    private static let kernelIndexSMC: UInt32 = 2
    static let maxFans = 8

    /// Matches `FanRPMRange.plausibleCeiling` and `SMCFanBridge
    /// .plausibleRPM`. A value outside it is a decoding error, and a
    /// decoding error must not become a clamp bound in a root process.
    private static let plausibleRPM: ClosedRange<Double> = 0...20_000

    /// 0 when the SMC user client could not be opened. Every operation then
    /// short-circuits to "no data" / "write failed" — never to a guess.
    private let connection: io_connect_t

    init() {
        var conn: io_connect_t = 0
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        if service != 0 {
            let result = IOServiceOpen(service, mach_task_self_, 0, &conn)
            IOObjectRelease(service)
            if result != KERN_SUCCESS {
                conn = 0
            }
        }
        connection = conn
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    var isOpen: Bool { connection != 0 }

    // MARK: - Reads (for the daemon's own clamp bounds)

    /// `FNum`. `nil` on fanless hardware or an unreadable key.
    func readFanCount() -> Int? {
        guard connection != 0 else { return nil }
        guard let bytes = readKey("FNum"), let first = bytes.first else { return nil }
        let count = Int(first)
        return (0...Self.maxFans).contains(count) ? count : nil
    }

    /// The daemon's own read of `F{i}Mn`/`F{i}Mx` — safety requirement 1's
    /// "against the SMC's own limits read at daemon start". A fan whose
    /// min *or* max is missing or implausible is **absent** from the
    /// result, not present with a substituted bound, because a substituted
    /// bound is what a root process would then clamp real writes against.
    func readRanges(fanCount: Int) -> [Int: FanRPMRange] {
        var ranges: [Int: FanRPMRange] = [:]
        for index in 0..<min(fanCount, Self.maxFans) {
            guard let minRPM = plausible(readFloatKey("F\(index)Mn")),
                  let maxRPM = plausible(readFloatKey("F\(index)Mx")) else { continue }
            let range = FanRPMRange(minRPM: minRPM, maxRPM: maxRPM)
            guard range.isUsable else { continue }
            ranges[index] = range
        }
        return ranges
    }

    func readActualRPM(fan index: Int) -> Double? {
        plausible(readFloatKey("F\(index)Ac"))
    }

    private func plausible(_ value: Double?) -> Double? {
        guard let value, Self.plausibleRPM.contains(value) else { return nil }
        return value
    }

    // MARK: - Writes

    /// `F{i}Md` — 1 takes the fan out of firmware control, 0 gives it back.
    ///
    /// A `ui8 ` key (attr `0xd0`, measured in the spike). The daemon writes
    /// only 0 or 1 here; the parameter is a `Bool` rather than a number
    /// precisely so no other value can be expressed at this call site.
    func setForcedMode(_ forced: Bool, fan index: Int) -> Bool {
        writeKey("F\(index)Md", bytes: [forced ? 1 : 0])
    }

    /// `F{i}Tg` — the target RPM, a 4-byte little-endian `flt ` key.
    ///
    /// **This method does not clamp.** That is not an omission: clamping
    /// happens in `FanDaemonClamp.resolve`, one layer up, against ranges
    /// this type read at startup, and putting a second clamp here would
    /// create two places that could disagree about the bound — with the
    /// lower layer's version being the one that silently wins. The single
    /// caller (`FanDaemonService.setTarget`) has no path to this method
    /// that does not go through `resolve` first.
    func setTargetRPM(_ rpm: Double, fan index: Int) -> Bool {
        guard rpm.isFinite else { return false }
        let bits = Float(rpm).bitPattern
        let payload: [UInt8] = [
            UInt8(truncatingIfNeeded: bits),
            UInt8(truncatingIfNeeded: bits >> 8),
            UInt8(truncatingIfNeeded: bits >> 16),
            UInt8(truncatingIfNeeded: bits >> 24)
        ]
        return writeKey("F\(index)Tg", bytes: payload)
    }

    /// One `WRITE_BYTES` round trip.
    ///
    /// The keyinfo round trip first is not ceremony — it is the check that
    /// the key exists *and* that its declared size matches the payload we
    /// are about to send. Writing four bytes into a key the SMC believes is
    /// one byte wide is the sort of mistake that, in a root process talking
    /// to a power controller, does not deserve a second chance.
    @discardableResult
    private func writeKey(_ name: String, bytes payload: [UInt8]) -> Bool {
        guard connection != 0, let keyCode = Self.fourCC(name) else { return false }
        guard (1...32).contains(payload.count) else { return false }

        var infoRequest = [UInt8](repeating: 0, count: Layout.structSize)
        Self.putUInt32(&infoRequest, at: Layout.key, keyCode)
        infoRequest[Layout.data8] = Command.readKeyInfo.rawValue
        guard let infoReply = callSMC(infoRequest) else { return false }

        let declaredSize = Int(Self.getUInt32(infoReply, at: Layout.keyInfoDataSize))
        guard declaredSize == payload.count else { return false }

        var request = [UInt8](repeating: 0, count: Layout.structSize)
        Self.putUInt32(&request, at: Layout.key, keyCode)
        Self.putUInt32(&request, at: Layout.keyInfoDataSize, UInt32(declaredSize))
        Self.putUInt32(
            &request,
            at: Layout.keyInfoDataType,
            Self.getUInt32(infoReply, at: Layout.keyInfoDataType)
        )
        request[Layout.data8] = Command.writeBytes.rawValue
        for (offset, byte) in payload.enumerated() {
            request[Layout.bytes + offset] = byte
        }
        return callSMC(request) != nil
    }

    // MARK: - SMC protocol (mirrors SMCFanBridge)

    private func callSMC(_ input: [UInt8]) -> [UInt8]? {
        guard input.count == Layout.structSize else { return nil }
        var output = [UInt8](repeating: 0, count: Layout.structSize)
        var outputSize = Layout.structSize
        let kr = input.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                IOConnectCallStructMethod(
                    connection,
                    Self.kernelIndexSMC,
                    inPtr.baseAddress,
                    Layout.structSize,
                    outPtr.baseAddress,
                    &outputSize
                )
            }
        }
        guard kr == KERN_SUCCESS,
              outputSize == Layout.structSize,
              output[Layout.result] == 0 else { return nil }
        return output
    }

    private func readKey(_ name: String) -> [UInt8]? {
        guard let keyCode = Self.fourCC(name) else { return nil }

        var infoRequest = [UInt8](repeating: 0, count: Layout.structSize)
        Self.putUInt32(&infoRequest, at: Layout.key, keyCode)
        infoRequest[Layout.data8] = Command.readKeyInfo.rawValue
        guard let infoReply = callSMC(infoRequest) else { return nil }

        let size = Int(Self.getUInt32(infoReply, at: Layout.keyInfoDataSize))
        guard (1...32).contains(size) else { return nil }

        var readRequest = [UInt8](repeating: 0, count: Layout.structSize)
        Self.putUInt32(&readRequest, at: Layout.key, keyCode)
        Self.putUInt32(&readRequest, at: Layout.keyInfoDataSize, UInt32(size))
        readRequest[Layout.data8] = Command.readBytes.rawValue
        guard let readReply = callSMC(readRequest) else { return nil }

        return Array(readReply[Layout.bytes..<(Layout.bytes + size)])
    }

    private func readFloatKey(_ name: String) -> Double? {
        guard let bytes = readKey(name), bytes.count == 4 else { return nil }
        let bits = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        let value = Double(Float(bitPattern: bits))
        return value.isFinite ? value : nil
    }

    // MARK: - Encoding helpers

    static func fourCC(_ name: String) -> UInt32? {
        let scalars = Array(name.unicodeScalars)
        guard scalars.count == 4, scalars.allSatisfy({ $0.isASCII }) else { return nil }
        return scalars.reduce(UInt32(0)) { ($0 << 8) | UInt32($1.value) }
    }

    private static func putUInt32(_ buffer: inout [UInt8], at offset: Int, _ value: UInt32) {
        buffer[offset] = UInt8(truncatingIfNeeded: value)
        buffer[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        buffer[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        buffer[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private static func getUInt32(_ buffer: [UInt8], at offset: Int) -> UInt32 {
        UInt32(buffer[offset])
            | (UInt32(buffer[offset + 1]) << 8)
            | (UInt32(buffer[offset + 2]) << 16)
            | (UInt32(buffer[offset + 3]) << 24)
    }
}
