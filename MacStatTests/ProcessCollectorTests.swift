import XCTest
@testable import SystemMetricsKit

final class ProcessCollectorTests: XCTestCase {

    func testPercentComputesRatioOfCPUTimeToElapsed() {
        // 0.5s of CPU time over 1s of wall time = 50%.
        let percent = ProcessCollector.percent(previousNanos: 0, currentNanos: 500_000_000, elapsedSeconds: 1)
        XCTAssertEqual(percent, 50, accuracy: 0.0001)
    }

    func testPercentCanExceedOneHundredForMultiThreadedWork() {
        // 2s of CPU time over 1s of wall time = 200% — a busy multi-threaded
        // process, `top`-style, is not clamped to a single core's ceiling.
        let percent = ProcessCollector.percent(previousNanos: 0, currentNanos: 2_000_000_000, elapsedSeconds: 1)
        XCTAssertEqual(percent, 200, accuracy: 0.0001)
    }

    func testPercentIsZeroForNonPositiveElapsedTime() {
        XCTAssertEqual(ProcessCollector.percent(previousNanos: 0, currentNanos: 100, elapsedSeconds: 0), 0)
        XCTAssertEqual(ProcessCollector.percent(previousNanos: 0, currentNanos: 100, elapsedSeconds: -1), 0)
    }

    func testPercentIsZeroWhenCurrentIsLessThanPrevious() {
        // A PID reused between samples by an unrelated process with lower
        // cumulative CPU time — rare, but must not report a negative
        // percentage.
        let percent = ProcessCollector.percent(previousNanos: 1_000_000_000, currentNanos: 500_000_000, elapsedSeconds: 1)
        XCTAssertEqual(percent, 0)
    }

    func testCollectTopProcessesReturnsRealDataOnThisMachine() {
        // Integration-level smoke test — same "run it against the real
        // machine, not a mock" posture `MachHostBridge`/`HIDSensorBridge`
        // are tested with elsewhere in this codebase (or rather, aren't
        // independently unit tested at all — this is a step better).
        let collector = ProcessCollector()
        let first = collector.collectTopProcesses(limit: 5)
        XCTAssertFalse(first.isEmpty, "a real Mac always has at least a handful of processes running")
        XCTAssertLessThanOrEqual(first.count, 5)
        // First call has no delta baseline yet — every result must be 0%,
        // never a misleading "since process start" average.
        XCTAssertTrue(first.allSatisfy { $0.cpuPercent == 0 })
    }
}
