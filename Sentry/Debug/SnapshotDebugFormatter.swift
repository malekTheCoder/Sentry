import Foundation
import SentryKit

/// Turns a `SystemSnapshot` into raw key/value pairs for the debug window
/// (plan Phase 1 exit criterion: "Debug window dumping every raw value").
///
/// This is deliberately **not** `MetricFormatter`. `MetricFormatter` exists to
/// make numbers pleasant for an end user — it rounds, hides `nil` behind "—",
/// and picks a unit. That is precisely the wrong behavior for a tool whose
/// entire purpose is cross-checking Sentry's computed values against
/// Activity Monitor / System Settings / `powermetrics` output: rounding or
/// hiding a `nil` here would hide the exact discrepancy a developer opened
/// this window to find.
///
/// Uses `Mirror` rather than a hand-written field list per struct so a field
/// added to any `SystemSnapshot` sub-struct later shows up here automatically
/// — the whole point of a standing tool instead of another one-off throwaway
/// script (which is what this replaces, per the plan).
public enum SnapshotDebugFormatter {

    public struct Field: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let type: String
        public let value: String

        public init(name: String, type: String, value: String) {
            self.id = name
            self.name = name
            self.type = type
            self.value = value
        }
    }

    public struct Section: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let fields: [Field]

        public init(name: String, fields: [Field]) {
            self.id = name
            self.name = name
            self.fields = fields
        }
    }

    /// The sub-struct properties on `SystemSnapshot`, in the order the plan
    /// lists them ("battery, cpu, gpu, ane, memory, disk, network, thermal,
    /// sleepAssertion"), plus `location` appended at the end (added after the
    /// plan was written, for the "Location Log" feature — see
    /// `MacLocation`'s doc comment) — listed explicitly, rather than
    /// discovered purely via `Mirror`, so the section order in the window is
    /// stable and matches the plan even though `Mirror`'s child order
    /// already happens to follow declaration order (an implementation
    /// detail `Mirror`'s docs don't actually guarantee). `topProcesses`
    /// (added alongside process-scoped alert rules — see
    /// `SystemSnapshot.topProcesses`'s doc comment) is appended last,
    /// after `location`, for the same "added after the plan was written"
    /// reasoning.
    private static let subStructKeys = [
        "battery", "cpu", "gpu", "ane", "memory", "disk", "network", "thermal", "sleepAssertion", "location",
        "topProcesses",
    ]

    /// One `Section` per `SystemSnapshot` sub-struct, plus a leading
    /// "Snapshot" section for the top-level identity fields (`id`,
    /// `timestamp`, `deviceID`, `schemaVersion`) that aren't part of any
    /// sub-struct but are still raw values worth cross-checking (e.g. is the
    /// coordinator actually ticking at the configured interval).
    public static func sections(for snapshot: SystemSnapshot) -> [Section] {
        let topMirror = Mirror(reflecting: snapshot)
        var metaFields: [Field] = []
        var subStructValues: [String: Any] = [:]

        for child in topMirror.children {
            guard let label = child.label else { continue }
            if subStructKeys.contains(label) {
                subStructValues[label] = child.value
            } else {
                metaFields.append(
                    Field(name: label, type: String(describing: type(of: child.value)), value: describe(child.value))
                )
            }
        }

        var sections = [Section(name: "Snapshot", fields: metaFields)]
        for key in subStructKeys {
            guard let value = subStructValues[key] else { continue }
            sections.append(section(name: displayName(for: key), optionalValue: value))
        }
        return sections
    }

    /// Plain-text rendering for the "Copy" button — the same content the
    /// window shows, formatted for pasting into a bug report rather than
    /// into SwiftUI.
    public static func plainText(for snapshot: SystemSnapshot) -> String {
        sections(for: snapshot)
            .map { section in
                let header = "== \(section.name) =="
                let body = section.fields
                    .map { "\($0.name): \($0.type) = \($0.value)" }
                    .joined(separator: "\n")
                return body.isEmpty ? header : "\(header)\n\(body)"
            }
            .joined(separator: "\n\n")
    }

    // MARK: - Section building

    /// `optionalValue` is always an `Optional<SomeStats>` boxed in `Any` —
    /// every sub-struct field on `SystemSnapshot` is optional (a Mac missing
    /// a capability produces a smaller snapshot, not fake zeros). Unwraps it
    /// and, when absent, emits a single field whose value is the literal
    /// string "nil" rather than omitting the section — a missing section
    /// would look like a bug in this tool, not like the collector genuinely
    /// having nothing to report.
    private static func section(name: String, optionalValue: Any) -> Section {
        let mirror = Mirror(reflecting: optionalValue)
        guard mirror.displayStyle == .optional else {
            // Defensive fallback only — every current sub-struct field is
            // `Optional`, so this path isn't reachable today, but a future
            // non-optional sub-struct shouldn't make this function trap.
            return Section(name: name, fields: fields(from: optionalValue))
        }
        guard let unwrapped = mirror.children.first?.value else {
            let typeName = String(describing: mirror.subjectType)
            return Section(name: name, fields: [Field(name: "(value)", type: typeName, value: "nil")])
        }

        // Only a struct (e.g. `BatteryStats`) has named properties worth
        // breaking into one field each. A sub-struct field that's itself an
        // enum (`sleepAssertion: SleepAssertionState?`) has no such named
        // properties — `Mirror`'s children for an enum case are the case
        // name and its associated-value tuple, not struct fields, so running
        // that through `fields(from:)` would bypass `describe`'s dedicated
        // `.enum` handling entirely and print the raw tuple instead of
        // `active(mode: ..., expiresAt: ..., reason: ...)`. Collapsing to a
        // single field and routing through `describe` keeps one formatting
        // path for every enum, whether nested in a struct or not.
        guard Mirror(reflecting: unwrapped).displayStyle == .struct else {
            let typeName = String(describing: type(of: unwrapped))
            return Section(name: name, fields: [Field(name: "(value)", type: typeName, value: describe(unwrapped))])
        }
        return Section(name: name, fields: fields(from: unwrapped))
    }

    private static func fields(from value: Any) -> [Field] {
        Mirror(reflecting: value).children.map { child in
            let name = child.label ?? "?"
            let typeName = String(describing: type(of: child.value))
            return Field(name: name, type: typeName, value: describe(child.value))
        }
    }

    private static func displayName(for key: String) -> String {
        switch key {
        case "cpu": return "CPU"
        case "gpu": return "GPU"
        case "ane": return "ANE"
        case "sleepAssertion": return "Sleep Assertion"
        case "location": return "Location"
        case "topProcesses": return "Top Processes"
        default: return key.prefix(1).uppercased() + key.dropFirst()
        }
    }

    // MARK: - Value formatting

    /// Recursively renders a single value with no rounding, no unit
    /// conversion, and no placeholder for absence — `nil` prints as the
    /// literal text "nil", never as an empty string or a dash. `Mirror`'s
    /// `displayStyle` is what lets this stay generic across every field type
    /// `SystemSnapshot` currently has (and most it's likely to grow):
    ///
    /// - `.optional`: unwrap one level, or "nil" if empty.
    /// - `.collection`: render each element and join as `[a, b, c]` — covers
    ///   `perCorePercent`, `cellVoltagesMV`, `fanRPMs`.
    /// - `.enum`: cases with no associated value (`ThermalStats.PressureLevel`,
    ///   `MemoryPressureLevel`) fall through to `String(describing:)`, which
    ///   already prints just the case name. Cases *with* associated values
    ///   (`SleepAssertionState.active(mode:expiresAt:reason:)`) don't survive
    ///   `String(describing:)` usefully doing the label-matching by hand —
    ///   `Mirror` exposes the case name as the single child's label and the
    ///   payload as a nested tuple mirror, which this walks to print
    ///   `active(mode: ..., expiresAt: ..., reason: ...)` instead of Swift's
    ///   own (perfectly serviceable, but less readable) default.
    /// - `.struct` / `.class`: only reachable if a future field is itself a
    ///   struct rather than a primitive; renders as `Type(field: value, ...)`
    ///   so a new nested type doesn't need a case added here to show up.
    /// - default (numbers, `String`, `Bool`, `UUID`, `Date`, ...):
    ///   `String(describing:)` as-is — deliberately not `String(format:)`,
    ///   because trimming a `Double` to "2 decimal places" is exactly the
    ///   kind of lossy formatting this tool exists to avoid.
    public static func describe(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            guard let child = mirror.children.first else { return "nil" }
            return describe(child.value)

        case .collection:
            let items = mirror.children.map { describe($0.value) }
            return "[" + items.joined(separator: ", ") + "]"

        case .enum:
            guard let child = mirror.children.first else {
                // No associated value: String(describing:) already yields
                // just the case name (e.g. "nominal").
                return String(describing: value)
            }
            let caseName = child.label ?? String(describing: value)
            let payloadMirror = Mirror(reflecting: child.value)
            if payloadMirror.displayStyle == .tuple {
                let parts = payloadMirror.children.map { part -> String in
                    if let label = part.label, !label.hasPrefix(".") {
                        return "\(label): \(describe(part.value))"
                    }
                    return describe(part.value)
                }
                return "\(caseName)(\(parts.joined(separator: ", ")))"
            }
            return "\(caseName)(\(describe(child.value)))"

        case .struct, .class:
            let parts = mirror.children.map { part -> String in
                let label = part.label ?? "?"
                return "\(label): \(describe(part.value))"
            }
            let typeName = String(describing: mirror.subjectType)
            return "\(typeName)(\(parts.joined(separator: ", ")))"

        default:
            return String(describing: value)
        }
    }
}
