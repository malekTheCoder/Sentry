import Foundation
import MacStatKit
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
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        topProcesses = collector.collectTopProcesses(limit: limit)
    }
}
