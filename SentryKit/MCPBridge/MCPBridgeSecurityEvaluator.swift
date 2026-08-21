import Foundation

// `Security` inside the platform guard rather than above it: this file is
// compiled into SentryKit_iOS too (that target compiles the same source
// directory), and there is no reason for the iOS build to link a framework
// for a type it cannot see.
#if os(macOS)
import Security

/// The production `MCPBridgePeerEvaluator`: the three Security-framework calls
/// that `MCPBridgePeerGate`'s tested decision logic wraps.
///
/// **Everything interesting is in `MCPBridgePeerGate`, not here**, and that
/// split is the whole design. On a machine with no signing identities every
/// real evaluation fails identically, so a test that exercised this type could
/// only ever assert "it refused", proving nothing about the branch that
/// matters. So this type is kept as close to zero-logic as an API of this
/// shape allows, and the gate above it holds every decision.
///
/// **This evaluator lives in `SentryKit`** rather than in the tool and is
/// compiled into three binaries: the framework (so Sentry can gate its own
/// anonymous listener), and the `SentryMCPBridge` tool (which links no
/// framework of ours and compiles `SentryKit/MCPBridge/` directly). See
/// `MCPBridgeContract`'s header for why both sides verify.
///
/// **Unverified.** `SecCodeCheckValidity` has never returned `errSecSuccess`
/// on this branch, because there has never been a signed peer to hand it. What
/// *is* known is that it returns non-success here, and that the gate turns
/// non-success into a refusal — the direction that fails safe.
public struct MCPBridgeSecurityEvaluator: MCPBridgePeerEvaluator {

    public init() {}

    public func evaluate(pid: Int32, requirement: String) -> MCPBridgePeerFailure? {

        // The requirement is compiled first, before any code object is
        // fetched. If our own requirement string is malformed the refusal
        // should say *that* — a `.requirementNotSatisfied` blamed on the
        // caller would send whoever is debugging this to inspect the wrong
        // binary.
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
        // `MCPBridgePeerGate`'s doc comment for the pid-reuse weakness this
        // carries and why the undocumented audit-token property was not used
        // instead.
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

#endif
