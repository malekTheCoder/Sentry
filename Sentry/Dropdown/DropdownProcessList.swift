import Foundation
import SentryKit

/// The dropdown's compact "why is CPU busy" list.
///
/// **Why this exists.** A review flagged `SystemVitals.headline(for:)`'s
/// `.cpu` case — "CPU is very busy" — as a verdict with no next step:
/// competitors (iStat Menus, Stats) answer "busy because of what" on the
/// same surface that told you it's busy. This is that answer, surfaced
/// inside the CPU vital's expanded detail rows
/// (`VitalsSection.details(for:)`) rather than as a new card, matching the
/// dropdown's existing progressive-disclosure idiom (`VitalsSection`'s own
/// doc comment) instead of inventing a second one.
///
/// **Reuses `ProcessCollector`/`ProcessStats`, doesn't re-enumerate.** The
/// Dashboard's `ProcessMonitor`/`TopProcessesCard` already do full per-process
/// enumeration for their own top-N-by-CPU card — this type performs no
/// syscalls of its own. `DropdownViewModel` owns a second `ProcessMonitor`
/// instance (see that type's doc comment for why a second instance rather
/// than sharing the Dashboard's), and this is purely the view-facing shaping
/// of whatever that instance last published.
enum DropdownProcessList {
    /// The 3 busiest processes by CPU, descending.
    ///
    /// Deliberately re-sorts and re-caps rather than trusting `processes` to
    /// already be exactly this — `ProcessMonitor.topProcesses` happens to be
    /// pre-sorted and capped to whatever `limit` its owning instance was
    /// constructed with, but that's an implementation detail of a class this
    /// function doesn't own; stating the contract here means the result is
    /// correct even if a future caller hands it an unsorted or
    /// differently-sized array. Pure so the sorting/truncation rule itself is
    /// unit-testable (`SentryTests/DropdownProcessListTests.swift`) without a
    /// running `ProcessMonitor` or a real process table.
    static func topThree(_ processes: [ProcessStats]) -> [ProcessStats] {
        Array(processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(3))
    }
}
