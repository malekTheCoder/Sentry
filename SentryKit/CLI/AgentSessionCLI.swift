import Foundation

/// Pure logic behind `sentryctl sessions` and `sentryctl stop <client-name>`
/// — split out of `SentryCLI/main.swift` for the same reason
/// `CLIDuration`/`StatuslineRenderer` already are (see those types' doc
/// comments): `SentryCLI`'s `main.swift` is a top-level script, not a
/// library, so anything worth unit-testing has to live in `SentryKit`
/// instead, with `main.swift` reduced to argument-plumbing and printing.
public enum AgentSessionCLI {

    /// Parses `sentryctl stop <client-name>`'s trailing positional argument.
    ///
    /// - Parameter arguments: the full argument list *including* the `stop`
    ///   command itself at index 0 — mirrors how `main.swift` already parses
    ///   `sentry hook pretooluse` (`arguments[1]`), rather than introducing a
    ///   second convention for a second positional subcommand.
    /// - Returns: the client name, or `nil` if none was given — the caller
    ///   is expected to print a targeted usage error on `nil` rather than
    ///   index out of bounds.
    public static func stopTargetClientName(from arguments: [String]) -> String? {
        guard arguments.count > 1, !arguments[1].isEmpty else { return nil }
        return arguments[1]
    }

    /// One human-readable line for `sentryctl sessions`' plain-text mode
    /// (i.e. without `--json`) — matches this CLI's existing convention of a
    /// short, comma-joined summary (see `runSessionReport` in
    /// `SentryCLI/main.swift`) rather than a multi-line record per session.
    ///
    /// - Parameter now: injectable so "Xs ago" is deterministic in tests,
    ///   same reasoning as `MCPAccessController`'s injectable `clock`.
    public static func formatSessionLine(_ session: MCPPayloads.AgentSessionInfo, now: Date = Date()) -> String {
        let secondsAgo = max(0, Int(now.timeIntervalSince(session.lastCallAt)))
        var parts = ["last call \(secondsAgo)s ago"]
        if session.holdsKeepAwake {
            parts.append("holds keep-awake")
        }
        if !session.recentTools.isEmpty {
            parts.append("recent: " + session.recentTools.prefix(3).joined(separator: ", "))
        }
        return "\(session.clientName) — \(parts.joined(separator: ", "))"
    }
}
