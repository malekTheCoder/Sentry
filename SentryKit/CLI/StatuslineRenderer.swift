import Foundation

/// Output shapes for `sentryctl statusline` (plan §21.3).
///
/// The names are the CLI's `--format` values verbatim, and — like
/// `MetricID`'s raw values — they are the contract. Someone's `.tmux.conf`
/// or `starship.toml` will contain the string `compact`; renaming a case
/// here silently breaks a dotfile that nothing in this repo can see.
public enum StatuslineFormat: String, CaseIterable, Sendable {
    /// `🔋78% 45W  ⚙️12%  🌡️62°C` — emoji, for a terminal with a normal font.
    case compact
    /// `batt=78% watts=45 charging=1 cpu=12% temp=62` — no glyphs at all, so
    /// it survives a font without emoji coverage and is trivially parseable
    /// by `awk -F'[= ]'` if someone wants to reuse it as data.
    case plain
    /// `compact`, wrapped in tmux `#[fg=…]` style sequences drawn from the
    /// user's active Sentry theme.
    case tmux
    /// `compact`, using Nerd Font glyphs instead of emoji.
    case nerdfont
}

/// Turns a `SystemSnapshot` into the one short line `sentryctl statusline`
/// prints (plan §21.3).
///
/// **Why this is a pure function in `SentryKit` rather than code inside the
/// CLI target.** `SentryCLI` is a `type: tool` target; nothing links it, so
/// nothing can test it. Every formatting decision below — which segments
/// appear, what a missing reading does, how staleness is marked, which
/// theme token colors a hot CPU — is exactly the kind of thing that rots
/// silently, so it lives here where `SentryTests` can pin it down. The CLI
/// side is left with argument parsing, one XPC call, and a `write(2)`.
///
/// **A missing reading is an absent segment, never a zero.** This is the
/// same P5 discipline `SystemSnapshot`'s all-optional sub-structs and
/// `MetricFormatter.unavailable` exist for, and it matters more here than
/// almost anywhere else in the app: a status line is glanced at, not read.
/// A `🌡️0°C` on a Mac whose thermal sensors this build can't reach is not a
/// cosmetic bug — it is a confident, wrong statement about the machine, and
/// it is the single most likely way this feature could mislead someone.
/// Dropping the segment leaves a visibly shorter line, which is honest and
/// which a user notices.
///
/// **Rendering never fails.** There is no `throws` and no optional return:
/// the worst case is an empty string, which the CLI treats as "I have
/// nothing to say" rather than printing a broken line into somebody's shell
/// prompt. See `StatuslineRenderer.render`'s return-value note.
public enum StatuslineRenderer {

    /// How alarming a reading is. Only `tmux` renders this (as color); the
    /// other formats deliberately stay monochrome, because a prompt that
    /// changes width or gains punctuation under load is a prompt that
    /// reflows the user's terminal at the worst possible moment.
    public enum Severity: Sendable, Equatable {
        case nominal
        case warning
        case danger
    }

    // MARK: - Thresholds
    //
    // Deliberately literal constants rather than anything user-configurable.
    // A statusline has no settings UI, and `AppSettings` gaining four fields
    // that exist only to color a tmux segment would be a real maintenance
    // cost for a cosmetic knob. These match the rough bands the dropdown's
    // own coloring uses; if they ever need to agree exactly, that is a
    // shared-constants refactor, not a copy-paste.

    static let cpuWarningPercent: Double = 60
    static let cpuDangerPercent: Double = 85
    static let temperatureWarningCelsius: Double = 80
    static let temperatureDangerCelsius: Double = 95
    static let batteryWarningPercent: Double = 20
    static let batteryDangerPercent: Double = 10

    /// Beyond this, a cached snapshot stops being "the last known reading"
    /// and becomes a number about a machine state that no longer exists.
    ///
    /// `sentryctl statusline` falls back to a cached snapshot when the app
    /// can't answer inside its latency budget (§21.5's Starship
    /// `command_timeout` lesson: a slow prompt is worse than a stale one).
    /// That trade only holds while "stale" means seconds-to-minutes. A CPU
    /// percentage from twenty minutes ago is not a degraded reading, it is a
    /// different question's answer, and the honest output at that point is
    /// nothing at all. Fifteen minutes is chosen to comfortably outlast a
    /// laptop lid-close-and-reopen (where the app is alive but was not
    /// sampling) without outlasting a build.
    public static let maximumUsableStaleness: TimeInterval = 15 * 60

    // MARK: - Rendering

    /// - Parameters:
    ///   - snapshot: the reading to render. May be a live one or one
    ///     recovered from `StatuslineCache`.
    ///   - theme: only consulted by `.tmux`. Pass `Theme.defaultTheme` for
    ///     the other formats; resolving the user's real theme costs a file
    ///     read the other formats have no use for.
    ///   - format: which of §21.3's four shapes to emit.
    ///   - staleBy: how old this snapshot is, if it came from the cache
    ///     rather than from a live call. `nil` means "this is fresh" and
    ///     suppresses the staleness marker entirely — passing `0` would
    ///     render a `⏳0s` that is technically true and visually noisy.
    /// - Returns: one line, without a trailing newline. **Empty** when the
    ///   snapshot carried none of the four segments — the caller must treat
    ///   that as no-data (and say so on stderr) rather than printing a blank
    ///   line and exiting 0, because a blank status line and a working one
    ///   showing nothing look identical to the user.
    public static func render(
        snapshot: SystemSnapshot,
        theme: Theme = .defaultTheme,
        format: StatuslineFormat,
        staleBy: TimeInterval? = nil
    ) -> String {
        let segments = self.segments(from: snapshot, format: format)
        guard !segments.isEmpty else { return "" }

        var rendered: [String]
        switch format {
        case .compact, .nerdfont:
            rendered = segments.map(\.text)
        case .plain:
            rendered = segments.map(\.text)
        case .tmux:
            rendered = segments.map { segment in
                let hex = color(for: segment.severity, metric: segment.metric, theme: theme)
                return "#[fg=\(hex)]\(segment.text)"
            }
        }

        if let staleBy, staleBy > 0 {
            rendered.append(stalenessMarker(staleBy, format: format, theme: theme))
        }

        let joined = rendered.joined(separator: separator(for: format))
        // tmux styles are sticky: without an explicit reset the last
        // segment's foreground bleeds into whatever the user's status line
        // puts after `#()`. `#[default]` restores the status bar's own
        // style rather than guessing at a "normal" color.
        return format == .tmux ? joined + "#[default]" : joined
    }

    private static func separator(for format: StatuslineFormat) -> String {
        switch format {
        // Two spaces between glyph groups, one inside them — matches
        // §21.3's example spacing, which reads as three groups rather than
        // six loose tokens.
        case .compact, .nerdfont, .tmux: return "  "
        case .plain: return " "
        }
    }

    // MARK: - Segments

    /// One renderable piece of the line, kept as a struct rather than a
    /// pre-joined string so `.tmux` can color each piece independently
    /// without re-deriving which metric it came from.
    struct Segment {
        var metric: MetricID
        var text: String
        var severity: Severity
    }

    static func segments(from snapshot: SystemSnapshot, format: StatuslineFormat) -> [Segment] {
        var result: [Segment] = []

        // Battery charge, plus the wattage that goes with it.
        //
        // The wattage is deliberately *two different metrics* depending on
        // which way the energy is flowing: charging input while charging,
        // system draw otherwise. Showing only one of them would leave the
        // segment blank for half of every day, and showing both would double
        // the width of the most-glanced-at part of the line. `plain` names
        // which one it picked (`charging=1|0`) so a script parsing this
        // never has to guess; the glyph formats swap 🔋 for 🔌, which is the
        // same information at a glance.
        if let battery = snapshot.battery {
            let charge = battery.chargePercent
            let glyph = format.batteryGlyph(pluggedIn: battery.isPluggedIn)
            let severity: Severity = {
                if charge <= batteryDangerPercent && !battery.isPluggedIn { return .danger }
                if charge <= batteryWarningPercent && !battery.isPluggedIn { return .warning }
                return .nominal
            }()
            let value = MetricFormatter.compact(charge, unit: .percent)

            switch format {
            case .plain:
                result.append(Segment(metric: .batteryChargePercent, text: "batt=\(value)", severity: severity))
            case .compact, .nerdfont, .tmux:
                result.append(Segment(metric: .batteryChargePercent, text: "\(glyph)\(value)", severity: severity))
            }

            let watts = battery.isCharging ? battery.chargingWatts : battery.systemPowerInWatts
            if let watts, watts.isFinite {
                let metric: MetricID = battery.isCharging ? .batteryChargingWatts : .batterySystemPowerWatts
                let formatted = MetricFormatter.compact(watts, unit: .watts)
                switch format {
                case .plain:
                    result.append(Segment(
                        metric: metric,
                        text: "watts=\(MetricFormatter.compact(watts, unit: .watts, includeUnit: false)) charging=\(battery.isCharging ? 1 : 0)",
                        severity: .nominal
                    ))
                case .compact, .nerdfont, .tmux:
                    result.append(Segment(metric: metric, text: formatted, severity: .nominal))
                }
            }
        }

        if let cpu = snapshot.cpu {
            let percent = cpu.totalPercent
            let severity: Severity = {
                if percent >= cpuDangerPercent { return .danger }
                if percent >= cpuWarningPercent { return .warning }
                return .nominal
            }()
            let value = MetricFormatter.compact(percent, unit: .percent)
            switch format {
            case .plain:
                result.append(Segment(metric: .cpuTotalPercent, text: "cpu=\(value)", severity: severity))
            case .compact, .nerdfont, .tmux:
                result.append(Segment(metric: .cpuTotalPercent, text: "\(format.cpuGlyph)\(value)", severity: severity))
            }
        }

        // Temperature is the segment most likely to be absent: `socTemperatureCelsius`
        // is nil on any Mac where the HID sensor bridge didn't resolve, which
        // is a supported, non-exceptional state (see `ThermalStats`). Note
        // that `thermal != nil` is *not* enough — `pressureLevel` is always
        // populated while the temperature may not be.
        if let celsius = snapshot.thermal?.socTemperatureCelsius, celsius.isFinite {
            let severity: Severity = {
                if celsius >= temperatureDangerCelsius { return .danger }
                if celsius >= temperatureWarningCelsius { return .warning }
                return .nominal
            }()
            switch format {
            case .plain:
                result.append(Segment(
                    metric: .thermalSocTempC,
                    text: "temp=\(MetricFormatter.compact(celsius, unit: .celsius, includeUnit: false))",
                    severity: severity
                ))
            case .compact, .nerdfont, .tmux:
                // §21.3's example spells out "62°C" — the unit letter, not
                // the menu bar's bare "62°". This used to be
                // `MetricFormatter.compact(...) + "C"`, a hand-glued letter
                // that would have kept saying "C" over a Fahrenheit number
                // the moment the display preference existed.
                // `TemperatureFormatter`'s `.whole` style is that same shape
                // with the unit derived from the value instead of assumed.
                let value = TemperatureFormatter.string(celsius: celsius, style: .whole)
                result.append(Segment(metric: .thermalSocTempC, text: "\(format.temperatureGlyph)\(value)", severity: severity))
            }
        }

        return result
    }

    // MARK: - Staleness

    static func stalenessMarker(_ age: TimeInterval, format: StatuslineFormat, theme: Theme) -> String {
        let seconds = Int(age.rounded())
        let short = seconds >= 60 ? "\(seconds / 60)m" : "\(seconds)s"
        switch format {
        case .plain:
            return "stale_s=\(seconds)"
        case .compact:
            return "⏳\(short)"
        case .nerdfont:
            // nf-fa-history — a clock-with-arrow, present in every Nerd Font
            // patch (Font Awesome 4 range), unlike the Material Design
            // codepoints which moved in the v3 remap.
            return "\u{f1da}\(short)"
        case .tmux:
            return "#[fg=\(hex(theme.textTertiary))]⏳\(short)"
        }
    }

    // MARK: - Colors (tmux only)

    /// Resolves a segment to a tmux-acceptable `#rrggbb` string.
    ///
    /// **Severity wins over the per-metric theme color.** A user who set CPU
    /// to a pleasant cyan still wants to see red when the machine is at
    /// 95%; the per-metric palette is for identification, the severity
    /// colors are for alarm. Only `.nominal` falls through to
    /// `Theme.metricColor(for:)`.
    ///
    /// **The dark side of each `ThemeColor` pair is used unconditionally.**
    /// `ThemeColor` carries a light/dark pair because AppKit can ask
    /// `NSApp.effectiveAppearance`; a CLI writing bytes into a pipe has no
    /// appearance to ask, and tmux/Starship do not report the terminal's
    /// background. Assuming dark is the better bet for a terminal by a wide
    /// margin, and it is a documented, single-line-to-change decision rather
    /// than an accident. `opacity` is dropped entirely — there is no alpha
    /// in a terminal SGR color.
    static func color(for severity: Severity, metric: MetricID, theme: Theme) -> String {
        switch severity {
        case .danger: return hex(theme.danger)
        case .warning: return hex(theme.warning)
        case .nominal: return hex(theme.metricColor(for: metric) ?? theme.textPrimary)
        }
    }

    /// tmux accepts `#rrggbb` directly in a style spec. Theme hex strings
    /// are authored with the leading `#` (see `ThemeColor.light`), but that
    /// is a convention rather than something the type validates, so this
    /// normalizes rather than trusting it — a theme file missing the `#`
    /// would otherwise emit `#[fg=0a0d0a]`, which tmux rejects by silently
    /// dropping the whole style and leaving the raw text uncolored.
    static func hex(_ color: ThemeColor) -> String {
        let raw = color.dark.trimmingCharacters(in: .whitespaces)
        return raw.hasPrefix("#") ? raw : "#" + raw
    }
}

// MARK: - Glyphs

private extension StatuslineFormat {

    /// Nerd Font codepoints below are all from the Font Awesome 4 block
    /// (U+F000–U+F2E0), which every Nerd Font patch has carried since the
    /// project started and which survived the v3 remap that moved the
    /// Material Design Icons range. Picking glyphs from the stable block
    /// matters because a missing glyph renders as a tofu box in the user's
    /// prompt, and there is no way for this process to detect that.
    var batteryGlyphFull: String { self == .nerdfont ? "\u{f240}" : "🔋" }
    var batteryGlyphPlugged: String { self == .nerdfont ? "\u{f1e6}" : "🔌" }

    func batteryGlyph(pluggedIn: Bool) -> String {
        pluggedIn ? batteryGlyphPlugged : batteryGlyphFull
    }

    /// nf-fa-microchip. §21.3's example uses ⚙️ for CPU; kept verbatim for
    /// the emoji formats even though a gear is a slightly odd CPU metaphor,
    /// because the plan's example string is what a reader will compare
    /// against and a silent substitution is worse than a mediocre glyph.
    var cpuGlyph: String { self == .nerdfont ? "\u{f2db}" : "⚙️" }

    /// nf-fa-thermometer_full.
    var temperatureGlyph: String { self == .nerdfont ? "\u{f2c7}" : "🌡️" }
}
