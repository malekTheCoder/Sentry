import Foundation

#if os(macOS)

/// Abstraction over "how to reach `MacStatXPCServiceProtocol`," so
/// `MCPToolCatalog`/`ResourceCatalog`/`ResourceSubscriptionPump`/
/// `MacStatMCPServerFactory` don't need to know whether the caller is a
/// genuinely separate process or code already living inside `MacStat.app`.
///
/// Two conformers:
/// - `MacStatXPCClient` — a real `NSXPCConnection`, for the stdio
///   `MacStatMCP` binary (a truly separate process).
/// - `LocalXPCServiceCaller` (`MacStat/App/LocalXPCServiceCaller.swift`) — a
///   direct in-process call with no XPC transport at all, for
///   `MCPRemoteServer`. Self-connecting via `NSXPCConnection` to a Mach
///   service this exact same process vends via `NSXPCListener` was tried
///   first and found unreliable in practice (every call failed with
///   "Couldn't communicate with a helper application") — there's also no
///   real reason to round-trip through Mach IPC to reach an object that's
///   already sitting in the same address space, so this protocol exists to
///   let `MCPRemoteServer` skip that hop entirely rather than working around
///   the self-connection failure.
public protocol MCPServiceCalling: Sendable {
    func readCall(
        _ body: @escaping (MacStatXPCServiceProtocol, @escaping (Data?, String?) -> Void) -> Void
    ) async -> (Data?, String?)

    func writeCall(
        _ body: @escaping (MacStatXPCServiceProtocol, @escaping (Bool, String?) -> Void) -> Void
    ) async -> (Bool, String?)
}
#endif
