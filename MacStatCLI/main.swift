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
