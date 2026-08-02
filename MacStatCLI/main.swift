import Foundation
import MacStatKit

// MacStatCLI ("macstat") — a plain shell CLI reusing the same
// `MacStatXPCClient` connection code `MacStatMCP` uses, with no MCP client
// required. Usable directly from a shell hook, a `Makefile`, a CI runner
// script on a Mac build box, or a terminal-agent tool that prefers shelling
// out over an MCP round-trip. See MacStat-AI-Features-Research.md item #13.
//
// Also doubles as the Claude Code `PreToolUse` hook package (item #3):
// `macstat hook pretooluse` is meant to be wired into `.claude/settings.json`
// directly — see `integrations/claude-code/README.md` (this repo) for the
// exact hook config and install steps.

let arguments = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    let usage = """
    macstat — talk to a running MacStat.app from the shell.

    USAGE:
        macstat check [--json]
            One-shot go/wait recommendation (thermal, CPU, battery). Exit
            code 0 if "go", 1 if "wait" — usable directly as a shell guard:
                macstat check || echo "not a great time to build"

        macstat wait --until=<condition> [--timeout=<seconds>]
            Blocks until <condition> holds or the timeout elapses.
            <condition> is one of: thermal_normal, cpu_below:N,
            battery_above:N, memory_below:N. Exit code 0 if satisfied before
            the timeout, 1 if it timed out.

        macstat hook pretooluse
            Claude Code `PreToolUse` hook entry point: reads nothing from
            stdin, calls `check` internally, and exits 0 (allow) or 2 (deny,
            with a reason on stderr) per Claude Code's documented hook
            contract. See integrations/claude-code/README.md for the
            .claude/settings.json wiring.

        macstat status
            Prints the current thermal/CPU/battery snapshot as JSON.

        macstat watch [--interval=<seconds>] [--count=<n>] [--timeout=<seconds>]
            Streams snapshots to stdout as newline-delimited JSON — one
            compact object per line, nothing else on stdout, ever — until
            Ctrl-C, or after --count snapshots. --interval defaults to 2
            (minimum 0.5). --timeout is an overall wall-clock deadline;
            hitting it exits 124, matching timeout(1). Connection loss (app
            not running, app quit mid-stream) exits 1 with one line on
            stderr. Pipe-friendly by construction:
                macstat watch --interval=1 | jq .cpu.totalPercent

        macstat statusline [--segments=cpu,mem,battery] [--color]
            One compact line for tmux/Starship/Claude Code status lines,
            e.g. "cpu 42% · mem 12.6G · 89%⚡". Segments render in the
            order given; unavailable readings render as "—", never a fake
            zero. Plain text by default; --color opts into ANSI color for
            attention states only.

        macstat session-report --since=<seconds> [--json]
            Aggregated CPU/thermal/memory "cost" summary over the last
            <seconds> — meant to be called from a Claude Code `Stop` hook to
            enrich a completion notification with real resource context.
    """
    FileHandle.standardError.write((usage + "\n").data(using: .utf8) ?? Data())
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("macstat: " + message + "\n").data(using: .utf8) ?? Data())
    exit(1)
}

func flagValue(_ name: String, in args: [String]) -> String? {
    let prefix = "--\(name)="
    return args.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
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

let xpcClient = MacStatXPCClient()
let clientName = "macstat CLI"

func runCheck(json: Bool) async -> SystemAdvisor.Recommendation {
    let (data, message) = await xpcClient.readCall { $0.preflightCheck(clientName: clientName, reply: $1) }
    guard let data else {
        fail(message ?? "MacStat denied this request. Is MacStat running, and is the preflight_check MCP tool enabled in Settings → AI Access?")
    }
    guard let recommendation = try? JSONDecoder().decode(SystemAdvisor.Recommendation.self, from: data) else {
        fail("couldn't decode MacStat's response")
    }
    if json {
        printJSON(recommendation)
    } else if recommendation.recommendation == "go" {
        print("go — no reason to wait right now.")
    } else {
        print("wait — " + recommendation.reasons.joined(separator: " "))
    }
    return recommendation
}

func runWait(condition: String, timeoutSeconds: Double) async -> MCPPayloads.WaitResult {
    let (data, message) = await xpcClient.readCall {
        $0.waitUntilReady(clientName: clientName, condition: condition, timeoutSeconds: timeoutSeconds, reply: $1)
    }
    guard let data else {
        fail(message ?? "MacStat denied this request. Is MacStat running, and is the wait_until_ready MCP tool enabled in Settings → AI Access?")
    }
    guard let result = try? JSONDecoder().decode(MCPPayloads.WaitResult.self, from: data) else {
        fail("couldn't decode MacStat's response")
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
        fail(message ?? "MacStat denied this request. Is MacStat running, and is the get_session_resource_report MCP tool enabled in Settings → AI Access?")
    }
    guard let report = try? JSONDecoder().decode(MCPPayloads.SessionResourceReport.self, from: data) else {
        fail("couldn't decode MacStat's response")
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

func runStatus() async {
    let (data, message) = await xpcClient.readCall { $0.getSystemSnapshot(clientName: clientName, reply: $1) }
    guard let data else {
        fail(message ?? "MacStat denied this request. Is MacStat running?")
    }
    guard let text = String(data: data, encoding: .utf8) else {
        fail("couldn't decode MacStat's response")
    }
    print(text)
}

/// `watch`: streams snapshots as NDJSON on stdout at a fixed cadence.
///
/// **stdout is data, stderr is diagnostics — absolutely.** Every byte on
/// stdout is a snapshot line; usage errors, connection failures, and the
/// timeout notice all go to stderr, so `macstat watch | consumer` never has
/// to filter banners out of its data stream.
///
/// **Cadence is drift-corrected, not sleep-chained.** Each tick sleeps
/// until `start + n × interval` rather than `interval` after the previous
/// emit, so XPC round-trip latency doesn't accumulate — a `--interval=2
/// --count=30` run spans ~60s of wall clock, not 60s-plus-thirty-RTTs.
/// When a fetch overruns the interval the next tick fires immediately
/// (sleep-until-past returns at once); ticks are late, never skipped, so
/// `--count` always yields exactly N lines.
///
/// **`--timeout` is a detached watchdog, not a per-iteration check,** so it
/// bounds even a hung XPC call: `MacStatXPCClient.readCall` resolves on
/// connection *errors*, but an app-side stall (beachballing main actor)
/// replies never, and a deadline checked only between iterations would
/// never fire. `exit(124)` matches `timeout(1)` so wrapper scripts can
/// tell "deadline hit" (124) from "connection lost" (1). Like timeout(1)'s
/// SIGTERM, the watchdog can in principle cut a line mid-write; consumers
/// of a deadline-killed stream must already tolerate a truncated tail, and
/// each line is a single write(2) so it takes the kernel preempting a
/// sub-KB write to ever observe one.
///
/// **Ctrl-C needs no handler.** Default SIGINT disposition kills the
/// process between writes or mid-sleep; every completed line is already
/// flushed because `FileHandle.write` is an unbuffered write(2) — unlike
/// `print`, whose libc FILE buffering would hold lines hostage for ~4KB
/// when stdout is a pipe, which for a slow-cadence stream means minutes of
/// invisible data.
func runWatch(options: CLIOptions.WatchOptions) async -> Never {
    if let timeout = options.timeoutSeconds {
        Task.detached {
            try? await Task.sleep(for: .seconds(timeout))
            FileHandle.standardError.write("macstat: watch reached --timeout after \(timeout)s\n".data(using: .utf8) ?? Data())
            exit(124)
        }
    }

    let clock = ContinuousClock()
    let start = clock.now
    var emitted = 0
    while true {
        let (data, message) = await xpcClient.readCall { $0.getSystemSnapshot(clientName: clientName, reply: $1) }
        guard let data else {
            fail(message ?? "MacStat denied this request. Is MacStat running?")
        }
        // NDJSONLine.make is a pass-through today (the app encodes
        // compactly) and re-flattens if that ever changes — see its doc
        // comment. nil means line breaks + unparseable, i.e. the payload
        // is corrupt; ending the stream beats emitting a malformed line.
        guard var line = NDJSONLine.make(from: data) else {
            fail("couldn't frame MacStat's response as a single NDJSON line")
        }
        line.append(0x0A)
        FileHandle.standardOutput.write(line)
        emitted += 1
        if let count = options.count, emitted >= count {
            exit(0)
        }
        try? await Task.sleep(until: start + .seconds(options.intervalSeconds) * emitted, clock: clock)
    }
}

/// `statusline`: one snapshot, one line, exit. The interesting logic —
/// segment selection, "—" honesty, color thresholds — all lives in
/// `StatuslineRenderer` (MacStatKit) where `MacStatTests` can reach it;
/// this shim only fetches, decodes, and prints.
func runStatusline(options: CLIOptions.StatuslineOptions) async {
    let (data, message) = await xpcClient.readCall { $0.getSystemSnapshot(clientName: clientName, reply: $1) }
    guard let data else {
        fail(message ?? "MacStat denied this request. Is MacStat running?")
    }
    let decoder = JSONDecoder()
    // MCPXPCService.encodeAndReply encodes dates as ISO-8601; the default
    // strategy (seconds-since-reference-date numbers) would throw on every
    // snapshot.
    decoder.dateDecodingStrategy = .iso8601
    guard let snapshot = try? decoder.decode(SystemSnapshot.self, from: data) else {
        fail("couldn't decode MacStat's response")
    }
    // A single `print` — exactly one line, one trailing newline. tmux
    // `#()`, Starship custom commands, and Claude Code's statusline all
    // strip a trailing newline; what breaks them is a *second* line, which
    // this cannot produce (the renderer never emits \n).
    print(StatuslineRenderer.render(snapshot: snapshot, segments: options.segments, colorized: options.color))
}

guard let command = arguments.first else {
    printUsage()
    exit(64) // EX_USAGE
}

switch command {
case "check":
    let json = arguments.contains("--json")
    let recommendation = await runCheck(json: json)
    exit(recommendation.recommendation == "go" ? 0 : 1)

case "wait":
    guard let condition = flagValue("until", in: arguments) else {
        fail("missing --until=<condition> (thermal_normal, cpu_below:N, battery_above:N, memory_below:N)")
    }
    let timeoutSeconds = flagValue("timeout", in: arguments).flatMap(Double.init) ?? 120
    let result = await runWait(condition: condition, timeoutSeconds: timeoutSeconds)
    exit(result.satisfied ? 0 : 1)

case "status":
    await runStatus()
    exit(0)

case "watch":
    switch CLIOptions.WatchOptions.parse(Array(arguments.dropFirst())) {
    case .success(let options):
        await runWatch(options: options)
    case .failure(let error):
        fail(error.message)
    }

case "statusline":
    switch CLIOptions.StatuslineOptions.parse(Array(arguments.dropFirst())) {
    case .success(let options):
        await runStatusline(options: options)
        exit(0)
    case .failure(let error):
        fail(error.message)
    }

case "session-report":
    let sinceSeconds = flagValue("since", in: arguments).flatMap(Double.init) ?? 3600
    await runSessionReport(sinceSeconds: sinceSeconds, json: arguments.contains("--json"))
    exit(0)

case "hook":
    guard arguments.count > 1, arguments[1] == "pretooluse" else {
        printUsage()
        exit(64)
    }
    let recommendation = await runCheck(json: false)
    if recommendation.recommendation == "go" {
        exit(0)
    } else {
        // Claude Code's documented `PreToolUse` contract: exit code 2 denies
        // the pending tool call and feeds stderr back to the model as
        // context, which is exactly what should happen here — "Mac is at
        // 101°C, thermal pressure critical" is more useful to the model
        // than a bare non-zero exit.
        FileHandle.standardError.write((recommendation.reasons.joined(separator: " ") + "\n").data(using: .utf8) ?? Data())
        exit(2)
    }

case "-h", "--help", "help":
    printUsage()
    exit(0)

default:
    printUsage()
    exit(64)
}
