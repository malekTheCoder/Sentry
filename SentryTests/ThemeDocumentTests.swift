import XCTest
@testable import SentryKit

/// `.sentrytheme` export, import, and — mostly — rejection.
///
/// **The rejection cases are the point.** Import is untrusted input: a
/// hand-edited file, something downloaded from a forum, or an export from a
/// future build. The requirement is that every one of those either produces a
/// complete, valid theme or produces a clear message — never a crash, and
/// never a half-applied theme that leaves the app in a state the user can't
/// explain. Most of this file is one test per way that can go wrong.
final class ThemeDocumentTests: XCTestCase {

    // MARK: - Helpers

    private func file(
        format: String? = "sentry.theme",
        version: Int? = 1,
        theme: [String: Any]? = nil
    ) -> Data {
        var object: [String: Any] = [:]
        if let format { object["format"] = format }
        if let version { object["formatVersion"] = version }
        if let theme { object["theme"] = theme }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// A minimally-valid theme object: the six required tokens and nothing
    /// else, so tests can add exactly the one bad field they're about.
    private var minimalTheme: [String: Any] {
        func color(_ hex: String) -> [String: Any] {
            ["light": hex, "dark": hex, "opacity": 1.0]
        }
        return [
            "id": "custom.test",
            "name": "Test Theme",
            "isBuiltIn": false,
            "background": color("#101010"),
            "surface": color("#202020"),
            "surfaceElevated": color("#303030"),
            "textPrimary": color("#FFFFFF"),
            "textSecondary": color("#CCCCCC"),
            "textTertiary": color("#999999"),
        ]
    }

    private func assertRejects(
        _ data: Data,
        _ expected: ThemeDocumentError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try ThemeDocument.decode(data)
            XCTFail("expected rejection, got a theme", file: file, line: line)
        } catch let error as ThemeDocumentError {
            XCTAssertEqual(error, expected, file: file, line: line)
            XCTAssertFalse(
                (error.errorDescription ?? "").isEmpty,
                "every rejection must carry a message a user can act on",
                file: file, line: line
            )
        } catch {
            XCTFail("expected ThemeDocumentError, got \(error)", file: file, line: line)
        }
    }

    // MARK: - Round trip

    func testEveryBuiltInPresetSurvivesAnExportImportRoundTrip() throws {
        for preset in Theme.builtInPresets {
            let data = try ThemeDocument.encode(preset)
            let restored = try ThemeDocument.decode(data)

            // Identity is deliberately *not* preserved — see below — so
            // compare everything else.
            XCTAssertEqual(restored.name, preset.name)
            for token in ThemeColorToken.allCases {
                XCTAssertEqual(restored[token], preset[token], "\(preset.name).\(token.rawValue)")
            }
            XCTAssertEqual(restored.metricColors, preset.metricColors, preset.name)
            XCTAssertEqual(restored.chartFill, preset.chartFill, preset.name)
            XCTAssertEqual(restored.fontFamily, preset.fontFamily, preset.name)
            XCTAssertEqual(restored.barFontSize, preset.barFontSize, preset.name)
            XCTAssertEqual(restored.barFontWeight, preset.barFontWeight, preset.name)
            XCTAssertEqual(restored.numericStyle, preset.numericStyle, preset.name)
            XCTAssertEqual(restored.density, preset.density, preset.name)
            XCTAssertEqual(restored.chartStyle, preset.chartStyle, preset.name)
            XCTAssertEqual(restored.cornerRadius, preset.cornerRadius, preset.name)
            XCTAssertEqual(restored.chartLineWidth, preset.chartLineWidth, preset.name)
            XCTAssertEqual(restored.barGraphWidth, preset.barGraphWidth, preset.name)
            XCTAssertEqual(restored.showChartGrid, preset.showChartGrid, preset.name)
            XCTAssertEqual(restored.useMaterialBackground, preset.useMaterialBackground, preset.name)
            XCTAssertEqual(restored.materialStyle, preset.materialStyle, preset.name)
            XCTAssertEqual(restored.glowIntensity, preset.glowIntensity, preset.name)
            XCTAssertEqual(restored.scanlineOverlay, preset.scanlineOverlay, preset.name)
        }
    }

    func testCustomFontNamesSurviveTheRoundTrip() throws {
        var theme = Theme.system.duplicated(named: "Berkeley")
        theme.fontFamily = .custom("BerkeleyMono-Regular")
        let restored = try ThemeDocument.decode(try ThemeDocument.encode(theme))
        XCTAssertEqual(restored.fontFamily, .custom("BerkeleyMono-Regular"))
    }

    func testExportingABuiltInPresetStripsItsBuiltInIdentity() throws {
        let data = try ThemeDocument.encode(Theme.slate)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let theme = try XCTUnwrap(object["theme"] as? [String: Any])

        XCTAssertEqual(object["format"] as? String, "sentry.theme")
        XCTAssertEqual(theme["isBuiltIn"] as? Bool, false)
        let id = try XCTUnwrap(theme["id"] as? String)
        XCTAssertFalse(id.hasPrefix(Theme.builtInIDPrefix), "an exported file must not claim a built-in id")
        // The ancestry is what makes reset-to-preset work after re-import.
        XCTAssertEqual(theme["basePresetID"] as? String, Theme.slate.id)
    }

    func testImportedThemesAlwaysGetAFreshIdentity() throws {
        let data = file(theme: minimalTheme)
        let first = try ThemeDocument.decode(data)
        let second = try ThemeDocument.decode(data)

        XCTAssertNotEqual(first.id, second.id, "importing the same file twice must produce two themes, not one")
        XCTAssertTrue(first.id.hasPrefix(Theme.customIDPrefix))
        XCTAssertFalse(first.isBuiltIn)
        // The file's own id claim is discarded.
        XCTAssertNotEqual(first.id, "custom.test")
    }

    func testExportIsPrettyPrintedAndKeySortedForHumanEditing() throws {
        let data = try ThemeDocument.encode(Theme.system)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\n"), "an interchange file people edit should not be one line")
        XCTAssertLessThan(
            try XCTUnwrap(text.range(of: "\"format\"")).lowerBound,
            try XCTUnwrap(text.range(of: "\"theme\"")).lowerBound,
            "sorted keys put the format marker before the payload"
        )
    }

    // MARK: - Envelope rejection

    func testRejectsNonJSON() {
        do {
            _ = try ThemeDocument.decode(Data("this is not json".utf8))
            XCTFail("expected rejection")
        } catch let error as ThemeDocumentError {
            guard case .notJSON = error else { return XCTFail("wrong case: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testRejectsEmptyData() {
        do {
            _ = try ThemeDocument.decode(Data())
            XCTFail("expected rejection")
        } catch let error as ThemeDocumentError {
            guard case .notJSON = error else { return XCTFail("wrong case: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testRejectsATopLevelArray() {
        assertRejects(Data("[1, 2, 3]".utf8), .topLevelNotAnObject)
    }

    func testRejectsAFileWithNoFormatMarker() {
        assertRejects(file(format: nil, theme: minimalTheme), .missingFormatMarker)
    }

    func testRejectsSomeoneElsesJSON() {
        // The realistic accident: dragging in a package.json or a VS Code
        // theme. The message must not be about colors.
        assertRejects(file(format: "vscode.theme", theme: minimalTheme), .wrongFormat(found: "vscode.theme"))
    }

    func testRejectsAFutureFormatVersion() {
        assertRejects(
            file(version: 99, theme: minimalTheme),
            .unsupportedVersion(found: 99, newestSupported: ThemeDocument.currentFormatVersion)
        )
    }

    func testAcceptsAFileWithNoVersionKeyAsVersionOne() throws {
        let theme = try ThemeDocument.decode(file(version: nil, theme: minimalTheme))
        XCTAssertEqual(theme.name, "Test Theme")
    }

    func testRejectsAFileWithNoThemeObject() {
        assertRejects(file(theme: nil), .missingThemeObject)
    }

    // MARK: - The silent-substitution trap

    /// The whole reason import does its own key check instead of leaning on
    /// `Theme.init(from:)`: that decoder is deliberately permissive so old
    /// settings files keep working, and it would happily turn an empty object
    /// into a perfect copy of the default theme wearing whatever name the
    /// file claimed — reporting success the entire time.
    func testRejectsAnEmptyThemeObjectRatherThanSubstitutingTheDefault() {
        assertRejects(
            file(theme: ["name": "Sneaky"]),
            .missingRequiredTokens(ThemeDocument.requiredThemeKeys.sorted())
        )
    }

    func testRejectsAThemeMissingOnlyOneRequiredToken() {
        var theme = minimalTheme
        theme.removeValue(forKey: "textSecondary")
        assertRejects(file(theme: theme), .missingRequiredTokens(["textSecondary"]))
    }

    func testAcceptsAThemeMissingOnlyOptionalTokens() throws {
        // `accent`, geometry and effects are absent from `minimalTheme`
        // entirely: those genuinely should fall back rather than reject, or
        // every added token would break every existing file.
        let theme = try ThemeDocument.decode(file(theme: minimalTheme))
        XCTAssertEqual(theme.accent, Theme.defaultTheme.accent)
        XCTAssertEqual(theme.density, Theme.defaultTheme.density)
        // ...but the tokens that *were* present came from the file.
        XCTAssertEqual(theme.background.light, "#101010")
    }

    // MARK: - Value rejection

    func testRejectsAMalformedHexString() {
        var theme = minimalTheme
        theme["textPrimary"] = ["light": "#ZZZZZZ", "dark": "#FFFFFF", "opacity": 1.0]
        assertRejects(file(theme: theme), .malformedColor(token: "textPrimary.light", value: "#ZZZZZZ"))
    }

    func testRejectsAMalformedHexInTheDarkHalfOnly() {
        // Easy to miss: a file that looks fine in the appearance the author
        // uses and is broken in the other.
        var theme = minimalTheme
        theme["surface"] = ["light": "#FFFFFF", "dark": "not-a-color", "opacity": 1.0]
        assertRejects(file(theme: theme), .malformedColor(token: "surface.dark", value: "not-a-color"))
    }

    func testRejectsOutOfRangeOpacity() {
        var theme = minimalTheme
        theme["background"] = ["light": "#101010", "dark": "#101010", "opacity": 4.2]
        assertRejects(
            file(theme: theme),
            .numberOutOfRange(field: "background.opacity", value: 4.2, lowerBound: 0, upperBound: 1)
        )
    }

    func testRejectsAnAbsurdFontSize() {
        var theme = minimalTheme
        theme["barFontSize"] = 400
        assertRejects(
            file(theme: theme),
            .numberOutOfRange(
                field: "barFontSize",
                value: 400,
                lowerBound: Double(ThemeLimits.barFontSize.lowerBound),
                upperBound: Double(ThemeLimits.barFontSize.upperBound)
            )
        )
    }

    func testRejectsAnAbsurdMenuBarGraphWidth() {
        // The hostile case: a theme that would push every other status item
        // off the user's menu bar.
        var theme = minimalTheme
        theme["barGraphWidth"] = 4000
        do {
            _ = try ThemeDocument.decode(file(theme: theme))
            XCTFail("expected rejection")
        } catch let error as ThemeDocumentError {
            guard case .numberOutOfRange(let field, _, _, _) = error else {
                return XCTFail("wrong case: \(error)")
            }
            XCTAssertEqual(field, "barGraphWidth")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testRejectsAGradientWithTooManyStops() {
        var theme = minimalTheme
        theme["chartFill"] = (0..<50).map { _ in ["light": "#FFFFFF", "dark": "#FFFFFF", "opacity": 1.0] }
        assertRejects(
            file(theme: theme),
            .tooManyChartFillStops(found: 50, maximum: ThemeLimits.chartFillStops.upperBound)
        )
    }

    func testRejectsAnEmptyName() {
        var theme = minimalTheme
        theme["name"] = "   "
        assertRejects(file(theme: theme), .emptyName)
    }

    func testRejectsAnAbsurdlyLongName() {
        var theme = minimalTheme
        theme["name"] = String(repeating: "x", count: 500)
        assertRejects(
            file(theme: theme),
            .nameTooLong(found: 500, maximum: ThemeLimits.nameLength.upperBound)
        )
    }

    func testRejectsUnknownMetricKeysRatherThanDroppingThem() {
        var theme = minimalTheme
        theme["metricColors"] = [
            "cpu.total_percent": ["light": "#FF0000", "dark": "#FF0000", "opacity": 1.0],
            "cpu.made_up": ["light": "#00FF00", "dark": "#00FF00", "opacity": 1.0],
            "another.invention": ["light": "#0000FF", "dark": "#0000FF", "opacity": 1.0],
        ]
        // Collected and sorted, so a file with several gets one message
        // rather than three consecutive dialogs.
        assertRejects(file(theme: theme), .unknownMetricKeys(["another.invention", "cpu.made_up"]))
    }

    func testRejectsAFileClaimingABuiltInIdentifier() {
        var theme = minimalTheme
        theme["id"] = "builtin.system"
        assertRejects(file(theme: theme), .reservedIdentifier("builtin.system"))
    }

    func testRejectsAWrongTypedFieldWithAMessageThatNamesTheField() {
        var theme = minimalTheme
        theme["density"] = 17
        do {
            _ = try ThemeDocument.decode(file(theme: theme))
            XCTFail("expected rejection")
        } catch let error as ThemeDocumentError {
            guard case .decodingFailed(let detail) = error else {
                return XCTFail("wrong case: \(error)")
            }
            XCTAssertTrue(
                detail.lowercased().contains("density"),
                "the message must name the offending key, got: \(detail)"
            )
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testNothingIsAppliedWhenValidationFails() {
        // The "half-applied theme" the brief rules out: the failure is thrown
        // rather than returned alongside a partly-built value, so there is no
        // theme in existence for a caller to accidentally use.
        var theme = minimalTheme
        theme["glowIntensity"] = 12.0
        XCTAssertThrowsError(try ThemeDocument.decode(file(theme: theme)))
    }

    // MARK: - Filenames

    func testSuggestedFilenameIsSafeForTheFilesystem() {
        var theme = Theme.system.duplicated(named: "My / Weird : Theme")
        XCTAssertEqual(ThemeDocument.suggestedFilename(for: theme), "My - Weird - Theme.sentrytheme")

        theme.name = "///"
        XCTAssertFalse(
            ThemeDocument.suggestedFilename(for: theme).hasPrefix("."),
            "a name of pure punctuation must not produce a dotfile"
        )
    }

    // MARK: - Validation of in-app themes

    func testEveryBuiltInPresetPassesTheSameValidationImportsMustPass() throws {
        // A preset that couldn't survive its own importer would mean the
        // limits and the shipped values disagree — which shows up as "I
        // exported a theme from Sentry and Sentry wouldn't open it."
        for preset in Theme.builtInPresets {
            XCTAssertNoThrow(try ThemeDocument.validate(preset), preset.name)
        }
    }
}
