import XCTest
@testable import SentryKit

/// Tests for the kill-switch/per-agent-stop seams that are exercisable
/// without a live XPC connection: `PowerControlService`'s additive agent
/// assertion ownership (real `IOPMAssertion`s, same safety reasoning as
/// `PowerControlServiceTests` — public, unprivileged API, and every test
/// releases what it creates) and `LocalCommandExecutor`'s
/// `setAgentAccessPaused` command, the Mac-side landing point of the Watch's
/// kill switch. The remaining links — `MCPXPCService.authorize` consulting
/// the guardrail engine, and `AppDelegate`'s settings sink releasing on a
/// kill-switch rising edge — are composition-root glue over the pure pieces
/// tested here and in `AgentGuardrailsTests`.
@MainActor
final class AgentTerminationControlsTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeTestDefaults(_ name: String) -> UserDefaults {
        let suiteName = "dev.malekswilam.sentry.tests.AgentTerminationControlsTests.\(name).\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - PowerControlService agent ownership

    func testAgentAssertionRecordsOwner() throws {
        let service = PowerControlService(defaults: makeTestDefaults("recordsOwner"))
        defer { service.releaseAssertion() }

        XCTAssertNil(service.agentAssertionOwner)
        try service.startAgentAssertion(mode: .systemOnly, duration: 60, reason: "test", clientName: "Claude Code")
        XCTAssertEqual(service.agentAssertionOwner, "Claude Code")
    }

    func testReleaseClearsOwner() throws {
        let service = PowerControlService(defaults: makeTestDefaults("releaseClears"))
        try service.startAgentAssertion(mode: .systemOnly, duration: 60, reason: "test", clientName: "Claude Code")
        service.releaseAssertion()
        XCTAssertNil(service.agentAssertionOwner, "an inactive assertion has no agent owner, whatever the stale tag says")
    }

    func testUserStartedAssertionIsNotAgentOwned() throws {
        let service = PowerControlService(defaults: makeTestDefaults("userNotOwned"))
        defer { service.releaseAssertion() }

        try service.startAssertion(mode: .systemOnly, duration: 60, reason: "user's own hold")
        XCTAssertNil(service.agentAssertionOwner)
    }

    func testUserAssertionReplacingAgentOneClearsOwnership() throws {
        // The generation-tag design: the user's fresh assertion bumps
        // `assertionGeneration`, so the agent tag goes stale and the kill
        // switch must not tear down the user's hold.
        let service = PowerControlService(defaults: makeTestDefaults("userReplaces"))
        defer { service.releaseAssertion() }

        try service.startAgentAssertion(mode: .systemOnly, duration: 60, reason: "agent", clientName: "Claude Code")
        try service.startAssertion(mode: .systemOnly, duration: 60, reason: "user's own hold")
        XCTAssertNil(service.agentAssertionOwner)
        XCTAssertFalse(service.releaseAgentAssertion(), "nothing agent-held should be releasable")
        XCTAssertNotEqual(service.state, .inactive, "the user's hold must survive an agent release sweep")
    }

    func testReleaseAgentAssertionMatchesOwner() throws {
        let service = PowerControlService(defaults: makeTestDefaults("matchesOwner"))
        defer { service.releaseAssertion() }

        try service.startAgentAssertion(mode: .systemOnly, duration: 60, reason: "agent", clientName: "Claude Code")
        XCTAssertFalse(service.releaseAgentAssertion(ownedBy: "Cursor"), "another client's stop must not release this hold")
        XCTAssertNotEqual(service.state, .inactive)
        XCTAssertTrue(service.releaseAgentAssertion(ownedBy: "Claude Code"))
        XCTAssertEqual(service.state, .inactive)
    }

    func testReleaseAgentAssertionWithoutNameReleasesAnyAgentHold() throws {
        // The kill-switch shape: release whatever agent holds, whoever it is.
        let service = PowerControlService(defaults: makeTestDefaults("anyAgent"))
        try service.startAgentAssertion(mode: .systemOnly, duration: 60, reason: "agent", clientName: "Cursor")
        XCTAssertTrue(service.releaseAgentAssertion())
        XCTAssertEqual(service.state, .inactive)
        XCTAssertFalse(service.releaseAgentAssertion(), "second sweep finds nothing — idempotent")
    }

    func testZeroDurationAgentRequestTagsNothing() throws {
        // `startAssertionInternal` documents a zero-length request as "nothing
        // held"; the ownership tag must agree rather than claim a hold exists.
        let service = PowerControlService(defaults: makeTestDefaults("zeroDuration"))
        try service.startAgentAssertion(mode: .systemOnly, duration: 0, reason: "degenerate", clientName: "Claude Code")
        XCTAssertEqual(service.state, .inactive)
        XCTAssertNil(service.agentAssertionOwner)
    }

    // MARK: - LocalCommandExecutor setAgentAccessPaused (the Watch kill switch's landing point)

    private func command(type: String, parametersJSON: String = "{}") -> ControlCommand {
        ControlCommand(
            deviceID: "test-device",
            issuedAt: Date(),
            commandType: type,
            parametersJSON: parametersJSON,
            nonce: UUID().uuidString,
            expiresAt: Date().addingTimeInterval(300)
        )
    }

    private func makeExecutor(_ name: String) -> (LocalCommandExecutor, PowerControlService) {
        let power = PowerControlService(defaults: makeTestDefaults(name))
        let executor = LocalCommandExecutor(powerControl: power, deviceID: "test-device")
        return (executor, power)
    }

    func testSetAgentAccessPausedInvokesHandlerWithTrue() {
        let (executor, power) = makeExecutor("pauseTrue")
        defer { power.releaseAssertion() }

        var received: [Bool] = []
        executor.agentAccessPauseHandler = { received.append($0) }

        let status = executor.execute(command(type: "setAgentAccessPaused", parametersJSON: #"{"paused":true}"#))
        XCTAssertEqual(status.state, "completed")
        XCTAssertEqual(received, [true])
    }

    func testSetAgentAccessPausedPassesFalseThrough() {
        let (executor, power) = makeExecutor("pauseFalse")
        defer { power.releaseAssertion() }

        var received: [Bool] = []
        executor.agentAccessPauseHandler = { received.append($0) }

        let status = executor.execute(command(type: "setAgentAccessPaused", parametersJSON: #"{"paused":false}"#))
        XCTAssertEqual(status.state, "completed")
        XCTAssertEqual(received, [false])
    }

    func testSetAgentAccessPausedDefaultsToPausedWhenParameterOmitted() {
        // "Stop agents" is the only intent a sender omitting the flag could
        // have meant — see `LocalCommandExecutor.Parameters.paused`.
        let (executor, power) = makeExecutor("pauseDefault")
        defer { power.releaseAssertion() }

        var received: [Bool] = []
        executor.agentAccessPauseHandler = { received.append($0) }

        XCTAssertEqual(executor.execute(command(type: "setAgentAccessPaused")).state, "completed")
        XCTAssertEqual(received, [true])
    }

    func testSetAgentAccessPausedRejectedWhenUnwired() {
        // No handler must mean an honest rejection, never a silent
        // "completed" for a switch that didn't flip.
        let (executor, power) = makeExecutor("pauseUnwired")
        defer { power.releaseAssertion() }

        let status = executor.execute(command(type: "setAgentAccessPaused", parametersJSON: #"{"paused":true}"#))
        XCTAssertEqual(status.state, "rejected")
    }

    func testSetAgentAccessPausedIsNonceIdempotent() {
        // Same `NonceTracker` gate as every other command: a redelivered
        // kill-switch command reports success again but doesn't re-flip.
        let (executor, power) = makeExecutor("pauseIdempotent")
        defer { power.releaseAssertion() }

        var callCount = 0
        executor.agentAccessPauseHandler = { _ in callCount += 1 }

        let repeated = command(type: "setAgentAccessPaused", parametersJSON: #"{"paused":true}"#)
        XCTAssertEqual(executor.execute(repeated).state, "completed")
        XCTAssertEqual(executor.execute(repeated).state, "completed")
        XCTAssertEqual(callCount, 1)
    }

    // MARK: - Decision plumbing

    func testGuardrailDecisionCountsAsDenied() {
        // `MCPActivityLog`'s denied-capacity partition and `MCPXPCService`'s
        // logging both branch on `isDenied`; the new case must sort with the
        // denials.
        XCTAssertTrue(MCPAccessController.Decision.denyGuardrail(reason: "test").isDenied)
    }
}
