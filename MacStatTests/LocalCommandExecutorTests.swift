import XCTest
@testable import MacStatKit

/// Unit tests for `LocalCommandExecutor` (`MacStatKit/Services/LocalCommandExecutor.swift`)
/// — the Mac-side handler that turns a `ControlCommand` arriving over
/// `LocalSyncServer` into a real `PowerControlService` call. Real
/// `IOPMAssertion` creation, same justification/cleanup discipline as
/// `PowerControlServiceTests` (public, unprivileged API, safe in a test
/// host, every test releases what it creates).
@MainActor
final class LocalCommandExecutorTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeTestDefaults(_ name: String) -> UserDefaults {
        let suiteName = "dev.malekswilam.macstat.tests.LocalCommandExecutorTests.\(name).\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeExecutor(_ name: String) -> (LocalCommandExecutor, PowerControlService) {
        let powerControl = PowerControlService(defaults: makeTestDefaults(name))
        let executor = LocalCommandExecutor(powerControl: powerControl, deviceID: "test-mac")
        return (executor, powerControl)
    }

    private func command(
        type: String,
        parametersJSON: String,
        nonce: String = UUID().uuidString,
        expiresAt: Date = Date().addingTimeInterval(300)
    ) -> ControlCommand {
        ControlCommand(
            deviceID: "test-mac",
            issuedAt: Date(),
            commandType: type,
            parametersJSON: parametersJSON,
            nonce: nonce,
            expiresAt: expiresAt
        )
    }

    // MARK: - keepAwake

    func testKeepAwakeStartsARealAssertionAndReportsCompleted() throws {
        let (executor, powerControl) = makeExecutor("keepAwake")
        defer { powerControl.releaseAssertion() }

        let status = executor.execute(command(
            type: "keepAwake",
            parametersJSON: #"{"durationSeconds":60,"mode":"systemOnly"}"#
        ))

        XCTAssertEqual(status.state, "completed")
        XCTAssertTrue(status.assertionActive)
        XCTAssertNotNil(status.assertionExpiresAt)
        guard case .active(let mode, _, _) = powerControl.state else {
            return XCTFail("expected an active assertion")
        }
        XCTAssertEqual(mode, .systemOnly)
    }

    func testKeepAwakeWithUnknownModeIsRejected() {
        let (executor, powerControl) = makeExecutor("keepAwakeBadMode")
        defer { powerControl.releaseAssertion() }

        let status = executor.execute(command(
            type: "keepAwake",
            parametersJSON: #"{"durationSeconds":60,"mode":"notARealMode"}"#
        ))

        XCTAssertEqual(status.state, "rejected")
        XCTAssertFalse(status.assertionActive)
    }

    // MARK: - releaseAwake

    func testReleaseAwakeReleasesAnActiveAssertion() throws {
        let (executor, powerControl) = makeExecutor("release")
        try powerControl.startAssertion(mode: .systemOnly, duration: 60, reason: "pre-existing")

        let status = executor.execute(command(type: "releaseAwake", parametersJSON: "{}"))

        XCTAssertEqual(status.state, "completed")
        XCTAssertFalse(status.assertionActive)
        XCTAssertEqual(powerControl.state, .inactive)
    }

    // MARK: - extendAwake / truncateAwake

    func testExtendAwakeLengthensRemainingTime() throws {
        let (executor, powerControl) = makeExecutor("extend")
        defer { powerControl.releaseAssertion() }
        try powerControl.startAssertion(mode: .systemOnly, duration: 60, reason: "pre-existing")

        let status = executor.execute(command(type: "extendAwake", parametersJSON: #"{"deltaSeconds":900}"#))

        XCTAssertEqual(status.state, "completed")
        guard case .active(_, let expiresAt, _) = powerControl.state, let expiresAt else {
            return XCTFail("expected a timed active assertion")
        }
        // Original 60s + 900s extension, generous tolerance for test wall-clock drift.
        XCTAssertEqual(expiresAt.timeIntervalSinceNow, 960, accuracy: 5)
    }

    func testTruncateAwakeWithNoActiveAssertionIsRejected() {
        let (executor, powerControl) = makeExecutor("truncateNoAssertion")
        defer { powerControl.releaseAssertion() }

        let status = executor.execute(command(type: "truncateAwake", parametersJSON: #"{"deltaSeconds":900}"#))

        XCTAssertEqual(status.state, "rejected")
    }

    // MARK: - Unknown command type

    func testUnknownCommandTypeIsRejected() {
        let (executor, powerControl) = makeExecutor("unknown")
        defer { powerControl.releaseAssertion() }

        let status = executor.execute(command(type: "danceAJig", parametersJSON: "{}"))

        XCTAssertEqual(status.state, "rejected")
        XCTAssertTrue(status.message.contains("danceAJig"))
    }

    // MARK: - Expiry

    func testExpiredCommandIsReportedAsExpiredAndNeverExecuted() {
        let (executor, powerControl) = makeExecutor("expired")
        defer { powerControl.releaseAssertion() }

        let status = executor.execute(command(
            type: "keepAwake",
            parametersJSON: #"{"durationSeconds":60,"mode":"systemOnly"}"#,
            expiresAt: Date().addingTimeInterval(-10)
        ))

        XCTAssertEqual(status.state, "expired")
        XCTAssertEqual(powerControl.state, .inactive)
    }

    // MARK: - Idempotency

    func testDuplicateNonceIsNotExecutedTwiceButStillReportsCompleted() throws {
        let (executor, powerControl) = makeExecutor("duplicate")
        defer { powerControl.releaseAssertion() }

        let duplicateCommand = command(
            type: "keepAwake",
            parametersJSON: #"{"durationSeconds":60,"mode":"systemOnly"}"#,
            nonce: "same-nonce"
        )

        let first = executor.execute(duplicateCommand)
        XCTAssertEqual(first.state, "completed")

        guard case .active(_, let firstExpiresAt, _) = powerControl.state else {
            return XCTFail("expected an active assertion after first execution")
        }

        // Simulate the Mac's assertion having been separately adjusted
        // between the two deliveries — if the duplicate re-ran
        // `startAssertion`, this would get clobbered back to ~60s.
        try powerControl.adjustAssertion(bySeconds: 500)

        let second = executor.execute(duplicateCommand)
        XCTAssertEqual(second.state, "completed", "a redelivered nonce should still report success")

        guard case .active(_, let secondExpiresAt, _) = powerControl.state, let secondExpiresAt else {
            return XCTFail("expected the assertion to remain active")
        }
        XCTAssertNotEqual(firstExpiresAt, secondExpiresAt, "the duplicate must not have re-run startAssertion and reset the extension")
    }
}
