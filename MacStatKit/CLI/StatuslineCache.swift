import Foundation

/// The last snapshot `macstat statusline` successfully read, kept on disk so
/// the *next* invocation has something honest to fall back on when the app
/// can't answer inside the latency budget.
///
/// **Why a cache exists at all.** §21.5's Starship lesson is that a prompt
/// command which blocks is worse than one which is stale — Starship's own
/// answer is `command_timeout`, after which it drops the module entirely.
/// Dropping the module is a legitimate outcome and this CLI does it too (see
/// `StatuslineRenderer.maximumUsableStaleness`), but it is the *worse* of the
/// two available outcomes: a status line that flickers empty every time the
/// app is momentarily busy trains the user to ignore it. One prior reading,
/// explicitly labeled with its age, is strictly more useful and no less
/// honest.
///
/// **This is a cache, not a data store.** It lives under `~/Library/Caches`
/// rather than `~/Library/Application Support` (where `SettingsStore` and
/// `HistoryStore` keep the things that must survive) precisely because macOS
/// is free to delete it, and nothing here breaks when it does — the next
/// invocation simply has no fallback, which is the same state as a fresh
/// install. It is a single file that is overwritten in place, so it cannot
/// grow; there is no pruning job to forget to write.
///
/// **It is deleted, not merely ignored, when access is denied.** If the user
/// turns MCP access off in Settings → AI Access, a cached snapshot on disk
/// would let `statusline` keep rendering real telemetry from a Mac whose
/// owner just said "stop giving this to tools." That is not a stale reading,
/// it is a permission being routed around, so `discard()` exists and the CLI
/// calls it on any denial. See `MCPAccessController` for why the denial is
/// authoritative.
public struct StatuslineCache: Sendable {

    /// What gets written. A wrapper rather than a bare `SystemSnapshot`
    /// because the *capture* time and the snapshot's own `timestamp` are
    /// different facts: `SystemSnapshot.timestamp` is when the app sampled
    /// the hardware, `capturedAt` is when this CLI received it. They are
    /// normally milliseconds apart and can be much further apart if the app
    /// was serving a snapshot from a paused sampling loop, and the staleness
    /// a user cares about is measured from the *reading*, not the transfer.
    /// Both are stored so a future reader can tell them apart instead of
    /// having to assume.
    public struct Entry: Codable, Sendable {
        public var capturedAt: Date
        public var snapshot: SystemSnapshot

        public init(capturedAt: Date = Date(), snapshot: SystemSnapshot) {
            self.capturedAt = capturedAt
            self.snapshot = snapshot
        }

        /// Age measured from the snapshot's own sample time, clamped at zero
        /// so a clock adjustment between write and read can't produce a
        /// negative "stale for -4s" in somebody's prompt.
        public func age(now: Date = Date()) -> TimeInterval {
            max(0, now.timeIntervalSince(snapshot.timestamp))
        }
    }

    public let fileURL: URL

    /// - Parameter fileURL: override for tests. The default is
    ///   `~/Library/Caches/dev.malekswilam.macstat/statusline.json`, using
    ///   the CLI's own bundle identifier as the subdirectory so it is
    ///   obvious in a `ls` who wrote it.
    public init(fileURL: URL = StatuslineCache.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        let caches = (try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("dev.malekswilam.macstat", isDirectory: true)
            .appendingPathComponent("statusline.json", isDirectory: false)
    }

    /// Best-effort write. Every failure path — unwritable directory, full
    /// disk, a sandbox that didn't exist when this was written — is
    /// swallowed on purpose: the caller has already printed a correct,
    /// fresh status line by this point, and the only thing a thrown error
    /// could accomplish is turning a successful invocation into a failed
    /// one over a file whose entire purpose is to be optional.
    @discardableResult
    public func store(_ snapshot: SystemSnapshot, now: Date = Date()) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Entry(capturedAt: now, snapshot: snapshot)) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // `.atomic` so a `statusline` killed mid-write (entirely
            // plausible — this runs from a shell prompt the user may be
            // ^C-ing) leaves the previous good entry in place rather than a
            // truncated file the next invocation has to fail to parse.
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Returns the cached entry, or `nil` when there isn't one, it can't be
    /// read, it can't be decoded, or it is older than `maximumAge`.
    ///
    /// All four are collapsed into `nil` deliberately: to the caller they
    /// are the same situation ("no usable fallback"), and a corrupt cache
    /// file is not worth a distinct user-facing message when the recovery —
    /// overwrite it on the next successful call — is automatic either way.
    public func load(
        now: Date = Date(),
        maximumAge: TimeInterval = StatuslineRenderer.maximumUsableStaleness
    ) -> Entry? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entry = try? decoder.decode(Entry.self, from: data) else { return nil }
        guard entry.age(now: now) <= maximumAge else { return nil }
        return entry
    }

    /// Removes the cache file. See the type doc comment — this is called on
    /// a permission denial, so that revoking access in Settings takes effect
    /// on the *next* prompt rather than whenever the file happens to age out.
    public func discard() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
