import Foundation
import MacStatKit

// MARK: - Severity

/// How much attention a reading deserves.
///
/// This is the *only* thing in the redesigned dropdown allowed to introduce
/// color. The previous layout gave each of six modules its own hue from
/// `Theme.metricColors`, which meant a perfectly healthy Mac lit up in six
/// colors and a genuinely overheating one lit up in… six colors. Here the
/// text ramp carries hierarchy and `warning`/`danger` are spent only on a
/// reading that has actually crossed a threshold, so color means "look at
/// this" and nothing else.
///
/// `Comparable` so a screenful of readings collapses to `vitals.map(\.level).max()`
/// — the dropdown's overall verdict is by definition its worst reading.
enum VitalLevel: Int, Comparable, Sendable {
    case normal = 0
    case warning = 1
    case critical = 2

    static func < (lhs: VitalLevel, rhs: VitalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// SF Symbol paired with the color everywhere a level is rendered, so
    /// severity survives color-blindness, a monochrome theme, and a screenshot
    /// (plan §9.4 — never meaning in color alone).
    ///
    /// Outline glyphs, not `.fill` ones, and two different *shapes* rather than
    /// two shades of the same one: at 9pt a filled triangle is a solid blob
    /// that competes with the number beside it, while triangle-vs-octagon is
    /// legible as a difference even without color. `nil` at `.normal` — an
    /// icon that is always present carries no information.
    var symbolName: String? {
        switch self {
        case .normal: return nil
        case .warning: return "exclamationmark.triangle"
        case .critical: return "exclamationmark.octagon"
        }
    }

    /// Spoken by VoiceOver after the value, for the same reason.
    var accessibilityDescription: String {
        switch self {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }
}

// MARK: - One row of the glance

/// A label/value pair revealed when a vital row is expanded. Values arrive
/// pre-formatted so all the nil handling stays in `MetricFormatting` and a
/// missing reading can never render as a fabricated zero (P5).
struct VitalDetail: Identifiable, Equatable, Sendable {
    let label: String
    let value: String

    var id: String { label }
}

/// A headline reading as the view needs to typeset it: digits, then an
/// optional unit run rendered smaller and quieter.
struct VitalValue: Equatable, Sendable {
    let number: String
    /// nil when there is nothing to read — the placeholder em dash is a
    /// complete statement and takes no unit.
    let unit: String?

    /// What VoiceOver and the status line read, and the fallback wherever the
    /// two-run treatment doesn't apply.
    var plain: String { number + (unit ?? "") }

    /// Percentages are the only unit the vitals column uses; `includeUnit:
    /// false` gets the bare figure from the same formatter the menu bar uses,
    /// so the digits can never disagree between the two surfaces.
    static func percent(_ value: Double?) -> VitalValue {
        guard let value, value.isFinite else {
            return VitalValue(number: MetricFormatting.placeholder, unit: nil)
        }
        return VitalValue(
            number: MetricFormatter.compact(value, unit: .percent, includeUnit: false),
            unit: "%"
        )
    }
}

/// One line of the dropdown's "is my Mac OK" list.
///
/// Deliberately flat and pre-formatted: the view layer decides *how* a level
/// looks, this decides *what* the reading is. That split is what lets the
/// thresholds below be reasoned about (and, if the "only work in Dropdown/"
/// constraint is ever lifted, unit-tested) without standing up a SwiftUI
/// hierarchy.
struct Vital: Identifiable, Equatable, Sendable {
    /// Drives both the Settings "Modules" filter and the accessibility label.
    let module: MetricModule
    let title: String
    /// The headline readout, split into its digits and its unit.
    ///
    /// Every vital reports a percentage on purpose — four values in the same
    /// unit form a single right-aligned column the eye can scan in one pass,
    /// which a mix of "12%", "412 GB" and "3.4 MB/s" cannot. The absolute
    /// figures live in `details`, one click away.
    ///
    /// Split because the view sets the unit as a smaller, quieter run tight
    /// against the number: `ByteCountFormatter`-style "6.69 GB" strings put a
    /// full space between the two and give the unit the same weight as the
    /// figure, which makes a column of them look ragged. Kept as text, not a
    /// `Double` plus a `MetricUnit`, so all the nil handling stays in
    /// `MetricFormatting` (P5).
    let value: VitalValue
    /// 0...1 for the meter, or nil when the module reported nothing — a nil
    /// draws an empty track rather than a zero-width fill, because "no data"
    /// and "0%" are different statements.
    let fraction: Double?
    let level: VitalLevel
    /// Why this row is flagged, in the user's words ("Pressure critical").
    /// nil at `.normal`, because a normal reading needs no explanation.
    let levelNote: String?
    let details: [VitalDetail]

    var id: String { module.rawValue }
}

// MARK: - The verdict

/// The single line at the top of the dropdown that answers "is my Mac OK?".
///
/// Separate from the vitals list because the answer isn't always *in* the
/// list: thermal pressure and throttling are the most common reasons a Mac
/// is unwell, and neither is a percentage that belongs in a column of four
/// meters. Rolling them into one sentence here is what lets the list stay
/// four calm rows.
struct SystemStatus: Equatable, Sendable {
    let level: VitalLevel
    /// One short sentence, e.g. "Everything looks normal" / "Running hot".
    let headline: String
    /// Supporting specifics, at most a couple of clauses. Empty at `.normal`.
    let reasons: [String]

    var symbolName: String {
        level.symbolName ?? "checkmark.circle"
    }
}

// MARK: - Derivation

/// Turns a `SystemSnapshot` into the four vitals and the one-line verdict.
///
/// **Where the thresholds come from.** Everything that already has a canonical
/// number in MacStatKit reads it from there — `SystemAdvisor.highCPUPercent`,
/// `.lowBatteryPercent`, `.highSoCTempCelsius` are the same constants
/// `AlertEngine.defaultRules` and the `preflight_check` MCP tool use, so the
/// dropdown can't quietly disagree with the alert that fires two seconds later.
/// Only the two the kit has no opinion on — disk headroom and the memory
/// fallback — are stated here, with their reasoning.
enum SystemVitals {

    /// Below this fraction of the startup disk free, macOS itself starts
    /// misbehaving (Time Machine snapshots stop thinning, Xcode and Photos
    /// refuse to write). 10% is the "start deleting things" mark, 5% the
    /// "something is about to fail" mark.
    static let diskWarningFreeFraction: Double = 0.10
    static let diskCriticalFreeFraction: Double = 0.05

    /// Used only when `MemoryStats.pressureLevel` is nil. The kernel's own
    /// pressure level is a far better signal than used/total (a Mac at 95%
    /// used with everything cached and no swap is perfectly happy), so these
    /// are a deliberately late-firing fallback rather than the primary rule.
    static let memoryWarningUsedPercent: Double = 90
    static let memoryCriticalUsedPercent: Double = 97

    /// Battery is only "low" when the Mac is actually running on it — 8% while
    /// plugged in and charging is a normal state, not a problem.
    static let batteryCriticalPercent: Double = 10

    // MARK: Vitals

    static func vitals(for snapshot: SystemSnapshot?, enabledModules: Set<MetricModule>) -> [Vital] {
        guard let snapshot else { return [] }
        var result: [Vital] = []
        if enabledModules.contains(.cpu), let cpu = snapshot.cpu {
            result.append(cpuVital(cpu, snapshot: snapshot))
        }
        if enabledModules.contains(.memory), let memory = snapshot.memory, memory.totalBytes > 0 {
            result.append(memoryVital(memory))
        }
        if enabledModules.contains(.disk), let disk = snapshot.disk, disk.totalBytes > 0 {
            result.append(diskVital(disk))
        }
        // Absent (not placeholdered) on a Mac with no battery: a desktop that
        // shows a permanent "Battery —" row is stating a missing capability as
        // a missing *reading*, which is the same P5 lie as a fabricated zero.
        if enabledModules.contains(.battery), let battery = snapshot.battery {
            result.append(batteryVital(battery))
        }
        return result
    }

    private static func cpuVital(_ cpu: CPUStats, snapshot: SystemSnapshot) -> Vital {
        let percent = cpu.totalPercent
        let level: VitalLevel = percent >= SystemAdvisor.highCPUPercent ? .warning : .normal
        var details: [VitalDetail] = [
            VitalDetail(label: "E-cores", value: MetricFormatting.percent(cpu.ecorePercent, decimals: 1)),
            VitalDetail(label: "P-cores", value: MetricFormatting.percent(cpu.pcorePercent, decimals: 1)),
            VitalDetail(
                label: "Frequency",
                value: MetricFormatting.value(snapshot.value(for: .cpuFrequencyMHz), metric: .cpuFrequencyMHz)
            ),
            VitalDetail(label: "Package power", value: MetricFormatting.watts(cpu.packagePowerWatts))
        ]
        if let load = cpu.loadAverage1m {
            details.append(VitalDetail(label: "Load average", value: String(format: "%.2f", load)))
        }
        if let processes = cpu.processCount {
            details.append(VitalDetail(label: "Processes", value: MetricFormatting.integer(processes)))
        }
        return Vital(
            module: .cpu,
            title: "CPU",
            value: .percent(percent),
            fraction: clampFraction(percent / 100),
            level: level,
            levelNote: level == .normal ? nil : "Sustained high load",
            details: details
        )
    }

    private static func memoryVital(_ memory: MemoryStats) -> Vital {
        let usedPercent = Double(memory.usedBytes) / Double(memory.totalBytes) * 100
        let level: VitalLevel
        let note: String?
        switch memory.pressureLevel {
        case .critical:
            level = .critical
            note = "Pressure critical"
        case .warning:
            level = .warning
            note = "Pressure elevated"
        case .normal:
            level = .normal
            note = nil
        case nil:
            if usedPercent >= memoryCriticalUsedPercent {
                level = .critical
                note = "Nearly all memory in use"
            } else if usedPercent >= memoryWarningUsedPercent {
                level = .warning
                note = "Most memory in use"
            } else {
                level = .normal
                note = nil
            }
        }
        var details: [VitalDetail] = [
            VitalDetail(label: "Used", value: MetricFormatting.bytes(memory.usedBytes)),
            VitalDetail(label: "Total", value: MetricFormatting.bytes(memory.totalBytes)),
            VitalDetail(label: "App", value: MetricFormatting.bytes(memory.appMemoryBytes)),
            VitalDetail(label: "Wired", value: MetricFormatting.bytes(memory.wiredBytes)),
            VitalDetail(label: "Compressed", value: MetricFormatting.bytes(memory.compressedBytes)),
            VitalDetail(label: "Cached", value: MetricFormatting.bytes(memory.cachedBytes)),
            VitalDetail(label: "Swap", value: MetricFormatting.bytes(memory.swapUsedBytes))
        ]
        details.append(VitalDetail(label: "Pressure", value: pressureText(memory.pressureLevel)))
        return Vital(
            module: .memory,
            title: "Memory",
            value: .percent(usedPercent),
            fraction: clampFraction(usedPercent / 100),
            level: level,
            levelNote: note,
            details: details
        )
    }

    private static func diskVital(_ disk: DiskStats) -> Vital {
        let total = Double(disk.totalBytes)
        let free = Double(disk.freeBytes)
        let freeFraction = free / total
        let usedPercent = (1 - freeFraction) * 100
        let level: VitalLevel
        let note: String?
        if freeFraction <= diskCriticalFreeFraction {
            level = .critical
            note = "Almost out of space"
        } else if freeFraction <= diskWarningFreeFraction {
            level = .warning
            note = "Running low on space"
        } else {
            level = .normal
            note = nil
        }
        return Vital(
            module: .disk,
            title: "Disk",
            value: .percent(usedPercent),
            fraction: clampFraction(usedPercent / 100),
            level: level,
            levelNote: note,
            details: [
                VitalDetail(label: "Free", value: MetricFormatting.bytes(disk.freeBytes)),
                VitalDetail(label: "Capacity", value: MetricFormatting.bytes(disk.totalBytes)),
                VitalDetail(label: "Read", value: MetricFormatting.bytesPerSecond(disk.readBytesPerSec)),
                VitalDetail(label: "Write", value: MetricFormatting.bytesPerSecond(disk.writeBytesPerSec)),
                VitalDetail(
                    label: "Read IOPS",
                    value: MetricFormatting.value(disk.readIOPS, metric: .diskReadIOPS)
                ),
                VitalDetail(
                    label: "Write IOPS",
                    value: MetricFormatting.value(disk.writeIOPS, metric: .diskWriteIOPS)
                )
            ]
        )
    }

    private static func batteryVital(_ battery: BatteryStats) -> Vital {
        let charge = battery.chargePercent
        let onBattery = !battery.isPluggedIn
        let level: VitalLevel
        let note: String?
        if onBattery, charge <= batteryCriticalPercent {
            level = .critical
            note = "Critically low"
        } else if onBattery, charge <= SystemAdvisor.lowBatteryPercent {
            level = .warning
            note = "Running low"
        } else {
            level = .normal
            note = nil
        }
        let timeLabel = battery.isCharging ? "Time to full" : "Time remaining"
        let timeValue = MetricFormatting.minutesRemaining(
            battery.isCharging ? battery.timeToFullMinutes : battery.timeToEmptyMinutes
        )
        let powerLabel = battery.isCharging ? "Charging at" : "Drawing"
        let powerValue = MetricFormatting.watts(
            battery.isCharging ? battery.chargingWatts : battery.systemPowerInWatts
        )
        return Vital(
            module: .battery,
            title: "Battery",
            value: .percent(charge),
            fraction: clampFraction(charge / 100),
            level: level,
            levelNote: note,
            details: [
                VitalDetail(label: "State", value: batteryStateText(battery)),
                VitalDetail(label: timeLabel, value: timeValue),
                VitalDetail(label: powerLabel, value: powerValue),
                VitalDetail(label: "Health", value: MetricFormatting.percent(battery.healthPercent, decimals: 1)),
                VitalDetail(label: "Cycles", value: MetricFormatting.integer(battery.cycleCount)),
                VitalDetail(label: "Temperature", value: MetricFormatting.celsius(battery.temperatureCelsius)),
                VitalDetail(label: "Adapter", value: adapterText(battery))
            ]
        )
    }

    // MARK: Status

    /// The verdict line. Built from findings rather than from `vitals` alone so
    /// thermal state — which has no percentage and therefore no row — is still
    /// part of the answer, and so the *reason* survives ("Thermal pressure is
    /// serious" rather than a red row the user has to interpret).
    static func status(
        for snapshot: SystemSnapshot?,
        vitals: [Vital],
        enabledModules: Set<MetricModule>
    ) -> SystemStatus {
        guard let snapshot else {
            return SystemStatus(level: .normal, headline: "Waiting for the first reading", reasons: [])
        }

        var findings: [(level: VitalLevel, headline: String, reason: String)] = []

        if enabledModules.contains(.thermal), let thermal = snapshot.thermal {
            if thermal.isThrottling {
                findings.append((.critical, "Your Mac is throttling", "Thermal throttling is active"))
            }
            switch thermal.pressureLevel {
            case .critical, .serious:
                findings.append((.critical, "Running hot", "Thermal pressure is \(thermal.pressureLevel.displayName.lowercased())"))
            case .fair:
                findings.append((.warning, "Warming up", "Thermal pressure is fair"))
            case .nominal:
                break
            }
            if let temp = thermal.socTemperatureCelsius, temp > SystemAdvisor.highSoCTempCelsius {
                findings.append((.critical, "Running hot", "SoC is at \(MetricFormatting.celsius(temp))"))
            }
        }

        // Every flagged vital contributes its own note, so the list and the
        // verdict can never disagree about which row is the problem.
        for vital in vitals where vital.level != .normal {
            let note = vital.levelNote ?? "\(vital.title) \(vital.value.plain)"
            findings.append((vital.level, headline(for: vital), "\(vital.title): \(note.lowercased())"))
        }

        guard let worstLevel = findings.map(\.level).max() else {
            return SystemStatus(level: .normal, headline: "Everything looks normal", reasons: [])
        }
        // `first(where:)`, not `max(by:)`: with two findings at the same level
        // `max(by:)` returns the *last*, so a throttling Mac that was also low
        // on disk would headline the disk. Appending in priority order (thermal
        // first, then the vitals in list order) and taking the first match makes
        // that tie-break explicit instead of an artifact of the algorithm.
        let headline = findings.first { $0.level == worstLevel }?.headline ?? "Everything looks normal"

        // Sorted by severity but *stably* — `sorted(by:)` is not guaranteed
        // stable, and reasons that reshuffle between two identical snapshots
        // would flicker under the 1 Hz-ish refresh. Deduplicated because two
        // thermal rules ("serious pressure" and "SoC above 95°C") routinely
        // fire together and would otherwise say the same thing twice.
        var seen = Set<String>()
        let reasons = findings.enumerated()
            .sorted { lhs, rhs in
                lhs.element.level == rhs.element.level
                    ? lhs.offset < rhs.offset
                    : lhs.element.level > rhs.element.level
            }
            .map(\.element.reason)
            .filter { seen.insert($0).inserted }
        return SystemStatus(level: worstLevel, headline: headline, reasons: reasons)
    }

    private static func headline(for vital: Vital) -> String {
        switch vital.module {
        case .cpu: return "CPU is very busy"
        case .memory: return vital.level == .critical ? "Memory pressure is critical" : "Memory is under pressure"
        case .disk: return vital.level == .critical ? "Startup disk is almost full" : "Startup disk is filling up"
        case .battery: return vital.level == .critical ? "Battery is critically low" : "Battery is low"
        default: return "\(vital.title) needs attention"
        }
    }

    // MARK: Text helpers

    private static func pressureText(_ level: MemoryPressureLevel?) -> String {
        switch level {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        case nil: return MetricFormatting.placeholder
        }
    }

    private static func batteryStateText(_ battery: BatteryStats) -> String {
        if battery.isCharging { return "Charging" }
        if battery.isPluggedIn { return "Plugged in, not charging" }
        return "On battery"
    }

    private static func adapterText(_ battery: BatteryStats) -> String {
        if let description = battery.adapterDescription, !description.isEmpty {
            if let rated = battery.adapterRatedWatts { return "\(description) · \(rated) W" }
            return description
        }
        if let rated = battery.adapterRatedWatts { return "\(rated) W" }
        return battery.isPluggedIn ? "Connected" : MetricFormatting.placeholder
    }

    /// Guards the meter against a non-finite or out-of-range reading rather
    /// than letting it draw a negative or overflowing bar.
    private static func clampFraction(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }
}
