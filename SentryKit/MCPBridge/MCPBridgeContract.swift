import Foundation

// MARK: - The MCP command-line bridge's contract
//
// **Read this before anything else in `SentryKit/MCPBridge/`.**
//
// ## The bug this directory exists to fix
//
// `AppDelegate` used to call `NSXPCListener(machServiceName:
// "dev.malekswilam.sentry.xpc")` and resume it, and nothing in the project
// ever told launchd that name existed — no `MachServices` key, no
// LaunchAgent, nothing. The listener was constructed, `resume()` returned
// without complaint, and every `sentryctl` invocation and every stdio-MCP tool
// call died with "Couldn't communicate with a helper application" *while
// Sentry was running and visibly healthy*. Two things made that failure
// expensive to diagnose: `NSXPCListener` reports a failed `bootstrap_check_in`
// nowhere at all, and the client's error message blamed the app not running.
//
// ## The measurement that fixed the design
//
// The obvious repair — "add a LaunchAgent with a `MachServices` key and keep
// the app's listener" — does not work, and it was worth ten minutes to prove
// that rather than ship it and find out. Declaring
// `dev.malekswilam.xpctest.svc` in a bootstrapped LaunchAgent and then
// running `xpc_connection_create_mach_service(…, XPC_CONNECTION_MACH_SERVICE_
// LISTENER)` from an unrelated process still fails with `Connection
// invalid`; the *same* binary, launched by launchd as that job, checks in
// successfully. So:
//
//     Only the process launchd itself started as the job may vend the job's
//     Mach service. Declaring the name is necessary and not sufficient.
//
// Sentry is started by the user from Finder, the Dock, or a login item —
// never by launchd as a `MachServices`-owning job — so **Sentry's own
// process can never vend this name**, no matter what plist ships beside it.
// (Making the app itself the LaunchAgent's program was considered and
// rejected: launchd would spawn a second copy of a menu-bar app every time a
// CLI invocation arrived, and a Finder-launched copy still could not check
// in.)
//
// ## What is here instead: a rendezvous broker, not a relay
//
// `SentryMCPBridge` is a small user-level LaunchAgent, launched on demand,
// that owns the Mach service and does exactly two things:
//
//   1. Sentry connects *out* to it at launch and hands it the endpoint of an
//      **anonymous** `NSXPCListener` (`NSXPCListener.anonymous()`), which
//      needs no launchd registration by design — that is the entire purpose
//      of anonymous listeners.
//   2. `sentryctl` / `SentryMCP` connect to it, ask for that endpoint, and
//      then open a **direct** `NSXPCConnection(listenerEndpoint:)` to Sentry.
//
// The bridge is therefore not on the data path. It never sees a snapshot, a
// tool call, or a client name; it brokers one handshake and gets out of the
// way. That is deliberate and load-bearing: a relay would have to
// re-implement all twenty-odd methods of `SentryXPCServiceProtocol`, would
// have to be revised every time one is added, and would become a second
// place where a permission decision could accidentally be made. The broker's
// entire vocabulary is `publish`, `withdraw`, `resolveAppEndpoint` — see
// `MCPBridgeProtocol`.
//
// This shape was verified end to end on a machine with **no** signing
// identities, by bootstrapping the equivalent three processes by hand with
// `launchctl bootstrap`: launchd on-demand-launched the broker on the first
// client connection, the app deposited its anonymous endpoint, the client
// resolved it and called a method on the app directly. What that experiment
// could not cover is the peer gate (below) and `SMAppService`.
//
// ## What cannot be verified without a Developer ID certificate
//
// Stated up front so no reader assumes otherwise. `SMAppService.agent(
// plistName:)` requires the agent binary to be signed with the same *real*
// Team ID as the app registering it. The machine this was written on has
// zero code-signing identities (`security find-identity -v -p codesigning` →
// "0 valid identities found"), so:
//
//   * `SMAppService.agent(...).register()` has **never succeeded** here.
//   * The Mach service has therefore never been published, no connection has
//     ever been brokered, and `SecCodeCheckValidity` has never returned
//     `errSecSuccess` against a real signed peer.
//
// What *has* been observed is the inert state, which is the property that
// makes this safe to merge before certificates exist: with the agent
// unregistered the app behaves exactly as it did before this change (menu
// bar, dashboard, history, alerts, and the HTTP MCP transport all unaffected
// — that transport never touched this path, see `LocalXPCServiceCaller`),
// nothing prompts for an administrator password at any point, and `sentryctl`
// fails with a message that names the *real* cause instead of the old
// "Is Sentry running?" misdirection.
//
// ## Two properties of this arrangement worth naming
//
// The shape is deliberate throughout: pure decision logic here,
// `SMAppService` registration driven by an explicit user action and never at
// launch, honest per-state UI, inert without the agent. Within that, two
// things are worth naming rather than leaving to be inferred:
//
//   * **This agent runs as the user, not as root.** It is a rendezvous
//     desk, not a privileged operation. The blast radius of a peer-gate
//     mistake here is "a local process signed by someone else could ask
//     Sentry for metrics", not local privilege escalation. The gate is still
//     fail-closed; the stakes are simply not the same, and pretending
//     otherwise would misdirect a future reviewer's attention.
//   * **The concrete `SecCode` evaluator lives in `SentryKit`, not in the
//     tool target.** A helper that only ever verifies its own callers could
//     keep its evaluator to itself. Here *both* sides verify — the bridge
//     gates who may publish and who may resolve, and Sentry's own anonymous
//     listener gates who may connect to it — so a single shared file beats
//     two copies of the same four Security-framework calls drifting apart.

#if os(macOS)

/// Names all three participants must agree on, in one place so a typo cannot
/// silently reproduce the exact bug this directory fixes — a registered
/// agent that nothing can reach.
public enum MCPBridgeNaming {

    /// The launchd job label, the Mach service name, and the basename of the
    /// property list in `Sentry.app/Contents/Library/LaunchAgents/`.
    ///
    /// `SMAppService.agent(plistName:)` looks the plist up by *file name*
    /// inside that directory, and launchd requires the plist's `Label` to
    /// equal the file's basename without the extension. Deriving all three
    /// from one constant is the only way to keep them in step.
    ///
    /// **This is the same string as `SentryXPCServiceName.machService`, on
    /// purpose.** That constant is the client-facing name and predates this
    /// file; keeping it means no `sentryctl` invocation, MCP config, or
    /// integration doc had to change to pick up the fix. The two are pinned
    /// equal by `MCPBridgeNamingTests` rather than merged, because this file
    /// is compiled into the `SentryMCPBridge` tool target (which links no
    /// framework of ours) while `SentryXPCProtocol.swift` is not — see
    /// `project.yml`.
    public static let label = "dev.malekswilam.sentry.xpc"

    /// `…/Contents/Library/LaunchAgents/<this>`. Passed verbatim to
    /// `SMAppService.agent(plistName:)`.
    public static var plistName: String { "\(label).plist" }

    /// The `MachServices` key the agent publishes and both the app and the
    /// command-line tools dial.
    public static var machService: String { label }
}

/// Timings the bridge and its clients depend on.
public enum MCPBridgeTiming {

    /// How long the bridge stays alive holding a published endpoint with no
    /// activity before exiting on its own.
    ///
    /// The load-bearing mitigation for the uninstall problem: a user who
    /// drags Sentry to the Trash without unregistering leaves a launchd job
    /// that can no longer start, and a copy that happens to be running should
    /// retire itself rather than linger. Five minutes rather than something
    /// tighter because this process holds nothing dangerous — it is a table
    /// with one entry in it — and because being evicted mid-session would
    /// make the *next* `sentryctl` invocation pay a cold-launch penalty for
    /// no benefit.
    public static let idleExitAfter: TimeInterval = 300

    /// How long a client waits for the bridge to answer `resolveAppEndpoint`
    /// before giving up.
    ///
    /// Bounded on purpose. The first invocation after a reboot pays for
    /// launchd to cold-start the agent, which is fast but not free; every
    /// later one is a table lookup. A `sentryctl statusline` call running in
    /// somebody's shell prompt has its own much tighter budget (50 ms, see
    /// `SentryCLI`) and gives up long before this fires — this timeout
    /// exists so the *other* subcommands cannot hang forever against a wedged
    /// agent.
    public static let resolveTimeout: TimeInterval = 5
}

#endif
