import Foundation

// MARK: - Option parsing for `macstat watch` / `macstat statusline`

/// Typed, testable argument parsing for the two streaming/formatting
/// subcommands. Lives in MacStatKit rather than `MacStatCLI/main.swift` for
/// the same reason `StatuslineRenderer` does: everything here is a pure
/// `[String] -> Result` function, `MacStatTests` links MacStatKit but not
/// the CLI tool target, and validation rules (interval floor, count ≥ 1,
/// segment vocabulary) are exactly the kind of logic that regresses
/// silently when it can only be exercised by hand-running the binary.
///
/// **Flag grammar.** Both `--flag=value` and `--flag value` are accepted.
/// The `=` form is the house style — `check`/`wait`/`session-report` in
/// `main.swift` parse only `--until=...`/`--timeout=...` — and stays the
/// documented spelling. The two-token form is accepted *in addition*
/// because these two subcommands are built for embedding in other tools'
/// config files (tmux, Starship, Claude Code settings), where users
/// copy-paste `--interval 5` from muscle memory of every getopt-style tool
/// they've ever used; rejecting it would be correctness theater. Accepting
/// both costs one branch here and is fully covered by tests.
///
/// **Unknown flags are errors, not ignored.** The pre-existing subcommands
/// silently ignore stray arguments, but on `watch` — a long-running data
/// producer — a typo like `--intreval 5` silently running at the default
/// cadence could go unnoticed for a whole session. Failing fast with the
/// offending token costs nothing and matches how every getopt tool behaves.
public enum CLIOptions {

    /// A parse failure with a user-facing message. `main.swift` routes this
    /// through `fail(_:)`, so messages are written to read well after the
    /// `"macstat: "` prefix — lowercase, one line, name the flag.
    public struct ParseError: Error, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    // MARK: watch

    /// Parsed form of `macstat watch [--interval=<s>] [--count=<n>]
    /// [--timeout=<s>]`.
    public struct WatchOptions: Equatable, Sendable {
        /// Seconds between snapshots. Default 2 — matches the app's fast
        /// sampling tier closely enough that a tighter default would mostly
        /// re-deliver identical snapshots.
        public var intervalSeconds: Double = 2
        /// Emit exactly this many snapshots then exit 0; `nil` streams
        /// until Ctrl-C (or `--timeout`).
        public var count: Int?
        /// Overall wall-clock deadline; `nil` means none. On expiry the
        /// process exits 124, matching `timeout(1)`, so wrapper scripts
        /// can distinguish "deadline hit" from "connection lost" (1).
        public var timeoutSeconds: Double?

        public init(intervalSeconds: Double = 2, count: Int? = nil, timeoutSeconds: Double? = nil) {
            self.intervalSeconds = intervalSeconds
            self.count = count
            self.timeoutSeconds = timeoutSeconds
        }

        /// The floor on `--interval`. 0.5s is already faster than the
        /// app's fast sampling tier refreshes, so anything tighter burns
        /// XPC round-trips re-reading the *same* cached snapshot —
        /// there's no fresher data to be had, only load. Values below the
        /// floor are an error rather than a silent clamp: a user asking
        /// for `--interval 0.1` believes they're getting 10Hz, and quietly
        /// delivering 2Hz would misrepresent the stream's cadence.
        public static let minimumInterval = 0.5

        public static func parse(_ arguments: [String]) -> Result<WatchOptions, ParseError> {
            var options = WatchOptions()
            var scanner = FlagScanner(arguments)
            while let flag = scanner.next() {
                switch flag.name {
                case "interval":
                    guard let value = flag.value, let interval = Double(value), interval.isFinite else {
                        return .failure(ParseError("--interval needs a number of seconds (e.g. --interval=2)"))
                    }
                    guard interval >= minimumInterval else {
                        return .failure(ParseError("--interval must be at least \(minimumInterval) seconds"))
                    }
                    options.intervalSeconds = interval
                case "count":
                    guard let value = flag.value, let count = Int(value), count >= 1 else {
                        return .failure(ParseError("--count needs a whole number of snapshots ≥ 1"))
                    }
                    options.count = count
                case "timeout":
                    guard let value = flag.value, let timeout = Double(value), timeout.isFinite, timeout > 0 else {
                        return .failure(ParseError("--timeout needs a positive number of seconds"))
                    }
                    options.timeoutSeconds = timeout
                default:
                    return .failure(ParseError("unknown argument '\(flag.raw)' — watch takes --interval, --count, --timeout"))
                }
            }
            return .success(options)
        }
    }

    // MARK: statusline

    /// Parsed form of `macstat statusline [--segments=cpu,mem,battery]
    /// [--color]`.
    public struct StatuslineOptions: Equatable, Sendable {
        /// Which segments render, in the order given — order is preserved
        /// because status-line real estate is positional (see
        /// `StatuslineRenderer.render`). Defaults to all three.
        public var segments: [StatuslineSegment] = StatuslineSegment.allCases
        /// ANSI color, strictly opt-in — see `StatuslineRenderer.render`'s
        /// doc comment for why escape bytes are off by default.
        public var color = false

        public init(segments: [StatuslineSegment] = StatuslineSegment.allCases, color: Bool = false) {
            self.segments = segments
            self.color = color
        }

        public static func parse(_ arguments: [String]) -> Result<StatuslineOptions, ParseError> {
            var options = StatuslineOptions()
            var scanner = FlagScanner(arguments)
            while let flag = scanner.next() {
                switch flag.name {
                case "segments":
                    guard let value = flag.value, !value.isEmpty else {
                        return .failure(ParseError("--segments needs a comma-separated list (e.g. --segments=cpu,mem,battery)"))
                    }
                    var segments: [StatuslineSegment] = []
                    for name in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                        guard let segment = StatuslineSegment(rawValue: name) else {
                            let known = StatuslineSegment.allCases.map(\.rawValue).joined(separator: ", ")
                            return .failure(ParseError("unknown segment '\(name)' — segments are: \(known)"))
                        }
                        // Repeats are dropped rather than rejected:
                        // `--segments=cpu,cpu` has one plausible reading
                        // (show cpu) and rendering it twice serves nobody.
                        if !segments.contains(segment) { segments.append(segment) }
                    }
                    // Non-empty raw value that parses to zero segments is
                    // unreachable (`split` on a non-empty string yields at
                    // least one piece, and unknown pieces already errored),
                    // but the guard documents the invariant render relies on.
                    guard !segments.isEmpty else {
                        return .failure(ParseError("--segments needs at least one segment"))
                    }
                    options.segments = segments
                case "color":
                    // Boolean flag: takes no value. In the two-token
                    // grammar a following bare word belongs to the *next*
                    // flag scan, and `FlagScanner` only attaches values via
                    // `=`, so `--color` composes safely with anything after.
                    guard flag.value == nil else {
                        return .failure(ParseError("--color takes no value"))
                    }
                    options.color = true
                default:
                    return .failure(ParseError("unknown argument '\(flag.raw)' — statusline takes --segments, --color"))
                }
            }
            return .success(options)
        }
    }

    // MARK: - Shared scanner

    /// Walks an argument vector yielding `(name, value)` pairs, accepting
    /// `--name=value`, `--name value`, and bare `--name`.
    ///
    /// Disambiguation rule for the two-token form: a token is consumed as
    /// the preceding flag's value only when it does *not* itself start
    /// with `--`. That makes `--color --segments cpu` parse as two flags
    /// rather than `--color` swallowing `--segments`, at the cost of not
    /// supporting values that literally begin with `--` — which no value
    /// in this grammar (numbers, segment lists) can.
    struct FlagScanner {
        struct Flag {
            /// The name without leading dashes (`interval`).
            let name: String
            /// The attached value, if any. `nil` distinguishes "no value"
            /// from `--name=` (empty string), so boolean flags can reject
            /// the latter explicitly.
            let value: String?
            /// The original token, for error messages that show the user
            /// exactly what they typed.
            let raw: String
        }

        private var remaining: [String]

        init(_ arguments: [String]) {
            self.remaining = arguments
        }

        mutating func next() -> Flag? {
            guard !remaining.isEmpty else { return nil }
            let token = remaining.removeFirst()
            guard token.hasPrefix("--") else {
                // A bare word where a flag belongs: surface it as a
                // nameless flag so the caller's `default:` case reports it
                // as unknown, instead of it vanishing silently the way
                // the older subcommands' `flagValue` scan would.
                return Flag(name: token, value: nil, raw: token)
            }
            let body = token.dropFirst(2)
            if let equals = body.firstIndex(of: "=") {
                return Flag(
                    name: String(body[..<equals]),
                    value: String(body[body.index(after: equals)...]),
                    raw: token
                )
            }
            // Two-token form: only claim the next token when it isn't
            // itself a flag (see the type-level disambiguation rule).
            if let candidate = remaining.first, !candidate.hasPrefix("--") {
                remaining.removeFirst()
                return Flag(name: String(body), value: candidate, raw: token)
            }
            return Flag(name: String(body), value: nil, raw: token)
        }
    }
}
