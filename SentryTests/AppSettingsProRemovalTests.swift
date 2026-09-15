import XCTest
@testable import SentryKit

/// What happens to a `settings.json` that still remembers Sentry Pro.
///
/// **This is the migration proof for removing the licensing fields, and it
/// follows `AppSettingsFanControlRemovalTests` exactly, because this is the
/// same hazard.** Every install that ever ran a build with Pro has at least
/// `"proUnlockOverrideEnabled": false` on disk; an install that bought a
/// license also has `"proLicenseBlob"` (a long
/// `sentry-pro-v1.<payload>.<signature>` string) and
/// `"proLicenseLastVerifiedAt"` (an ISO date). `SettingsStore.load` treats a
/// decode failure as a *corrupt file* and falls back to defaults wholesale —
/// right for a file someone hand-edited into nonsense, catastrophic for a
/// file that is merely one release out of date. A `keyNotFound` or
/// `typeMismatch` here would silently reset the user's theme, alert rules,
/// menu bar layout and MCP tool grants, on the upgrade launch, with nothing
/// on screen.
///
/// It is tolerated for a structural reason rather than a lucky one:
/// `AppSettings.init(from:)` opens a container keyed by `CodingKeys`, and a
/// JSON key with no matching case is never looked up at all. These tests pin
/// that in the removal direction, so a future refactor to a synthesized
/// `Codable` conformance — strict in both directions — fails here rather
/// than in the field.
@MainActor
final class AppSettingsProRemovalTests: XCTestCase {

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    /// The realistic upgrade for a *paying* user: a settings file written by
    /// a build that had an installed license, decoded by a build that has no
    /// concept of one.
    func testSettingsWrittenByALicensedBuildStillDecode() throws {
        let settings = try decode(#"""
        {
          "themeID": "terminal",
          "proUnlockOverrideEnabled": true,
          "proLicenseBlob": "sentry-pro-v1.eyJsaWNlbnNlSUQiOiI5QzVBLTExRUYifQ.MEUCIQDf8xN2Vg",
          "proLicenseLastVerifiedAt": 774921600,
          "updateCheckDaily": false
        }
        """#)

        // The removed keys are ignored, and — the part that matters — every
        // neighbouring key still lands.
        XCTAssertEqual(settings.themeID, "terminal")
        XCTAssertFalse(settings.updateCheckDaily)
    }

    /// The blob does not have to be well-formed to be ignored. A key with no
    /// `CodingKeys` case is never decoded, so its *contents* are never
    /// type-checked — which matters because `proLicenseLastVerifiedAt` was a
    /// `Date` and dates are exactly the field a strict decoder trips over
    /// when the encoding strategy differs across builds.
    func testStaleProKeysOfTheWrongShapeAreStillIgnored() throws {
        for junk in [#""proLicenseBlob": 7"#,
                     #""proLicenseBlob": null"#,
                     #""proLicenseBlob": { "sig": [1, 2, 3] }"#,
                     #""proLicenseLastVerifiedAt": "2026-08-13T09:41:00Z""#,
                     #""proLicenseLastVerifiedAt": []"#,
                     #""proUnlockOverrideEnabled": "yes""#,
                     #""proEntitlement": { "features": ["remoteSync"] }"#] {
            let settings = try decode("{ \(junk), \"themeID\": \"nocturne\" }")
            XCTAssertEqual(
                settings.themeID, "nocturne",
                "a removed key's value must never be inspected, however malformed: \(junk)"
            )
        }
    }

    /// Deliberately *not* a `schemaVersion` bump — the same call
    /// `AppSettingsFanControlRemovalTests` documents. Nothing changed
    /// meaning; three fields went away, and the decoder's additive tolerance
    /// does the rest. Bumping "to be safe" would strand files at a version
    /// no migration handles.
    func testRemovingTheKeysDidNotChangeTheSchemaVersion() throws {
        let settings = try decode(#"{"proUnlockOverrideEnabled":true,"schemaVersion":1}"#)
        XCTAssertEqual(settings.schemaVersion, 1)
        XCTAssertEqual(AppSettings().schemaVersion, AppSettings.currentSchemaVersion)
    }

    /// The file cleans itself up: once this build saves, the license is
    /// gone from disk. Not merely tidy — a persisted license blob is a
    /// record of a purchase for a product that no longer exists, and
    /// leaving a signed token lying in a user's settings file after the
    /// system that read it was deleted is the kind of residue the
    /// fan-control removal already refused to leave.
    func testReencodingDropsEveryProKeyEntirely() throws {
        let settings = try decode(#"""
        {
          "proUnlockOverrideEnabled": true,
          "proLicenseBlob": "sentry-pro-v1.abc.def",
          "proLicenseLastVerifiedAt": 774921600,
          "themeID": "terminal"
        }
        """#)

        let data = try JSONEncoder().encode(settings)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertNil(json["proUnlockOverrideEnabled"])
        XCTAssertNil(json["proLicenseBlob"])
        XCTAssertNil(json["proLicenseLastVerifiedAt"])
        XCTAssertEqual(json["themeID"] as? String, "terminal")
    }

    /// The regression this file guards against is "one stale key resets the
    /// user's world", so the assertion has to be about the world — a full
    /// round trip alongside the stale block, checking the neighbours that
    /// would be most expensive to lose.
    func testEverythingElseSurvivesAlongsideTheStaleProBlock() throws {
        let settings = try decode(#"""
        {
          "proUnlockOverrideEnabled": true,
          "proLicenseBlob": "sentry-pro-v1.abc.def",
          "proLicenseLastVerifiedAt": 774921600,
          "themeID": "terminal",
          "mcpServerEnabled": true,
          "mcpRemotePort": 9001,
          "rawRetentionHours": 120,
          "hourlyRetentionDays": 300,
          "agentGuardrails": { "killSwitchEngaged": true }
        }
        """#)

        XCTAssertEqual(settings.themeID, "terminal")
        XCTAssertTrue(settings.mcpServerEnabled)
        XCTAssertEqual(settings.mcpRemotePort, 9001)
        XCTAssertTrue(settings.agentGuardrails.killSwitchEngaged)
        // The shipped alert rules must still be there — the loudest possible
        // symptom of a botched removal would be a user who upgrades into an
        // app with no alerts.
        XCTAssertFalse(settings.alertRules.isEmpty)

        // **A licensed user's above-default retention survives literally.**
        // Under `HistoryProGate` these two were clamped to 48/90 before they
        // reached `RollupJob` on an unlicensed copy; the clamp is gone, so a
        // file written by a paying user keeps every hour and day it asked
        // for rather than losing them at the moment Pro was cancelled.
        XCTAssertEqual(settings.rawRetentionHours, 120)
        XCTAssertEqual(settings.hourlyRetentionDays, 300)
    }
}
