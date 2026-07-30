import Foundation
import MCP
import MacStatKit

// MacStatMCP — the stdio JSON-RPC binary from plan §13.2. An MCP client
// (Claude Desktop, Claude Code, Cursor, …) spawns this as a subprocess and
// talks to it over stdin/stdout; this binary in turn talks to the
// already-running `MacStat.app` over a local `NSXPCConnection` to the Mach
// service `MacStatXPCServiceName.machService`. It never touches IOKit,
// SQLite, or any of `StatsCoordinator`/`PowerControlService`/`HistoryStore`/
// `AlertEngine` directly — see `MacStatXPCServiceProtocol`'s doc comment for
// why that boundary matters (one sampling loop, one SQLite owner,
// permission gating lives in the app, not here).
//
// **Zero network, for real.** This file imports only `Foundation`, `MCP`
// (the local stdio/XPC-agnostic protocol library), and `MacStatKit`. No
// `URLSession`, no `Network.framework`, no socket of any kind — every tool
// call this binary answers comes from the XPC round-trip above. `AIAccessPane`
// makes the same claim in the Settings UI (for this transport specifically —
// see that pane's doc comment for the separate, off-by-default, LAN-bound
// remote transport `MacStat/App/MCPRemoteServer.swift` provides instead).
//
// The actual tool/resource dispatch wiring lives in `MacStatKit/MCP/
// MacStatMCPServerFactory.swift`, shared with `MCPRemoteServer` — this file
// is just the stdio-specific entry point now.

let xpcClient = MacStatXPCClient()
let clientIdentity = MCPClientIdentity()
let subscriptionPump = ResourceSubscriptionPump(xpcClient: xpcClient, clientName: "MacStat (resource subscription)")

let server = await MacStatMCPServerFactory.makeServer(
    xpcClient: xpcClient,
    clientIdentity: clientIdentity,
    subscriptionPump: subscriptionPump
)

let transport = StdioTransport()

do {
    try await server.start(transport: transport) { clientInfo, _ in
        await clientIdentity.set(clientInfo.name)
    }
    // `server.start` returns once the connection is established; the
    // process needs to stay alive for the lifetime of the stdio session,
    // which ends when the parent (the MCP client) closes the pipe — at
    // which point `StdioTransport` finishes its read loop and this task
    // sleep is the only thing keeping the process from exiting first.
    try await Task.sleep(for: .seconds(365 * 24 * 60 * 60))
} catch {
    FileHandle.standardError.write("MacStatMCP failed to start: \(error)\n".data(using: .utf8) ?? Data())
    exit(1)
}
