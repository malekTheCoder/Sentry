import Foundation

#if os(macOS)

/// Thin async wrapper around an `NSXPCConnection` to `MacStat.app`. Every
/// call gets a *fresh* `remoteObjectProxyWithErrorHandler` rather than one
/// cached proxy, so a connection interruption between calls (MacStat quit,
/// crashed, or hasn't launched yet) surfaces as a clear per-call error
/// instead of every subsequent call silently hanging.
///
/// Originally private to `MacStatMCP/main.swift`; moved here so the
/// standalone `macstat` CLI (see `MacStatCLI/main.swift`) can reuse the same
/// connection/reply-race handling instead of duplicating it — both binaries
/// are thin XPC clients with no direct access to
/// `StatsCoordinator`/`HistoryStore`/etc., per `MacStatXPCServiceProtocol`'s
/// doc comment.
public final class MacStatXPCClient: @unchecked Sendable {
    private let connection: NSXPCConnection

    public init() {
        connection = NSXPCConnection(machServiceName: MacStatXPCServiceName.machService, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: MacStatXPCServiceProtocol.self)
        connection.resume()
    }

    /// Resolves exactly once, from whichever of `body`'s reply closure or the
    /// XPC error handler fires first — guarded by `ResumeOnce` since both
    /// *can* legitimately race (a connection interruption arriving just as
    /// the app-side reply is in flight).
    public func readCall(_ body: @escaping (MacStatXPCServiceProtocol, @escaping (Data?, String?) -> Void) -> Void) async -> (Data?, String?) {
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

    public func writeCall(_ body: @escaping (MacStatXPCServiceProtocol, @escaping (Bool, String?) -> Void) -> Void) async -> (Bool, String?) {
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

#endif
