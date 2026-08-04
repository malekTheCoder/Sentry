import XCTest
@testable import Sentry
@testable import SentryKit

/// Coverage for `DropdownProcessList.topThree(_:)` — the pure sort/truncate
/// rule behind the dropdown's CPU-row "why is it busy" list
/// (`VitalsSection.topProcessRows`). Deliberately feeds it inputs a real
/// `ProcessMonitor` would never hand it (already-sorted, over-sized,
/// under-sized, empty) to prove the function derives its own answer rather
/// than trusting the caller.
final class DropdownProcessListTests: XCTestCase {

    private func process(_ name: String, cpu: Double, pid: Int32 = 1) -> ProcessStats {
        ProcessStats(pid: pid, name: name, cpuPercent: cpu, residentMemoryBytes: 0)
    }

    func testReturnsTopThreeByCPUDescending() {
        let processes = [
            process("a", cpu: 10, pid: 1),
            process("b", cpu: 90, pid: 2),
            process("c", cpu: 50, pid: 3),
            process("d", cpu: 30, pid: 4)
        ]
        let top = DropdownProcessList.topThree(processes)
        XCTAssertEqual(top.map(\.name), ["b", "c", "d"])
        XCTAssertEqual(top.map(\.cpuPercent), [90, 50, 30])
    }

    /// Doesn't trust the input to already be sorted.
    func testSortsEvenWhenInputIsNotAlreadySorted() {
        let processes = [
            process("low", cpu: 1, pid: 1),
            process("high", cpu: 99, pid: 2),
            process("mid", cpu: 40, pid: 3)
        ]
        let top = DropdownProcessList.topThree(processes)
        XCTAssertEqual(top.map(\.name), ["high", "mid", "low"])
    }

    func testFewerThanThreeReturnsAllOfThem() {
        let processes = [process("only", cpu: 5, pid: 1)]
        XCTAssertEqual(DropdownProcessList.topThree(processes).map(\.name), ["only"])
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(DropdownProcessList.topThree([]), [])
    }

    /// Doesn't trust the input to already be capped — a caller that (by
    /// accident, or by sharing a differently-configured `ProcessMonitor` in
    /// the future) hands more than 3 rows still gets exactly 3 back.
    func testMoreThanThreeIsTruncated() {
        let processes = (0..<10).map { process("p\($0)", cpu: Double($0), pid: Int32($0)) }
        XCTAssertEqual(DropdownProcessList.topThree(processes).count, 3)
    }
}
