import XCTest
@testable import SentryKit

/// What happens to a `settings.json` that still remembers fan control.
///
/// **This is the test that replaces `FanControlSettingsTests`, and it exists
/// because removing a persisted key is the half of a feature removal that
/// can break users who never used the feature's UI.** Every install that
/// ever ran a build with the Fans pane has a `"fanControl": { … }` block on
/// disk. `SettingsStore.load` treats a decode failure as a *corrupt file*
/// and falls back to defaults wholesale — which is the right call for a
/// file someone hand-edited into nonsense, and a catastrophe if it fires
/// for a file that is merely one release out of date. A `keyNotFound` or
/// `typeMismatch` here would silently reset the user's theme, alert rules,
/// menu bar layout, MCP tool grants and Pro license blob, and it would do
/// it on the upgrade launch, with no error on screen.
///
/// The decoder tolerates it for a structural reason rather than a lucky
/// one: `AppSettings.init(from:)` opens a container keyed by `CodingKeys`,
/// and a JSON key with no matching case is never looked up at all. That is
/// the same property that makes *adding* a field safe, applied in the
/// direction nobody usually tests. These tests pin it in that direction, so
/// a future refactor to a synthesized `Codable` conformance — which would
/// be strict in both directions — fails here rather than in the field.
@MainActor
final class AppSettingsFanControlRemovalTests: XCTestCase {

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    /// The realistic upgrade: a settings file written by a build that had
    /// the whole fan-control block, decoded by a build that has none of it.
    func testSettingsWrittenWithAFanControlBlockStillDecode() throws {
        let settings = try decode(#"""
        {
          "themeID": "terminal",
          "fanControl": {
            "defaultPolicy": {
              "mode": "fixed",
              "manualTargetRPM": 4200,
              "curve": { "points": [ { "celsius": 50, "rpm": 1200 },
                                     { "celsius": 95, "rpm": 5000 } ] },
              "sensorName": "P-cluster",
              "hysteresisCelsius": 3,
              "safetyCeilingCelsius": 95
            },
            "perFanOverrides": [ { "fanIndex": 1,
                                   "policy": { "mode": "manual" } } ],
            "controlEnabledOnLaunch": true,
            "restoreAutoOnLaunch": false
          },
          "updateCheckDaily": false
        }
        """#)

        // The removed key is ignored, and — the part that matters — every
        // neighbouring key still lands.
        XCTAssertEqual(settings.themeID, "terminal")
        XCTAssertFalse(settings.updateCheckDaily)
    }

    /// The block does not have to be well-formed to be ignored. A key with
    /// no `CodingKeys` case is never decoded, so its *contents* are never
    /// type-checked — which matters because the shapes that block could
    /// take have changed across builds, and none of them are this build's
    /// problem any more.
    func testAFanControlBlockOfTheWrongShapeIsStillIgnored() throws {
        for junk in [#""fanControl": 7"#,
                     #""fanControl": null"#,
                     #""fanControl": "auto""#,
                     #""fanControl": []"#,
                     #""fanControl": { "mode": { "nested": [1, 2, 3] } }"#] {
            let settings = try decode("{ \(junk), \"themeID\": \"nocturne\" }")
            XCTAssertEqual(
                settings.themeID, "nocturne",
                "a removed key's value must never be inspected, however malformed: \(junk)"
            )
        }
    }

    /// Deliberately *not* a `schemaVersion` bump. Nothing changed meaning —
    /// a field went away — so a stale file keeps whatever version it had and
    /// the decoder's additive tolerance does the rest. A test pins this
    /// because bumping the version "to be safe" would be the intuitive
    /// wrong move, and would strand files at a version no migration handles.
    func testRemovingTheKeyDidNotChangeTheSchemaVersion() throws {
        let settings = try decode(#"{"fanControl":{"controlEnabledOnLaunch":true},"schemaVersion":1}"#)
        XCTAssertEqual(settings.schemaVersion, 1)
        XCTAssertEqual(AppSettings().schemaVersion, AppSettings.currentSchemaVersion)
    }

    /// The file cleans itself up: once this build saves, the block is gone.
    /// Not merely tidy — a persisted record of which fan curve a user
    /// wanted is data for a feature that no longer exists, and the same
    /// argument `AppDelegate` makes when it drops the dead
    /// `pendingAlertPushes` defaults key applies to it.
    func testReencodingDropsTheBlockEntirely() throws {
        let settings = try decode(#"{"fanControl":{"controlEnabledOnLaunch":true},"themeID":"terminal"}"#)

        let data = try JSONEncoder().encode(settings)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertNil(json["fanControl"])
        XCTAssertEqual(json["themeID"] as? String, "terminal")
    }

    /// A full round trip through the removed key still preserves everything
    /// else, including the nested blocks that survived the removal — the
    /// regression this whole file guards against is "one stale key resets
    /// the user's world", so the assertion has to be about the world.
    func testEverythingElseSurvivesAlongsideTheStaleBlock() throws {
        let settings = try decode(#"""
        {
          "fanControl": { "controlEnabledOnLaunch": true },
          "themeID": "terminal",
          "mcpServerEnabled": true,
          "mcpRemotePort": 9001,
          "proUnlockOverrideEnabled": true,
          "hourlyRetentionDays": 45,
          "agentGuardrails": { "killSwitchEngaged": true }
        }
        """#)

        XCTAssertEqual(settings.themeID, "terminal")
        XCTAssertTrue(settings.mcpServerEnabled)
        XCTAssertEqual(settings.mcpRemotePort, 9001)
        XCTAssertTrue(settings.proUnlockOverrideEnabled)
        XCTAssertEqual(settings.hourlyRetentionDays, 45)
        XCTAssertTrue(settings.agentGuardrails.killSwitchEngaged)
        // The shipped alert rules must still be there — the loudest possible
        // symptom of a botched removal would be a user who upgrades into an
        // app with no alerts.
        XCTAssertFalse(settings.alertRules.isEmpty)
    }

    /// The other half of the removal: `ProFeature` lost its `.fanControl`
    /// case. Nothing persisted a `ProFeature`, so there is no stored value
    /// to fail on — but `ProFeature` *is* `Codable` and `CaseIterable`, and
    /// this pins that the enum no longer offers fan control to any caller
    /// that enumerates features (the Pro upsell copy does exactly that).
    func testProFeatureNoLongerOffersFanControl() {
        XCTAssertFalse(
            ProFeature.allCases.contains { $0.rawValue == "fanControl" },
            "Sentry does not sell fan control any more; it reads fan speeds for free."
        )
        XCTAssertNil(ProFeature(rawValue: "fanControl"))
        for feature in ProFeature.allCases {
            XCTAssertFalse(
                feature.summary.localizedCaseInsensitiveContains("fixed speed"),
                "\(feature) still advertises setting a fan speed"
            )
        }
    }
}
