import XCTest
@testable import MacStatKit

/// Safety requirement 3: who is allowed to speak to a root process.
///
/// **Why a fake evaluator rather than the real Security-framework calls.**
/// On this machine `security find-identity -v -p codesigning` reports zero
/// valid identities, so `SecCodeCheckValidity` can only ever fail — a suite
/// built on the real evaluator could assert "it refused" and nothing else,
/// proving nothing about the branch that matters. `FanDaemonPeerGate` takes
/// its evaluator as a parameter for exactly this reason, and
/// `SecurityFrameworkPeerEvaluator` is deliberately kept to four
/// mechanical lines so that almost nothing of consequence lives on the
/// untestable side of that line.
///
/// What remains genuinely unverified, and is stated here rather than
/// implied: no real `SecCodeCheckValidity` verdict against a real signed
/// Sentry has ever been observed from this branch.
final class FanDaemonPeerGateTests: XCTestCase {

    /// Answers whatever the test wants, and records what it was asked.
    private final class FakeEvaluator: FanDaemonPeerEvaluator {
        var answer: FanDaemonPeerFailure?
        private(set) var calls: [(pid: Int32, requirement: String)] = []

        init(answer: FanDaemonPeerFailure? = nil) { self.answer = answer }

        func evaluate(pid: Int32, requirement: String) -> FanDaemonPeerFailure? {
            calls.append((pid, requirement))
            return answer
        }
    }

    private let ownPID: Int32 = 4242

    // MARK: - Accept

    func testAPeerWhoseSignatureSatisfiesTheRequirementIsAccepted() {
        let evaluator = FakeEvaluator(answer: nil)
        let decision = FanDaemonPeerGate.decide(pid: 501, ownPID: ownPID, evaluator: evaluator)
        XCTAssertEqual(decision, .accept)
        XCTAssertTrue(decision.isAccepted)
    }

    func testTheProductionRequirementIsWhatGetsEvaluated() {
        // Not a tautology: a gate that quietly evaluated a *weaker*
        // requirement than the one documented would pass every other test
        // in this file.
        let evaluator = FakeEvaluator()
        _ = FanDaemonPeerGate.decide(pid: 501, ownPID: ownPID, evaluator: evaluator)
        XCTAssertEqual(evaluator.calls.map(\.requirement), [FanDaemonPeerGate.clientRequirement])
    }

    // MARK: - Reject: implausible peers, before any evaluation

    func testImplausiblePidsAreRejectedWithoutConsultingTheEvaluatorAtAll() {
        // pid 0 is the kernel, 1 is launchd, negatives are impossible.
        // Rejected before the Security framework is asked, so a Security
        // framework that somehow said yes could not override this.
        for pid: Int32 in [0, 1, -1, Int32.min] {
            let evaluator = FakeEvaluator(answer: nil)
            let decision = FanDaemonPeerGate.decide(pid: pid, ownPID: ownPID, evaluator: evaluator)
            XCTAssertEqual(decision, .reject(.implausiblePeer(pid: pid)))
            XCTAssertTrue(evaluator.calls.isEmpty, "pid \(pid) must be rejected before evaluation")
        }
    }

    func testAConnectionAppearingToComeFromTheDaemonItselfIsRejected() {
        let evaluator = FakeEvaluator(answer: nil)
        let decision = FanDaemonPeerGate.decide(pid: ownPID, ownPID: ownPID, evaluator: evaluator)
        XCTAssertEqual(decision, .reject(.implausiblePeer(pid: ownPID)))
        XCTAssertTrue(evaluator.calls.isEmpty)
    }

    // MARK: - Reject: every evaluator failure fails closed

    func testEveryEvaluatorFailureRejects() {
        // The important direction. There is no failure mode — including one
        // that is entirely our own fault — that results in a root process
        // accepting a connection it could not verify.
        let failures: [FanDaemonPeerFailure] = [
            .staticCodeUnavailable(osStatus: -67062),
            .requirementNotSatisfied(osStatus: -67050),
            .requirementMalformed(osStatus: -67028),
            .implausiblePeer(pid: 9)
        ]
        for failure in failures {
            let decision = FanDaemonPeerGate.decide(
                pid: 501,
                ownPID: ownPID,
                evaluator: FakeEvaluator(answer: failure)
            )
            XCTAssertEqual(decision, .reject(failure))
            XCTAssertFalse(decision.isAccepted, "\(failure) must not be accepted")
        }
    }

    func testAMalformedRequirementRejectsEveryoneRatherThanNobody() {
        // The case most likely to be hit first on a machine where signing
        // was never set up, and the one where "fail open" would be easiest
        // to write by accident.
        let decision = FanDaemonPeerGate.decide(
            pid: 501,
            ownPID: ownPID,
            evaluator: FakeEvaluator(answer: .requirementMalformed(osStatus: -67028)),
            requirement: "this is not a code requirement"
        )
        XCTAssertFalse(decision.isAccepted)
    }

    func testEveryFailureExplainsItselfDistinctly() {
        let failures: [FanDaemonPeerFailure] = [
            .implausiblePeer(pid: 1),
            .staticCodeUnavailable(osStatus: -1),
            .requirementNotSatisfied(osStatus: -2),
            .requirementMalformed(osStatus: -3)
        ]
        let messages = failures.map(\.message)
        XCTAssertEqual(Set(messages).count, failures.count, "each failure must read differently")
        for message in messages {
            XCTAssertFalse(message.isEmpty)
        }
        XCTAssertTrue(
            FanDaemonPeerFailure.requirementNotSatisfied(osStatus: -2).message.contains("Sentry"),
            "the interesting refusal must say what was expected"
        )
    }

    // MARK: - The requirement string itself

    func testTheRequirementPinsBundleIdentifierAnchorAndTeamID() {
        // Each clause prevents a different bypass — see
        // `FanDaemonPeerGate.clientRequirement`'s doc comment. Dropping any
        // one of them is a silent weakening, so all three are asserted.
        let requirement = FanDaemonPeerGate.clientRequirement
        XCTAssertTrue(requirement.contains("identifier \"dev.malekswilam.macstat\""))
        XCTAssertTrue(requirement.contains("anchor apple generic"))
        XCTAssertTrue(requirement.contains("certificate leaf[subject.OU] = \"H7T2D2GL7U\""))
    }

    func testTheRequirementMatchesTheOneEmbeddedInTheDaemonsInfoPlist() {
        // ⚠️ This string is necessarily duplicated: launchd reads the
        // daemon's `SMAuthorizedClients` plist entry and cannot read Swift,
        // so the two cannot share a constant. This test is the only thing
        // keeping them identical. If it fails, edit BOTH
        // `FanDaemonPeerGate.clientRequirement` and the `SMAuthorizedClients`
        // entry under the `SentryFanDaemon` target in `project.yml`.
        //
        // The expected text is written out literally rather than derived,
        // so a change on the Swift side cannot make this test agree with
        // itself.
        XCTAssertEqual(
            FanDaemonPeerGate.clientRequirement,
            "identifier \"dev.malekswilam.macstat\" and anchor apple generic and certificate leaf[subject.OU] = \"H7T2D2GL7U\""
        )
    }
}
