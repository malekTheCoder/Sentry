import XCTest
@testable import SentryKit

/// Duplication, per-token and global reset, token addressing, and the
/// settings persistence a custom theme depends on.
final class ThemeEditingTests: XCTestCase {

    // MARK: - Token addressing

    /// `ThemeColorToken` exists so the editor, the contrast auditor and reset
    /// can't drift apart (see its doc comment). This is the test that catches
    /// a token added to `Theme` and forgotten in the subscript: a getter that
    /// returned the wrong property would make one well edit another's color.
    func testEveryTokenReadsAndWritesItsOwnProperty() {
        for token in ThemeColorToken.allCases {
            var theme = Theme.system
            let sentinel = ThemeColor(hex: "#0F0F0F", opacity: 0.42)
            theme[token] = sentinel
            XCTAssertEqual(theme[token], sentinel, token.rawValue)

            // And nothing else moved.
            for other in ThemeColorToken.allCases where other != token {
                XCTAssertEqual(theme[other], Theme.system[other], "\(token.rawValue) also wrote \(other.rawValue)")
            }
        }
    }

    func testEveryTokenBelongsToExactlyOneSection() {
        let grouped = ThemeColorToken.Section.allCases.flatMap(\.tokens)
        XCTAssertEqual(Set(grouped), Set(ThemeColorToken.allCases))
        XCTAssertEqual(grouped.count, ThemeColorToken.allCases.count, "a token appears in two sections")
    }

    func testTextAndBackdropClassificationsAreDisjointAndCoverTheAuditedSets() {
        for token in ThemeColorToken.allCases {
            XCTAssertFalse(token.isTextToken && token.isBackdropToken, token.rawValue)
        }
        XCTAssertEqual(Set(ThemeContrastAudit.auditedTextTokens), Set(ThemeColorToken.allCases.filter(\.isTextToken)))
        XCTAssertEqual(Set(ThemeContrastAudit.auditedBackdrops), Set(ThemeColorToken.allCases.filter(\.isBackdropToken)))
    }

    // MARK: - Duplication

    func testDuplicatingAPresetProducesAnEditableForkThatRemembersItsAncestor() {
        let fork = Theme.slate.duplicated()

        XCTAssertNotEqual(fork.id, Theme.slate.id)
        XCTAssertTrue(fork.id.hasPrefix(Theme.customIDPrefix))
        XCTAssertFalse(fork.isBuiltIn)
        XCTAssertTrue(fork.isCustom)
        XCTAssertEqual(fork.basePresetID, Theme.slate.id)
        XCTAssertEqual(fork.basePreset?.id, Theme.slate.id)

        for token in ThemeColorToken.allCases {
            XCTAssertEqual(fork[token], Theme.slate[token], token.rawValue)
        }
    }

    func testDuplicatingTwiceProducesTwoDistinctThemes() {
        XCTAssertNotEqual(Theme.slate.duplicated().id, Theme.slate.duplicated().id)
    }

    /// A fork of a fork points at the *shipped preset*, not at the
    /// intermediate custom theme. Otherwise "reset to preset" would resolve
    /// to whatever the user happened to have edited that other theme into
    /// afterwards — an answer that changes behind your back.
    func testForkingAForkKeepsTheOriginalPresetAsTheAncestor() {
        var first = Theme.slate.duplicated(named: "First")
        first.accent = ThemeColor(hex: "#FF00FF")
        let second = first.duplicated(named: "Second")

        XCTAssertEqual(second.basePresetID, Theme.slate.id)
        XCTAssertNotEqual(second.basePresetID, first.id)
        // The edit still carries across — it's a copy of `first`, not of Nord.
        XCTAssertEqual(second.accent, ThemeColor(hex: "#FF00FF"))
    }

    func testResolveFindsCustomThemesAndFallsBackToTheDefault() {
        let custom = Theme.slate.duplicated(named: "Mine")
        XCTAssertEqual(Theme.resolve(id: custom.id, in: [custom]).name, "Mine")
        XCTAssertEqual(Theme.resolve(id: Theme.tokyoNight.id, in: [custom]).id, Theme.tokyoNight.id)
        XCTAssertEqual(Theme.resolve(id: "custom.deleted", in: [custom]).id, Theme.defaultTheme.id)
        XCTAssertEqual(Theme.resolve(id: "", in: []).id, Theme.defaultTheme.id)
    }

    // MARK: - Per-token reset

    func testPerTokenResetRestoresOnlyThatToken() {
        var fork = Theme.oneDark.duplicated(named: "Mine")
        fork.accent = ThemeColor(hex: "#FF00FF")
        fork.textPrimary = ThemeColor(hex: "#123456")

        XCTAssertTrue(fork.resetAvailability(for: .accent).canReset)
        fork.resetToPreset(.accent)

        XCTAssertEqual(fork.accent, Theme.oneDark.accent)
        XCTAssertEqual(fork.textPrimary, ThemeColor(hex: "#123456"), "reset must not touch a token it wasn't asked about")
    }

    func testResetAvailabilityGoesQuietOnceATokenMatchesItsPreset() {
        var fork = Theme.oneDark.duplicated(named: "Mine")
        if case .alreadyMatchesPreset = fork.resetAvailability(for: .accent) {} else {
            XCTFail("a fresh fork already matches its preset")
        }

        fork.accent = ThemeColor(hex: "#FF00FF")
        XCTAssertTrue(fork.resetAvailability(for: .accent).canReset)

        fork.resetToPreset(.accent)
        XCTAssertFalse(fork.resetAvailability(for: .accent).canReset)
    }

    /// A theme with no ancestor — an import, say — must say *why* reset is
    /// unavailable rather than showing a dead button.
    func testAThemeWithNoAncestorExplainsWhyResetIsUnavailable() {
        var orphan = Theme.system.duplicated(named: "Imported")
        orphan.basePresetID = nil

        let availability = orphan.resetAvailability(for: .accent)
        XCTAssertFalse(availability.canReset)
        XCTAssertEqual(availability, .noBasePreset)
        XCTAssertNotNil(availability.unavailableReason)
        XCTAssertFalse(availability.unavailableReason!.isEmpty)

        // And the operation itself is inert rather than destructive.
        let before = orphan
        orphan.resetToPreset(.accent)
        XCTAssertEqual(orphan, before)
    }

    func testAThemeNamingAPresetThisBuildLacksSaysSo() {
        var stale = Theme.system.duplicated(named: "From the future")
        stale.basePresetID = "builtin.doesNotExist"

        let availability = stale.resetAvailability(for: .accent)
        XCTAssertEqual(availability, .basePresetMissing(id: "builtin.doesNotExist"))
        XCTAssertFalse(availability.canReset)
        XCTAssertTrue(availability.unavailableReason?.contains("builtin.doesNotExist") ?? false)
    }

    // MARK: - Per-metric reset

    func testResettingAMetricColorRestoresThePresetValue() {
        var fork = Theme.oneDark.duplicated(named: "Mine")
        fork.metricColors[MetricID.cpuTotalPercent.rawValue] = ThemeColor(hex: "#FF00FF")
        fork.resetMetricColorToPreset(.cpuTotalPercent)
        XCTAssertEqual(
            fork.metricColors[MetricID.cpuTotalPercent.rawValue],
            Theme.oneDark.metricColors[MetricID.cpuTotalPercent.rawValue]
        )
    }

    /// When the preset has no entry for a metric, the reset removes the key
    /// rather than writing some color in — `ThemePalette.metricColor` falls
    /// back to the accent for a missing key, so writing a value would leave
    /// the fork permanently different from its preset in a way the user
    /// couldn't undo.
    func testResettingAMetricThePresetNeverColoredRemovesTheKey() {
        var fork = Theme.oneDark.duplicated(named: "Mine")
        let key = MetricID.batteryCycleCount.rawValue
        XCTAssertNil(Theme.oneDark.metricColors[key], "fixture assumption")

        fork.metricColors[key] = ThemeColor(hex: "#FF00FF")
        fork.resetMetricColorToPreset(.batteryCycleCount)
        XCTAssertNil(fork.metricColors[key])
    }

    // MARK: - Global reset

    func testGlobalResetRestoresEveryTokenButKeepsIdentity() {
        var fork = Theme.tokyoNight.duplicated(named: "Custom Dark")
        let keptID = fork.id

        fork.accent = ThemeColor(hex: "#FF00FF")
        fork.background = ThemeColor(hex: "#FFFFFF")
        fork.density = .spacious
        fork.chartStyle = .bars
        fork.barFontSize = 15
        fork.glowIntensity = 0.9
        fork.metricColors[MetricID.cpuTotalPercent.rawValue] = ThemeColor(hex: "#00FF00")
        fork.chartFill = []

        XCTAssertTrue(fork.globalResetAvailability.canReset)
        fork.resetAllToPreset()

        for token in ThemeColorToken.allCases {
            XCTAssertEqual(fork[token], Theme.tokyoNight[token], token.rawValue)
        }
        XCTAssertEqual(fork.metricColors, Theme.tokyoNight.metricColors)
        XCTAssertEqual(fork.chartFill, Theme.tokyoNight.chartFill)
        XCTAssertEqual(fork.density, Theme.tokyoNight.density)
        XCTAssertEqual(fork.chartStyle, Theme.tokyoNight.chartStyle)
        XCTAssertEqual(fork.barFontSize, Theme.tokyoNight.barFontSize)
        XCTAssertEqual(fork.glowIntensity, Theme.tokyoNight.glowIntensity)

        // Identity is the user's, not the preset's.
        XCTAssertEqual(fork.id, keptID)
        XCTAssertEqual(fork.name, "Custom Dark", "reset must not discard the name the user typed")
        XCTAssertFalse(fork.isBuiltIn)
        XCTAssertEqual(fork.basePresetID, Theme.tokyoNight.id)
    }

    /// The check has to ignore `id` and `name`, which always differ between a
    /// fork and its preset — written as `self == preset` the button would
    /// never go quiet, and "Reset All" would always look like it had something
    /// to do.
    func testGlobalResetGoesQuietOnAnUneditedFork() {
        let fork = Theme.tokyoNight.duplicated(named: "Untouched")
        XCTAssertFalse(fork.globalResetAvailability.canReset)
        if case .alreadyMatchesPreset = fork.globalResetAvailability {} else {
            XCTFail("expected alreadyMatchesPreset, got \(fork.globalResetAvailability)")
        }
    }

    func testGlobalResetNoticesANonColorEdit() {
        var fork = Theme.tokyoNight.duplicated(named: "Denser")
        fork.density = .spacious
        XCTAssertTrue(fork.globalResetAvailability.canReset, "a density change is still a change")
    }

    // MARK: - Persistence

    func testCustomThemesRoundTripThroughAppSettings() throws {
        var theme = Theme.tokyoNight.duplicated(named: "Mine")
        theme.accent = ThemeColor(light: "#112233", dark: "#445566", opacity: 0.9)
        theme.fontFamily = .custom("IBMPlexMono")

        var settings = AppSettings()
        settings.customThemes = [theme]
        settings.themeID = theme.id

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(restored.themeID, theme.id)
        XCTAssertEqual(restored.customThemes.count, 1)
        XCTAssertEqual(restored.customThemes.first, theme)
        XCTAssertEqual(restored.customThemes.first?.basePresetID, Theme.tokyoNight.id)
    }

    /// The additive-decoding contract, tested from the direction that
    /// actually matters: a settings file written before the theme editor
    /// existed must still decode, with everything else intact.
    func testASettingsFileWithNoCustomThemesKeyStillDecodes() throws {
        let json = """
        {"themeID": "builtin.nord", "launchAtLogin": true, "schemaVersion": 1}
        """
        let restored = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(restored.customThemes, [])
        XCTAssertEqual(restored.themeID, "builtin.nord")
        XCTAssertTrue(restored.launchAtLogin)
    }

    /// The other direction: a stored theme object missing tokens this build
    /// added must not take the whole settings file down with it. `Theme` has
    /// its own tolerant decoder for exactly this — and it is deliberately
    /// *not* what `.sentrytheme` import uses (see `ThemeDocumentTests`).
    func testAStoredThemeMissingTokensFallsBackPerTokenRatherThanThrowing() throws {
        let json = """
        {"customThemes": [{"id": "custom.abc", "name": "Sparse", "isBuiltIn": false,
          "background": {"light": "#111111", "dark": "#111111", "opacity": 1}}]}
        """
        let restored = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        let theme = try XCTUnwrap(restored.customThemes.first)
        XCTAssertEqual(theme.id, "custom.abc")
        XCTAssertEqual(theme.name, "Sparse")
        XCTAssertEqual(theme.background.light, "#111111")
        XCTAssertEqual(theme.accent, Theme.defaultTheme.accent, "a missing token falls back to the default preset's")
        XCTAssertNil(theme.basePresetID)
    }

    func testSettingsStoreResolvesACustomThemeByID() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-editor-tests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SettingsStore(fileURL: url, debounceInterval: 0.01)
        let theme = Theme.ivory.duplicated(named: "Mine")
        store.settings.customThemes = [theme]
        store.settings.themeID = theme.id

        XCTAssertEqual(store.resolvedTheme().id, theme.id)
        XCTAssertEqual(store.resolvedTheme().name, "Mine")

        // Deleting the theme without changing `themeID` must fall back rather
        // than leave the app pointed at nothing.
        store.settings.customThemes = []
        XCTAssertEqual(store.resolvedTheme().id, Theme.defaultTheme.id)
    }

    func testBuiltInPresetsStillResolveWhenCustomThemesExist() throws {
        let custom = Theme.ivory.duplicated(named: "Mine")
        for preset in Theme.builtInPresets {
            XCTAssertEqual(Theme.resolve(id: preset.id, in: [custom]).id, preset.id, preset.name)
        }
    }

    // MARK: - Limits

    /// The editor's sliders and the importer's validator read the same table,
    /// so a value the editor can produce is always a value an export can be
    /// re-imported with. A default that sat outside its own limit would break
    /// that on the first duplicate.
    func testEveryPresetsNumbersSitInsideTheEditableRanges() {
        for preset in Theme.builtInPresets {
            XCTAssertTrue(ThemeLimits.barFontSize.contains(preset.barFontSize), preset.name)
            XCTAssertTrue(ThemeLimits.cornerRadius.contains(preset.cornerRadius), preset.name)
            XCTAssertTrue(ThemeLimits.chartLineWidth.contains(preset.chartLineWidth), preset.name)
            XCTAssertTrue(ThemeLimits.barGraphWidth.contains(preset.barGraphWidth), preset.name)
            XCTAssertTrue(ThemeLimits.glowIntensity.contains(preset.glowIntensity), preset.name)
            XCTAssertTrue(ThemeLimits.chartFillStops.contains(preset.chartFill.count), preset.name)
            XCTAssertTrue(ThemeLimits.nameLength.contains(preset.name.count), preset.name)
        }
    }

    func testEveryPresetsColorsParse() {
        for preset in Theme.builtInPresets {
            for token in ThemeColorToken.allCases {
                XCTAssertTrue(preset[token].isWellFormed, "\(preset.name).\(token.rawValue)")
            }
            for (key, color) in preset.metricColors {
                XCTAssertTrue(color.isWellFormed, "\(preset.name).\(key)")
                XCTAssertNotNil(MetricID(rawValue: key), "\(preset.name) names an unknown metric \(key)")
            }
        }
    }
}
