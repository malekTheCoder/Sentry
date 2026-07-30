import Foundation

/// One row of the Dashboard's "Top Processes" card (plan §17 Phase 8:
/// "per-process CPU/GPU/network attribution" — GPU/network per-process
/// attribution has no equivalently cheap public API on Apple Silicon the
/// way `libproc` gives CPU/memory, so this ships CPU + memory only; see
/// `ProcessCollector`'s doc comment).
///
/// Deliberately not part of `SystemSnapshot`/`HistoryStore`: this is a
/// live, Mac-local ranked list recomputed on its own cadence
/// (`ProcessMonitor`), not a scalar metric with a stable identity worth
/// charting over time the way `MetricID` values are — a process's PID is
/// meaningless across samples once it exits, so there's nothing coherent
/// to persist or sync.
public struct ProcessStats: Codable, Sendable, Equatable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var name: String
    /// Percent of one CPU core, `top`-style — a busy multi-threaded process
    /// can exceed 100.
    public var cpuPercent: Double
    public var residentMemoryBytes: UInt64

    public init(pid: Int32, name: String, cpuPercent: Double, residentMemoryBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.residentMemoryBytes = residentMemoryBytes
    }
}
