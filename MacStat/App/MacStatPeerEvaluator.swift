import Foundation
import Security
import MacStatKit

/// The app-side production `FanDaemonPeerEvaluator` — the same three
/// Security-framework calls as the daemon's `SecurityFrameworkPeerEvaluator`,
/// duplicated rather than shared for the same reason `SMCFanWriter`
/// re-implements the SMC protocol layer: the daemon target deliberately
/// compiles a closed list of files and links no framework of ours, so the
/// only way to "share" this type would be to compile this file into the
/// daemon too, coupling the root process's audit surface to the app's.
/// Twenty lines of duplication is cheaper than that coupling.
///
/// Everything decision-shaped lives in `MCPPeerGate`, which is fully
/// tested; this type stays zero-logic for the reason the daemon's
/// evaluator documents: on an unsigned machine every real evaluation fails
/// identically, so only the gate's branches are worth testing.
struct MacStatPeerEvaluator: FanDaemonPeerEvaluator {

    func evaluate(pid: Int32, requirement: String) -> FanDaemonPeerFailure? {
        var secRequirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            requirement as CFString,
            [],
            &secRequirement
        )
        guard requirementStatus == errSecSuccess, let secRequirement else {
            return .requirementMalformed(osStatus: requirementStatus)
        }

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

/// Reads the Team ID out of this process's own code signature — the value
/// `MCPPeerGate` pins its client requirement to (see that type's doc
/// comment for why the host's own team, not a compiled-in constant).
///
/// Returns `nil` for an ad-hoc build (no certificate, so no team), which
/// the gate turns into "refuse everyone" — and which is also precisely the
/// build that can't register the LaunchAgent in the first place.
enum OwnCodeSignature {
    static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        ) == errSecSuccess, let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
