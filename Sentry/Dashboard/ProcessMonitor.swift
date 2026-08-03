import Foundation
import SentryKit
import SystemMetricsKit

/// Owns `ProcessCollector`'s own polling cadence — deliberately separate
/// from `StatsCoordinator`'s tiered loop (see `ProcessCollector`'s doc
/// comment for why: per-process enumeration is pricier than any existing
/// collector and its ranked-list result doesn't fit `SystemSnapshot`'s
/// shape). Only runs while something is actually observing it (the
/// Dashboard window) — `start()`/`stop()` are the Dashboard's job to call
/// on appear/disappear, the same "don't pay for what nobody's looking at"
/// posture `DashboardViewModel.refresh()`'s doc comment already applies to
/// history queries.
@MainActor
public final class ProcessMonitor: ObservableObject {
    @Published public private(set) var topProcesses: [ProcessStats] = []
    /// Live agent/build-tool processes for the Dashboard's orchestration
    /// view, regardless of whether they'd make the top-N cut. Same
    /// enumeration pass as `topProcesses` (see `ProcessCollector.collect`).
    @Published public private(set) var agentProcesses: [ProcessStats] = []

    /// Executable names that count as "agent workload": the agent CLIs
    /// themselves plus the build/runtime tools they spend their lives
    /// driving. Lowercased, matched exactly against `proc_name` output.
    public static let agentProcessNames: Set<String> = [
        "claude", "codex", "gemini", "aider",
        "xcodebuild", "swift-frontend", "swiftc", "sourcekit-lsp",
        "node", "bun", "cargo", "rustc", "ninja", "make",
    ]

    private let collector = ProcessCollector()
    private let interval: TimeInterval
    private let limit: Int
    private var timer: Timer?

    public init(interval: TimeInterval = 5, limit: Int = 8) {
        self.interval = interval
        self.limit = limit
    }

    public func start() {
        guard timer == nil else { return }
        // First pass primes the per-PID CPU-time baselines and necessarily
        // reports 0% for everything; without a fast follow-up the card
        // opens on a column of zeros for a full interval. One extra pass a
        // second later turns the baselines into real percentages.
        refresh()
        Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.timer != nil else { return }
                self.refresh()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let collected = collector.collect(limit: limit, matching: Self.agentProcessNames)
        topProcesses = collected.top
        agentProcesses = collected.matched
    }
}
