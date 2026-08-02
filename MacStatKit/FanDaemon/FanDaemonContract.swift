import Foundation

// MARK: - The privileged fan daemon's contract (fan-control plan §4.2, §8)
//
// **Read this before anything else in `MacStatKit/FanDaemon/`.**
//
// Phase 3 is the write path, and the write path is a *root process*. The
// spike (`docs/fan-control-spike.md`) measured that SMC fan keys carry the
// writable attribute bit but that macOS refuses the write to an
// unprivileged process on Apple Silicon. Closing that gap means an
// `SMAppService` LaunchDaemon running as uid 0 for as long as Sentry is
// controlling a fan. That is a materially different kind of code from the
// rest of this app, and this directory is written to that standard:
//
//   1. **Everything in this directory is pure.** No IOKit, no XPC objects,
//      no `SMAppService`, no file I/O, no clocks it doesn't take as a
//      parameter. Every decision the daemon makes that could be wrong in a
//      dangerous way — what RPM to clamp a request to, when to hand the
//      fans back to the firmware, whether to talk to a caller at all — is
//      expressed here as a function over values, so it can be tested
//      exhaustively on a machine where the daemon itself cannot even be
//      registered. See this file's "What cannot be tested here" note.
//
//   2. **These files are compiled into *two* binaries.** `MacStatKit`
//      (so the app can reason about the same rules) and the
//      `SentryFanDaemon` tool target (so the root process enforces them).
//      The daemon deliberately does *not* link `MacStatKit.framework` —
//      it compiles this handful of files directly, the same technique
//      `MacStatKit_watchOS` already uses in `project.yml`. A root binary
//      whose entire compile surface is "Foundation plus six pure files
//      plus its own SMC writer" is a much smaller thing to audit than one
//      that drags in GRDB, the MCP SDK and SwiftNIO.
//
//   3. **The vocabulary is closed.** `FanDaemonCommand` below has exactly
//      three cases and no case carries an SMC key name or a raw byte
//      payload. A client cannot ask this daemon to write `CH0B` or to poke
//      an arbitrary address; it can ask for a target RPM on a fan ordinal,
//      ask for firmware control back, or ask what the daemon sees. Anything
//      the daemon can do that is not one of those three is a bug in the
//      daemon, not a request from a client.
//
// **What cannot be tested here, stated up front so no reader assumes
// otherwise.** `SMAppService.daemon(plistName:)` registration requires the
// daemon binary to be signed with the same *real* Team ID as the app and
// the app to satisfy the daemon's `SMAuthorizedClients` designated
// requirement. The machine this was written on has zero code-signing
// identities (`security find-identity -v -p codesigning` → 0 valid
// identities), so registration fails there by construction, the Mach
// service is never published, and no XPC connection is ever established.
// Consequently: the SMC *write* itself, the end-to-end XPC round trip, the
// real `SecCodeCheckValidity` verdict against a real signed client, and
// launchd's behavior on daemon exit have **never been observed**. What has
// been observed is that with no registered daemon the app behaves exactly
// as it did in Phase 2 — live RPM, every write control disabled and
// explained — which is what makes this safe to land before certificates
// exist. See `PrivilegedFanControlBackend`'s doc comment for the inert
// path, and `docs/fan-control-spike.md` for the first-run checklist.

#if os(macOS)

/// Names both halves of the daemon must agree on, in one place so a typo
/// cannot silently produce "the daemon is installed but nothing can reach
/// it" — the same hoisting `MacStatXPCServiceName` does for the MCP
/// listener.
public enum FanDaemonNaming {

    /// The launchd job label, the Mach service name, and the basename of
    /// the property list in `Sentry.app/Contents/Library/LaunchDaemons/`.
    ///
    /// `SMAppService.daemon(plistName:)` looks the plist up by *file name*
    /// inside that directory, and launchd requires the plist's `Label` to
    /// equal the file's basename without the extension. Deriving all three
    /// from one constant is the only way to keep them in step; they were
    /// three separate literals in the first draft and drifted within an
    /// hour.
    public static let label = "dev.malekswilam.macstat.fandaemon"

    /// `…/Contents/Library/LaunchDaemons/<this>`. Passed verbatim to
    /// `SMAppService.daemon(plistName:)`.
    public static var plistName: String { "\(label).plist" }

    /// The `MachServices` key the daemon publishes and the client dials.
    public static var machService: String { label }
}

/// Timings the daemon's fail-safe depends on. Shared rather than duplicated
/// because the client's send interval and the daemon's expiry window are
/// two halves of one agreement: if the client ever sends less often than
/// the daemon expires, every user gets a fan that snaps back to firmware
/// control every few seconds and no test on either side alone would catch
/// it.
public enum FanDaemonTiming {

    /// How often a client that currently holds a fan must say so.
    public static let heartbeatInterval: TimeInterval = 5

    /// How long the daemon waits, hearing nothing, before deciding the
    /// client is gone and handing every fan back to the firmware.
    ///
    /// Three missed heartbeats rather than one. A single missed beat is
    /// routine — the app's main actor can be busy behind a modal sheet, a
    /// spinning beachball, or a `runModal` confirmation — and reverting on
    /// it would make manual control feel like it randomly gives up. Three
    /// is long enough to be certain and short enough that a crashed app
    /// leaves the fans wrong for at most fifteen seconds.
    public static let heartbeatTimeout: TimeInterval = 15

    /// How long the daemon stays alive with **no connected client at all**
    /// before exiting on its own.
    ///
    /// This is the load-bearing mitigation for the uninstall problem (see
    /// `FanDaemonFailSafe`'s doc comment): a daemon that outlives the app
    /// — because the user dragged Sentry to the Trash without unregistering
    /// it — reverts the fans and then *exits*, rather than sitting at uid 0
    /// forever waiting for a client that will never come back.
    public static let idleExitAfter: TimeInterval = 60
}

/// The daemon's entire command vocabulary (safety requirement 2).
///
/// **Not a wire type.** `NSXPCConnection` requires an `@objc` protocol, so
/// what actually crosses the boundary is the three plainly-typed methods on
/// `FanDaemonProtocol` — an `Int` fan ordinal and a `Double` RPM, both of
/// which the daemon re-validates. This enum exists so the *set* of things
/// the daemon can be asked to do is nameable, exhaustively switchable, and
/// printable in a log line, and so a fourth capability cannot be added
/// without a reviewer seeing a new case appear here.
///
/// Note what is absent and must stay absent: there is no `writeKey(_:_:)`,
/// no `readKey(_:)`, no "set fan mode to an arbitrary value". The daemon
/// writes exactly two SMC keys per fan (`F{i}Tg`, `F{i}Md`) and the values
/// it writes are computed by the daemon, not supplied by the client.
public enum FanDaemonCommand: Equatable, Sendable {
    /// Take control of one fan and hold it at an RPM the *daemon* clamps.
    case setTarget(fanIndex: Int, requestedRPM: Double)
    /// Hand one fan back to the firmware (`F{i}Md = 0`).
    case returnToFirmware(fanIndex: Int)
    /// Report fan count, per-fan hardware limits, and which fans the daemon
    /// currently holds. Read-only.
    case describe

    /// For log lines. Deliberately includes the *requested* RPM, not the
    /// clamped one — a log that only records what was written cannot show
    /// that a client asked for something outrageous.
    public var logSummary: String {
        switch self {
        case .setTarget(let index, let rpm):
            return "setTarget(fan: \(index), requested: \(Int(rpm.rounded())) rpm)"
        case .returnToFirmware(let index):
            return "returnToFirmware(fan: \(index))"
        case .describe:
            return "describe"
        }
    }
}

/// Everything the daemon can refuse or fail with, as values rather than
/// strings, so the app can react differently to "your build isn't allowed
/// to talk to this daemon" than to "that fan doesn't exist."
///
/// Crosses the XPC boundary as its `message` (an `@objc` protocol cannot
/// carry a Swift enum), but is reconstructed nowhere — the app treats the
/// message as opaque display text. That is deliberate: a client that
/// branched on a parsed reason string would be trusting the daemon's
/// wording, and the only decisions the app makes on the daemon's behalf are
/// already encoded in `FanWriteAvailability`.
public enum FanDaemonRefusal: Equatable, Sendable {
    case unknownFan(index: Int)
    case limitsUnreadable(index: Int)
    case limitsNonsensical(index: Int, minRPM: Double, maxRPM: Double)
    case requestNotFinite
    case smcWriteFailed(key: String)
    case peerRejected(reason: String)

    public var message: String {
        switch self {
        case .unknownFan(let index):
            return "This Mac has no fan \(index + 1)."
        case .limitsUnreadable(let index):
            return "The SMC wouldn't report fan \(index + 1)'s speed range, so there is nothing safe to clamp a request against. Refusing rather than writing an unbounded value."
        case .limitsNonsensical(let index, let minRPM, let maxRPM):
            return "The SMC reported fan \(index + 1)'s range as \(Int(minRPM.rounded()))–\(Int(maxRPM.rounded())) rpm, which cannot be right. Refusing rather than trusting it."
        case .requestNotFinite:
            return "That speed isn't a real number."
        case .smcWriteFailed(let key):
            return "The SMC refused the write to \(key)."
        case .peerRejected(let reason):
            return "Sentry's fan helper refused this connection: \(reason)"
        }
    }
}

#endif
