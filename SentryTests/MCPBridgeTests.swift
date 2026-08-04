import XCTest
import ServiceManagement
@testable import Sentry
@testable import SentryKit

/// Tests for the command-line bridge's pure layer.
///
/// **What these can and cannot prove, stated up front.** The machine this was
/// written on has zero code-signing identities, so `SMAppService.agent(...)
/// .register()` cannot succeed and no real peer evaluation can return
/// `errSecSuccess`. Every branch that matters is therefore expressed as a
/// function over values — the same split `FanDaemonPeerGateTests` makes — and
/// driven here with a fake evaluator. What is *not* covered, and cannot be
/// from this branch: launchd actually publishing the Mach service, a real
/// `SecCodeCheckValidity` verdict against a real signed peer, and the
/// end-to-end round trip through a registered agent. See
/// `SentryKit/MCPBridge/MCPBridgeContract.swift`.
///
/// One thing *was* verified outside these tests and is recorded there rather
/// than here because no unit test can express it: the underlying rendezvous
/// (launchd on-demand launch → app deposits an anonymous endpoint → client
/// resolves it and calls the app directly) was exercised end to end with three
/// hand-bootstrapped processes and no signing involved.
final class MCPBridgeNamingTests: XCTestCase {

    /// The whole feature turns on these three strings agreeing. They are
    /// deliberately *not* one constant — `MCPBridgeNaming` is compiled into
    /// the `SentryMCPBridge` tool target, which links no framework of ours —
    /// so this is the thing that keeps them from drifting.
    func testLabelPlistNameAndMachServiceAgree() {
        XCTAssertEqual(MCPBridgeNaming.label, "dev.malekswilam.sentry.xpc")
        XCTAssertEqual(MCPBridgeNaming.plistName, "dev.malekswilam.sentry.xpc.plist")
        XCTAssertEqual(MCPBridgeNaming.machService, MCPBridgeNaming.label)
    }

    /// launchd requires the job's `Label` to equal the plist's basename minus
    /// ".plist", and `SMAppService.agent(plistName:)` looks the file up by that
    /// basename. Getting this wrong produces an agent that registers and can
    /// never be reached — exactly the class of bug this whole change fixes, so
    /// it is worth a test that says so.
    func testPlistNameIsLabelPlusExtension() {
        XCTAssertEqual(
            MCPBridgeNaming.plistName,
            MCPBridgeNaming.label + ".plist"
        )
        XCTAssertEqual(
            (MCPBridgeNaming.plistName as NSString).deletingPathExtension,
            MCPBridgeNaming.label
        )
    }

    /// The client-facing name must not have changed. `integrations/` docs,
    /// shell scripts, and every MCP client config in the wild dial this
    /// string; keeping it identical was a design goal of the fix, not an
    /// accident.
    func testMachServiceMatchesTheLongstandingClientFacingName() {
        XCTAssertEqual(SentryXPCServiceName.machService, MCPBridgeNaming.machService)
        XCTAssertEqual(SentryXPCServiceName.machService, "dev.malekswilam.sentry.xpc")
    }

    func testIdleExitIsLongerThanTheResolveTimeout() {
        // Otherwise a client could time out waiting for an agent that was
        // about to retire itself mid-answer, and the resulting error would
        // describe a wedged bridge rather than a race.
        XCTAssertGreaterThan(MCPBridgeTiming.idleExitAfter, MCPBridgeTiming.resolveTimeout)
    }
}

final class MCPBridgePeerGateTests: XCTestCase {

    /// Records what it was asked and answers with whatever it was told to.
    private struct StubEvaluator: MCPBridgePeerEvaluator {
        let result: MCPBridgePeerFailure?
        final class Box: @unchecked Sendable { var requirements: [String] = []; var pids: [Int32] = [] }
        let box = Box()

        func evaluate(pid: Int32, requirement: String) -> MCPBridgePeerFailure? {
            box.pids.append(pid)
            box.requirements.append(requirement)
            return result
        }
    }

    // MARK: - The exact requirement strings

    /// ⚠️ These two assertions are the mechanism that keeps the Swift
    /// constants and the `SMAuthorizedClients` entry in `project.yml` /
    /// `SentryMCPBridge/Info.plist` from diverging. launchd reads a plist and
    /// cannot read Swift, so the strings must be duplicated; this test is what
    /// makes a change on the Swift side fail loudly instead of silently
    /// producing a mismatch that only shows up on a signed build.
    func testPublisherRequirementIsExactlyAsShipped() {
        XCTAssertEqual(
            MCPBridgePeerGate.publisherRequirement,
            "identifier \"dev.malekswilam.sentry\" and anchor apple generic and certificate leaf[subject.OU] = \"H7T2D2GL7U\""
        )
    }

    func testConsumerRequirementIsExactlyAsShipped() {
        XCTAssertEqual(
            MCPBridgePeerGate.consumerRequirement,
            "anchor apple generic and certificate leaf[subject.OU] = \"H7T2D2GL7U\""
        )
    }

    /// The consumer requirement is deliberately looser, and the looseness is
    /// specifically the absence of an `identifier` clause — see
    /// `MCPBridgePeerGate`'s doc comment for why one cannot be written for the
    /// nested tools. Both still pin the anchor and the Team ID; a requirement
    /// that dropped either would be no requirement at all.
    func testConsumerRequirementStillPinsAnchorAndTeam() {
        XCTAssertTrue(MCPBridgePeerGate.consumerRequirement.contains("anchor apple generic"))
        XCTAssertTrue(MCPBridgePeerGate.consumerRequirement.contains("H7T2D2GL7U"))
        XCTAssertFalse(MCPBridgePeerGate.consumerRequirement.contains("identifier"))
        XCTAssertTrue(MCPBridgePeerGate.publisherRequirement.contains("identifier"))
    }

    // MARK: - Fail-closed behaviour

    func testAcceptsWhenTheEvaluatorSucceeds() {
        let evaluator = StubEvaluator(result: nil)
        let decision = MCPBridgePeerGate.decide(
            pid: 4321,
            ownPID: 99,
            requirement: MCPBridgePeerGate.consumerRequirement,
            evaluator: evaluator
        )
        XCTAssertTrue(decision.isAccepted)
        XCTAssertEqual(evaluator.box.requirements, [MCPBridgePeerGate.consumerRequirement])
        XCTAssertEqual(evaluator.box.pids, [4321])
    }

    /// The requirement is passed through untouched. A gate that quietly
    /// substituted a different requirement than its caller asked for would be
    /// the worst possible bug in this file, because both call sites would
    /// still look correct.
    func testPassesTheRequirementItWasGivenVerbatim() {
        let evaluator = StubEvaluator(result: nil)
        _ = MCPBridgePeerGate.decide(
            pid: 500,
            ownPID: 99,
            requirement: MCPBridgePeerGate.publisherRequirement,
            evaluator: evaluator
        )
        XCTAssertEqual(evaluator.box.requirements, [MCPBridgePeerGate.publisherRequirement])
    }

    func testRejectsEveryImplausiblePID() {
        let evaluator = StubEvaluator(result: nil)
        for pid: Int32 in [-1, 0, 1] {
            let decision = MCPBridgePeerGate.decide(
                pid: pid,
                ownPID: 99,
                requirement: MCPBridgePeerGate.consumerRequirement,
                evaluator: evaluator
            )
            XCTAssertEqual(decision, .reject(.implausiblePeer(pid: pid)), "pid \(pid)")
        }
        // And never consulted the evaluator for any of them — the point is
        // that these are refused before any Security-framework call, not that
        // the call happens to fail.
        XCTAssertTrue(evaluator.box.pids.isEmpty)
    }

    func testRejectsItsOwnPID() {
        let evaluator = StubEvaluator(result: nil)
        let decision = MCPBridgePeerGate.decide(
            pid: 4242,
            ownPID: 4242,
            requirement: MCPBridgePeerGate.consumerRequirement,
            evaluator: evaluator
        )
        XCTAssertEqual(decision, .reject(.implausiblePeer(pid: 4242)))
        XCTAssertTrue(evaluator.box.pids.isEmpty)
    }

    /// Every evaluator failure is a refusal. There is no failure this gate
    /// treats as "probably fine" — in particular not `.requirementMalformed`,
    /// which is our own bug and the one most likely to be hit first on a
    /// machine where signing was never set up.
    func testEveryEvaluatorFailureIsARefusal() {
        let failures: [MCPBridgePeerFailure] = [
            .staticCodeUnavailable(osStatus: -67062),
            .requirementNotSatisfied(osStatus: -67050),
            .requirementMalformed(osStatus: -67029)
        ]
        for failure in failures {
            let decision = MCPBridgePeerGate.decide(
                pid: 777,
                ownPID: 99,
                requirement: MCPBridgePeerGate.consumerRequirement,
                evaluator: StubEvaluator(result: failure)
            )
            XCTAssertEqual(decision, .reject(failure))
            XCTAssertFalse(decision.isAccepted)
        }
    }

    /// Every failure has to explain itself to a human — these strings reach
    /// `sentryctl`'s stderr and the Settings pane. The unsigned-build case in
    /// particular must say so, because on this project that is overwhelmingly
    /// why a reader will ever see one.
    func testFailureMessagesAreNonEmptyAndNameTheUnsignedCase() {
        let all: [MCPBridgePeerFailure] = [
            .implausiblePeer(pid: 3),
            .staticCodeUnavailable(osStatus: -1),
            .requirementNotSatisfied(osStatus: -2),
            .requirementMalformed(osStatus: -3)
        ]
        for failure in all {
            XCTAssertFalse(failure.message.isEmpty, "\(failure)")
        }
        XCTAssertTrue(
            MCPBridgePeerFailure.requirementNotSatisfied(osStatus: -2).message
                .contains("Developer ID")
        )
    }
}

final class MCPBridgeRegistrationTests: XCTestCase {

    /// Only one state permits command-line access, and it is not the one a
    /// hopeful reading would pick: `.awaitingApproval` means macOS has the
    /// registration and is *not* running the agent, so tools still fail.
    /// Treating it as usable would put a green tick above a feature that
    /// doesn't work.
    func testOnlyRegisteredIsUsable() {
        XCTAssertTrue(MCPBridgeRegistration.registered.isUsable)
        XCTAssertFalse(MCPBridgeRegistration.awaitingApproval.isUsable)
        XCTAssertFalse(MCPBridgeRegistration.notRegistered.isUsable)
        XCTAssertFalse(MCPBridgeRegistration.unavailable(reason: "nope").isUsable)
    }

    /// The three states must be *distinguishable in words*, not just in the
    /// type system — that is the whole requirement this enum exists to meet.
    /// A user who reads the label and the paragraph should be able to tell
    /// which of the three problems they have.
    func testEveryStateHasDistinctUserFacingText() {
        let states: [MCPBridgeRegistration] = [
            .registered, .awaitingApproval, .notRegistered, .unavailable(reason: "code signature invalid")
        ]
        let labels = states.map(\.shortLabel)
        let explanations = states.map(\.explanation)

        XCTAssertEqual(Set(labels).count, states.count, "two states share a label: \(labels)")
        XCTAssertEqual(Set(explanations).count, states.count)
        for text in labels + explanations {
            XCTAssertFalse(text.isEmpty)
        }
    }

    /// The failure state must carry macOS's own words rather than replacing
    /// them with a guess. `FanControlPane` sets the same rule for the fan
    /// helper: print what the system said.
    func testUnavailableQuotesTheUnderlyingReason() {
        let registration = MCPBridgeRegistration.unavailable(reason: "Operation not permitted")
        XCTAssertTrue(registration.explanation.contains("Operation not permitted"))
    }

    /// The states that need the user to go somewhere say where. This is the
    /// specific failure the old code had — it told people to check whether the
    /// app was running, which was never the problem — so it is worth pinning.
    func testActionableStatesPointSomewhereReal() {
        XCTAssertTrue(
            MCPBridgeRegistration.awaitingApproval.explanation.contains("Login Items")
        )
        XCTAssertTrue(
            MCPBridgeRegistration.notRegistered.explanation.contains("background item")
        )
    }

    /// The unavailable state must not leave a user thinking the whole app is
    /// broken. Only two things stop working, and the HTTP transport is not one
    /// of them — it never used this path. Regressing that claim would be
    /// worse than saying nothing.
    func testUnavailableScopesTheDamageHonestly() {
        let explanation = MCPBridgeRegistration.unavailable(reason: "x").explanation
        XCTAssertTrue(explanation.contains("Remote Access"))
        XCTAssertTrue(explanation.contains("sentry"))
    }
}

final class SentryXPCClientMessagingTests: XCTestCase {

    /// `SentryCLI`'s `statusline` decides whether it may fall back to a
    /// possibly-stale cached reading by testing this prefix. If a
    /// connection-level message ever stopped carrying it, a user whose Sentry
    /// was unreachable would get a hard failure in their shell prompt instead
    /// of a labelled stale number; if a *permission denial* ever started
    /// carrying it, a user who had just switched the tool off would keep
    /// seeing telemetry rendered out of a file. Both directions matter.
    func testEveryConnectionLevelMessageCarriesThePrefix() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: 4099,
            userInfo: [NSLocalizedDescriptionKey: "Couldn't communicate with a helper application."]
        )
        let messages = [
            SentryXPCClient.callFailure(error),
            SentryXPCClient.mismatchedInterface
        ]
        for message in messages {
            XCTAssertTrue(
                message.hasPrefix(SentryXPCClient.unreachablePrefix),
                "missing prefix: \(message)"
            )
        }
    }

    /// The message must not ask the question that used to be asked. "Is
    /// Sentry running?" was wrong in the common case and sent people to check
    /// the one thing that was already fine — it is the specific regression
    /// this change exists to prevent.
    func testMessagesDoNotAskWhetherTheAppIsRunningAsTheFirstExplanation() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 4099, userInfo: nil)
        XCTAssertFalse(SentryXPCClient.callFailure(error).contains("Is Sentry running?"))
        XCTAssertFalse(SentryXPCClient.mismatchedInterface.contains("Is Sentry running?"))
    }
}

@MainActor
final class MCPEndpointPublisherTests: XCTestCase {

    /// A stub `SentryXPCServiceProtocol` — the publisher only ever hands this
    /// to `NSXPCListener` as an exported object, so nothing here is called.
    private final class NullService: NSObject, SentryXPCServiceProtocol {
        func ping(reply: @escaping (Bool) -> Void) { reply(true) }
        func getSystemSnapshot(clientName: String, reply: @escaping (Data?, String?) -> Void) { reply(nil, "stub") }
        func getBatteryStatus(clientName: String, reply: @escaping (Data?, String?) -> Void) { reply(nil, "stub") }
        func getBatteryHealthHistory(clientName: String, sinceDays: Int, reply: @escaping (Data?, String?) -> Void) { reply(nil, "stub") }
        func getMetricHistory(clientName: String, metric: String, sinceSeconds: Double, reply: @escaping (Data?, String?) -> Void) { reply(nil, "stub") }
        func getThermalStatus(clientName: String, reply: @escaping (Data?, String?) -> Void) { reply(nil, "stub") }
        func getResourceUsage(clientName: String, reply: @escaping (Data?, String?) -> Void) { reply(nil, "stub") }
        func getAlertHistory(clientName: String, limit: Int, sinceSeconds: Double, ruleID: String, reply: @escaping (Data?, String?) -> Void) { reply(nil, "stub") }
        func getDeviceInfo(clientName: String, reply: @escaping (Data?, String?) -> Void) { reply(nil, "stub") }
        func getSleepState(clientName: String, reply: @escaping (Data?, String?) -> Void) { reply(nil, "stub") }
        func preflightCheck(clientName: String, reply: @escaping (Data?, String?) -> Void) { reply(nil, "stub") }
        func getResourceEventsSince(clientName: String, sinceSeconds: Double, reply: @escaping (Data?, String?) -> Void) { reply(nil, "stub") }
        func getAgentCapacity(clientName: String, requestedAgents: Int, reply: @escaping (Data?, String?) -> Void) { reply(nil, "stub") }
        func getAgentActivity(clientName: String, limit: Int, reply: @escaping (Data?, String?) -> Void) { reply(nil, "stub") }
        func getSessionResourceReport(clientName: String, sinceSeconds: Double, reply: @escaping (Data?, String?) -> Void) { reply(nil, "stub") }
        func keepAwake(clientName: String, mode: String, durationSeconds: Double, reason: String, reply: @escaping (Bool, String?) -> Void) { reply(false, "stub") }
        func releaseAwake(clientName: String, reply: @escaping (Bool, String?) -> Void) { reply(false, "stub") }
        func setRefreshInterval(clientName: String, tier: String, seconds: Double, reply: @escaping (Bool, String?) -> Void) { reply(false, "stub") }
        func setAlertRuleEnabled(clientName: String, ruleID: String, enabled: Bool, reply: @escaping (Bool, String?) -> Void) { reply(false, "stub") }
        func createAlertRule(clientName: String, ruleJSON: Data, reply: @escaping (Bool, String?) -> Void) { reply(false, "stub") }
        func waitUntilReady(clientName: String, condition: String, timeoutSeconds: Double, reply: @escaping (Data?, String?) -> Void) { reply(nil, "stub") }
    }

    /// Every `SMAppService.Status` maps to exactly one honest state, and the
    /// mapping is driven here rather than through `SMAppService` — which on a
    /// machine with no signing identities can only ever report one value,
    /// making every other branch untestable. Same injection
    /// `PrivilegedFanControlBackendTests` uses for the fan daemon.
    func testEveryServiceStatusMapsToAnHonestState() {
        let expected: [(SMAppService.Status, MCPBridgeRegistration)] = [
            (.enabled, .registered),
            (.requiresApproval, .awaitingApproval),
            (.notRegistered, .notRegistered),
            (.notFound, .notRegistered)
        ]
        for (status, want) in expected {
            let publisher = MCPEndpointPublisher(service: NullService(), statusProbe: { status })
            XCTAssertEqual(publisher.registration, want, "\(status)")
        }
    }

    /// `.requiresApproval` is the trap: macOS has accepted the registration,
    /// so it is tempting to call it success — but the agent is not running and
    /// the tools still fail. Reporting it as usable would put a green tick
    /// above a feature that doesn't work.
    func testAwaitingApprovalIsNotReportedAsWorking() {
        let publisher = MCPEndpointPublisher(service: NullService(), statusProbe: { .requiresApproval })
        XCTAssertFalse(publisher.registration.isUsable)
        XCTAssertFalse(publisher.isPublished)
    }

    /// Nothing is claimed to be published until something actually publishes,
    /// in any state — including the one where everything is registered.
    func testNothingIsClaimedPublishedBeforeAnythingIsPublished() {
        for status: SMAppService.Status in [.enabled, .requiresApproval, .notRegistered, .notFound] {
            let publisher = MCPEndpointPublisher(service: NullService(), statusProbe: { status })
            XCTAssertFalse(publisher.isPublished, "\(status)")
            XCTAssertNil(publisher.lastPublishFailure, "\(status)")
        }
    }

    /// `publishIfRegistered()` must open no connection when the agent isn't
    /// registered — the property that keeps every unconfigured install exactly
    /// as it was. Asserted indirectly but meaningfully: after the call the
    /// publisher still reports nothing published and no failure, which it
    /// could not do if it had tried and failed against a Mach service that
    /// does not exist.
    func testPublishIsAWholeNoOpWhenNotRegistered() {
        let publisher = MCPEndpointPublisher(service: NullService(), statusProbe: { .notRegistered })
        publisher.publishIfRegistered()
        XCTAssertFalse(publisher.isPublished)
        XCTAssertNil(publisher.lastPublishFailure)
    }

    /// The real object graph `AppDelegate` builds — real `SMAppService` probe,
    /// no injection — on whatever machine runs this suite.
    ///
    /// In the spirit of `PrivilegedFanControlBackendTests`'s equivalent: it
    /// asserts the property this whole change was designed around, which is
    /// that constructing the publisher on a machine where nobody has set
    /// command-line access up changes nothing and connects to nothing.
    func testTheRealCompositionIsInertUntilSomebodySetsItUp() {
        let publisher = MCPEndpointPublisher(service: NullService())

        if publisher.registration.isUsable {
            // Would mean the agent really is registered on this machine. Not a
            // failure of the code, but it invalidates the premise of the rest
            // of this test, so it stops here loudly rather than asserting
            // something meaningless.
            XCTFail("this suite assumes command-line access is not set up; the agent appears to be registered")
            return
        }

        publisher.publishIfRegistered()
        XCTAssertFalse(publisher.isPublished)
        XCTAssertNil(publisher.lastPublishFailure)

        // And `refresh()` must be safe to call — it is called on every
        // appearance of the Settings pane, and must prompt nothing and launch
        // nothing.
        publisher.refresh()
        XCTAssertFalse(publisher.registration.isUsable)
    }
}
