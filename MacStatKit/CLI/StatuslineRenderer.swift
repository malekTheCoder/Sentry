import Foundation

// MARK: - StatuslineRenderer: `macstat statusline`'s one-line formatter

/// The segment vocabulary for `macstat statusline --segments=...`. Raw
/// values are the exact strings users type on the command line, so parsing
/// is `StatuslineSegment(rawValue:)` and the usage text can be generated
/// from `allCases` rather than drifting from a hand-maintained list.
///
/// Deliberately tiny — cpu, mem, battery — because a status line is the one
/// surface in this app where *less* is the feature. The dropdown and the
/// iPhone dashboard exist for everything else; adding disk/network/thermal
/// segments here is cheap if someone asks, but each one added by default
/// costs every tmux user horizontal space they didn't opt into.
public enum StatuslineSegment: String, CaseIterable, Sendable {
    case cpu
    case mem
    case battery
}

/// Renders a `SystemSnapshot` as one compact plain-text line for embedding
/// in tmux `status-right`, a Starship custom module, or a Claude Code
/// status line: `cpu 42% · mem 12.6G · 89%⚡`.
///
/// **Why this is a pure function over `SystemSnapshot` and not part of
/// `MacStatCLI/main.swift`.** Same reasoning as `BatteryGlyph`'s "all of the
/// interesting behaviour here is arithmetic" note: everything worth testing
/// about the status line — which segments render, what an absent reading
/// looks like, where the color thresholds sit — needs no XPC connection and
/// no process. Keeping it in MacStatKit means
/// `MacStatTests/StatuslineRendererTests.swift` exercises the real
/// formatter against constructed snapshots, and `main.swift` stays a thin
/// transport shim (fetch, decode, render, print), which is the shape the
/// whole CLI already has.
///
/// **The honesty rule (P5) applies with full force.** A status line is
/// glanced at hundreds of times a day; a fabricated `0%` there is *more*
/// misleading than in the dropdown, not less, because there's no
/// surrounding context to contradict it. So every absent sub-struct renders
/// as `MetricFormatter.unavailable` ("—"), never a zero: a Mac mini shows
/// `—` for battery, a snapshot taken before the first CPU sample shows
/// `cpu —`. The em-dash is the same glyph every other surface in this app
/// uses for "no reading", so a user who has seen the dropdown already knows
/// what it means.
///
/// **Formatting is delegated to `MetricFormatter` wherever it can be.**
/// Percentages go through `MetricFormatter.compact(_:unit:.percent)` so the
/// status line and the menu bar can never round the same reading two
/// different ways. The one deliberate exception is bytes — see
/// `compactBytes(_:)` below for why `MetricFormatter.compact(_:unit:.bytes)`
/// (which wraps `ByteCountFormatter`) is not usable on this surface.
///
/// **The bolt follows `BatteryGlyph.State.showsBolt`'s rule, not Apple's.**
/// `⚡` is appended for `isCharging` alone, never for merely-plugged-in:
/// macOS routinely holds a battery at 80% or pauses charging when the pack
/// is hot, and a bolt in those states claims the battery is filling when it
/// is not. Plugged-but-not-charging renders as a plain percentage — true,
/// if less flashy — exactly as the menu bar glyph draws it.
public enum StatuslineRenderer {

    /// The inter-segment separator. A middle dot (`·`) rather than `|` or
    /// `,` because it reads as a visual gap without being a shell
    /// metacharacter, and it matches the compact-line idiom Starship and
    /// tmux themes already use.
    public static let separator = " · "

    /// Renders the selected segments in the order the caller listed them —
    /// `--segments=battery,cpu` really does put battery first, because a
    /// user arranging a status line cares about position, not just
    /// membership.
    ///
    /// - Parameter colorized: opt-in ANSI color (`--color`). Off by
    ///   default because the primary consumers (tmux `#()`, Starship
    ///   `custom` modules, Claude Code status lines) each have their own
    ///   styling pipeline, and raw escape bytes leak as `^[[33m` garbage in
    ///   any consumer that doesn't interpret them. When on, color marks
    ///   only *attention* states (see `Tint`) — a healthy line stays
    ///   uncolored rather than glowing green, so color present ==
    ///   something worth a glance.
    public static func render(
        snapshot: SystemSnapshot,
        segments: [StatuslineSegment],
        colorized: Bool = false
    ) -> String {
        segments.map { segment in
            switch segment {
            case .cpu: cpuSegment(snapshot.cpu, colorized: colorized)
            case .mem: memSegment(snapshot.memory, colorized: colorized)
            case .battery: batterySegment(snapshot.battery, colorized: colorized)
            }
        }
        .joined(separator: separator)
    }

    // MARK: - Segments

    /// `cpu 42%`, or `cpu —` when the snapshot carries no CPU sample. The
    /// label stays even when the value is absent so a multi-segment line
    /// keeps its shape — `cpu — · mem 12.6G` is scannable, a bare `— ·
    /// mem 12.6G` is a puzzle.
    private static func cpuSegment(_ cpu: CPUStats?, colorized: Bool) -> String {
        guard let cpu else { return "cpu " + MetricFormatter.unavailable }
        let value = MetricFormatter.compact(cpu.totalPercent, unit: .percent)
        return "cpu " + tinted(value, Tint.forCPU(percent: cpu.totalPercent), colorized: colorized)
    }

    /// `mem 12.6G`, or `mem —`. Color keys off `MemoryStats.pressureLevel`
    /// rather than a used-bytes threshold, because used-vs-total is the
    /// wrong signal on macOS — the kernel deliberately keeps memory "full"
    /// of cache, and the OS's own pressure level is the number that actually
    /// predicts trouble. No pressure reading, no color: an inferred
    /// threshold would be exactly the kind of fabricated signal P5 forbids.
    private static func memSegment(_ memory: MemoryStats?, colorized: Bool) -> String {
        guard let memory else { return "mem " + MetricFormatter.unavailable }
        let value = compactBytes(memory.usedBytes)
        return "mem " + tinted(value, Tint.forMemory(pressure: memory.pressureLevel), colorized: colorized)
    }

    /// `89%⚡` / `54%` / `—`. Deliberately unlabeled — the `%` plus optional
    /// bolt is self-identifying, and it's the segment users most want at
    /// the far edge of a status line where every character counts. The
    /// unavailable case is a bare `—` (no orphaned label, no glyph): on a
    /// desktop Mac that's the honest whole answer, and it's still
    /// distinguishable from a reading because a real battery segment always
    /// carries `%`.
    private static func batterySegment(_ battery: BatteryStats?, colorized: Bool) -> String {
        guard let battery else { return MetricFormatter.unavailable }
        let percent = MetricFormatter.compact(battery.chargePercent, unit: .percent)
        // Bolt only while current actually flows in — see the type-level
        // doc comment and `BatteryGlyph.State.showsBolt`.
        let value = percent + (battery.isCharging ? "⚡" : "")
        return tinted(value, Tint.forBattery(percent: battery.chargePercent, isCharging: battery.isCharging), colorized: colorized)
    }

    // MARK: - Byte formatting

    /// `13_529_146_982` → `"12.6G"`. Binary (1024-based) scaling with a
    /// single-letter unit and no space.
    ///
    /// **Why not `MetricFormatter.compact(_:unit:.bytes)`.** That path wraps
    /// `ByteCountFormatter`, which is the right tool for UI — and the wrong
    /// one here, for two reasons this surface can't tolerate:
    ///
    /// 1. **Locale sensitivity.** `ByteCountFormatter` localizes both the
    ///    decimal separator and the unit ("12,6 Go" on a French system). A
    ///    status line is quasi-machine-readable — it gets embedded in tmux
    ///    format strings and parsed by prompt frameworks — so its shape must
    ///    be byte-identical across machines. This formatter is
    ///    locale-independent by construction (`String(format:)` with C
    ///    locale semantics via explicit formatting).
    /// 2. **Width.** `"12.6 GB"` is seven characters where `"12.6G"` is
    ///    five; across three segments the spaces and second unit letters add
    ///    up on a surface whose entire budget is one prompt line.
    ///
    /// The 1024 base matches `ByteCountFormatter.CountStyle.memory`, which
    /// is what the dropdown and menu bar use for these same fields — so
    /// while the *spelling* differs ("12.6G" vs "12.6 GB"), the *number*
    /// never does, which is the part of "never render the same reading two
    /// ways" that actually protects users.
    ///
    /// Precision policy mirrors `MetricFormatter.compact`'s watts rule (one
    /// decimal below the threshold where it stops being informative): one
    /// decimal for G/T under 100, none at or above, none ever for M/K —
    /// nobody tunes anything to a tenth of a megabyte.
    public static func compactBytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        let kib = 1024.0
        let mib = kib * 1024
        let gib = mib * 1024
        let tib = gib * 1024
        func scaled(_ divisor: Double, _ suffix: String, decimals: Bool) -> String {
            let scaled = value / divisor
            let wantsDecimal = decimals && scaled < 100
            return String(format: wantsDecimal ? "%.1f%@" : "%.0f%@", scaled, suffix)
        }
        switch value {
        case tib...: return scaled(tib, "T", decimals: true)
        case gib...: return scaled(gib, "G", decimals: true)
        case mib...: return scaled(mib, "M", decimals: false)
        case kib...: return scaled(kib, "K", decimals: false)
        default: return String(format: "%.0fB", value)
        }
    }

    // MARK: - Color

    /// The three-state attention scale `--color` maps onto ANSI. `none` is
    /// deliberately the healthy state — see `render`'s doc comment: color
    /// on this surface means "look", so the absence of color is itself
    /// information and a permanently-green segment would destroy that.
    enum Tint {
        case none
        /// ANSI yellow (33): worth a glance, not an interruption.
        case caution
        /// ANSI red (31): the reading itself is the interruption.
        case alarm

        /// CPU thresholds sit at 60/85 — below 60 a laptop is just
        /// working; 85+ sustained is where fans, throttling, and "why is
        /// my build slow" live. These are display thresholds only (what
        /// deserves color in a prompt), deliberately independent of
        /// `AlertEngine`'s user-configurable rules: a status line tint is
        /// not an alert and must not silently re-use alert semantics.
        static func forCPU(percent: Double) -> Tint {
            guard percent.isFinite else { return .none }
            if percent >= 85 { return .alarm }
            if percent >= 60 { return .caution }
            return .none
        }

        /// Memory color comes from the kernel's own pressure verdict — the
        /// only signal that isn't a guess (see `memSegment`). `nil`
        /// pressure yields no color, not "assume normal": unknown is
        /// unknown.
        static func forMemory(pressure: MemoryPressureLevel?) -> Tint {
            switch pressure {
            case .critical: .alarm
            case .warning: .caution
            case .normal, nil: .none
            }
        }

        /// Battery: 10/20 percent, muted while charging — a battery at 8%
        /// *and filling* is a resolving situation, not an emergency, so it
        /// downgrades red to yellow rather than crying wolf while the bolt
        /// is showing.
        static func forBattery(percent: Double, isCharging: Bool) -> Tint {
            guard percent.isFinite else { return .none }
            if percent <= 10 { return isCharging ? .caution : .alarm }
            if percent <= 20 { return .caution }
            return .none
        }
    }

    /// Wraps `value` in the tint's ANSI SGR pair, or returns it untouched
    /// when color is off or the tint is `.none` — the escape bytes must not
    /// exist at all in the default output, not merely render invisibly.
    private static func tinted(_ value: String, _ tint: Tint, colorized: Bool) -> String {
        guard colorized else { return value }
        let code: String
        switch tint {
        case .none: return value
        case .caution: code = "33"
        case .alarm: code = "31"
        }
        return "\u{1B}[\(code)m\(value)\u{1B}[0m"
    }
}
