import Foundation
import SentryKit

// SentryCLI ("sentryctl") — a plain shell CLI reusing the same
// `SentryXPCClient` connection code `SentryMCP` uses, with no MCP client
// required. Usable directly from a shell hook, a `Makefile`, a CI runner
// script on a Mac build box, or a terminal-agent tool that prefers shelling
// out over an MCP round-trip. See Sentry-AI-Features-Research.md item #13.
//
// Also doubles as the Claude Code `PreToolUse` hook package (item #3):
// `sentry hook pretooluse` is meant to be wired into `.claude/settings.json`
// directly — see `integrations/claude-code/README.md` (this repo) for the
// exact hook config and install steps.

let arguments = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    let usage = """
    sentry — talk to a running Sentry.app from the shell.

    USAGE:
        sentryctl check [--json]
            One-shot preflight verdict (thermal, CPU, battery, memory,
            other agent sessions): proceed, caution, wait, or do_not_start.
            Exit code 0 for proceed/caution, 1 otherwise — usable directly
            as a shell guard:
                sentryctl check || echo "not a great time to build"

        sentry wait --until=<condition> [--timeout=<seconds>]
            Blocks until <condition> holds or the timeout elapses.
            <condition> is one of: ready (check's own policy),
            thermal_normal, cpu_below:N, battery_above:N, memory_below:N.
            Exit code 0 if satisfied before the timeout, 1 if it timed out.

        sentry hook pretooluse
            Claude Code `PreToolUse` hook entry point: reads nothing from
            stdin, calls `check` internally, and exits 0 (allow) or 2 (deny,
            with a reason on stderr) per Claude Code's documented hook
            contract. See integrations/claude-code/README.md for the
            .claude/settings.json wiring.

        sentryctl status
            Prints the current thermal/CPU/battery snapshot as JSON.

        sentryctl watch --metric <id> [--interval 1s]
            Streams one JSON object per line (NDJSON) until killed — a
            proper streaming primitive, safe to pipe into `head`, `jq
            --unbuffered`, or a log file:
                sentryctl watch --metric cpu.total_percent --interval 2s | jq .value
            `--list-metrics` prints every streamable ID and its unit.
            Sentry's MCP rate limit (Settings → AI Access, 20/min by
            default) applies; `watch` widens its own interval when it is
            hit and reports the new cadence on stderr and in each line's
            `intervalSeconds`.

        sentryctl statusline [--format compact|plain|tmux|nerdfont]
            One short line for a tmux status bar, a Starship prompt, or
            Claude Code's status line. Gives up on Sentry after 50ms and
            falls back to the last reading it saw, labeled with its age —
            a slow prompt is worse than a stale one. Exit 0 whenever a
            line was printed, 124 when the timeout hit with nothing
            cached. See docs/integrations/ for copy-pasteable configs.

        sentry session-report --since=<seconds> [--json]
            Aggregated CPU/thermal/memory "cost" summary over the last
            <seconds> — meant to be called from a Claude Code `Stop` hook to
            enrich a completion notification with real resource context.

        sentryctl sessions [--json]
            Lists MCP clients that have called this Mac recently (same
            "active" window `get_agent_capacity` uses) — client name, last
            call, and whether it holds the keep-awake assertion. Headless
            equivalent of Settings → AI Access → Agents.

        sentryctl stop <client-name>
            Revokes a client by its self-reported name: denies further calls
            made under that name and releases any keep-awake hold it started
            — same mechanism as the "Stop" button in Settings → AI Access →
            Agents. Exit code 0 if the client was active and got stopped, 1
            with an explanation on stderr otherwise (no such active client,
            or it was already stopped). Client names are self-reported, not
            verified identities — see `sentryctl sessions` for the exact,
            case-sensitive spelling to pass.
    """
    FileHandle.standardError.write((usage + "\n").data(using: .utf8) ?? Data())
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("sentryctl: " + message + "\n").data(using: .utf8) ?? Data())
    exit(1)
}

func flagValue(_ name: String, in args: [String]) -> String? {
    let prefix = "--\(name)="
    return args.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
}

/// `--name=value` (what `check`/`wait`/`session-report` have always used) or
/// `--name value` (what plan §21.2.1 writes for the newer commands:
/// `sentryctl watch --metric cpu.total_percent`, `--format compact`).
///
/// Both spellings are accepted for every option rather than picking one,
/// because the two halves of this CLI's documented surface already disagree
/// — §21.2.1's tables use the space form throughout while the shipped
/// commands and `integrations/claude-code/README.md` use the `=` form — and
/// a user who copies a snippet from the wrong page should get their answer,
/// not a usage error. Accepting both costs three lines; rejecting one costs
/// a support conversation.
///
/// A trailing `--name` with nothing after it returns `nil`, the same as an
/// absent flag. That is deliberate: callers report "missing required
/// `--name`" either way, which is the accurate message for `sentryctl watch
/// --metric` typed without an argument.
func optionValue(_ name: String, in args: [String]) -> String? {
    if let joined = flagValue(name, in: args) { return joined }
    guard let index = args.firstIndex(of: "--\(name)"), args.index(after: index) < args.endIndex else {
        return nil
    }
    let next = args[args.index(after: index)]
    // `sentryctl statusline --format --json` should complain about a missing
    // format, not silently adopt "--json" as one.
    return next.hasPrefix("--") ? nil : next
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
        fail("failed to encode response")
    }
    print(text)
}

let xpcClient = SentryXPCClient()
let clientName = "sentryctl"

/// Decodes `preflight_check`'s `AgentPreflight.Assessment` — the tool moved
/// from `SystemAdvisor.Recommendation`'s binary go/wait to the four-level
/// verdict contract, and this CLI (per plan §21.2.1's standing rule) decodes
/// the *same* Codable model the MCP tool serves rather than a private copy.
func runCheck(json: Bool) async -> AgentPreflight.Assessment {
    let (data, message) = await xpcClient.readCall { $0.preflightCheck(clientName: clientName, reply: $1) }
    guard let data else {
        fail(message ?? "Sentry denied this request. Is Sentry running, and is the preflight_check MCP tool enabled in Settings → AI Access?")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let assessment = try? decoder.decode(AgentPreflight.Assessment.self, from: data) else {
        fail("couldn't decode Sentry's response")
    }
    if json {
        printJSON(assessment)
    } else if assessment.reasons.isEmpty {
        print("proceed — no reason to wait right now.")
    } else {
        print(assessment.verdict.rawValue + " — " + assessment.reasons.map(\.message).joined(separator: " "))
    }
    return assessment
}

/// `proceed` and `caution` both exit 0: caution means "start, but expect
/// contention/slowness", which for a go/no-go exit code is a go — the
/// distinction is in the printed reasons/JSON for callers who care.
func isGo(_ assessment: AgentPreflight.Assessment) -> Bool {
    assessment.verdict == .proceed || assessment.verdict == .caution
}

func runWait(condition: String, timeoutSeconds: Double) async -> MCPPayloads.WaitResult {
    let (data, message) = await xpcClient.readCall {
        $0.waitUntilReady(clientName: clientName, condition: condition, timeoutSeconds: timeoutSeconds, reply: $1)
    }
    guard let data else {
        fail(message ?? "Sentry denied this request. Is Sentry running, and is the wait_until_ready MCP tool enabled in Settings → AI Access?")
    }
    guard let result = try? JSONDecoder().decode(MCPPayloads.WaitResult.self, from: data) else {
        fail("couldn't decode Sentry's response")
    }
    if result.satisfied {
        print("ready — waited \(Int(result.waitedSeconds))s.")
    } else {
        print("timed out after \(Int(result.waitedSeconds))s — condition never satisfied.")
    }
    return result
}

func runSessionReport(sinceSeconds: Double, json: Bool) async {
    let (data, message) = await xpcClient.readCall {
        $0.getSessionResourceReport(clientName: clientName, sinceSeconds: sinceSeconds, reply: $1)
    }
    guard let data else {
        fail(message ?? "Sentry denied this request. Is Sentry running, and is the get_session_resource_report MCP tool enabled in Settings → AI Access?")
    }
    guard let report = try? JSONDecoder().decode(MCPPayloads.SessionResourceReport.self, from: data) else {
        fail("couldn't decode Sentry's response")
    }
    if json {
        printJSON(report)
    } else {
        var parts: [String] = []
        if let avg = report.averageCPUPercent, let peak = report.peakCPUPercent {
            parts.append("CPU avg \(Int(avg))% / peak \(Int(peak))%")
        }
        if let peakTemp = report.peakSoCTemperatureCelsius {
            parts.append("peak SoC \(Int(peakTemp))°C")
        }
        if report.secondsThrottling > 0 {
            parts.append("throttled for ~\(Int(report.secondsThrottling))s")
        }
        if report.alertsFired > 0 {
            parts.append("\(report.alertsFired) alert(s) fired")
        }
        print(parts.isEmpty ? "No resource data for this window." : parts.joined(separator: ", "))
    }
}

/// `sentryctl sessions` — see `SentryXPCServiceProtocol.listAgentSessions`'s
/// doc comment for why this XPC call carries no `clientName` of its own and
/// isn't gated by `MCPAccessController` the way every other call in this
/// file is.
func runSessions(json: Bool) async {
    let (data, message) = await xpcClient.readCall { $0.listAgentSessions(reply: $1) }
    guard let data else {
        fail(message ?? "Sentry didn't answer. Is Sentry running?")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let sessions = try? decoder.decode([MCPPayloads.AgentSessionInfo].self, from: data) else {
        fail("couldn't decode Sentry's response")
    }
    if json {
        printJSON(sessions)
        return
    }
    if sessions.isEmpty {
        print("No active agent sessions.")
        return
    }
    for session in sessions.sorted(by: { $0.lastCallAt > $1.lastCallAt }) {
        print(AgentSessionCLI.formatSessionLine(session))
    }
}

/// `sentryctl stop <client-name>` — revokes via
/// `SentryXPCServiceProtocol.revokeAgentSession`, which mirrors
/// `AIAccessPane`'s own per-agent "Stop" button exactly (see that method's
/// doc comment). Returns whether the revocation happened, matching this
/// CLI's exit-code convention of 0 for "did the thing", 1 otherwise.
func runStop(clientName: String) async -> Bool {
    let (ok, message) = await xpcClient.writeCall { $0.revokeAgentSession(clientName: clientName, reply: $1) }
    if ok {
        print("Stopped \"\(clientName)\" — released its keep-awake hold (if any) and denied further calls under that name.")
    } else {
        fail(message ?? "couldn't stop \"\(clientName)\".")
    }
    return ok
}

func runStatus() async {
    let (data, message) = await xpcClient.readCall { $0.getSystemSnapshot(clientName: clientName, reply: $1) }
    guard let data else {
        fail(message ?? "Sentry denied this request. Is Sentry running?")
    }
    guard let text = String(data: data, encoding: .utf8) else {
        fail("couldn't decode Sentry's response")
    }
    print(text)
}

// MARK: - stdout discipline (plan §21.5, the `gh` CLI row)
//
// "stdout is always the data, stderr is always human diagnostics, nothing
// else touches stdout. This is what makes a CLI pipeable without surprises."
// `print()` honors that on its own — the reason this exists is the *other*
// half of being a good pipeline citizen, which `print()` gets wrong.
//
// **SIGPIPE.** `sentryctl watch | head -3` closes the read end after three
// lines. The default disposition of SIGPIPE terminates the process, so the
// shell reports exit status 141 and any `&&` after the pipeline does not
// run — for a command whose entire purpose is to be piped into something
// that stops reading, that is a bug, not a nicety. Ignoring the signal turns
// the fourth write into an `EPIPE` return value this code can see, and the
// honest response to "nobody is listening any more" is to stop and exit
// successfully, which is exactly what `head` users expect and what `yes`,
// `seq` and friends do.
//
// **Partial writes and EINTR.** `write(2)` on a pipe may write fewer bytes
// than asked (a full pipe buffer plus a small `PIPE_BUF`-exceeding line) and
// may return `EINTR` on any signal. `FileHandle.write` raises an
// Objective-C exception on failure, which is not catchable in Swift and
// would abort the process; `print()` buffers through stdio, which means a
// line can sit unwritten while a consumer waits. A streaming command must
// neither crash nor buffer, so both are avoided in favor of the raw loop.
enum Stdout {

    /// Installs the SIGPIPE disposition this writer depends on. Called only
    /// from the streaming path rather than at process start, so the
    /// pre-existing commands' `print()`-and-die-on-EPIPE behavior is left
    /// exactly as it was — this change should not silently alter what
    /// `sentryctl status | head -1` does today.
    static func ignoreSIGPIPE() {
        signal(SIGPIPE, SIG_IGN)
    }

    /// Writes `text` followed by a newline, looping until every byte is
    /// gone. Exits 0 on `EPIPE`; exits 1 with a diagnostic on anything else.
    static func writeLine(_ text: String) {
        var bytes = Array((text + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                write(1, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            switch errno {
            case EINTR:
                // A signal arrived mid-write. Nothing was lost; retry.
                continue
            case EPIPE:
                // The downstream reader is gone (`| head`, a closed tmux
                // pane). There is nothing left to say and no failure to
                // report — the consumer got what it asked for.
                exit(0)
            default:
                FileHandle.standardError.write(
                    ("sentryctl: couldn't write to stdout: \(String(cString: strerror(errno)))\n").data(using: .utf8) ?? Data()
                )
                exit(1)
            }
        }
        // Silence the "never mutated" warning while keeping `bytes` a var
        // so `withUnsafeBytes` sees a stable buffer for the whole loop.
        bytes.removeAll(keepingCapacity: false)
    }
}

func warn(_ message: String) {
    FileHandle.standardError.write(("sentryctl: " + message + "\n").data(using: .utf8) ?? Data())
}

/// One newline-delimited-JSON line: compact (no pretty-printing — NDJSON's
/// whole contract is one object per line), sorted keys so a diff of two
/// captured streams is about the values rather than key order, ISO-8601
/// dates to match every other `--json` surface in this CLI.
let ndjsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}()

let snapshotDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}()

// MARK: - sentryctl watch (plan §21.2.1, final row)

/// Whether a denial reply from the app is the rate limiter pushing back
/// rather than a permission decision.
///
/// **This matches on the message text, which is unquestionably fragile**, so
/// it is worth being precise about what breaks if it stops matching. The XPC
/// contract carries denials as `(nil, String?)` — `SentryXPCServiceProtocol`
/// explains why (`@objc` bridging leaves no room for a typed error), so the
/// reason genuinely is a human string and there is no `Decision` enum on
/// this side of the boundary to switch over. If `MCPXPCService`'s wording
/// changes, or the string is localized into a language without "rate limit"
/// in it, this returns `false` and `watch` exits immediately with the app's
/// real reason printed to stderr. That is the safe direction to fail: loud
/// and accurate, just less accommodating than it could be. The unsafe
/// direction — treating a permission denial as a transient rate limit and
/// retrying forever — is the one this ordering rules out.
func isRateLimitDenial(_ reason: String) -> Bool {
    reason.range(of: "rate limit", options: .caseInsensitive) != nil
}

func runWatch(metric: MetricID, requestedInterval: Double) async -> Never {
    Stdout.ignoreSIGPIPE()

    // The app's MCP rate limiter (`MCPAccessController`, default 20
    // calls/minute) counts read tools too, so `--interval 1s` asks for three
    // times the default budget. Rather than dying twenty seconds in, or —
    // far worse — quietly skipping samples, `watch` widens its own interval
    // on each rate-limit denial until the app stops refusing, and says so on
    // stderr. Every emitted line carries the interval actually used
    // (`MCPPayloads.MetricSample.intervalSeconds`), so a stream that settled
    // at 4s does not claim to be a 1s stream. The ceiling exists so a
    // misconfigured rate limit of 0 degrades to one sample a minute instead
    // of doubling into hours.
    let intervalCeiling: Double = 60
    var effectiveInterval = max(0, requestedInterval)
    var previousSampleAt: Date?

    while true {
        let (data, message) = await xpcClient.readCall { $0.getSystemSnapshot(clientName: clientName, reply: $1) }

        guard let data else {
            let reason = message ?? "Sentry didn't answer. Is Sentry running?"
            // A denial on the *first* sample is never backed off. It means
            // the app isn't running, or `get_system_snapshot` is disabled —
            // conditions that will not resolve by waiting, and where the
            // right behavior per this task's brief is to fail with an
            // actionable message rather than hang.
            guard previousSampleAt != nil, isRateLimitDenial(reason) else {
                fail(reason)
            }
            let widened = min(max(effectiveInterval * 2, 1), intervalCeiling)
            if widened > effectiveInterval {
                effectiveInterval = widened
                warn("rate-limited by Sentry; widening --interval to \(formatInterval(effectiveInterval)). Raise the limit in Settings → AI Access to stream faster.")
            }
            try? await Task.sleep(nanoseconds: UInt64(effectiveInterval * 1_000_000_000))
            continue
        }

        guard let snapshot = try? snapshotDecoder.decode(SystemSnapshot.self, from: data) else {
            fail("couldn't decode Sentry's snapshot — this `sentryctl` and Sentry.app are probably different versions.")
        }

        let value = snapshot.value(for: metric)
        let sample = MCPPayloads.MetricSample(
            timestamp: snapshot.timestamp,
            metric: metric.rawValue,
            unit: metric.unit.rawValue,
            value: value,
            // `value(for:)` returns nil for a metric this Mac (or this
            // build) genuinely cannot read — no GPU sample yet, no HID
            // thermal bridge, `cpu.user_percent` which the collector does
            // not split out. The line is still emitted, because a gap in a
            // stream is information; what is never emitted is a zero
            // standing in for it.
            available: value != nil,
            intervalSeconds: previousSampleAt.map { snapshot.timestamp.timeIntervalSince($0) }
        )
        previousSampleAt = snapshot.timestamp

        guard let line = try? ndjsonEncoder.encode(sample), let text = String(data: line, encoding: .utf8) else {
            fail("failed to encode sample")
        }
        Stdout.writeLine(text)

        try? await Task.sleep(nanoseconds: UInt64(effectiveInterval * 1_000_000_000))
    }
}

func formatInterval(_ seconds: Double) -> String {
    seconds == seconds.rounded() ? "\(Int(seconds))s" : String(format: "%.2fs", seconds)
}

// MARK: - sentryctl statusline (plan §21.3)

/// Resolves the theme the user actually picked, for `--format tmux`.
///
/// Reads `SettingsStore`'s JSON file directly instead of instantiating a
/// `SettingsStore`: that type is an `ObservableObject` with a debounced
/// write path and main-thread expectations, all of which exist for an app
/// that mutates settings. This process only ever reads, once, and must do it
/// inside a latency budget measured in milliseconds.
///
/// Every failure — no file, unreadable, corrupt, or a `themeID` naming a
/// theme this build doesn't have — resolves to `Theme.defaultTheme`. A
/// status line rendered in the default palette is a cosmetic miss; refusing
/// to render one because a settings file couldn't be parsed would be a
/// broken prompt.
func resolveTheme() -> Theme {
    guard let data = try? Data(contentsOf: SettingsStore.defaultSettingsURL()),
          let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
        return .defaultTheme
    }
    return Theme.builtInPresets.first { $0.id == settings.themeID } ?? .defaultTheme
}

enum StatuslineOutcome: Sendable {
    case answered(Data?, String?)
    case timedOut
}

/// Races the XPC call against a hard deadline and takes whichever finishes
/// first.
///
/// **Why a deadline is mandatory here and nowhere else in this CLI.** §21.5:
/// Starship's `command_timeout` exists because a prompt command that blocks
/// blocks the *shell*, and a developer will uninstall a tool that makes
/// their terminal feel slow long before they will investigate why. Every
/// other `sentryctl` command is invoked deliberately and may take as long as
/// the machine takes; `statusline` is invoked before every prompt, by a
/// program that is not prepared to wait, and a hung `Sentry.app` must
/// degrade this command rather than the user's shell.
///
/// The budget covers the XPC round trip only. It is not, and cannot be, a
/// budget for the whole process: dyld resolving `SentryKit.framework` and
/// the Swift runtime dominate startup and are already spent by the time this
/// function is entered. Callers integrating into a prompt should still set
/// their own outer timeout (Starship's `command_timeout`, documented in
/// `docs/integrations/starship.md`) — this budget makes the *common* slow
/// case fast, it does not make the process instantaneous.
///
/// Cancelling the losing task does not cancel an in-flight `NSXPCConnection`
/// reply — there is no cancellation in that API — but the process exits
/// within microseconds of this returning, so the abandoned reply is
/// collected by process teardown rather than leaking.
func snapshotWithinBudget(millis: Double) async -> StatuslineOutcome {
    await withTaskGroup(of: StatuslineOutcome.self) { group in
        group.addTask {
            let (data, message) = await xpcClient.readCall { $0.getSystemSnapshot(clientName: clientName, reply: $1) }
            return .answered(data, message)
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(max(0, millis) * 1_000_000))
            return .timedOut
        }
        let first = await group.next() ?? .timedOut
        group.cancelAll()
        return first
    }
}

/// Renders the most recent cached snapshot, explicitly labeled with its age,
/// or exits with `code` when there is nothing usable to fall back on.
///
/// The stale line goes to stdout and the reason goes to stderr, and the exit
/// status is 0 — because from the prompt's point of view this invocation
/// succeeded: it produced a line, and the line says how old it is. Reserving
/// a non-zero status for "I printed nothing" is what lets a tmux/Starship
/// config distinguish "Sentry is briefly busy" from "Sentry is gone."
func renderFromCacheOrExit(
    cache: StatuslineCache,
    format: StatuslineFormat,
    theme: Theme,
    reason: String,
    code: Int32
) -> Never {
    guard let entry = cache.load() else {
        warn(reason + " No recent reading cached either, so there is nothing to show.")
        exit(code)
    }
    let line = StatuslineRenderer.render(
        snapshot: entry.snapshot,
        theme: theme,
        format: format,
        staleBy: entry.age()
    )
    guard !line.isEmpty else {
        warn(reason + " The cached reading has no displayable metrics.")
        exit(code)
    }
    warn(reason + " Showing the last reading instead, marked with its age.")
    Stdout.writeLine(line)
    exit(0)
}

func runStatusline(format: StatuslineFormat, budgetMillis: Double) async -> Never {
    let cache = StatuslineCache()
    // Only `--format tmux` consults the theme, and resolving it is a file
    // read on a latency-budgeted path. Skipping it for the other three
    // formats is not a micro-optimization for its own sake — it is one
    // fewer thing that can be slow or fail on the prompt path.
    let theme = format == .tmux ? resolveTheme() : Theme.defaultTheme

    switch await snapshotWithinBudget(millis: budgetMillis) {

    case .timedOut:
        renderFromCacheOrExit(
            cache: cache,
            format: format,
            theme: theme,
            reason: "Sentry didn't answer within \(Int(budgetMillis))ms.",
            // 124, matching `timeout(1)` and §21.2's convention. §21.2.1's
            // table says `statusline` exits 0 "always"; that describes the
            // path where a line was produced, which includes the stale
            // fallback above. Exiting 0 having printed *nothing* would tell
            // a caller "success" about an invocation that gave it no data,
            // and 124 is precisely the established word for why.
            code: 124
        )

    case .answered(nil, let message):
        let reason = message ?? "Sentry didn't answer."
        // `SentryXPCClient` prefixes every connection-level failure with
        // this phrase; anything else came back from `MCPXPCService`'s
        // permission gate. The phrase is a constant rather than the string
        // literal it used to be here — it was matched in two files and
        // nothing would have failed if the wording drifted, which for a
        // branch that decides whether to show possibly-stale telemetry is
        // not a good property.
        if reason.hasPrefix(SentryXPCClient.unreachablePrefix) {
            renderFromCacheOrExit(cache: cache, format: format, theme: theme, reason: reason, code: 1)
        }
        // A permission denial is *not* eligible for the cache fallback. If
        // the user has just turned MCP access off in Settings → AI Access,
        // continuing to render telemetry out of a file on disk would route
        // around the decision they made rather than reflect it, so the
        // cached copy is destroyed here as well as ignored.
        cache.discard()
        warn(reason)
        exit(1)

    case .answered(.some(let data), _):
        guard let snapshot = try? snapshotDecoder.decode(SystemSnapshot.self, from: data) else {
            fail("couldn't decode Sentry's snapshot — this `sentryctl` and Sentry.app are probably different versions.")
        }
        cache.store(snapshot)
        let line = StatuslineRenderer.render(snapshot: snapshot, theme: theme, format: format, staleBy: nil)
        guard !line.isEmpty else {
            // Reached Sentry, got a snapshot, and it contained no battery,
            // no CPU and no temperature — which happens in the first
            // second or two after launch, before the first sampling tick.
            // Printing an empty line would be indistinguishable from a
            // working status line on an idle machine.
            warn("Sentry has no readable metrics yet — it may have just launched.")
            exit(1)
        }
        Stdout.writeLine(line)
        exit(0)
    }
}

guard let command = arguments.first else {
    printUsage()
    exit(64) // EX_USAGE
}

switch command {
case "check":
    let json = arguments.contains("--json")
    let assessment = await runCheck(json: json)
    exit(isGo(assessment) ? 0 : 1)

case "wait":
    guard let condition = flagValue("until", in: arguments) else {
        fail("missing --until=<condition> (ready, thermal_normal, cpu_below:N, battery_above:N, memory_below:N)")
    }
    let timeoutSeconds = flagValue("timeout", in: arguments).flatMap(Double.init) ?? 120
    let result = await runWait(condition: condition, timeoutSeconds: timeoutSeconds)
    exit(result.satisfied ? 0 : 1)

case "status":
    await runStatus()
    exit(0)

case "watch":
    if arguments.contains("--list-metrics") {
        // Fifty-odd lines into a `| head -5` or `| fzf` is the same closed
        // pipe `watch` itself has to survive, so this branch installs the
        // same signal disposition rather than relying on being short.
        Stdout.ignoreSIGPIPE()
        // stdout, because this is data: `sentryctl watch --list-metrics |
        // fzf` is the obvious use, and it is the fastest way to find the
        // exact spelling of an ID without opening the plan's Appendix A.
        for metric in MetricID.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            Stdout.writeLine("\(metric.rawValue)\t\(metric.unit.rawValue)")
        }
        exit(0)
    }
    guard let rawMetric = optionValue("metric", in: arguments) else {
        fail("missing --metric <id>. Run `sentryctl watch --list-metrics` to see them all.")
    }
    guard let metric = MetricID(rawValue: rawMetric) else {
        // Appendix A's templated IDs (`cpu.core.3_percent`,
        // `thermal.fan_0_rpm`) are constructed strings, not `MetricID`
        // cases, and `SystemSnapshot.value(for:)` — the only thing that can
        // read a metric out of a snapshot — takes a `MetricID`. So they are
        // genuinely unsupported here rather than merely unlisted, and
        // saying so is better than a bare "unknown metric" that sends
        // someone hunting for a typo they didn't make.
        if rawMetric.hasPrefix("cpu.core.") || rawMetric.hasPrefix("thermal.fan_") {
            fail("`\(rawMetric)` is a per-core/per-fan metric, which `watch` can't stream — only the enumerable metrics in `sentryctl watch --list-metrics` can be read out of a snapshot.")
        }
        fail("unknown metric `\(rawMetric)`. Run `sentryctl watch --list-metrics` to see them all.")
    }
    let rawInterval = optionValue("interval", in: arguments) ?? "1s"
    guard let interval = CLIDuration.seconds(rawInterval), interval > 0 else {
        fail("couldn't read --interval `\(rawInterval)` — expected \(CLIDuration.acceptedFormsDescription), greater than zero.")
    }
    await runWatch(metric: metric, requestedInterval: interval)

case "statusline":
    let rawFormat = optionValue("format", in: arguments) ?? StatuslineFormat.compact.rawValue
    guard let format = StatuslineFormat(rawValue: rawFormat) else {
        fail("unknown --format `\(rawFormat)` — expected one of: " + StatuslineFormat.allCases.map(\.rawValue).joined(separator: ", ") + ".")
    }
    // Overridable purely so the degraded path is exercisable end-to-end
    // (`--timeout-ms=0` forces it) rather than only reachable when the
    // machine happens to be wedged. A path that cannot be demonstrated is a
    // path nobody has actually seen work.
    let rawBudget = optionValue("timeout-ms", in: arguments) ?? "50"
    guard let budget = Double(rawBudget), budget.isFinite, budget >= 0 else {
        fail("couldn't read --timeout-ms `\(rawBudget)` — expected a non-negative number of milliseconds.")
    }
    await runStatusline(format: format, budgetMillis: budget)

case "session-report":
    let sinceSeconds = flagValue("since", in: arguments).flatMap(Double.init) ?? 3600
    await runSessionReport(sinceSeconds: sinceSeconds, json: arguments.contains("--json"))
    exit(0)

case "sessions":
    await runSessions(json: arguments.contains("--json"))
    exit(0)

case "stop":
    guard let target = AgentSessionCLI.stopTargetClientName(from: arguments) else {
        fail("missing <client-name>. Run `sentryctl sessions` to see active clients.")
    }
    let stopped = await runStop(clientName: target)
    exit(stopped ? 0 : 1)

case "hook":
    guard arguments.count > 1, arguments[1] == "pretooluse" else {
        printUsage()
        exit(64)
    }
    let assessment = await runCheck(json: false)
    if isGo(assessment) {
        exit(0)
    } else {
        // Claude Code's documented `PreToolUse` contract: exit code 2 denies
        // the pending tool call and feeds stderr back to the model as
        // context, which is exactly what should happen here — "Mac is at
        // 101°C, thermal pressure critical" is more useful to the model
        // than a bare non-zero exit.
        FileHandle.standardError.write((assessment.reasons.map(\.message).joined(separator: " ") + "\n").data(using: .utf8) ?? Data())
        exit(2)
    }

case "-h", "--help", "help":
    printUsage()
    exit(0)

default:
    printUsage()
    exit(64)
}
