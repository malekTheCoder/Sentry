import Foundation
import SentryKit

/// Pure parsing of the command output behind `SecurityPostureCollector`.
///
/// Split out from the collector for the same reason `AnomalyDetector` is
/// split from `DashboardViewModel`: this is the part with real failure
/// modes worth testing, and it has nothing to do with spawning processes.
/// Every function here takes an optional `String` — `nil` meaning "the
/// command didn't run, timed out, or exited non-zero" — and returns a
/// `PostureState`, never a `Bool`.
///
/// **Anything unrecognised is `.unknown`.** These are unversioned,
/// undocumented CLI output formats that Apple can change in any release.
/// The correct response to output this parser doesn't recognise is to say
/// so, not to fall back to a default that happens to look reassuring.
public enum SecurityPostureParser {

    /// `fdesetup status`
    ///
    /// Known forms:
    /// - `FileVault is On.`
    /// - `FileVault is Off.`
    /// - `FileVault is Off, but will be enabled after the next restart.`
    ///
    /// The deferred-enable form is reported as `.off`, deliberately: it
    /// describes the disk right now, and right now the disk is not
    /// encrypted. A Mac that is stolen before the next restart is stolen
    /// unencrypted.
    public static func fileVault(_ output: String?) -> PostureState {
        guard let text = normalise(output) else { return .unknown }
        if text.contains("filevault is on") { return .on }
        if text.contains("filevault is off") { return .off }
        return .unknown
    }

    /// `csrutil status`
    ///
    /// Known forms:
    /// - `System Integrity Protection status: enabled.`
    /// - `System Integrity Protection status: disabled.`
    /// - `System Integrity Protection status: unknown (Custom Configuration).`
    /// - `System Integrity Protection status: enabled (Custom Configuration).`
    ///
    /// A custom configuration means *some* SIP protections are off and
    /// others are on. There is no honest single-bit answer to that, so it
    /// maps to `.unknown` — including when the line also says "enabled",
    /// because reporting a partially-disabled SIP as fully on would be the
    /// more damaging of the two possible errors.
    public static func systemIntegrityProtection(_ output: String?) -> PostureState {
        guard let text = normalise(output) else { return .unknown }
        if text.contains("custom configuration") { return .unknown }
        if text.contains("status: enabled") { return .on }
        if text.contains("status: disabled") { return .off }
        return .unknown
    }

    /// `spctl --status`
    ///
    /// Known forms: `assessments enabled` / `assessments disabled`.
    public static func gatekeeper(_ output: String?) -> PostureState {
        guard let text = normalise(output) else { return .unknown }
        if text.contains("assessments enabled") { return .on }
        if text.contains("assessments disabled") { return .off }
        return .unknown
    }

    /// `socketfilterfw --getglobalstate`
    ///
    /// Known forms:
    /// - `Firewall is disabled. (State = 0)`
    /// - `Firewall is enabled. (State = 1)`
    /// - `Firewall is enabled. (State = 2)` — "block all incoming".
    ///
    /// State 2 is *more* restrictive than 1, so both are `.on`. The numeric
    /// form is checked first because it is the stable part of the output;
    /// the prose has changed wording across releases.
    public static func firewallGlobalState(_ output: String?) -> PostureState {
        guard let text = normalise(output) else { return .unknown }
        if text.contains("state = 1") || text.contains("state = 2") { return .on }
        if text.contains("state = 0") { return .off }
        if text.contains("firewall is enabled") { return .on }
        if text.contains("firewall is disabled") { return .off }
        return .unknown
    }

    /// `socketfilterfw --getstealthmode`
    ///
    /// Known forms: `Stealth mode enabled` / `Stealth mode disabled`.
    public static func firewallStealthMode(_ output: String?) -> PostureState {
        guard let text = normalise(output) else { return .unknown }
        if text.contains("stealth mode enabled") { return .on }
        if text.contains("stealth mode disabled") { return .off }
        return .unknown
    }

    /// A `defaults read <domain> <key>` result for a boolean key.
    ///
    /// `defaults` prints `1`/`0` for `NSNumber` booleans and `true`/`false`
    /// for genuine `CFBoolean`s depending on how the key was written, so
    /// both spellings are accepted. A missing key makes `defaults` exit
    /// non-zero, which the runner turns into `nil` — and therefore
    /// `.unknown`, not `.off`. That distinction is the whole point: "the
    /// key isn't set" and "the key is set to false" are different facts,
    /// and only one of them is a finding.
    public static func booleanDefault(_ output: String?) -> PostureState {
        guard let text = normalise(output) else { return .unknown }
        switch text {
        case "1", "true", "yes": return .on
        case "0", "false", "no": return .off
        default: return .unknown
        }
    }

    /// A `defaults read` result for an integer key. `nil` on anything
    /// unparseable.
    public static func integerDefault(_ output: String?) -> Int? {
        guard let text = normalise(output) else { return nil }
        return Int(text)
    }

    /// Ports with a listening TCP socket bound to a **network-reachable**
    /// address, from `netstat -an -p tcp`.
    ///
    /// **Loopback-only listeners are excluded**, and that exclusion is the
    /// difference between an honest finding and a scary one: a service
    /// bound to `127.0.0.1` cannot be reached from the network at all, so
    /// reporting it as "Screen Sharing is reachable" would be false. Only
    /// wildcard binds (`*.5900`) and binds to a real interface address are
    /// counted.
    ///
    /// Expected line shape (BSD netstat):
    /// ```
    /// tcp4       0      0  *.22                   *.*                    LISTEN
    /// tcp4       0      0  127.0.0.1.5900         *.*                    LISTEN
    /// ```
    /// Anything that doesn't match is skipped rather than guessed at.
    public static func listeningPorts(netstatOutput: String?) -> Set<Int>? {
        guard let output = netstatOutput else { return nil }

        var ports = Set<Int>()
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            guard line.contains("LISTEN") else { continue }

            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard columns.count >= 4, columns[0].lowercased().hasPrefix("tcp") else { continue }

            let localAddress = columns[3]
            guard let separator = localAddress.lastIndex(of: ".") else { continue }
            let host = String(localAddress[localAddress.startIndex..<separator])
            let portText = String(localAddress[localAddress.index(after: separator)...])
            guard let port = Int(portText) else { continue }
            guard isNetworkReachableHost(host) else { continue }
            ports.insert(port)
        }
        return ports
    }

    /// `.on` when something is listening on `port`, `.off` when the scan
    /// succeeded and nothing was, `.unknown` when the scan itself failed.
    public static func listenerState(port: Int, in ports: Set<Int>?) -> PostureState {
        guard let ports else { return .unknown }
        return ports.contains(port) ? .on : .off
    }

    // MARK: - Helpers

    /// Loopback binds aren't reachable from the network. IPv6 loopback in
    /// netstat's output appears as `::1`, and the link-local/`%interface`
    /// suffix forms are stripped before comparison.
    static func isNetworkReachableHost(_ host: String) -> Bool {
        let bare = host.split(separator: "%").first.map(String.init) ?? host
        switch bare {
        case "127.0.0.1", "::1", "localhost":
            return false
        default:
            // 127.0.0.0/8 in full — macOS services occasionally bind to
            // 127.0.0.53 and similar.
            return !bare.hasPrefix("127.")
        }
    }

    /// Trimmed and lowercased, or `nil` for `nil`/blank input — so every
    /// parser above can compare against lowercase literals and treat empty
    /// output as no answer rather than as a negative one.
    private static func normalise(_ output: String?) -> String? {
        guard let output else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
