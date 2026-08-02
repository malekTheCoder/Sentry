import Foundation
import IOKit

/// Read-only bridge to the SMC's fan keys (`FNum`, `F0Ac`, `F1Ac`, …) via
/// the classic `AppleSMC` user client. This is what finally implements the
/// fan-RPM readout `HIDSensorBridge` deliberately refused to guess at: the
/// HID path's field selector for fans is undocumented, but the SMC key
/// protocol — selector 2, the 80-byte `SMCParamStruct` — has been stable
/// for over fifteen years, is exercised by every shipping fan utility
/// (Macs Fan Control, TG Pro, Stats, iStat Menus), and was verified on
/// this project's own hardware matrix (M1 Pro MacBookPro18,3: `FNum` = 2,
/// per-fan `flt` actual/target/min/max keys, all readable unprivileged).
///
/// **Read-only by construction.** The only SMC commands this type can emit
/// are `READ_KEYINFO` (9) and `READ_BYTES` (5). There is no write path
/// here at all — fan *control* (writing `F0Tg`/`F0Md`) requires root and a
/// privileged helper, and belongs to a future, separately-reviewed change.
///
/// **Same honesty rules as every other bridge (§14.4):** every call is
/// checked, nothing is force-unwrapped, iteration is bounded, and any
/// failure — service missing (a fanless MacBook Air has no fan keys),
/// connection refused, malformed reply, implausible value — degrades to
/// "no data", never to a fabricated number. A genuine 0 RPM is *kept*:
/// Apple Silicon spins its fans fully down at idle, and reporting that as
/// "no fans" would be exactly the fabrication this codebase removes.
final class SMCFanBridge {
    static let shared = SMCFanBridge()

    /// `SMCParamStruct` geometry, taken from the C layout (verified with
    /// `offsetof` on this toolchain rather than assumed): total size 80;
    /// key at 0, keyInfo.dataSize at 28, keyInfo.dataType at 32, result at
    /// 40, command byte (`data8`) at 42, payload bytes at 48.
    private enum Layout {
        static let structSize = 80
        static let key = 0
        static let keyInfoDataSize = 28
        static let keyInfoDataType = 32
        static let result = 40
        static let data8 = 42
        static let bytes = 48
    }

    private enum Command: UInt8 {
        case readBytes = 5
        case readKeyInfo = 9
    }

    private static let kernelIndexSMC: UInt32 = 2

    /// More fans than any Mac has ever shipped with; a larger `FNum` is a
    /// misread, not a discovery.
    private static let maxFans = 8

    /// Physically plausible fan speed. 0 is a real reading (fans parked at
    /// idle); anything above this is a misdecoded field.
    private static let plausibleRPM: ClosedRange<Double> = 0...20_000

    /// 0 when the SMC user client couldn't be opened — every read then
    /// short-circuits to "no data". Opened once and kept for the process
    /// lifetime, matching how the other bridges treat their connections:
    /// collectors sample every few seconds and re-opening per sample would
    /// be pure churn.
    private let connection: io_connect_t

    private init() {
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

    // MARK: - Public reads

    /// Actual RPM per fan, in fan order (`F0Ac`, `F1Ac`, …). Empty on any
    /// Mac without readable fan keys — which includes every fanless Air —
    /// and empty rather than partial nonsense on a malformed reply.
    func readFanRPMs() -> [Double] {
        guard connection != 0 else { return [] }
        guard let count = readFanCount(), count > 0 else { return [] }

        var rpms: [Double] = []
        for index in 0..<min(count, Self.maxFans) {
            guard let rpm = readFloatKey("F\(index)Ac"),
                  Self.plausibleRPM.contains(rpm) else { continue }
            rpms.append(rpm)
        }
        return rpms
    }

    /// `FNum` — how many fans the SMC says this Mac has. `nil` when the key
    /// doesn't exist (fanless hardware) or can't be read.
    func readFanCount() -> Int? {
        guard connection != 0 else { return nil }
        guard let bytes = readKey("FNum"), let first = bytes.first else { return nil }
        let count = Int(first)
        return (0...Self.maxFans).contains(count) ? count : nil
    }

    /// One fan's static-ish hardware description: the range the SMC itself
    /// reports (`F{i}Mn` / `F{i}Mx`) plus the current target (`F{i}Tg`).
    ///
    /// Every field is optional and independently so — a Mac that answers
    /// `F0Ac` but not `F0Mx` is a real possibility, and the fan-control
    /// shell is written to show the speed while admitting the range is
    /// unknown rather than substituting a plausible-looking ceiling.
    struct FanHardwareDescription {
        let index: Int
        let minRPM: Double?
        let maxRPM: Double?
        /// `F{i}Tg`. On Apple Silicon at idle this legitimately reads 0.0
        /// alongside a 0.0 actual — the fans are parked, not unreported.
        let targetRPM: Double?
    }

    /// Per-fan limits and targets, in fan order.
    ///
    /// **Still read-only, and deliberately so.** These are exactly the keys
    /// a write path would need (`F{i}Mn`/`F{i}Mx` to clamp against,
    /// `F{i}Tg` to write and to verify by readback), and reading them is
    /// what lets the fan-control settings shell clamp against measured
    /// hardware instead of hardcoded numbers — the spike found fan 0 and
    /// fan 1 of the *same* MacBook Pro topping out 462 rpm apart, so no
    /// constant could be correct. Nothing here writes: this type's only
    /// SMC commands remain `READ_KEYINFO` and `READ_BYTES`, and adding a
    /// write command is a separate, separately-reviewed change requiring a
    /// privileged helper (see this file's header and
    /// `docs/fan-control-spike.md`).
    func readFanHardware() -> [FanHardwareDescription] {
        guard connection != 0 else { return [] }
        guard let count = readFanCount(), count > 0 else { return [] }

        return (0..<min(count, Self.maxFans)).map { index in
            FanHardwareDescription(
                index: index,
                minRPM: plausible(readFloatKey("F\(index)Mn")),
                maxRPM: plausible(readFloatKey("F\(index)Mx")),
                targetRPM: plausible(readFloatKey("F\(index)Tg"))
            )
        }
    }

    /// Same "no data beats bad data" filter `readFanRPMs()` applies, reused
    /// so a misdecoded limit can't quietly become a clamp the whole feature
    /// trusts.
    private func plausible(_ value: Double?) -> Double? {
        guard let value, Self.plausibleRPM.contains(value) else { return nil }
        return value
    }

    // MARK: - SMC protocol

    /// One selector-2 round trip. `nil` unless the kernel call succeeds,
    /// the reply is exactly the expected 80 bytes, and the SMC's own result
    /// byte is 0.
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

    /// Reads a key's raw payload: keyinfo round trip for the size, then the
    /// bytes themselves. `nil` for a missing key or an out-of-range size.
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

    /// Reads a 4-byte `flt ` key (the type every Apple Silicon fan key
    /// uses) as a Double. `nil` if the payload isn't exactly 4 bytes or
    /// decodes to something non-finite.
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

    /// "FNum" -> 0x464E756D. `nil` for anything that isn't exactly four
    /// ASCII characters — a malformed key name is a programming error we'd
    /// rather surface as "no data" than trap on.
    static func fourCC(_ name: String) -> UInt32? {
        let scalars = Array(name.unicodeScalars)
        guard scalars.count == 4, scalars.allSatisfy({ $0.isASCII }) else { return nil }
        return scalars.reduce(UInt32(0)) { ($0 << 8) | UInt32($1.value) }
    }

    private static func putUInt32(_ buffer: inout [UInt8], at offset: Int, _ value: UInt32) {
        // The kernel consumes the struct in host byte order (little-endian
        // on every supported Mac) — these helpers just spell that out.
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
