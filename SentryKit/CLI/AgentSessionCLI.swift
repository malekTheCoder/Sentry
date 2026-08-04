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

    /// Parses `sentryctl session-report`'s optional `--client=<name>` /
    /// `--client <name>` flag (CLI session-scoping pass) — the exact
    /// identifier a user or script is expected to pipe in straight from
    /// `sentryctl sessions`' `clientName` column (see
    /// `SentryXPCServiceProtocol.getSessionResourceReport(targetClientName:)`'s
    /// doc comment for why that column, and not a session UUID, is the
    /// selector: `AgentSessionRegistry`/`AgentSessionInfo` don't expose one).
    ///
    /// Both spellings are accepted, matching `SentryCLI/main.swift`'s
    /// `optionValue` helper (this function is a standalone re-implementation
    /// of that same rule rather than a call into it, because `main.swift` is
    /// a script target with no library to import from — see this type's
    /// header comment) — `session-report`'s older `--since=` flag only ever
    /// accepted the `=` form, but there's no reason to carry that limitation
    /// into a brand-new flag.
    ///
    /// - Returns: `nil` when the flag is absent, or present with nothing
    ///   after it (`--client` at the end of `arguments`, or followed
    ///   immediately by another `--flag`) — both read as "no filter", the
    ///   same "missing means unset" contract `optionValue` documents.
    ///   Never returns an empty string: `--client=""` and a bare trailing
    ///   `--client` are indistinguishable from "omitted" once parsed, and
    ///   both should fall back to the whole-report default rather than
    ///   asking the XPC call to match a client literally named `""`.
    public static func sessionReportTargetClientName(from arguments: [String]) -> String? {
        let prefix = "--client="
        if let joined = arguments.first(where: { $0.hasPrefix(prefix) }) {
            let value = String(joined.dropFirst(prefix.count))
            return value.isEmpty ? nil : value
        }
        guard let index = arguments.firstIndex(of: "--client"), arguments.index(after: index) < arguments.endIndex else {
            return nil
        }
        let next = arguments[arguments.index(after: index)]
        return next.hasPrefix("--") ? nil : next
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
