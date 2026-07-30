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
// makes the same claim in the Settings UI; this is the file that has to keep
// it true.

// MARK: - XPC client

/// Thin async wrapper around an `NSXPCConnection` to `MacStat.app`. Every
/// call gets a *fresh* `remoteObjectProxyWithErrorHandler` rather than one
/// cached proxy, so a connection interruption between calls (MacStat quit,
/// crashed, or hasn't launched yet) surfaces as a clear per-call error
/// instead of every subsequent call silently hanging.
final class MacStatXPCClient: @unchecked Sendable {
    private let connection: NSXPCConnection

    init() {
        connection = NSXPCConnection(machServiceName: MacStatXPCServiceName.machService, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: MacStatXPCServiceProtocol.self)
        connection.resume()
    }

    /// Resolves exactly once, from whichever of `body`'s reply closure or the
    /// XPC error handler fires first — guarded by `ResumeOnce` since both
    /// *can* legitimately race (a connection interruption arriving just as
    /// the app-side reply is in flight).
    func readCall(_ body: @escaping (MacStatXPCServiceProtocol, @escaping (Data?, String?) -> Void) -> Void) async -> (Data?, String?) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(Data?, String?), Never>) in
            let box = ResumeOnce(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                box.resume((nil, "Couldn't reach MacStat.app: \(error.localizedDescription). Is MacStat running?"))
            }) as? MacStatXPCServiceProtocol else {
                box.resume((nil, "Couldn't create an XPC proxy to MacStat.app."))
                return
            }
            body(proxy) { data, message in box.resume((data, message)) }
        }
    }

    func writeCall(_ body: @escaping (MacStatXPCServiceProtocol, @escaping (Bool, String?) -> Void) -> Void) async -> (Bool, String?) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, String?), Never>) in
            let box = ResumeOnce(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                box.resume((false, "Couldn't reach MacStat.app: \(error.localizedDescription). Is MacStat running?"))
            }) as? MacStatXPCServiceProtocol else {
                box.resume((false, "Couldn't create an XPC proxy to MacStat.app."))
                return
            }
            body(proxy) { ok, message in box.resume((ok, message)) }
        }
    }
}

/// Resumes a `CheckedContinuation` at most once, guarded by a lock. Needed
/// because `remoteObjectProxyWithErrorHandler`'s error handler and the XPC
/// reply block are two independent completion paths that a real connection
/// failure mid-call can race between — `NSXPCConnection`'s own contract only
/// promises *one* of them fires per call, not which, and calling
/// `continuation.resume` twice is a Swift Concurrency crash, not a warning.
final class ResumeOnce<T>: @unchecked Sendable {
    private let continuation: CheckedContinuation<T, Never>
    private let lock = NSLock()
    private var didResume = false

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let alreadyResumed = didResume
        didResume = true
        lock.unlock()
        guard !alreadyResumed else { return }
        continuation.resume(returning: value)
    }
}

/// Captures the connecting MCP client's self-reported identity from the
/// `initialize` handshake, for the activity log (see
/// `MacStatXPCServiceProtocol`'s doc comment on why `clientName` is a label,
/// not an auth boundary). An `actor` because the initialize hook and every
/// tool-call handler run concurrently on the server's own task-per-request
/// model.
actor ClientIdentity {
    private(set) var name: String = "Unknown MCP Client"
    func set(_ name: String) { self.name = name }
}

// MARK: - Entry point

let xpcClient = MacStatXPCClient()
let clientIdentity = ClientIdentity()

let server = Server(
    name: "MacStat",
    version: "0.1.0",
    capabilities: .init(
        tools: .init(listChanged: false)
    )
)

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: MCPToolCatalog.tools)
}

await server.withMethodHandler(CallTool.self) { params in
    let clientName = await clientIdentity.name
    return await MCPToolCatalog.call(
        name: params.name,
        arguments: params.arguments ?? [:],
        clientName: clientName,
        xpcClient: xpcClient
    )
}

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
