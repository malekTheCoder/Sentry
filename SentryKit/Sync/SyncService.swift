import CloudKit
import Dispatch
import Foundation

// MARK: - Upload batching intent (plan §7.4)

/// One CloudKit save operation's worth of work, described declaratively so
/// this file can be built and fully unit-tested with no real
/// `CKModifyRecordsOperation` ever executing — same constraint as
/// `CKMapper`/`SyncRecords.swift` (no enrolled Apple Developer Program
/// account yet; see those files' doc comments). `SyncService` never saves a
/// record one at a time: every upload, whether it carries one queued
/// snapshot or twenty, is expressed as exactly one `UploadBatch` and handed
/// to `StatsTransport.upload(_:)` in a single call, matching plan §7.4's
/// explicit "batch with `CKModifyRecordsOperation`, never one save per
/// record."
///
/// `savePolicy` and `qualityOfService` use the real CloudKit/Foundation
/// types (`CKModifyRecordsOperation.RecordSavePolicy`, `QualityOfService`)
/// rather than a hand-rolled stand-in enum — both types are plain value
/// types with no entitlement or network dependency to construct, so using
/// them now means the eventual real `CloudKitTransport` conformer reads
/// `batch.savePolicy`/`batch.qualityOfService` straight into
/// `CKModifyRecordsOperation`'s own properties with no translation layer.
/// Plan §7.4's `.changedKeysOnly` phrasing maps to CloudKit's actual
/// `.changedKeys` case.
public struct UploadBatch: Sendable {
    /// Already-mapped records (via `CKMapper`), ready to hand to
    /// `CKModifyRecordsOperation(recordsToSave:recordIDsToDelete:)`.
    public var recordsToSave: [CKRecord]

    /// Plan §7.4: `savePolicy = .changedKeysOnly` (→ CloudKit's
    /// `.changedKeys`) so re-uploading an unchanged field doesn't ship the
    /// whole record.
    public var savePolicy: CKModifyRecordsOperation.RecordSavePolicy

    /// Plan §7.4: `.utility` for snapshot/health uploads (this type's usual
    /// case), `.userInitiated` reserved for the command-acknowledgement
    /// path — a caller uploading a `ControlStatus` in direct response to a
    /// user-issued `ControlCommand` should override the default.
    public var qualityOfService: QualityOfService

    public init(
        recordsToSave: [CKRecord],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy = .changedKeys,
        qualityOfService: QualityOfService = .utility
    ) {
        self.recordsToSave = recordsToSave
        self.savePolicy = savePolicy
        self.qualityOfService = qualityOfService
    }
}

/// Outcome of one `UploadBatch` attempt. An enum rather than `throws` with a
/// real `Error` type because the only two facts `SyncService`'s backoff
/// logic needs are "did it work" and, if not, "did the server tell us how
/// long to wait" (`CKError.retryAfterSeconds`, plan §7.4) — everything else
/// about *why* a real CloudKit call failed (network, quota, auth, per-record
/// partial failure) is a `CloudKitTransport` concern, not this scheduler's.
/// Tests construct this directly to simulate success/failure/
/// `retryAfterSeconds` without needing a real `CKError`.
public enum UploadAttemptResult: Sendable, Equatable {
    case success
    /// `retryAfterSeconds`: mirrors `CKError.retryAfterSeconds` when the
    /// (eventual real) server explicitly told the client how long to back
    /// off. `nil` means "failed, no server guidance" — `SyncService` falls
    /// back to its own computed exponential-backoff-with-jitter delay.
    case failure(retryAfterSeconds: TimeInterval?)
}

/// The injectable seam plan §7.4's rate-limiting requirements are tested
/// against. Production wiring points this at a closure that builds a real
/// `CKModifyRecordsOperation` from `batch` and awaits its result; tests
/// point it at a closure that returns canned `UploadAttemptResult`s (and can
/// count calls, fail N times then succeed, etc.) with no CloudKit container
/// anywhere in the process.
public typealias UploadAttempt = @Sendable (UploadBatch) async -> UploadAttemptResult

// MARK: - SyncService

/// The adaptive-cadence upload scheduler from plan §7.4's rate-limiting
/// table. Architecturally this is `StatsCoordinator`'s sibling — see
/// `SentryKit/Services/StatsCoordinator.swift`'s own doc comments for the
/// pattern this deliberately follows: a queue-confined class owning a
/// self-rescheduling `DispatchSourceTimer`, with an `effectiveInterval`-style
/// pure function computing the next delay from a small set of inputs, and
/// every mutable field confined to one private serial queue rather than
/// scattered `@MainActor`/lock usage.
///
/// **Why queue-confined-timer over "purely reactive, ticked from
/// `AppDelegate`'s existing loop":** that alternative was considered (per
/// this task's own design question) and rejected for the same reason
/// `StatsCoordinator` itself is a self-contained scheduler rather than
/// something `AppDelegate` drives by polling a "should I do work now"
/// method every N seconds: a reactive design only progresses when the
/// driving loop happens to tick, which quietly couples this service's
/// cadence to whatever interval `StatsCoordinator`'s *fastest* active tier
/// happens to run at (today 3s, user-adjustable down to 0.5s per
/// `StatsCoordinator.setBaseInterval`) instead of the cadence table's own
/// 30s/5min/10min numbers, and makes "significant event → immediate upload"
/// awkward to express (you'd need the reactive check to run *between*
/// scheduled ticks, which defeats the point of being reactive). Owning its
/// own timer means `SyncService`'s cadence is exactly what plan §7.4
/// specifies, independent of `StatsCoordinator`'s unrelated polling
/// cadence, and a significant event can simply cancel-and-reschedule the
/// timer for `.now()` — the same mechanism `noteSignificantEvent()` uses
/// below.
///
/// **What this class does not do:** call CloudKit. Every upload attempt is
/// routed through the injected `UploadAttempt` closure (see that typealias's
/// doc comment) — there is no `CKContainer`/`CKDatabase` reference anywhere
/// in this file, matching the project-wide constraint that there is no
/// enrolled Apple Developer Program account yet (`project.yml`:
/// `CODE_SIGNING_REQUIRED: NO`, `DEVELOPMENT_TEAM: ""`).
public final class SyncService: @unchecked Sendable {

    // MARK: - Cadence configuration (plan §7.4's table, as constructor knobs)

    private let acActiveInterval: TimeInterval
    private let acIdleInterval: TimeInterval
    private let batteryInterval: TimeInterval
    /// How long after `recordIPhoneActivity(at:)` the iPhone still counts as
    /// "recently active" for the AC-active-vs-AC-idle distinction. Plan
    /// §7.4: "no iPhone activity in 10 min."
    private let iPhoneActiveWindow: TimeInterval

    // MARK: - Backoff configuration

    private let backoffBaseDelay: TimeInterval
    private let backoffMaxDelay: TimeInterval
    /// Returns a value in `0...1`; multiplied into the capped exponential
    /// delay to produce "full jitter" (see `backoffDelay(...)`'s doc
    /// comment). Injectable so tests can pin it (e.g. always `1.0` to check
    /// the upper bound, always `0.0` to check the lower bound) instead of
    /// asserting on a nondeterministic `Double.random` draw.
    private let jitterUnit: @Sendable () -> Double

    // MARK: - Dependencies

    private let uploadAttempt: UploadAttempt
    /// Injectable `Date` source, matching the convention `AlertEngine`
    /// (`SentryKit/Services/AlertEngine.swift`) and
    /// `PowerControlServiceTests` already establish elsewhere in this
    /// codebase, so tests can drive "10 minutes since the iPhone was last
    /// active" without a real `sleep`.
    private let clock: @Sendable () -> Date

    // MARK: - Queue-confined state

    private let queue = DispatchQueue(label: "dev.malekswilam.sentry.syncservice", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var isRunning = false

    private var isOnBattery = false
    private var lastIPhoneActivityAt: Date?
    /// Consumed (reset to `false`) the moment a tick actually runs, so a
    /// significant event forces exactly the *next* upload to be immediate
    /// rather than pinning the cadence to 0 forever.
    private var forceImmediateStorage = false
    private var consecutiveFailures = 0
    private var pendingRecords: [CKRecord] = []
    private var pendingQoS: QualityOfService = .utility

    // MARK: - Init

    /// - Parameters:
    ///   - uploadAttempt: see `UploadAttempt`'s doc comment. Production
    ///     wiring supplies a closure that performs a real
    ///     `CKModifyRecordsOperation`; tests supply a closure returning
    ///     canned results.
    ///   - clock: injectable `Date` source (see `clock`'s doc comment).
    ///   - jitterUnit: injectable `0...1` source for backoff jitter (see
    ///     `jitterUnit`'s doc comment).
    ///   - acActiveInterval/acIdleInterval/batteryInterval/iPhoneActiveWindow:
    ///     plan §7.4's cadence table, defaulted to the plan's own numbers
    ///     (30s / 5min / 10min / 10min) but overridable so tests don't have
    ///     to wait on real wall-clock minutes to exercise the boundary.
    ///   - backoffBaseDelay/backoffMaxDelay: exponential-backoff knobs (see
    ///     `backoffDelay(...)`).
    public init(
        uploadAttempt: @escaping UploadAttempt,
        clock: @escaping @Sendable () -> Date = { Date() },
        jitterUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        acActiveInterval: TimeInterval = 30,
        acIdleInterval: TimeInterval = 300,
        batteryInterval: TimeInterval = 600,
        iPhoneActiveWindow: TimeInterval = 600,
        backoffBaseDelay: TimeInterval = 2,
        backoffMaxDelay: TimeInterval = 300
    ) {
        self.uploadAttempt = uploadAttempt
        self.clock = clock
        self.jitterUnit = jitterUnit
        self.acActiveInterval = acActiveInterval
        self.acIdleInterval = acIdleInterval
        self.batteryInterval = batteryInterval
        self.iPhoneActiveWindow = iPhoneActiveWindow
        self.backoffBaseDelay = backoffBaseDelay
        self.backoffMaxDelay = backoffMaxDelay
    }

    // MARK: - Pure cadence math (plan §7.4's table)

    /// The cadence table's first three rows, as one pure function so tests
    /// can assert the exact interval for each condition with no timer, no
    /// queue hop, and no instance at all. The fourth row ("significant
    /// event → immediate") and fifth row ("`refreshNow` → immediate") are
    /// deliberately *not* representable here — they're overrides applied on
    /// top of this base cadence, not another value this function could
    /// return, which is exactly why `SyncService` models them as a separate
    /// `forceImmediateStorage` flag (see `noteSignificantEvent()`) rather
    /// than a fourth branch here.
    ///
    /// - On battery wins outright regardless of iPhone activity — the plan
    ///   lists "Mac on battery" as its own row, independent of the
    ///   AC-active/AC-idle split, so battery power always yields the 10-minute
    ///   interval even if the iPhone was just active.
    public static func effectiveInterval(
        onBattery: Bool,
        iPhoneRecentlyActive: Bool,
        acActiveInterval: TimeInterval = 30,
        acIdleInterval: TimeInterval = 300,
        batteryInterval: TimeInterval = 600
    ) -> TimeInterval {
        if onBattery { return batteryInterval }
        return iPhoneRecentlyActive ? acActiveInterval : acIdleInterval
    }

    /// Exponential backoff with full jitter, honoring an explicit
    /// server-provided delay when present.
    ///
    /// - If `retryAfterSeconds` is non-nil (mirrors `CKError.retryAfterSeconds`,
    ///   plan §7.4: "honor `CKError.retryAfterSeconds`"), it wins outright —
    ///   no jitter is applied on top, since jittering a delay the server
    ///   explicitly asked for would defeat the point of it telling us.
    /// - Otherwise: `capped = min(maxDelay, baseDelay * 2^(attempt-1))`
    ///   (attempt 1 → `baseDelay`, attempt 2 → `2×baseDelay`, attempt 3 →
    ///   `4×baseDelay`, ...), then `delay = capped * jitterUnit()` — "full
    ///   jitter" (a uniform draw across `0...capped`, not just a small
    ///   wobble around `capped`), which is the AWS-architecture-blog
    ///   recommended shape for backoff because it spreads retries out
    ///   across the whole window instead of every failed client retrying in
    ///   near-lockstep at exactly `capped`.
    /// - `attempt` is 1-based (first failure = attempt 1); values `<= 0` are
    ///   treated as 1.
    public static func backoffDelay(
        attempt: Int,
        baseDelay: TimeInterval = 2,
        maxDelay: TimeInterval = 300,
        retryAfterSeconds: TimeInterval? = nil,
        jitterUnit: () -> Double = { Double.random(in: 0...1) }
    ) -> TimeInterval {
        if let retryAfterSeconds {
            return max(0, retryAfterSeconds)
        }
        let clampedAttempt = max(1, attempt)
        let exponent = Double(clampedAttempt - 1)
        let capped = min(maxDelay, baseDelay * pow(2, exponent))
        let unit = min(max(jitterUnit(), 0), 1)
        return capped * unit
    }

    // MARK: - Public API: lifecycle

    /// Starts the adaptive-cadence timer. Idempotent — a second call while
    /// already running is a no-op, same as `StatsCoordinator.snapshots()`'s
    /// `startPollingIfNeeded()`.
    public func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.scheduleNextTick()
        }
    }

    /// Cancels the timer. Restart with `start()`; queued-but-unsent records
    /// are preserved, matching the plan's framing of pruning/uploading as a
    /// resumable cycle rather than something that loses queued work across
    /// a pause.
    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.isRunning = false
        }
    }

    // MARK: - Public API: inputs that steer cadence

    /// Reports the Mac's current power source. A *change* from the
    /// previously reported state counts as one of plan §7.4's "significant
    /// event"s ("plugged in/unplugged") and forces the next upload
    /// immediate, in addition to changing which cadence row subsequent
    /// scheduled ticks fall into. Calling this repeatedly with the same
    /// value (e.g. once per `StatsCoordinator` battery-tier tick) is cheap
    /// and does not re-trigger the immediate override.
    public func updatePowerState(onBattery: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let changed = self.isOnBattery != onBattery
            self.isOnBattery = onBattery
            if changed {
                self.forceNextTickImmediate()
            }
        }
    }

    /// Records that the iPhone app was foregrounded/active, per plan §7.4's
    /// "Implement 'iPhone recently active' by having the iPhone write a
    /// lightweight `lastViewedAt` field on the `Device` record ... The Mac
    /// reads it and enters fast-cadence mode for 10 minutes." This method is
    /// the Mac-side half of that: whatever reads the synced `lastViewedAt`
    /// value calls this to feed it in. `at` defaults to `clock()`, not a
    /// hardcoded `Date()`, so tests can inject a specific instant.
    public func recordIPhoneActivity(at date: Date? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastIPhoneActivityAt = date ?? self.clock()
        }
    }

    /// Forces the next upload to happen immediately rather than waiting for
    /// the current cadence's timer to elapse — plan §7.4's "significant
    /// event (plugged in/unplugged, alert fired, assertion changed) →
    /// immediate" row. `updatePowerState(onBattery:)` already calls this
    /// automatically on a plug/unplug transition; callers own reporting the
    /// other two triggers explicitly (an `AlertEngine` firing, a sleep
    /// assertion changing) since `SyncService` has no way to observe those
    /// on its own.
    public func noteSignificantEvent() {
        queue.async { [weak self] in
            self?.forceNextTickImmediate()
        }
    }

    /// Forces the next upload to happen immediately in response to an
    /// inbound `refreshNow` `ControlCommand` — plan §7.4's fifth cadence
    /// row ("iPhone explicitly pulls to refresh"). Named distinctly from
    /// `noteSignificantEvent()`, even though the mechanism is identical,
    /// because the two are semantically different triggers (a local
    /// power/alert condition vs. an explicit remote request) and a caller
    /// reading call sites later should be able to tell which one fired
    /// without chasing this doc comment.
    public func handleRefreshNowRequested() {
        queue.async { [weak self] in
            self?.forceNextTickImmediate()
        }
    }

    private func forceNextTickImmediate() {
        // Must run on `queue`.
        forceImmediateStorage = true
        if isRunning {
            scheduleNextTick(after: 0)
        }
    }

    // MARK: - Public API: queuing records for upload

    /// Queues one `SnapshotRecord` (already mapped via `CKMapper.record(from:zoneID:)`)
    /// for the next batch. Snapshots use the default `.utility` QoS (plan
    /// §7.4).
    public func enqueueSnapshot(_ snapshot: SnapshotRecord, zoneID: CKRecordZone.ID) {
        enqueue(CKMapper.record(from: snapshot, zoneID: zoneID))
    }

    /// Queues one `DailyHealth` record for the next batch.
    public func enqueueDailyHealth(_ health: DailyHealth, zoneID: CKRecordZone.ID) {
        enqueue(CKMapper.record(from: health, zoneID: zoneID))
    }

    /// Queues an updated `Device` heartbeat/metadata record for the next
    /// batch.
    public func enqueueDeviceUpdate(_ device: Device, zoneID: CKRecordZone.ID) {
        enqueue(CKMapper.record(from: device, zoneID: zoneID))
    }

    /// Queues a `ControlStatus` acknowledgement for the next batch and
    /// bumps the batch's QoS to `.userInitiated` for this cycle (plan
    /// §7.4: "`.userInitiated` for commands") — a command acknowledgement
    /// is a direct response to a user action on the iPhone, so it should
    /// not sit behind `.utility`-priority snapshot work once a batch goes
    /// out. This also implies "significant event" urgency, so it forces the
    /// next tick immediate rather than waiting for the current cadence.
    public func enqueueControlStatus(_ status: ControlStatus, zoneID: CKRecordZone.ID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingRecords.append(CKMapper.record(from: status, zoneID: zoneID))
            self.pendingQoS = .userInitiated
            self.forceNextTickImmediate()
        }
    }

    private func enqueue(_ record: CKRecord) {
        queue.async { [weak self] in
            self?.pendingRecords.append(record)
        }
    }

    // MARK: - Public API: read-only state for tests/diagnostics

    /// The interval the *next scheduled* (non-forced) tick would use, given
    /// current power/activity state — i.e. `effectiveInterval(...)` applied
    /// to this instance's live inputs. Exists so tests can assert cadence
    /// behavior against a running instance without reaching into private
    /// state, mirroring `StatsCoordinator.currentBaseInterval(for:)`'s role.
    public func currentEffectiveInterval() -> TimeInterval {
        queue.sync {
            Self.effectiveInterval(
                onBattery: isOnBattery,
                iPhoneRecentlyActive: isIPhoneRecentlyActive(),
                acActiveInterval: acActiveInterval,
                acIdleInterval: acIdleInterval,
                batteryInterval: batteryInterval
            )
        }
    }

    /// The delay the next tick will actually be scheduled after, i.e.
    /// `0` if a significant event/`refreshNow` override is pending,
    /// otherwise the same value `currentEffectiveInterval()` returns. This
    /// is the one call that lets a test verify "significant event forces
    /// immediate upload" — call `noteSignificantEvent()`, then assert this
    /// returns `0` even though `currentEffectiveInterval()` still reports
    /// the un-overridden cadence.
    public func nextTickDelay() -> TimeInterval {
        queue.sync {
            forceImmediateStorage ? 0 : Self.effectiveInterval(
                onBattery: isOnBattery,
                iPhoneRecentlyActive: isIPhoneRecentlyActive(),
                acActiveInterval: acActiveInterval,
                acIdleInterval: acIdleInterval,
                batteryInterval: batteryInterval
            )
        }
    }

    public func pendingRecordCount() -> Int {
        queue.sync { pendingRecords.count }
    }

    public func consecutiveFailureCount() -> Int {
        queue.sync { consecutiveFailures }
    }

    /// Test-only hook: runs exactly one upload cycle (build batch → call
    /// `uploadAttempt` → apply success/backoff outcome → reschedule) and
    /// suspends until it finishes, without needing a real
    /// `DispatchSourceTimer` deadline to elapse. Production code never
    /// calls this — `start()`'s timer invokes the same underlying tick on
    /// its own schedule. This exists because `DispatchSourceTimer` deadlines
    /// are real wall-clock time even when `clock` is injected (unlike, say,
    /// `AlertEngine`'s purely synchronous evaluation), so there is no way
    /// for a test to deterministically observe "one tick happened" other
    /// than driving it directly and awaiting completion.
    public func runTickForTesting() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.performTick(reschedule: false) {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Timer-driven tick (queue-confined)

    private func scheduleNextTick(after overrideDelay: TimeInterval? = nil) {
        // Must run on `queue`.
        timer?.cancel()
        let delay = max(0, overrideDelay ?? nextDelayIgnoringOverrideParam())
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Leeway ~10% of the interval, same rationale as `StatsCoordinator`:
        // lets macOS coalesce this wakeup instead of waking the CPU exactly
        // on schedule. A zero-delay (forced-immediate) tick gets zero
        // leeway, which is correct — "immediate" should mean immediate.
        t.schedule(deadline: .now() + delay, leeway: .milliseconds(Int(delay * 100)))
        t.setEventHandler { [weak self] in
            self?.performTick(reschedule: true, completion: nil)
        }
        timer = t
        t.resume()
    }

    /// Helper for `scheduleNextTick(after:)` when no explicit override was
    /// passed — reads the forced-immediate flag and current cadence, same
    /// logic as `nextTickDelay()` but callable while already on `queue`
    /// (`nextTickDelay()` itself uses `queue.sync`, which would deadlock if
    /// called from a block already running on `queue`).
    private func nextDelayIgnoringOverrideParam() -> TimeInterval {
        forceImmediateStorage ? 0 : Self.effectiveInterval(
            onBattery: isOnBattery,
            iPhoneRecentlyActive: isIPhoneRecentlyActive(),
            acActiveInterval: acActiveInterval,
            acIdleInterval: acIdleInterval,
            batteryInterval: batteryInterval
        )
    }

    /// Delegates to `HeartbeatTracker` rather than re-deriving the same
    /// "how long since we last heard from the phone" comparison privately —
    /// an earlier version of this method did exactly that, duplicating
    /// `HeartbeatTracker.isFastCadence`'s logic in a second,
    /// independently-tested place with no static guarantee the two would
    /// stay in sync. `lastIPhoneActivityAt` here is a local cache
    /// (`recordIPhoneActivity(at:)`), not necessarily `Device.lastViewedAt`
    /// itself — once the real transport reads that field from CloudKit,
    /// this is also the seam where it should start feeding in.
    private func isIPhoneRecentlyActive() -> Bool {
        HeartbeatTracker.isFastCadence(lastViewedAt: lastIPhoneActivityAt, now: clock(), window: iPhoneActiveWindow)
    }

    /// One upload cycle. Runs on `queue` up to the point of dispatching the
    /// actual (possibly slow/async) `uploadAttempt` call, then hops off
    /// `queue` to await it — same pattern `StatsCoordinator.tick(tier:)`
    /// uses to keep a slow provider/network call from blocking this
    /// service's own queue — and hops back to `queue` only to apply the
    /// result and reschedule.
    private func performTick(reschedule: Bool, completion: (() -> Void)?) {
        // Must run on `queue`.
        forceImmediateStorage = false

        guard !pendingRecords.isEmpty else {
            if reschedule { scheduleNextTick() }
            completion?()
            return
        }

        let batch = UploadBatch(recordsToSave: pendingRecords, qualityOfService: pendingQoS)
        pendingRecords.removeAll()
        pendingQoS = .utility
        let attempt = uploadAttempt
        let failureCountAtAttempt = consecutiveFailures

        Task { [weak self] in
            let result = await attempt(batch)
            guard let self else {
                completion?()
                return
            }
            self.queue.async {
                switch result {
                case .success:
                    self.consecutiveFailures = 0
                    if reschedule { self.scheduleNextTick() }
                case .failure(let retryAfterSeconds):
                    self.consecutiveFailures = failureCountAtAttempt + 1
                    // Put the batch's records back at the front of the queue
                    // so a failed upload doesn't silently drop data — the
                    // next successful cycle re-sends them alongside whatever
                    // else accumulated in the meantime.
                    self.pendingRecords.insert(contentsOf: batch.recordsToSave, at: 0)
                    if reschedule {
                        let delay = Self.backoffDelay(
                            attempt: self.consecutiveFailures,
                            baseDelay: self.backoffBaseDelay,
                            maxDelay: self.backoffMaxDelay,
                            retryAfterSeconds: retryAfterSeconds,
                            jitterUnit: self.jitterUnit
                        )
                        self.scheduleNextTick(after: delay)
                    }
                }
                completion?()
            }
        }
    }

    deinit {
        // Same rationale as `StatsCoordinator.deinit`: `stop()` dispatches
        // `async` with `[weak self]`, which would silently no-op once `self`
        // is already gone, so teardown cancels the timer directly here
        // instead of relying on an in-flight `queue.async` that will never
        // run.
        timer?.cancel()
    }
}
