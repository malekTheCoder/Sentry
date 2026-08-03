import Foundation
import SentryKit

/// Calls `SentryXPCServiceProtocol` methods directly against an in-process
/// object — no `NSXPCConnection`, no Mach service lookup. See
/// `MCPServiceCalling`'s doc comment for why: `MCPRemoteServer` lives inside
/// `Sentry.app` already, and self-connecting via `NSXPCConnection` to a
/// Mach service this same process vends via `NSXPCListener` failed in
/// practice (every call errored with "Couldn't communicate with a helper
/// application") — there's no real reason to round-trip through Mach IPC to
/// reach an object already sitting in the same address space. Safe because
/// every `SentryXPCServiceProtocol` method is `nonisolated` on the
/// `@MainActor` `MCPXPCService` (it hops to `@MainActor` internally as
/// needed) — calling it directly from an arbitrary async context is exactly
/// what `NSXPCConnection` would have done anyway, just without the IPC hop.
final class LocalXPCServiceCaller: MCPServiceCalling, @unchecked Sendable {
    private let service: SentryXPCServiceProtocol

    init(service: SentryXPCServiceProtocol) {
        self.service = service
    }

    func readCall(
        _ body: @escaping (SentryXPCServiceProtocol, @escaping (Data?, String?) -> Void) -> Void
    ) async -> (Data?, String?) {
        await withCheckedContinuation { continuation in
            body(service) { data, message in
                continuation.resume(returning: (data, message))
            }
        }
    }

    func writeCall(
        _ body: @escaping (SentryXPCServiceProtocol, @escaping (Bool, String?) -> Void) -> Void
    ) async -> (Bool, String?) {
        await withCheckedContinuation { continuation in
            body(service) { ok, message in
                continuation.resume(returning: (ok, message))
            }
        }
    }
}
