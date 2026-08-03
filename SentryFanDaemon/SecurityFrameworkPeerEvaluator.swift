import Foundation
import Security

/// The production `FanDaemonPeerEvaluator`: the three Security-framework
/// calls that `FanDaemonPeerGate`'s tested decision logic wraps.
///
/// **Everything interesting about peer verification is in
/// `FanDaemonPeerGate`, not here**, and that split is the whole design. On
/// a machine with no signing identities every real evaluation fails
/// identically, so a test that exercised this type could only ever assert
/// "it refused", proving nothing about the branch that matters. So this
/// type is kept as close to zero-logic as an API this shape allows —
/// create a code object for the pid, compile the requirement, check
/// validity, map each failure to a case — and the gate above it holds the
/// decisions (implausible pids, fail-closed on a malformed requirement,
/// what "accept" requires) where they can be driven exhaustively with a
/// fake.
///
/// **Unverified.** `SecCodeCheckValidity` has never returned `errSecSuccess`
/// on this branch, because there has never been a signed client to hand it.
/// What *is* known is that it returns non-success here, and that the gate
/// turns non-success into a refusal — which is the direction that fails
/// safe.
struct SecurityFrameworkPeerEvaluator: FanDaemonPeerEvaluator {

    func evaluate(pid: Int32, requirement: String) -> FanDaemonPeerFailure? {

        // The requirement is compiled first, before any code object is
        // fetched. If our own requirement string is malformed we want the
        // refusal to say *that* — a `.requirementNotSatisfied` blamed on
        // the caller would send whoever is debugging this to inspect the
        // wrong binary.
        var secRequirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            requirement as CFString,
            [],
            &secRequirement
        )
        guard requirementStatus == errSecSuccess, let secRequirement else {
            return .requirementMalformed(osStatus: requirementStatus)
        }

        // `kSecGuestAttributePid` is the only peer identifier available
        // through public API from an `NSXPCConnection` — see
        // `FanDaemonPeerGate`'s doc comment for the pid-reuse weakness this
        // carries and why the undocumented audit-token property was not
        // used instead.
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        var code: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard guestStatus == errSecSuccess, let code else {
            return .staticCodeUnavailable(osStatus: guestStatus)
        }

        let validity = SecCodeCheckValidity(code, [], secRequirement)
        guard validity == errSecSuccess else {
            return .requirementNotSatisfied(osStatus: validity)
        }
        return nil
    }
}
