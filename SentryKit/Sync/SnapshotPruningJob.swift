import Foundation

/// Decides which CloudKit `Snapshot` records are due for deletion (plan
/// §7.4: "Mac deletes `Snapshot` records older than 7 days on each sync
/// cycle... Long-term history lives in `DailyHealth` (small) and in the
/// local Mac DB (full resolution)," so pruning the CloudKit copy loses
/// nothing — it's a bandwidth/storage cap on the sync container, not a data
/// retention decision).
///
/// Modeled the same way `SentryKit/Persistence/RollupJob.swift` structures
/// its retention enforcement — a small job type whose public methods take an
/// injected `now` so tests can drive them deterministically instead of
/// depending on the wall clock — except this job's "delete" step can't
/// actually run yet: there's no live
/// `CKContainer`/`CKDatabase` (see `SyncRecords.swift`'s top-level doc
/// comment), so unlike `RollupJob`'s `DELETE FROM sample_raw WHERE ts < ?`,
/// this type only *decides* which record IDs are stale. The real
/// `CKModifyRecordsOperation(recordIDsToDelete:)` call is separate,
/// network-calling glue that plugs in once `identifiersToPrune(...)`'s
/// output is available — deliberately kept out of this type so the decision
/// logic itself is fully unit-testable in-process today, with no mocking of
/// CloudKit required.
public enum SnapshotPruningJob {

    /// Plan §7.4: "older than 7 days."
    public static let retentionWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Minimal shape this job needs from a CloudKit `Snapshot` record: just
    /// enough to identify it for deletion and to age it against `now`.
    /// Deliberately not `SnapshotRecord` itself (`SyncRecords.swift`) —
    /// `SnapshotRecord` has no stable identifier of its own (its
    /// `CKRecord.ID.recordName` is a fresh random UUID minted only at
    /// `CKMapper.record(from:zoneID:)` time, per that file's "recordName
    /// convention" doc comment), so the caller that fetched real
    /// `CKRecord`s from CloudKit is the one that has `CKRecord.ID`s to hand
    /// in. Keeping this job generic over `Identifier` (rather than hardcoding
    /// `CKRecord.ID`) is what keeps it CloudKit-import-free and testable
    /// with plain strings/UUIDs.
    public struct Candidate<Identifier: Hashable>: Equatable where Identifier: Equatable {
        public let id: Identifier
        public let timestamp: Date

        public init(id: Identifier, timestamp: Date) {
            self.id = id
            self.timestamp = timestamp
        }
    }

    /// Returns the identifiers of every candidate strictly older than the
    /// 7-day retention window as of `now`.
    ///
    /// **Boundary rule**, matching `RollupJob`'s `ts < cutoff` convention
    /// (see its hourly/daily rollup methods): `cutoff = now -
    /// retentionWindow`, and a candidate is pruned iff `timestamp < cutoff`
    /// — i.e. iff `now.timeIntervalSince(timestamp) > retentionWindow`
    /// (strictly greater). A snapshot exactly 7 days old at the instant
    /// `now` is sampled is **kept**, not pruned — the window is "older than
    /// 7 days," not "7 days or older," and matching `RollupJob`'s existing
    /// strict-inequality precedent means the two retention jobs in this
    /// codebase agree on what "older than N" means at the exact boundary
    /// instead of silently disagreeing by one tick.
    public static func identifiersToPrune<Identifier>(
        _ candidates: [Candidate<Identifier>],
        now: Date = Date()
    ) -> [Identifier] {
        let cutoff = now.addingTimeInterval(-retentionWindow)
        return candidates
            .filter { $0.timestamp < cutoff }
            .map(\.id)
    }
}
