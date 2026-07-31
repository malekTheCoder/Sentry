import Foundation
import MacStatKit
#if canImport(Darwin)
import Darwin
#endif

/// Top-N processes by CPU, for the Dashboard's "Top Processes" card (plan
/// §17 Phase 8 stretch: "per-process CPU/GPU/network attribution"). CPU and
/// resident memory only — `libproc` (the same public, documented API `top`
/// and Activity Monitor use, `man 3 libproc`) has no per-process GPU or
/// network counters on Apple Silicon; IOReport's per-process breakdown, if
/// it exists at all, isn't part of the reverse-engineered surface this
/// codebase already leans on for system-wide GPU/ANE power (`IOReportBridge`),
/// so this ships the two attributions that are actually available rather
/// than guessing at undocumented ones.
///
/// **Not gated behind `dlopen`/`dlsym`, unlike `HIDSensorBridge`.**
/// `proc_listallpids`/`proc_pidinfo`/`proc_name` are public, documented
/// libproc APIs (`<libproc.h>`) directly callable via `import Darwin` — no
/// private-symbol resolution needed, confirmed by direct compilation. This
/// is the same tier of API `MachHostBridge` already calls unconditionally
/// for `host_processor_info`.
///
/// **Cadence:** deliberately *not* wired into `StatsCoordinator`'s tiered
/// poll loop — enumerating every process on the system (`proc_listallpids`)
/// and calling `proc_pidinfo` per-pid is meaningfully more expensive than
/// any existing collector's per-tick cost, and the result (a ranked list,
/// not a scalar) doesn't fit `SystemSnapshot`'s one-value-per-metric shape
/// or `HistoryStore`'s persistence model anyway (see `ProcessStats`'s doc
/// comment). `ProcessMonitor` owns its own slower timer instead.
public final class ProcessCollector {
    private struct PreviousSample {
        var totalTimeNanos: UInt64
        var timestamp: Date
    }

    // Comfortably above any personal Mac's real process count (typically a
    // few hundred to low thousands); bounds the enumeration the same way
    // `HIDSensorBridge.maxIterations` bounds its own CF iteration, so a
    // pathological process count can't make one collection unbounded.
    private static let maxProcesses = 8192

    private var previous: [pid_t: PreviousSample] = [:]

    public init() {}

    /// Returns the `limit` busiest processes by CPU, sorted descending.
    /// Every call updates the internal previous-sample map used for the
    /// *next* call's delta — like `CPUCollector`, the first call after
    /// launch (or after a process first appears) has no baseline yet and
    /// reports 0% for it rather than a misleadingly large "since process
    /// start" average.
    public func collectTopProcesses(limit: Int = 8, now: Date = Date()) -> [ProcessStats] {
        collect(limit: limit, matching: [], now: now).top
    }

    /// One enumeration, two views of it: the top-N by CPU, plus every
    /// process whose name (lowercased) is in `matching` regardless of rank.
    /// A single pass rather than two calls because the delta baseline
    /// (`previous`) is per-instance state — a second call microseconds later
    /// would see near-zero elapsed time and report nonsense percentages.
    /// This is what feeds the Dashboard's live agent-process view: `claude`
    /// at 0.2% CPU is exactly the row that never makes a top-8 cut.
    public func collect(
        limit: Int = 8,
        matching: Set<String>,
        now: Date = Date()
    ) -> (top: [ProcessStats], matched: [ProcessStats]) {
        var pids = [pid_t](repeating: 0, count: Self.maxProcesses)
        let bytesReturned = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard bytesReturned > 0 else { return (top: [], matched: []) }
        let count = min(Int(bytesReturned), Self.maxProcesses)

        var results: [ProcessStats] = []
        results.reserveCapacity(count)
        var matched: [ProcessStats] = []
        var nextPrevious: [pid_t: PreviousSample] = [:]
        nextPrevious.reserveCapacity(count)

        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0, let info = Self.taskInfo(for: pid) else { continue }
            let totalNanos = info.pti_total_user + info.pti_total_system
            nextPrevious[pid] = PreviousSample(totalTimeNanos: totalNanos, timestamp: now)

            let cpuPercent: Double
            if let prior = previous[pid] {
                cpuPercent = Self.percent(previousNanos: prior.totalTimeNanos, currentNanos: totalNanos, elapsedSeconds: now.timeIntervalSince(prior.timestamp))
            } else {
                cpuPercent = 0
            }

            let stats = ProcessStats(
                pid: pid,
                name: Self.processName(for: pid),
                cpuPercent: cpuPercent,
                residentMemoryBytes: info.pti_resident_size
            )
            results.append(stats)
            if !matching.isEmpty, matching.contains(stats.name.lowercased()) {
                matched.append(stats)
            }
        }

        previous = nextPrevious
        return (
            top: Array(results.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(max(0, limit))),
            matched: matched.sorted { $0.cpuPercent > $1.cpuPercent }
        )
    }

    /// Pure so it's independently unit-testable without real process
    /// enumeration — same reasoning as `DeltaTracker.rate(for:at:)` staying
    /// a small pure calculation separate from the syscalls that feed it.
    /// A negative delta (a PID reused between samples by an unrelated
    /// process with lower cumulative CPU time — possible but rare) or
    /// non-positive elapsed time both report 0% rather than a nonsensical
    /// negative percentage.
    static func percent(previousNanos: UInt64, currentNanos: UInt64, elapsedSeconds: TimeInterval) -> Double {
        guard elapsedSeconds > 0, currentNanos >= previousNanos else { return 0 }
        let deltaSeconds = Double(currentNanos - previousNanos) / 1_000_000_000
        return (deltaSeconds / elapsedSeconds) * 100
    }

    private static func taskInfo(for pid: pid_t) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let written = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, pointer, size)
        }
        guard written == size else { return nil }
        return info
    }

    private static func processName(for pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        let length = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            proc_name(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0 else { return "pid \(pid)" }
        return String(cString: buffer)
    }
}
