import XCTest
@testable import MacStatKit

/// Covers `StatuslineCache`, the one-file fallback `macstat statusline`
/// falls back to when `MacStat.app` can't answer inside its 50ms budget
/// (plan §21.5's Starship `command_timeout` precedent).
///
/// A cache that quietly returns something wrong is worse than no cache at
/// all here, because the CLI's whole justification for reading it is "a
/// labeled stale number beats a blank prompt" — and that trade collapses if
/// the number is unlabeled, unbounded in age, or survives the user revoking
/// access. Those three are what this suite pins.
final class StatuslineCacheTests: XCTestCase {

    private var directory: URL!
    private var cache: StatuslineCache!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatuslineCacheTests-\(UUID().uuidString)", isDirectory: true)
        cache = StatuslineCache(fileURL: directory.appendingPathComponent("statusline.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func snapshot(at timestamp: Date, cpu: Double = 33) -> SystemSnapshot {
        SystemSnapshot(
            timestamp: timestamp,
            deviceID: "test-device",
            cpu: CPUStats(totalPercent: cpu)
        )
    }

    // MARK: - Round trip

    func testStoringThenLoadingPreservesTheSnapshot() {
        let now = Date()
        XCTAssertTrue(cache.store(snapshot(at: now, cpu: 41)))

        let entry = cache.load(now: now)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.snapshot.cpu?.totalPercent, 41)
    }

    func testStoreCreatesItsDirectory() {
        // `~/Library/Caches/dev.malekswilam.macstat/` does not exist on a
        // machine where `statusline` has never run, which is every machine
        // the first time.
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(cache.store(snapshot(at: Date())))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.fileURL.path))
    }

    func testAgeIsMeasuredFromTheSampleTimeNotTheWriteTime() {
        // The distinction is the whole reason `Entry` wraps the snapshot
        // instead of being one: the user cares how old the *reading* is, and
        // a snapshot served from a paused sampling loop can be much older
        // than the moment the CLI received it.
        let sampledAt = Date(timeIntervalSince1970: 1_000_000)
        let receivedAt = sampledAt.addingTimeInterval(30)
        let entry = StatuslineCache.Entry(capturedAt: receivedAt, snapshot: snapshot(at: sampledAt))
        XCTAssertEqual(entry.age(now: receivedAt), 30, accuracy: 0.001)
    }

    func testAgeNeverGoesNegativeWhenTheClockMovesBackwards() {
        // NTP correction or a manual clock change between write and read
        // would otherwise put "stale_s=-4" in somebody's prompt.
        let sampledAt = Date(timeIntervalSince1970: 1_000_000)
        let entry = StatuslineCache.Entry(snapshot: snapshot(at: sampledAt))
        XCTAssertEqual(entry.age(now: sampledAt.addingTimeInterval(-90)), 0)
    }

    // MARK: - Bounded staleness

    func testAnEntryOlderThanTheStalenessCeilingIsNotReturned() {
        let sampledAt = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(cache.store(snapshot(at: sampledAt), now: sampledAt))

        let justInside = sampledAt.addingTimeInterval(StatuslineRenderer.maximumUsableStaleness - 1)
        XCTAssertNotNil(cache.load(now: justInside))

        let wellPast = sampledAt.addingTimeInterval(StatuslineRenderer.maximumUsableStaleness + 1)
        XCTAssertNil(
            cache.load(now: wellPast),
            "past the ceiling this stops being a degraded reading and becomes a claim about a machine state that no longer exists"
        )
    }

    // MARK: - Absent and corrupt files

    func testLoadingWithNoFileReturnsNilRatherThanThrowing() {
        XCTAssertNil(cache.load())
    }

    func testACorruptCacheFileIsTreatedAsNoCacheRatherThanCrashing() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: cache.fileURL)
        XCTAssertNil(cache.load())
        // And it self-heals: the next successful call overwrites it.
        XCTAssertTrue(cache.store(snapshot(at: Date())))
        XCTAssertNotNil(cache.load())
    }

    // MARK: - Revocation

    func testDiscardRemovesTheFileSoARevokedPermissionTakesEffectImmediately() {
        XCTAssertTrue(cache.store(snapshot(at: Date())))
        cache.discard()
        XCTAssertNil(cache.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL.path))
    }

    func testDiscardOnAnAbsentFileIsHarmless() {
        cache.discard()
        XCTAssertNil(cache.load())
    }

    // MARK: - Default location

    func testTheDefaultLocationIsUnderCachesAndNotApplicationSupport() {
        // Deliberate: macOS may delete this at will and nothing breaks. If
        // it ever moved next to settings.json/history.sqlite it would become
        // a file the app is expected to preserve, which it is not.
        let path = StatuslineCache.defaultFileURL().path
        XCTAssertTrue(path.contains("/Caches/"), path)
        XCTAssertFalse(path.contains("Application Support"), path)
        XCTAssertTrue(path.hasSuffix("dev.malekswilam.macstat/statusline.json"), path)
    }
}
