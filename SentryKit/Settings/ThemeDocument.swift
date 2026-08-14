import Foundation
import CoreGraphics

// MARK: - Errors

/// Everything that can be wrong with a `.sentrytheme` file, as a case rather
/// than a string, so the importer's tests can assert on *which* rejection
/// happened and the UI can show one clear sentence per cause.
///
/// **Why this is so granular.** Import is untrusted input: the file may have
/// been hand-edited, downloaded from a forum, or produced by a future build.
/// A single `case invalid` would let the UI say only "that file didn't work,"
/// which tells a user nothing about a stray comma versus a color they typed
/// as `#GGG`. Every case below is a message someone can act on.
public enum ThemeDocumentError: Error, Equatable, LocalizedError {
    case notJSON(underlying: String)
    case topLevelNotAnObject
    case missingFormatMarker
    case wrongFormat(found: String)
    case unsupportedVersion(found: Int, newestSupported: Int)
    case missingThemeObject
    /// The theme object decoded, but omitted tokens a theme cannot do
    /// without. See `ThemeDocument.requiredThemeKeys`.
    case missingRequiredTokens([String])
    case malformedColor(token: String, value: String)
    case numberOutOfRange(field: String, value: Double, lowerBound: Double, upperBound: Double)
    case tooManyChartFillStops(found: Int, maximum: Int)
    case emptyName
    case nameTooLong(found: Int, maximum: Int)
    /// A `metricColors` key that isn't a metric this build knows. Rejected
    /// rather than dropped: silently discarding half a theme's per-metric
    /// colors is the "half-applied theme" the brief specifically rules out.
    case unknownMetricKeys([String])
    /// The file claimed the `builtin.` namespace. Accepting it would let an
    /// imported theme shadow a shipped preset everywhere in the app.
    case reservedIdentifier(String)
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notJSON(let underlying):
            return String(localized: "This isn't valid JSON. (\(underlying))")
        case .topLevelNotAnObject:
            return String(localized: "A theme file must be a JSON object, not an array or a bare value.")
        case .missingFormatMarker:
            return String(localized: "This file has no \"format\" marker, so it isn't a Sentry theme.")
        case .wrongFormat(let found):
            return String(localized: "This file says it's \"\(found)\", not a Sentry theme.")
        case .unsupportedVersion(let found, let newest):
            return String(localized: "This theme is format version \(found); this build of Sentry understands up to \(newest). Update Sentry to open it.")
        case .missingThemeObject:
            return String(localized: "The file has no \"theme\" object in it.")
        case .missingRequiredTokens(let keys):
            return String(localized: "The theme is missing required colors: \(keys.joined(separator: ", ")).")
        case .malformedColor(let token, let value):
            return String(localized: "\"\(token)\" isn't a color Sentry can read: \"\(value)\". Use #RGB, #RRGGBB, or #RRGGBBAA.")
        case .numberOutOfRange(let field, let value, let lower, let upper):
            return String(localized: "\"\(field)\" is \(Self.number(value)), which is outside the allowed \(Self.number(lower))–\(Self.number(upper)).")
        case .tooManyChartFillStops(let found, let maximum):
            return String(localized: "The chart gradient has \(found) stops; the most Sentry accepts is \(maximum).")
        case .emptyName:
            return String(localized: "The theme has no name.")
        case .nameTooLong(let found, let maximum):
            return String(localized: "The theme's name is \(found) characters; the most Sentry accepts is \(maximum).")
        case .unknownMetricKeys(let keys):
            return String(localized: "The theme assigns colors to metrics Sentry doesn't have: \(keys.joined(separator: ", ")).")
        case .reservedIdentifier(let id):
            return String(localized: "The theme claims the identifier \"\(id)\", which is reserved for Sentry's built-in presets.")
        case .decodingFailed(let detail):
            return String(localized: "Sentry couldn't read the theme: \(detail)")
        }
    }

    /// Trailing zeros make range messages read like machine output; this
    /// prints 0.5 as "0.5" and 16.0 as "16".
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }
}

// MARK: - The file format

/// Read and write §9.3's `.sentrytheme` interchange file.
///
/// **The envelope.** A theme file is `{"format", "formatVersion", "theme"}`
/// rather than a bare `Theme` object. Three reasons, in order of how much
/// they cost to add later: a format marker lets the importer tell "this is
/// somebody's `package.json`" from "this is a theme with a typo in it," which
/// is the difference between a useful error and a confusing one; a version
/// integer means a future build that changes a token's *meaning* (rather than
/// adding one) has something to branch on, exactly as `AppSettings.schemaVersion`
/// does; and a wrapper leaves room for metadata — author, description — that
/// isn't part of the rendering model and shouldn't be smuggled into it.
///
/// **Two passes on import, deliberately.** The file is first inspected as raw
/// `JSONSerialization` output to check the envelope and confirm the theme
/// object actually contains the tokens it needs, and only then decoded through
/// `Theme.init(from:)`. That decoder is intentionally permissive so an old
/// `settings.json` keeps working (see its doc comment) — which means running
/// import through it alone would turn `{"format": "...", "theme": {}}` into a
/// pixel-perfect clone of Notion under whatever name the file claimed, and
/// report success. The raw pass is what makes "this file is missing its
/// colors" a rejection instead of a silent substitution. The cost is parsing a
/// two-kilobyte file twice, which is not a cost.
///
/// **Identity is never trusted.** An imported theme always gets a fresh
/// `custom.<uuid>` id, regardless of what the file said, and is always
/// `isBuiltIn == false`. A file naming itself `builtin.system` is rejected
/// outright rather than quietly renamed, because a file that tried it is more
/// likely hostile than confused and the user should be told.
public enum ThemeDocument {

    /// Value of the envelope's `format` key. Version-independent; the integer
    /// beside it is what moves.
    public static let formatMarker = "sentry.theme"

    /// The newest `formatVersion` this build can read. Bumped only when a
    /// stored field changes *meaning* — an added token is handled by
    /// `Theme.init(from:)`'s tolerance and needs no bump, the same contract
    /// `AppSettings.schemaVersion` documents.
    public static let currentFormatVersion = 1

    /// The file extension, without the dot, for `NSOpenPanel`/`NSSavePanel`
    /// and for `UTType`.
    public static let fileExtension = "sentrytheme"

    /// Tokens a theme file must actually contain.
    ///
    /// Not "every token" — that would make every future addition a breaking
    /// change for existing files, which is the trap `AppSettings` documents at
    /// length. This is the set whose absence would make the substituted
    /// default *invisible*: the three surfaces and the three-step text ramp
    /// are what a theme fundamentally is, and a file lacking them is not a
    /// theme that's missing a detail, it's not a theme. Everything else
    /// (`accent`, geometry, effects, per-metric colors) falls back to the
    /// default preset's value, and the editor shows the user the result before
    /// they commit to it.
    public static let requiredThemeKeys: Set<String> = [
        "background", "surface", "surfaceElevated",
        "textPrimary", "textSecondary", "textTertiary",
    ]

    // MARK: Export

    /// A `.sentrytheme` payload for one theme.
    ///
    /// Exporting a *built-in* preset is allowed and produces a file whose
    /// theme object carries `isBuiltIn: false` and a fresh custom id — the
    /// file is a starting point somebody will edit, not a claim on Sentry's
    /// namespace, and re-importing it must not produce a second thing calling
    /// itself `builtin.ivory`.
    public static func encode(_ theme: Theme, formatVersion: Int = currentFormatVersion) throws -> Data {
        var exported = theme
        if exported.isBuiltIn {
            exported.isBuiltIn = false
            exported.basePresetID = theme.id
            exported.id = Theme.newCustomID()
        }

        let encoder = JSONEncoder()
        // Sorted and indented because the whole point of a shareable file is
        // that a human reads and edits it — and because a stable key order
        // makes a theme file diffable in the git repo somebody will inevitably
        // keep them in.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(ThemeFile(formatVersion: formatVersion, theme: exported))
    }

    /// The on-disk shape. Internal to this type: nothing outside import and
    /// export needs to name it.
    private struct ThemeFile: Codable {
        var format: String = ThemeDocument.formatMarker
        var formatVersion: Int
        var theme: Theme

        init(formatVersion: Int, theme: Theme) {
            self.formatVersion = formatVersion
            self.theme = theme
        }
    }

    // MARK: Import

    /// Validate and decode a `.sentrytheme` file.
    ///
    /// Throws `ThemeDocumentError` — never a raw `DecodingError`, never a
    /// trap. On success the returned theme is guaranteed to have a fresh
    /// custom id, `isBuiltIn == false`, well-formed colors in every token, and
    /// numbers inside `ThemeLimits`. It is *not* guaranteed to be readable:
    /// contrast is a §9.4 concern the editor flags inline, and rejecting an
    /// import for low contrast would make it impossible to open somebody
    /// else's theme in order to fix it.
    public static func decode(_ data: Data) throws -> Theme {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ThemeDocumentError.notJSON(underlying: error.localizedDescription)
        }

        guard let object = raw as? [String: Any] else {
            throw ThemeDocumentError.topLevelNotAnObject
        }

        guard let format = object["format"] as? String else {
            throw ThemeDocumentError.missingFormatMarker
        }
        guard format == formatMarker else {
            throw ThemeDocumentError.wrongFormat(found: format)
        }

        // A missing version is treated as 1 rather than rejected: version 1 is
        // the only version that has ever existed, so a file written by hand
        // from the docs without the key is far more likely than a file from
        // the future that forgot it.
        let version = (object["formatVersion"] as? NSNumber)?.intValue ?? 1
        guard version <= currentFormatVersion else {
            throw ThemeDocumentError.unsupportedVersion(
                found: version,
                newestSupported: currentFormatVersion
            )
        }

        guard let themeObject = object["theme"] as? [String: Any] else {
            throw ThemeDocumentError.missingThemeObject
        }

        let present = Set(themeObject.keys)
        let missing = requiredThemeKeys.subtracting(present)
        guard missing.isEmpty else {
            throw ThemeDocumentError.missingRequiredTokens(missing.sorted())
        }

        if let claimedID = themeObject["id"] as? String,
           claimedID.hasPrefix(Theme.builtInIDPrefix) {
            throw ThemeDocumentError.reservedIdentifier(claimedID)
        }

        // Re-serialize the theme sub-object rather than decoding the whole
        // envelope through Codable, so the raw checks above and the typed
        // decode below are looking at exactly the same bytes.
        let themeData: Data
        do {
            themeData = try JSONSerialization.data(withJSONObject: themeObject)
        } catch {
            throw ThemeDocumentError.decodingFailed(error.localizedDescription)
        }

        var theme: Theme
        do {
            theme = try JSONDecoder().decode(Theme.self, from: themeData)
        } catch let error as DecodingError {
            throw ThemeDocumentError.decodingFailed(Self.describe(error))
        } catch {
            throw ThemeDocumentError.decodingFailed(error.localizedDescription)
        }

        try validate(theme)

        // Identity is assigned here, after validation, so the error messages
        // above still quote what the file actually said.
        theme.id = Theme.newCustomID()
        theme.isBuiltIn = false
        return theme
    }

    /// Everything checked about a decoded theme's *values*, shared by import
    /// and by the editor's pre-export sanity check.
    ///
    /// Ordered deliberately: name, then colors, then numbers. A user fixing a
    /// hand-written file gets told about the structural problem before the
    /// numeric one, and only one error is thrown at a time because a list of
    /// eleven simultaneous complaints is not more useful than the first.
    public static func validate(_ theme: Theme) throws {
        let trimmedName = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ThemeDocumentError.emptyName }
        guard trimmedName.count <= ThemeLimits.nameLength.upperBound else {
            throw ThemeDocumentError.nameTooLong(
                found: trimmedName.count,
                maximum: ThemeLimits.nameLength.upperBound
            )
        }

        for token in ThemeColorToken.allCases {
            try validateColor(theme[token], named: token.rawValue)
        }

        guard theme.chartFill.count <= ThemeLimits.chartFillStops.upperBound else {
            throw ThemeDocumentError.tooManyChartFillStops(
                found: theme.chartFill.count,
                maximum: ThemeLimits.chartFillStops.upperBound
            )
        }
        for (index, stop) in theme.chartFill.enumerated() {
            try validateColor(stop, named: "chartFill[\(index)]")
        }

        // Unknown metric keys are collected rather than thrown one at a time:
        // a file written against a different build is likely to have several,
        // and fixing them one error-dialog at a time would be miserable.
        let unknownMetricKeys = theme.metricColors.keys
            .filter { MetricID(rawValue: $0) == nil }
            .sorted()
        guard unknownMetricKeys.isEmpty else {
            throw ThemeDocumentError.unknownMetricKeys(unknownMetricKeys)
        }
        for key in theme.metricColors.keys.sorted() {
            guard let color = theme.metricColors[key] else { continue }
            try validateColor(color, named: "metricColors.\(key)")
        }

        if case .custom(let fontName) = theme.fontFamily,
           fontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // An empty PostScript name isn't a font that's merely missing —
            // `.custom("", size:)` is a request the renderer can't even fail
            // meaningfully at. A *named* font that isn't installed is fine and
            // deliberately not checked: it degrades to the system font, which
            // is the right outcome for a theme authored on someone else's Mac.
            throw ThemeDocumentError.malformedColor(token: "fontFamily", value: fontName)
        }

        try validate(Double(theme.barFontSize), field: "barFontSize", in: ThemeLimits.barFontSize)
        try validate(Double(theme.cornerRadius), field: "cornerRadius", in: ThemeLimits.cornerRadius)
        try validate(Double(theme.chartLineWidth), field: "chartLineWidth", in: ThemeLimits.chartLineWidth)
        try validate(Double(theme.barGraphWidth), field: "barGraphWidth", in: ThemeLimits.barGraphWidth)
        try validate(theme.glowIntensity, field: "glowIntensity", in: ThemeLimits.glowIntensity)
    }

    private static func validateColor(_ color: ThemeColor, named name: String) throws {
        for appearance in ThemeAppearance.allCases {
            let hex = color.hex(for: appearance)
            guard ThemeColor.components(fromHex: hex) != nil else {
                throw ThemeDocumentError.malformedColor(token: "\(name).\(appearance.rawValue)", value: hex)
            }
        }
        // Opacity is range-checked rather than clamped, unlike at the
        // rendering layer: the renderer clamps because it must draw
        // *something*, but an importer that clamps is an importer that
        // silently changes the file it was given.
        try validate(color.opacity, field: "\(name).opacity", in: ThemeLimits.opacity)
    }

    private static func validate<T: BinaryFloatingPoint>(
        _ value: T,
        field: String,
        in range: ClosedRange<T>
    ) throws {
        guard value.isFinite else {
            throw ThemeDocumentError.numberOutOfRange(
                field: field,
                value: 0,
                lowerBound: Double(range.lowerBound),
                upperBound: Double(range.upperBound)
            )
        }
        guard range.contains(value) else {
            throw ThemeDocumentError.numberOutOfRange(
                field: field,
                value: Double(value),
                lowerBound: Double(range.lowerBound),
                upperBound: Double(range.upperBound)
            )
        }
    }

    /// `DecodingError`'s own `localizedDescription` is "The data couldn't be
    /// read because it isn't in the correct format," which tells a user
    /// editing a theme file precisely nothing. This names the key.
    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue)
            return keys.isEmpty ? String(localized: "the theme") : "\"\(keys.joined(separator: "."))\""
        }
        switch error {
        case .typeMismatch(let type, let context):
            return String(localized: "\(path(context)) should be \(String(describing: type)).")
        case .valueNotFound(_, let context):
            return String(localized: "\(path(context)) is null.")
        case .keyNotFound(let key, _):
            return String(localized: "\"\(key.stringValue)\" is missing.")
        case .dataCorrupted(let context):
            return String(localized: "\(path(context)) is not a value Sentry recognizes.")
        @unknown default:
            return error.localizedDescription
        }
    }

    // MARK: Filenames

    /// A filesystem-safe default filename for the save panel. Falls back to
    /// the plain word rather than producing a dotfile or an empty stem when a
    /// name is entirely punctuation.
    public static func suggestedFilename(for theme: Theme) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = theme.name.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        let stem = cleaned.isEmpty ? String(localized: "Theme") : cleaned
        return "\(stem).\(fileExtension)"
    }
}
