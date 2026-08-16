import XCTest
@testable import SentryKit

/// Unit tests for `KeepAwakeRequest` (`SentryKit/Sync/KeepAwakeRequest.swift`)
/// — the one encoder behind every remote surface's `keepAwake`
/// `parametersJSON` (iPhone/Watch Siri intents, the Watch app's Keep Awake
/// page, the Control Center toggle). The JSON-shape tests pin the wire
/// contract; the executor round-trips prove the contract against the real
/// Mac-side handler, so "omitting `durationSeconds` means indefinite" is a
/// tested end-to-end fact rather than two implementations happening to
/// agree (the coincidence `ContentView.send(_:)`'s old comment warned
/// about).
@MainActor
final class KeepAwakeRequestTests: XCTestCase {

    // MARK: - Predicate

    func testZeroAndNegativeMinutesAreIndefinite() {
        // Zero is the documented "until you release it" contract shared
        // with `KeepMacAwakeIntent` and MCP's `keep_awake`; negatives fold
        // in because there is no coherent negative duration to preserve.
        XCTAssertTrue(KeepAwakeRequest.isIndefinite(minutes: 0))
        XCTAssertTrue(KeepAwakeRequest.isIndefinite(minutes: -5))
        XCTAssertFalse(KeepAwakeRequest.isIndefinite(minutes: 1))
    }

    // MARK: - Wire shape

    func testTimedRequestCarriesDurationSecondsAndMode() throws {
        let object = try decode(KeepAwakeRequest.parametersJSON(minutes: 45))
        XCTAssertEqual(object["durationSeconds"] as? Double, 45 * 60)
        XCTAssertEqual(object["mode"] as? String, "systemOnly")
    }

    func testIndefiniteRequestOmitsDurationSecondsEntirely() throws {
        // Omission is the contract — never an explicit zero the Mac has to
        // interpret through `executeKeepAwake`'s `> 0` coercion.
        let object = try decode(KeepAwakeRequest.parametersJSON(minutes: 0))
        XCTAssertNil(object["durationSeconds"])
        XCTAssertEqual(object["mode"] as? String, "systemOnly")
    }

    func testModeRoundTripsThroughAwakeModeRawValue() throws {
        // The string in the JSON must be an `AwakeMode.rawValue` —
        // `LocalCommandExecutor.executeKeepAwake` rejects anything else
        // with `kIOReturnBadArgument`.
        let object = try decode(KeepAwakeRequest.parametersJSON(minutes: 10))
        let raw = try XCTUnwrap(object["mode"] as? String)
        XCTAssertEqual(AwakeMode(rawValue: raw), .systemOnly)
    }

    // MARK: - Round trip against the real Mac-side handler

    func testIndefiniteRequestArmsAnUntimedAssertion() throws {
        let (executor, powerControl) = makeExecutor("indefinite")
        defer { powerControl.releaseAssertion() }

        let status = executor.execute(command(
            parametersJSON: KeepAwakeRequest.parametersJSON(minutes: 0)
        ))

        XCTAssertEqual(status.state, "completed")
        XCTAssertTrue(status.assertionActive)
        // The whole point: no `expiresAt`, so no timer will ever release
        // this — it ends when the user says so, exactly what the surface's
        // "until you release it" sentence promised.
        XCTAssertNil(status.assertionExpiresAt)
        guard case .active(_, let expiresAt, _) = powerControl.state else {
            return XCTFail("expected an active assertion")
        }
        XCTAssertNil(expiresAt)
    }

    func testTimedRequestArmsAHoldEndingWhenTheSentenceSaid() throws {
        let (executor, powerControl) = makeExecutor("timed")
        defer { powerControl.releaseAssertion() }

        let status = executor.execute(command(
            parametersJSON: KeepAwakeRequest.parametersJSON(minutes: 30)
        ))

        XCTAssertEqual(status.state, "completed")
        let expiresAt = try XCTUnwrap(status.assertionExpiresAt)
        // "Your Mac will stay awake for 30 minutes" must be what actually
        // got armed — generous tolerance for test wall-clock drift, same as
        // `LocalCommandExecutorTests`.
        XCTAssertEqual(expiresAt.timeIntervalSinceNow, 30 * 60, accuracy: 5)
    }

    // MARK: - Fixtures (mirrors LocalCommandExecutorTests' helpers)

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeExecutor(_ name: String) -> (LocalCommandExecutor, PowerControlService) {
        let suiteName = "dev.malekswilam.sentry.tests.KeepAwakeRequestTests.\(name).\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let powerControl = PowerControlService(defaults: defaults)
        return (LocalCommandExecutor(powerControl: powerControl, deviceID: "test-mac"), powerControl)
    }

    private func command(parametersJSON: String) -> ControlCommand {
        ControlCommand(
            deviceID: "test-mac",
            issuedAt: Date(),
            commandType: "keepAwake",
            parametersJSON: parametersJSON,
            nonce: UUID().uuidString,
            expiresAt: Date().addingTimeInterval(300)
        )
    }

    private func decode(_ json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
