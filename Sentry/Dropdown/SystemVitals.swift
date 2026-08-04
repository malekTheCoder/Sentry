import Foundation
import SentryKit

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

    /// One pre-formatted run with no separate unit — for the modules that
    /// joined the vitals list without a natural 0–100% reading (GPU aside,
    /// which does have one and uses `.percent` above).
    ///
    /// `.percent` splits number and unit because every percent sign is one
    /// glyph at a fixed width, so the split typesets as a tidy column. A
    /// byte-rate string ("1.2 MB/s") or a temperature ("58°") has no such
    /// fixed-width suffix — its unit varies in both text and magnitude with
    /// the number in front of it — so there is nothing clean to split off,
    /// and forcing one would just misalign the column these rows already
    /// don't share with the percent-based ones (the meter is unbounded too,
    /// see `SystemVitals.networkVital`/`thermalVital`/`aneVital`). Kept as
    /// text, not a `Double` + `MetricUnit`, for the same P5 reason `Vital`'s
    /// own doc comment gives: all the nil handling stays in
    /// `MetricFormatting`, which already returns `placeholder` for `nil`.
    static func raw(_ text: String) -> VitalValue {
        VitalValue(number: text, unit: nil)
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
/// number in SentryKit reads it from there — `SystemAdvisor.highCPUPercent`,
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

    /// Bug fix: this used to be four `if`s wired straight to CPU/Memory/Disk/
    /// Battery and nothing else, so a user who turned those four off and GPU/
    /// Network/Thermal *on* in Settings → Modules saw "No modules are turned
    /// on" in the dropdown even though three modules plainly were — and had no
    /// way to reach network throughput or SoC temperature from this surface at
    /// all. The fix is this table: one entry per `MetricModule` the app can
    /// build a row for, each guarded the same way the original four already
    /// were (module enabled *and* the snapshot actually carrying that reading),
    /// so turning a module on or off in Settings has the same visible effect
    /// here for all nine modules, not just the original four.
    ///
    /// `.system` has no entry: unlike every other module it has no snapshot
    /// field of its own (`SystemSnapshot` carries no `SystemStats`) — its
    /// metrics are uptime and process count, both of which already surface
    /// elsewhere in this dropdown (the caption line's uptime, CPU's own
    /// "Processes" detail row). A row that just repeated one of those under a
    /// fifth label would be noise, not a fix for the bug above.
    private static let builders: [(module: MetricModule, build: (SystemSnapshot) -> Vital?)] = [
        (.cpu, { snapshot in snapshot.cpu.map { cpuVital($0, snapshot: snapshot) } }),
        (.memory, { snapshot in
            guard let memory = snapshot.memory, memory.totalBytes > 0 else { return nil }
            return memoryVital(memory)
        }),
        (.disk, { snapshot in
            guard let disk = snapshot.disk, disk.totalBytes > 0 else { return nil }
            return diskVital(disk)
        }),
        // Absent (not placeholdered) on a Mac with no battery: a desktop that
        // shows a permanent "Battery —" row is stating a missing capability as
        // a missing *reading*, which is the same P5 lie as a fabricated zero.
        (.battery, { snapshot in snapshot.battery.map(batteryVital) }),
        (.gpu, { snapshot in snapshot.gpu.map(gpuVital) }),
        (.network, { snapshot in snapshot.network.map(networkVital) }),
        (.thermal, { snapshot in snapshot.thermal.map(thermalVital) }),
        (.ane, { snapshot in snapshot.ane.map(aneVital) })
    ]

    static func vitals(for snapshot: SystemSnapshot?, enabledModules: Set<MetricModule>) -> [Vital] {
        guard let snapshot else { return [] }
        return builders.compactMap { entry in
            guard enabledModules.contains(entry.module) else { return nil }
            return entry.build(snapshot)
        }
    }

    private static func cpuVital(_ cpu: CPUStats, snapshot: SystemSnapshot) -> Vital {
        let percent = cpu.totalPercent
        let level: VitalLevel = percent >= SystemAdvisor.highCPUPercent ? .warning : .normal
        var details: [VitalDetail] = [
            VitalDetail(label: String(localized: "E-cores"), value: MetricFormatting.percent(cpu.ecorePercent, decimals: 1)),
            VitalDetail(label: String(localized: "P-cores"), value: MetricFormatting.percent(cpu.pcorePercent, decimals: 1)),
            VitalDetail(
                label: String(localized: "Frequency"),
                value: MetricFormatting.value(snapshot.value(for: .cpuFrequencyMHz), metric: .cpuFrequencyMHz)
            ),
            VitalDetail(label: String(localized: "Package power"), value: MetricFormatting.watts(cpu.packagePowerWatts))
        ]
        if let load = cpu.loadAverage1m {
            // The value stays a bare number (load averages have no unit and
            // no words), so only the label goes through the catalog.
            details.append(VitalDetail(label: String(localized: "Load average"), value: String(format: "%.2f", load)))
        }
        if let processes = cpu.processCount {
            details.append(VitalDetail(label: String(localized: "Processes"), value: MetricFormatting.integer(processes)))
        }
        return Vital(
            module: .cpu,
            title: String(localized: "CPU"),
            value: .percent(percent),
            fraction: clampFraction(percent / 100),
            level: level,
            levelNote: level == .normal ? nil : String(localized: "Sustained high load"),
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
            note = String(localized: "Pressure critical")
        case .warning:
            level = .warning
            note = String(localized: "Pressure elevated")
        case .normal:
            level = .normal
            note = nil
        case nil:
            if usedPercent >= memoryCriticalUsedPercent {
                level = .critical
                note = String(localized: "Nearly all memory in use")
            } else if usedPercent >= memoryWarningUsedPercent {
                level = .warning
                note = String(localized: "Most memory in use")
            } else {
                level = .normal
                note = nil
            }
        }
        var details: [VitalDetail] = [
            VitalDetail(label: String(localized: "Used"), value: MetricFormatting.bytes(memory.usedBytes)),
            VitalDetail(label: String(localized: "Total"), value: MetricFormatting.bytes(memory.totalBytes)),
            VitalDetail(label: String(localized: "App"), value: MetricFormatting.bytes(memory.appMemoryBytes)),
            VitalDetail(label: String(localized: "Wired"), value: MetricFormatting.bytes(memory.wiredBytes)),
            VitalDetail(label: String(localized: "Compressed"), value: MetricFormatting.bytes(memory.compressedBytes)),
            VitalDetail(label: String(localized: "Cached"), value: MetricFormatting.bytes(memory.cachedBytes)),
            VitalDetail(label: String(localized: "Swap"), value: MetricFormatting.bytes(memory.swapUsedBytes))
        ]
        details.append(VitalDetail(label: String(localized: "Pressure"), value: pressureText(memory.pressureLevel)))
        return Vital(
            module: .memory,
            title: String(localized: "Memory"),
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
            note = String(localized: "Almost out of space")
        } else if freeFraction <= diskWarningFreeFraction {
            level = .warning
            note = String(localized: "Running low on space")
        } else {
            level = .normal
            note = nil
        }
        return Vital(
            module: .disk,
            title: String(localized: "Disk"),
            value: .percent(usedPercent),
            fraction: clampFraction(usedPercent / 100),
            level: level,
            levelNote: note,
            details: [
                VitalDetail(label: String(localized: "Free"), value: MetricFormatting.bytes(disk.freeBytes)),
                VitalDetail(label: String(localized: "Capacity"), value: MetricFormatting.bytes(disk.totalBytes)),
                VitalDetail(label: String(localized: "Read"), value: MetricFormatting.bytesPerSecond(disk.readBytesPerSec)),
                VitalDetail(label: String(localized: "Write"), value: MetricFormatting.bytesPerSecond(disk.writeBytesPerSec)),
                VitalDetail(
                    label: String(localized: "Read IOPS"),
                    value: MetricFormatting.value(disk.readIOPS, metric: .diskReadIOPS)
                ),
                VitalDetail(
                    label: String(localized: "Write IOPS"),
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
            note = String(localized: "Critically low")
        } else if onBattery, charge <= SystemAdvisor.lowBatteryPercent {
            level = .warning
            note = String(localized: "Running low")
        } else {
            level = .normal
            note = nil
        }
        let timeLabel = battery.isCharging
            ? String(localized: "Time to full")
            : String(localized: "Time remaining")
        let timeValue = MetricFormatting.minutesRemaining(
            battery.isCharging ? battery.timeToFullMinutes : battery.timeToEmptyMinutes
        )
        let powerLabel = battery.isCharging
            ? String(localized: "Charging at")
            : String(localized: "Drawing")
        let powerValue = MetricFormatting.watts(
            battery.isCharging ? battery.chargingWatts : battery.systemPowerInWatts
        )
        return Vital(
            module: .battery,
            title: String(localized: "Battery"),
            value: .percent(charge),
            fraction: clampFraction(charge / 100),
            level: level,
            levelNote: note,
            details: [
                VitalDetail(label: String(localized: "State"), value: batteryStateText(battery)),
                VitalDetail(label: timeLabel, value: timeValue),
                VitalDetail(label: powerLabel, value: powerValue),
                VitalDetail(label: String(localized: "Health"), value: MetricFormatting.percent(battery.healthPercent, decimals: 1)),
                VitalDetail(label: String(localized: "Cycles"), value: MetricFormatting.integer(battery.cycleCount)),
                VitalDetail(label: String(localized: "Temperature"), value: MetricFormatting.celsius(battery.temperatureCelsius)),
                VitalDetail(label: String(localized: "Adapter"), value: adapterText(battery))
            ]
        )
    }

    /// GPU utilization is the one addition that keeps the "every vital is a
    /// percentage" convention `Vital.value`'s doc comment describes — unlike
    /// `networkVital`/`thermalVital`/`aneVital` below, it slots into the
    /// existing meter and column exactly the way CPU does.
    ///
    /// **Level is always `.normal`.** Neither `SystemAdvisor` nor
    /// `AlertEngine.defaultRules` defines a "GPU is too busy" threshold
    /// anywhere in the kit — CPU's 90% and the battery/SoC-temp numbers this
    /// file already reuses are the *only* canonical thresholds that exist.
    /// Inventing a GPU number here, just for this row, would let the dropdown
    /// flag something the alert log and `preflight_check` MCP tool both stay
    /// silent about — a worse P5 violation than an unflagged row, since it
    /// reads as a claim ("this is bad") the rest of the app doesn't back up.
    /// The row stays informational until a canonical GPU threshold exists
    /// somewhere the alert engine can also read it from.
    private static func gpuVital(_ gpu: GPUStats) -> Vital {
        Vital(
            module: .gpu,
            title: String(localized: "GPU"),
            value: .percent(gpu.utilizationPercent),
            fraction: gpu.utilizationPercent.flatMap { clampFraction($0 / 100) },
            level: .normal,
            levelNote: nil,
            details: [
                VitalDetail(label: String(localized: "Renderer"), value: MetricFormatting.percent(gpu.rendererPercent, decimals: 1)),
                VitalDetail(label: String(localized: "Tiler"), value: MetricFormatting.percent(gpu.tilerPercent, decimals: 1)),
                VitalDetail(label: String(localized: "VRAM"), value: MetricFormatting.bytes(gpu.vramUsedBytes)),
                VitalDetail(label: String(localized: "Frequency"), value: MetricFormatting.value(gpu.frequencyMHz, unit: .megahertz)),
                VitalDetail(label: String(localized: "Power"), value: MetricFormatting.watts(gpu.powerWatts))
            ]
        )
    }

    /// Throughput is unbounded (a Time Machine backup can peg it at hundreds
    /// of MB/s for minutes without anything being wrong), so unlike the four
    /// original rows this one has no 0...1 quantity to put in the meter —
    /// `fraction: nil` draws the bare track, same as "not measured", which is
    /// an acceptable read here since there genuinely is no ceiling to measure
    /// against. `value` leads with download since that's the number a user
    /// checking "is something hogging my connection" almost always wants
    /// first; upload lives one tap away in the details, same trade the
    /// original disk row already makes for read vs. write.
    ///
    /// **Level is always `.normal`** — same reasoning as `gpuVital`: no
    /// canonical "network is too busy" threshold exists anywhere in the kit,
    /// and a Mac happily saturating a gigabit link is not a problem the way a
    /// CPU pegged at 100% is.
    private static func networkVital(_ network: NetworkStats) -> Vital {
        Vital(
            module: .network,
            title: String(localized: "Network"),
            value: .raw(MetricFormatting.bytesPerSecond(network.rxBytesPerSec)),
            fraction: nil,
            level: .normal,
            levelNote: nil,
            details: [
                VitalDetail(label: String(localized: "Download"), value: MetricFormatting.bytesPerSecond(network.rxBytesPerSec)),
                VitalDetail(label: String(localized: "Upload"), value: MetricFormatting.bytesPerSecond(network.txBytesPerSec)),
                VitalDetail(label: String(localized: "Interface"), value: network.activeInterface ?? MetricFormatting.placeholder),
                VitalDetail(label: String(localized: "Wi-Fi signal"), value: MetricFormatting.value(network.wifiRSSIdBm.map { Double($0) }, unit: .decibelMilliwatts)),
                VitalDetail(label: String(localized: "Link rate"), value: MetricFormatting.value(network.wifiTxRateMbps, unit: .megabitsPerSecond))
            ]
        )
    }

    /// Mirrors the thermal reasoning `status(for:vitals:enabledModules:)`
    /// already applies to the verdict line (throttling, pressure, SoC temp
    /// against `SystemAdvisor.highSoCTempCelsius`) so a flagged Thermal row
    /// and a "Running hot" verdict never disagree about *whether* the Mac is
    /// hot, even though they're computed in two places.
    ///
    /// **Why two places at all, instead of `status` reading this row's
    /// `level`/`levelNote` the way it does for every other vital.** Thermal
    /// is the one module `status` already had a bespoke block for before this
    /// row existed — throttling in particular has no percentage and so can
    /// never be a single `VitalDetail`, only a sentence. Folding thermal into
    /// the generic "every flagged vital contributes a finding" loop as well
    /// would append a *second*, differently-worded finding for the same
    /// condition (e.g. "Thermal pressure is serious" from the bespoke block
    /// and "Thermal: pressure serious" from this row), which the loop's
    /// string-based de-duplication would not catch since the two sentences
    /// don't match verbatim. `status` therefore still excludes `.thermal`
    /// from that loop — see its own comment there.
    private static func thermalVital(_ thermal: ThermalStats) -> Vital {
        let level: VitalLevel
        let note: String?
        if thermal.isThrottling {
            level = .critical
            note = String(localized: "Throttling")
        } else if thermal.pressureLevel == .critical || thermal.pressureLevel == .serious {
            level = .critical
            note = String(localized: "Pressure \(thermal.pressureLevel.displayName.lowercased())")
        } else if let temp = thermal.socTemperatureCelsius, temp > SystemAdvisor.highSoCTempCelsius {
            level = .critical
            note = String(localized: "SoC is at \(MetricFormatting.celsius(temp))")
        } else if thermal.pressureLevel == .fair {
            level = .warning
            note = String(localized: "Pressure elevated")
        } else {
            level = .normal
            note = nil
        }
        return Vital(
            module: .thermal,
            title: String(localized: "Thermals"),
            value: .raw(MetricFormatting.celsius(thermal.socTemperatureCelsius)),
            fraction: nil,
            level: level,
            levelNote: note,
            details: [
                VitalDetail(label: String(localized: "Pressure"), value: thermal.pressureLevel.displayName),
                VitalDetail(label: String(localized: "Throttling"), value: thermal.isThrottling ? String(localized: "Yes") : String(localized: "No")),
                VitalDetail(label: String(localized: "Fans"), value: fanText(thermal.fanRPMs))
            ]
        )
    }

    /// The Neural Engine reports power draw, not a load percentage — there is
    /// no "ANE at 40%" reading anywhere in `ANEStats`, so like network and
    /// thermal this row has no bounded quantity for the meter. `.normal`
    /// always, for the same no-canonical-threshold reason as `gpuVital`.
    private static func aneVital(_ ane: ANEStats) -> Vital {
        Vital(
            module: .ane,
            title: String(localized: "Neural Engine"),
            value: .raw(MetricFormatting.watts(ane.powerWatts)),
            fraction: nil,
            level: .normal,
            levelNote: nil,
            details: [
                VitalDetail(label: String(localized: "Power"), value: MetricFormatting.watts(ane.powerWatts)),
                VitalDetail(label: String(localized: "Active"), value: activeText(ane.isActive))
            ]
        )
    }

    // MARK: Status

    /// The verdict line. Built from findings rather than from `vitals` alone so
    /// throttling — which has no percentage and so can never be a
    /// `VitalDetail` — is still part of the answer, and so the *reason*
    /// survives ("Thermal pressure is serious" rather than a red row the user
    /// has to interpret). Thermal pressure and SoC temp *do* also have a row
    /// now (`thermalVital`), but this block stays the single source of truth
    /// for what thermal contributes to the verdict — see the exclusion note
    /// on the vitals loop below.
    static func status(
        for snapshot: SystemSnapshot?,
        vitals: [Vital],
        enabledModules: Set<MetricModule>
    ) -> SystemStatus {
        guard let snapshot else {
            return SystemStatus(level: .normal, headline: String(localized: "Waiting for the first reading"), reasons: [])
        }

        var findings: [(level: VitalLevel, headline: String, reason: String)] = []

        if enabledModules.contains(.thermal), let thermal = snapshot.thermal {
            if thermal.isThrottling {
                findings.append((.critical, String(localized: "Your Mac is throttling"), String(localized: "Thermal throttling is active")))
            }
            switch thermal.pressureLevel {
            case .critical, .serious:
                findings.append((.critical, String(localized: "Running hot"), String(localized: "Thermal pressure is \(thermal.pressureLevel.displayName.lowercased())")))
            case .fair:
                findings.append((.warning, String(localized: "Warming up"), String(localized: "Thermal pressure is fair")))
            case .nominal:
                break
            }
            if let temp = thermal.socTemperatureCelsius, temp > SystemAdvisor.highSoCTempCelsius {
                findings.append((.critical, String(localized: "Running hot"), String(localized: "SoC is at \(MetricFormatting.celsius(temp))")))
            }
        }

        // Every flagged vital contributes its own note, so the list and the
        // verdict can never disagree about which row is the problem.
        //
        // `.thermal` is excluded here even though `thermalVital` (see
        // `SystemVitals.vitals`) computes a `level`/`levelNote` for its own
        // row: this loop would otherwise append a *second*, differently
        // worded finding for the exact condition the bespoke thermal block
        // above already reported (e.g. "Thermal pressure is serious" here vs.
        // "Thermal: pressure serious" from the loop), and the string-based
        // de-duplication below only catches verbatim repeats. Thermal is the
        // one module whose verdict contribution predates having its own row
        // at all — throttling in particular has no percentage and so was
        // never expressible as a `Vital` — so it keeps its dedicated block
        // instead of also feeding this generic one.
        for vital in vitals where vital.level != .normal && vital.module != .thermal {
            let note = vital.levelNote ?? "\(vital.title) \(vital.value.plain)"
            findings.append((vital.level, headline(for: vital), "\(vital.title): \(note.lowercased())"))
        }

        guard let worstLevel = findings.map(\.level).max() else {
            return SystemStatus(level: .normal, headline: String(localized: "Everything looks normal"), reasons: [])
        }
        // `first(where:)`, not `max(by:)`: with two findings at the same level
        // `max(by:)` returns the *last*, so a throttling Mac that was also low
        // on disk would headline the disk. Appending in priority order (thermal
        // first, then the vitals in list order) and taking the first match makes
        // that tie-break explicit instead of an artifact of the algorithm.
        let headline = findings.first { $0.level == worstLevel }?.headline ?? String(localized: "Everything looks normal")

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
        case .cpu: return String(localized: "CPU is very busy")
        case .memory: return vital.level == .critical
            ? String(localized: "Memory pressure is critical")
            : String(localized: "Memory is under pressure")
        case .disk: return vital.level == .critical
            ? String(localized: "Startup disk is almost full")
            : String(localized: "Startup disk is filling up")
        case .battery: return vital.level == .critical
            ? String(localized: "Battery is critically low")
            : String(localized: "Battery is low")
        default: return String(localized: "\(vital.title) needs attention")
        }
    }

    // MARK: Text helpers

    private static func pressureText(_ level: MemoryPressureLevel?) -> String {
        switch level {
        case .normal: return String(localized: "Normal")
        case .warning: return String(localized: "Warning")
        case .critical: return String(localized: "Critical")
        case nil: return MetricFormatting.placeholder
        }
    }

    private static func batteryStateText(_ battery: BatteryStats) -> String {
        if battery.isCharging { return String(localized: "Charging") }
        if battery.isPluggedIn { return String(localized: "Plugged in, not charging") }
        return String(localized: "On battery")
    }

    private static func adapterText(_ battery: BatteryStats) -> String {
        if let description = battery.adapterDescription, !description.isEmpty {
            if let rated = battery.adapterRatedWatts { return "\(description) · \(rated) W" }
            return description
        }
        if let rated = battery.adapterRatedWatts { return "\(rated) W" }
        return battery.isPluggedIn ? String(localized: "Connected") : MetricFormatting.placeholder
    }

    /// "3200 RPM, 3400 RPM" for however many fans reported in, or the
    /// placeholder for a Mac that reports none (every laptop the app ships
    /// on, and any desktop the HID bridge couldn't read).
    private static func fanText(_ rpms: [Double]) -> String {
        guard !rpms.isEmpty else { return MetricFormatting.placeholder }
        return rpms.map { String(localized: "\(String(Int($0.rounded()))) RPM") }.joined(separator: ", ")
    }

    /// "Yes"/"No" for an optional flag, `placeholder` when the platform
    /// couldn't report it at all — distinguishing "not active" from "unknown"
    /// the same way every other absent reading in this file does (P5).
    private static func activeText(_ isActive: Bool?) -> String {
        guard let isActive else { return MetricFormatting.placeholder }
        return isActive ? String(localized: "Yes") : String(localized: "No")
    }

    /// Guards the meter against a non-finite or out-of-range reading rather
    /// than letting it draw a negative or overflowing bar.
    private static func clampFraction(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }
}

/// Moved here from the now-deleted `Sentry/Dropdown/ModuleCards/
/// ModuleCardStack.swift` (see that commit's dead-code cleanup) — this file
/// was already `thermal.pressureLevel.displayName`'s only consumer inside
/// `status(for:vitals:enabledModules:)` before `thermalVital` added a second
/// one, so the extension belongs next to its callers now rather than in a
/// deleted view file.
extension ThermalStats.PressureLevel {
    var displayName: String {
        switch self {
        case .nominal: return String(localized: "Nominal")
        case .fair: return String(localized: "Fair")
        case .serious: return String(localized: "Serious")
        case .critical: return String(localized: "Critical")
        }
    }
}
