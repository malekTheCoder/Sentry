import XCTest
@testable import SystemMetricsKit

/// `SMCFanBridge` is hardware-backed, so these tests are written to pass on
/// *any* Mac — a fanless Air legitimately returns no fans, and asserting a
/// specific count would just encode this development machine into the
/// suite. What is asserted unconditionally: the pure encoding helpers, and
/// the invariants every reading must satisfy when one is produced at all.
final class SMCFanBridgeTests: XCTestCase {

    // MARK: - fourCC encoding (pure)

    func testFourCCEncodesKnownKey() {
        // 'F' 'N' 'u' 'm' big-endian — the exact value the SMC expects for
        // the fan-count key.
        XCTAssertEqual(SMCFanBridge.fourCC("FNum"), 0x464E_756D)
    }

    func testFourCCRejectsWrongLength() {
        XCTAssertNil(SMCFanBridge.fourCC("FN"))
        XCTAssertNil(SMCFanBridge.fourCC("FNumX"))
        XCTAssertNil(SMCFanBridge.fourCC(""))
    }

    func testFourCCRejectsNonASCII() {
        XCTAssertNil(SMCFanBridge.fourCC("F€um"))
    }

    // MARK: - Live readings (invariants only, hardware-agnostic)

    func testFanRPMsAreAlwaysPlausible() {
        // Empty is a fully legitimate result (fanless hardware, denied
        // connection). But anything the bridge *does* report must be a
        // physically plausible RPM — the bridge promises "no data" over
        // fabricated data.
        for rpm in SMCFanBridge.shared.readFanRPMs() {
            XCTAssertGreaterThanOrEqual(rpm, 0)
            XCTAssertLessThanOrEqual(rpm, 20_000)
            XCTAssertTrue(rpm.isFinite)
        }
    }

    func testFanCountAgreesWithReadings() {
        // Readings can only come from fans the SMC says exist. (Fewer is
        // fine — an individual key read may fail — but never more.)
        let rpms = SMCFanBridge.shared.readFanRPMs()
        guard let count = SMCFanBridge.shared.readFanCount() else {
            XCTAssertTrue(rpms.isEmpty, "no fan count must mean no readings")
            return
        }
        XCTAssertLessThanOrEqual(rpms.count, count)
    }
}
