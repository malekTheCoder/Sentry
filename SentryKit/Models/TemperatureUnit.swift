import Foundation

// MARK: - TemperatureUnit

/// Which unit a temperature is *shown* in. Never which unit it is *stored*
/// in.
///
/// **The storage unit is Celsius and is not negotiable.** Every sensor path
/// in this codebase — `ThermalCollector`'s HID reads, `BatteryCollector`'s
/// `Double(temp) / 100.0`, `FanCurvePoint.celsius`, the `battery
/// .temperature_c` / `thermal.soc_temp_c` rows `HistoryStore` writes, the
/// `peakSoCTemperatureCelsius` fields on the MCP payloads, and the CSV/JSON
/// `HistoryExport` writes with a literal `"celsius"` unit column — speaks
/// Celsius and will keep speaking Celsius. This type converts at the last
/// possible moment, on the way into a string a human reads, and nowhere
/// else.
///
/// That is not a stylistic preference, it is the only version that can be
/// made correct. A history database whose rows silently changed meaning
/// when a display toggle flipped would make every stored series
/// uninterpretable — a `95` written last week would mean 95 °C and a `95`
/// written today would mean 35 °C, with nothing on the row to tell them
/// apart. The same argument applies to the sync wire (a Mac in °F relaying
/// to a phone in °C), to `FanCurve` (whose breakpoints are compared against
/// raw sensor readings by `FanControlService`, in the daemon, at a cadence
/// no UI is involved in), and to every threshold constant
/// (`SystemAdvisor.highSoCTempCelsius`, `AlertRule.threshold`,
/// `InsightHistorySummaries.sustainedHeatThreshold`). All of those stay in
/// Celsius; only the strings change.
///
/// **Why an enum with two cases rather than `Bool showsFahrenheit`.**
/// Kelvin and Rankine are jokes here, but "is this flag true or false" is
/// unreadable at a call site (`format(x, fahrenheit: true)` vs
/// `format(x, in: .fahrenheit)`), and a `String`-raw enum gives
/// `settings.json` a self-describing `"temperatureUnit": "fahrenheit"`
/// instead of an opaque boolean whose polarity a reader has to guess.
public enum TemperatureUnit: String, Codable, CaseIterable, Sendable, Hashable {
    /// The storage unit, and the shipped default for every install — see
    /// the note at the bottom of this type for why a locale-seeded first
    /// run was rejected.
    case celsius

    /// Display only. Absolute readings convert as `C × 9/5 + 32`;
    /// *differences* between two readings convert as `ΔC × 9/5` — see
    /// `delta(fromCelsius:)`, which exists precisely because getting that
    /// wrong is the classic bug in this area.
    case fahrenheit

    // MARK: Conversion

    /// Converts an absolute Celsius reading into this unit.
    ///
    /// Non-finite input is returned unchanged rather than mangled into
    /// `nan × 1.8 + 32`: callers already guard on `isFinite` before they
    /// render anything (`MetricFormatter.compact` traps-proofs itself that
    /// way, P5), and doing arithmetic on a NaN here would only move the
    /// guard somewhere less obvious.
    public func value(fromCelsius celsius: Double) -> Double {
        guard celsius.isFinite else { return celsius }
        switch self {
        case .celsius: return celsius
        case .fahrenheit: return celsius * 9 / 5 + 32
        }
    }

    /// The inverse of `value(fromCelsius:)` — takes a number *in this unit*
    /// and returns Celsius.
    ///
    /// Exists for the one direction of travel that isn't display: a
    /// user-editable field. `AlertsPane`'s threshold editor shows a rule's
    /// `threshold` in the display unit and has to put whatever the user
    /// types back into the Celsius the engine compares against — the same
    /// bidirectional bridge that pane already builds for byte-scale
    /// thresholds edited in GB. Nothing else should need this; if a second
    /// caller appears that is not an input control, it is probably
    /// converting something that should have stayed Celsius.
    public func celsiusValue(from value: Double) -> Double {
        guard value.isFinite else { return value }
        switch self {
        case .celsius: return value
        case .fahrenheit: return (value - 32) * 5 / 9
        }
    }

    /// Converts a *difference* of two Celsius readings into this unit.
    ///
    /// **This is not `value(fromCelsius:)` and the two must never be
    /// confused.** `ThermalDriftRule` reports "average temperature is up
    /// 4°C against this Mac's own recent baseline" — a delta. Running that
    /// `4` through the absolute conversion would print "up 39°F", which is
    /// not merely imprecise but a completely different (and alarming)
    /// claim; the correct answer is "up 7°F". The 32-degree offset is where
    /// the two scales' zeros sit, and a difference has no zero to offset.
    ///
    /// Kept as its own method rather than a `isDelta: Bool` parameter on
    /// the one above for the same reason `TemperatureUnit` isn't a `Bool`:
    /// the wrong one is silent, so the call site should read as an
    /// unmistakably different operation.
    public func delta(fromCelsius celsiusDelta: Double) -> Double {
        guard celsiusDelta.isFinite else { return celsiusDelta }
        switch self {
        case .celsius: return celsiusDelta
        case .fahrenheit: return celsiusDelta * 9 / 5
        }
    }

    // MARK: Display metadata

    /// `"°C"` / `"°F"` — the full suffix, degree sign included.
    ///
    /// Deliberately *not* added to `MetricUnit.suffix`
    /// (`SentryKit/Models/MetricID.swift`), which stays a hard `"°C"`.
    /// That property is a static description of the unit a *stored* value
    /// is in — `CLIDuration` parses against it and `HistoryExport` labels
    /// exported columns with `MetricUnit`'s raw value — and it is compiled
    /// into `SentryKit_watchOS`, a target that displays no temperature at
    /// all and has no settings file to read a preference from. Making a
    /// static, storage-describing property depend on a mutable display
    /// preference would be the wrong dependency in the wrong direction.
    public var suffix: String {
        switch self {
        case .celsius: return "°C"
        case .fahrenheit: return "°F"
        }
    }

    /// Name for a settings control: "Celsius" / "Fahrenheit".
    public var displayName: String {
        switch self {
        case .celsius: return String(localized: "Celsius")
        case .fahrenheit: return String(localized: "Fahrenheit")
        }
    }

    /// What VoiceOver and Siri should say instead of a degree sign.
    ///
    /// `StatusItemView.spoken` already learned that VoiceOver spells or
    /// skips `°`; the phrase it substituted was hardcoded "degrees", which
    /// was fine while there was only one unit and is ambiguous now.
    public var spokenSuffix: String {
        switch self {
        case .celsius: return String(localized: "degrees Celsius")
        case .fahrenheit: return String(localized: "degrees Fahrenheit")
        }
    }

    // MARK: - The ambient display preference

    /// The unit every display site formats in, for this process.
    ///
    /// **Why this is process-wide ambient state rather than a value
    /// threaded through call sites.** It was tried the other way first.
    /// A temperature reaches a human through, at last count, nineteen
    /// distinct surfaces: the menu bar's Core Graphics draw path
    /// (`BarModuleRenderer.valueText`), its VoiceOver summary, the
    /// dropdown's vitals rows, four Dashboard surfaces, five Settings
    /// panes, `AlertEngine`'s notification bodies, eight
    /// `ProtectionInsightRule`s' evidence sentences, two App Intents
    /// dialogs, `SystemAdvisor`/`AgentPreflight`'s reason strings, the
    /// `sentryctl` statusline, and `FanCurve`'s validation messages. Most
    /// of those are pure `Sendable` value types or free functions
    /// (`InsightPhrasing`, `FanCurve.issues()`, `MetricFormatter`) that
    /// deliberately own no reference to `SettingsStore` — the insight rules
    /// in particular have a documented contract that `evaluate` is a pure
    /// function of its `InsightContext` and reads no ambient configuration.
    /// Threading a `TemperatureUnit` into all of them would mean widening
    /// `InsightContext`, `AlertAction`, `FanCurveIssue`, `MetricFormatter`,
    /// and every intermediate that merely passes them along — a change an
    /// order of magnitude larger than the feature, touching files this task
    /// is explicitly not allowed to touch (`AppDelegate`, the composition
    /// root, is off-limits and is where such a value would have to
    /// originate).
    ///
    /// So: this follows `Locale.current`'s shape, which is the same problem
    /// (a single user-level display preference that unrelated formatting
    /// code all over a process needs, with no sane injection path) and the
    /// same solution. Every API in `TemperatureFormatter` still takes an
    /// explicit `in:` parameter that merely *defaults* to this — so tests
    /// pin the unit without touching global state, and a future caller that
    /// genuinely needs a different unit (a side-by-side comparison, an
    /// export) can ask for one.
    ///
    /// **Who writes it.** Exactly two places, both documented at the write:
    /// `SettingsStore` (macOS — mirrors `AppSettings.temperatureUnit` on
    /// load and on every mutation) and `RootTabView` (iOS — mirrors its
    /// `@AppStorage("temperatureUnit")`). Nothing else should.
    ///
    /// **Freshness.** The menu bar redraws on every sample tick (3s by
    /// default), the dropdown and Dashboard are SwiftUI views observing
    /// `SettingsStore`, and both therefore re-read this within one frame or
    /// one tick of the toggle moving. There is deliberately no
    /// notification/publisher here: adding one would imply the value is a
    /// source of truth that things subscribe to, when the actual source of
    /// truth is `AppSettings`, which already has a publisher.
    public static var display: TemperatureUnit {
        get { ambient.value }
        set { ambient.value = newValue }
    }

    /// Locked box behind `display`.
    ///
    /// A bare `static var` would be a data race the moment the statusline
    /// renderer or a background insight evaluation read it off the main
    /// thread — which both do. `NSLock` rather than `OSAllocatedUnfairLock`
    /// only because this file has no reason to import `os`; the contended
    /// case does not exist (one writer, on the main thread, a few times per
    /// app lifetime), so the cheaper lock buys nothing measurable.
    private static let ambient = AmbientBox()

    private final class AmbientBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: TemperatureUnit = .celsius

        var value: TemperatureUnit {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
            set {
                lock.lock()
                storage = newValue
                lock.unlock()
            }
        }
    }

    // MARK: - The default, and the locale-seeding alternative that was rejected
    //
    // The shipped default is `.celsius` for every install, new or upgrading
    // (`AppSettings.temperatureUnit`'s default argument). Seeding a *fresh*
    // install from `Locale.current.measurementSystem == .us` was written,
    // wired through `SettingsStore.load`'s file-absent branch, and then
    // taken back out. It is a genuinely attractive idea — a first-time user
    // in Boston reading "the SoC is at 78°" has been handed a number they
    // can't use, and every other surface on their Mac says °F — so the
    // reasons it lost are worth recording rather than rediscovering:
    //
    // 1. It cannot live in `AppSettings.default`, which is where a
    //    "default" belongs. That value doubles as `AppSettings.init(from:)`'s
    //    fallback for a settings file written before this key existed, and
    //    an absent key means "upgrading install," not "fresh install" —
    //    that equivalence is the entire premise of that decoder. Seeding
    //    there would flip every existing US user from °C to °F on the
    //    update that shipped this feature, without asking, which is exactly
    //    the thing the requirement forbids.
    //
    // 2. The only place that *can* tell the two populations apart is
    //    `SettingsStore.load`'s "no file on disk" branch. But
    //    `SettingsStore` is also what publishes `TemperatureUnit.display`
    //    (see `SettingsStore.mirrorTemperatureUnit`), so seeding there
    //    makes the process-wide display unit a function of whether a file
    //    happened to exist. Every `SettingsStore` built against a fresh
    //    temporary directory — the test suite does this constantly — would
    //    silently retune formatting for the rest of the process, on a US
    //    machine only. A display preference should change because a user
    //    changed it, never because of an environmental accident, and a
    //    behaviour that reproduces only under one system locale is the
    //    worst kind of bug to be handed.
    //
    // 3. The cost of losing it is one picker in Settings ▸ General ▸ Units,
    //    which is where a user looks for exactly this. The cost of keeping
    //    it is non-deterministic formatting. That is not a close trade.
    //
    // If this is revisited, the right shape is almost certainly to *ask*
    // rather than infer — a units row in the first-run welcome popover
    // (`Sentry/Onboarding/WelcomeView.swift`), pre-selected from the
    // locale — which keeps the default explicit and keeps the inference out
    // of the load path entirely.
}

// MARK: - TemperatureFormatter

/// The one place Celsius becomes a string.
///
/// Before this existed the same conversion-free rendering was spelled five
/// different ways: `MetricFormatter.compact` (`"58°"`),
/// `MetricFormatter.detailed` (`"58.4 °C"`), `InsightPhrasing.celsius`
/// (`"58°C"`), and roughly a dozen hand-rolled
/// `"\(Int(x.rounded())) °C"` interpolations in `FanControlPane`,
/// `FanCurve.issues()`, `SystemAdvisor`, `AgentPreflight`,
/// `SentryMacIntents` and `sentryctl`. Adding a unit toggle on top of that
/// arrangement would have meant a dozen independent conversions, each an
/// opportunity to forget the `+ 32` or apply it to a delta. Every one of
/// those call sites now routes here.
///
/// **Why five named styles rather than one.** They are not decoration —
/// every one of them is a shape the codebase was already producing by hand
/// before this type existed, and collapsing them would mean changing copy
/// that has nothing to do with units. `Style` is deliberately a struct over
/// two orthogonal axes (how many digits, where the unit goes) rather than a
/// flat enum of five opaque names, so that it is obvious the five are a
/// small chosen subset of a grid and not five arbitrary decisions.
///
/// **Precision is deliberately not converted along with the value.** A
/// tenth of a degree Celsius is 0.18 °F, so `.detailed` in Fahrenheit shows
/// about a fifth of a degree of real resolution — but rounding °F to whole
/// numbers to "match" would make the Dashboard's thermal card twitch
/// between two integers while the Celsius one moved smoothly, and the
/// underlying sensor cadence (medium tier, 5s) is what actually bounds the
/// honesty of that digit, not the scale it is printed in.
public enum TemperatureFormatter {

    /// How a temperature is spelled: how much precision, and how the unit
    /// is attached.
    public struct Style: Sendable, Hashable {

        public enum Precision: Sendable, Hashable {
            /// `58`. Sensor noise on the thermal tier is larger than a
            /// degree, so this is the honest default for prose.
            case whole
            /// `58.4`. For surfaces with room, where a moving tenth reads
            /// as "live" rather than as false precision.
            case tenth
        }

        public enum UnitPlacement: Sendable, Hashable {
            /// `58°` — the degree sign only, no letter.
            case degreeOnly
            /// `58°C` — unit attached, no space.
            case attached
            /// `58 °C` — unit after a space.
            case spaced
        }

        public var precision: Precision
        public var placement: UnitPlacement

        public init(precision: Precision, placement: UnitPlacement) {
            self.precision = precision
            self.placement = placement
        }

        /// `"58°"` — the menu bar, where every character is contested and
        /// the module is already labelled by an icon. Dropping the unit
        /// letter is a long-standing choice (`MetricFormatter
        /// .compactSuffix` has always done it); it survives the toggle
        /// because someone who picked °F does not need reminding of it
        /// twice a second.
        public static let compact = Style(precision: .whole, placement: .degreeOnly)

        /// `"58°C"` — prose. Insight evidence sentences, Siri dialogue,
        /// advisor and preflight reasons, the `sentryctl` statusline. A
        /// space before the unit reads as a typo mid-sentence.
        public static let whole = Style(precision: .whole, placement: .attached)

        /// `"58 °C"` — tabular values in Settings (`FanControlPane`'s
        /// curve rows and per-sensor list), where the number and its unit
        /// are separate visual columns.
        public static let wholeSpaced = Style(precision: .whole, placement: .spaced)

        /// `"4.2°C"` — a tenth, inside a sentence. `ThermalDriftRule`'s
        /// delta copy, which quoted the tenth before this type existed and
        /// needs it: 4.2 °C versus 4.0 °C is the boundary between that
        /// rule's advisory and warning tiers.
        public static let decimal = Style(precision: .tenth, placement: .attached)

        /// `"58.4 °C"` — the dropdown's vitals rows and the Dashboard
        /// cards, the two surfaces where a tenth is legible and wanted.
        public static let detailed = Style(precision: .tenth, placement: .spaced)
    }

    /// Formats an absolute Celsius reading.
    ///
    /// Non-finite input yields `MetricFormatter.unavailable` (`"—"`) rather
    /// than `"nan°C"`, matching what every other formatter in this codebase
    /// does with a value that isn't a reading (plan §3.2 P5: "no data" must
    /// never masquerade as data).
    ///
    /// - Parameter unit: defaults to `TemperatureUnit.display`, the user's
    ///   preference. Pass one explicitly to pin the output — which is what
    ///   the tests do, so they never touch process-wide state.
    public static func string(
        celsius: Double,
        style: Style = .whole,
        in unit: TemperatureUnit = .display
    ) -> String {
        guard celsius.isFinite else { return MetricFormatter.unavailable }
        return render(unit.value(fromCelsius: celsius), style: style, unit: unit)
    }

    /// Formats a *difference* between two Celsius readings — "up 4°C".
    ///
    /// Separate from `string(celsius:style:in:)` because the conversion is
    /// genuinely different (no 32-degree offset); see
    /// `TemperatureUnit.delta(fromCelsius:)`.
    ///
    /// Note this emits no sign for a positive delta: every current caller
    /// supplies its own direction word ("rose", "up"), and a bare `+` in
    /// the middle of an English sentence reads worse than the word already
    /// there.
    public static func delta(
        celsius: Double,
        style: Style = .whole,
        in unit: TemperatureUnit = .display
    ) -> String {
        guard celsius.isFinite else { return MetricFormatter.unavailable }
        return render(unit.delta(fromCelsius: celsius), style: style, unit: unit)
    }

    /// The bare converted number with no unit at all — for the two places
    /// that assemble their own suffix: `StatuslineRenderer`'s plain
    /// `temp=62` machine-readable segment, and any caller that has already
    /// drawn the unit elsewhere.
    ///
    /// Takes `style` for its *precision* only; the suffix is discarded.
    public static func number(
        celsius: Double,
        style: Style = .whole,
        in unit: TemperatureUnit = .display
    ) -> String {
        guard celsius.isFinite else { return MetricFormatter.unavailable }
        return digits(unit.value(fromCelsius: celsius), style: style)
    }

    /// What VoiceOver / Siri should say for an absolute reading:
    /// `"58 degrees Celsius"`.
    ///
    /// Built here rather than by string-replacing `"°"` in a formatted
    /// value (which is what `StatusItemView` used to do) because
    /// `.compact`'s output has no unit letter to replace and `.detailed`'s
    /// has a space that the replacement left dangling.
    public static func spoken(
        celsius: Double,
        in unit: TemperatureUnit = .display
    ) -> String {
        guard celsius.isFinite else { return MetricFormatter.unavailable }
        return digits(unit.value(fromCelsius: celsius), style: .whole) + " " + unit.spokenSuffix
    }

    // MARK: - Rendering

    private static func render(_ converted: Double, style: Style, unit: TemperatureUnit) -> String {
        let number = digits(converted, style: style)
        switch style.placement {
        case .degreeOnly: return number + "°"
        case .attached:   return number + unit.suffix
        case .spaced:     return number + " " + unit.suffix
        }
    }

    /// The numeric portion, at the precision the style asks for.
    ///
    /// `String(format:)` rather than `Int(value.rounded())`, matching
    /// `MetricFormatter.compactNumber`'s existing `.celsius` case
    /// byte-for-byte so that turning this feature on changes nothing at all
    /// for a user who stays on Celsius. The two disagree only at an exact
    /// half (`%.0f` rounds half-to-even, `Int(_:.rounded())` rounds half
    /// away from zero), which shifts `InsightPhrasing.celsius`'s output by
    /// one degree for a mean that lands precisely on `.5` — an acceptable
    /// trade for having one rounding rule in the app instead of two.
    ///
    /// Negative values are formatted, not clamped. Sub-zero readings are
    /// real (a Mac carried in from a cold car; the battery pack sensor is
    /// the one most likely to report one) and −18 °C must not print as
    /// `18°C`, which is what a `max(value, 0)` "sanity" guard would do.
    private static func digits(_ value: Double, style: Style) -> String {
        switch style.precision {
        case .whole: return String(format: "%.0f", value)
        case .tenth: return String(format: "%.1f", value)
        }
    }
}
