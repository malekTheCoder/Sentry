import Foundation

/// Local queue for `AlertPush` records fired via `AlertAction.pushToPhone`
/// (AI-agent-integration pass — see Sentry-AI-Features-Research.md item #7)
/// while there is no live CloudKit container to upload them to (blocked on
/// Apple Developer Program enrollment — see `SyncRecords.swift`'s top-level
/// doc comment). `AlertEngine.phonePushRecorder` writes here; a future
/// `SyncService` that actually talks to CloudKit drains it via `drain()`
/// once enrollment happens — nothing about this store or its callers needs
/// to change when that lands, only what's downstream of `drain()`.
///
/// `UserDefaults`-backed rather than a new `HistoryStore` SQLite table: this
/// is a small, transient outbox (dozens of entries at most between syncs),
/// not durable history a user browses — same reasoning `MCPActivityLog`
/// gives for staying in-memory, except this one *does* need to survive an
/// app relaunch between fire time and the next successful sync, hence
/// `UserDefaults` rather than a plain in-memory array.
public final class PendingAlertPushStore {
    private let defaults: UserDefaults
    private let key = "dev.malekswilam.sentry.pendingAlertPushes"
    /// Generous enough to survive a long offline stretch without ever
    /// mattering in practice, small enough that a misfiring rule can't grow
    /// this file unbounded.
    private let capacity = 200

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func enqueue(_ push: AlertPush) {
        var pending = all()
        pending.append(push)
        if pending.count > capacity {
            pending.removeFirst(pending.count - capacity)
        }
        save(pending)
    }

    public func all() -> [AlertPush] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([AlertPush].self, from: data)
        else {
            return []
        }
        return decoded
    }

    /// Returns every currently-queued push and empties the queue — the
    /// contract a future `SyncService` upload loop wants ("give me what's
    /// pending, and don't hand it to me twice").
    public func drain() -> [AlertPush] {
        let pending = all()
        defaults.removeObject(forKey: key)
        return pending
    }

    private func save(_ pending: [AlertPush]) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        defaults.set(data, forKey: key)
    }
}
