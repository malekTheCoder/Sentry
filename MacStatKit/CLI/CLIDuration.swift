import Foundation

/// Parses the duration strings the `macstat` CLI accepts on the command line
/// — `1s`, `500ms`, `2m`, and a bare `1.5` (seconds).
///
/// **Why this is a type and not two lines of `Double(string)`.** §21.2.1
/// writes the flag as `--interval 1s`, and §21.2.2 writes `--for 30s`. Those
/// suffixes are part of the documented surface, so `Double("1s")` — which
/// returns `nil` — is the one thing that must not happen silently. The
/// failure mode this exists to prevent is a CLI that reads `--interval 1s`,
/// gets `nil`, quietly falls back to a default, and streams at a cadence the
/// user did not ask for: correct-looking output, wrong data rate, no
/// diagnostic. Parsing returns an optional and the caller is expected to
/// exit non-zero on `nil`.
///
/// Deliberately *not* a general duration grammar. There is no `1h30m`, no
/// `PT1S`, no locale awareness. Compound durations belong to a scheduler,
/// not to a poll interval, and every unsupported form is rejected loudly
/// rather than partially parsed — `"1h30m"` returns `nil`, it does not
/// silently become one hour.
public enum CLIDuration {

    /// - Returns: the duration in seconds, or `nil` for anything this
    ///   doesn't recognize — including a negative or non-finite value, which
    ///   parse fine as numbers but are not durations.
    ///
    /// Zero is accepted here rather than rejected: it is meaningful for a
    /// timeout ("check once, don't wait"), and a caller that needs a
    /// positive value should say so at its own call site, where it can name
    /// the flag in the error message.
    public static func seconds(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }

        // Longest suffix first: "ms" must be tested before "s", or "500ms"
        // parses as the number "500m" with an "s" suffix and fails.
        let units: [(suffix: String, multiplier: Double)] = [
            ("ms", 0.001),
            ("s", 1),
            ("m", 60),
            ("h", 3600),
        ]

        for unit in units where text.hasSuffix(unit.suffix) {
            let number = String(text.dropLast(unit.suffix.count))
            guard let value = Double(number), value.isFinite, value >= 0 else { return nil }
            return value * unit.multiplier
        }

        guard let bare = Double(text), bare.isFinite, bare >= 0 else { return nil }
        return bare
    }

    /// Human-readable list of what `seconds(_:)` accepts, for the error
    /// message a caller prints on `nil`. Kept next to the parser so the two
    /// cannot disagree — an error message listing a syntax the parser
    /// rejects is worse than no error message.
    public static let acceptedFormsDescription = "a number of seconds (`1.5`) or a suffixed duration (`500ms`, `1s`, `2m`, `1h`)"
}
