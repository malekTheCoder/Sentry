import Foundation

/// One row of the Dashboard's "Top Processes" card (plan §17 Phase 8:
/// "per-process CPU/GPU/network attribution" — GPU/network per-process
/// attribution has no equivalently cheap public API on Apple Silicon the
/// way `libproc` gives CPU/memory, so this ships CPU + memory only; see
/// `ProcessCollector`'s doc comment).
///
/// Deliberately not part of `HistoryStore`: a process's PID is meaningless
/// across samples once it exits, and cumulative per-process history isn't
/// something this app charts over time the way `MetricID` values are — so
/// there's nothing coherent to persist to `sample_raw`/`sample_daily` or
/// sync to CloudKit.
///
/// **Is** part of `SystemSnapshot` (`SystemSnapshot.topProcesses`), unlike
/// the paragraph above might suggest — that field exists purely so
/// `SentryKit/Services/AlertEngine.swift` can evaluate a live "is process X
/// pegging CPU/memory right now" rule (`AlertRule.processNameMatch`)
/// against the *current* ranked list, the same way it reads every other
/// live metric off a snapshot. It is a transient, current-tick view, not a
/// persisted or synced history — `SystemSnapshot.topProcesses`'s own doc
/// comment covers the honest-nil/no-overwrite-between-ticks semantics that
/// make that distinction concrete.
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
