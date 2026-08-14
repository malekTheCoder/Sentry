import XCTest
@testable import SentryKit

/// The Pro gate in front of the theme editor's commit and file paths
/// (`ThemeEditingGate`), and — just as deliberately — the lapse contract
/// around it: what locked refuses, and what it must never touch (selecting
/// any theme, resolving an already-saved custom theme, deleting).
///
/// Entitlement flips are driven through the real override-only store
/// (`ProEntitlementStore`) rather than a bare boolean where the flip itself
/// is the thing under test — the same `isUnlocked(.customThemes)`
/// expression `ThemePane` evaluates per body pass. Store-level parity
/// across install/override/remove/relaunch is `LicenseProEntitlementTests`'
/// job (its `ProFeature.allCases` sweeps already cover `.customThemes`).
final class ThemeEditingGateTests: XCTestCase {

    private func makeSettingsStore() -> SettingsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-gate-tests-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return SettingsStore(fileURL: url, debounceInterval: 0.01)
    }

    // MARK: - Locked refusals

    func testLockedSaveThrowsRequiresProAndLeavesSettingsUntouched() {
        var settings = AppSettings()
        settings.themeID = Theme.oneDark.id
        let before = settings
        let fork = Theme.ivory.duplicated(named: "Mine")

        XCTAssertThrowsError(
            try ThemeEditingGate.commit(fork, into: &settings, isProUnlocked: false)
        ) { error in
            XCTAssertEqual(error as? ThemeEditingError, .requiresPro)
        }
        // Refusal before the first write: no appended theme, no moved
        // selection — a half-committed save would be worse than either
        // answer alone.
        XCTAssertEqual(settings, before)
    }

    /// The `authorize` half is what `ThemeFileIO` runs before opening an
    /// import or export panel — same error, both directions.
    func testLockedImportAndExportAuthorizationThrowsRequiresPro() {
        XCTAssertThrowsError(try ThemeEditingGate.authorize(isProUnlocked: false)) { error in
            XCTAssertEqual(error as? ThemeEditingError, .requiresPro)
        }
        XCTAssertNoThrow(try ThemeEditingGate.authorize(isProUnlocked: true))
    }

    /// The `FanWriteAvailability` rule: a state that blocks something must
    /// say why in plain language. Every locked-state sentence, no empties.
    func testEveryLockedSentenceExplainsItself() {
        let description = ThemeEditingError.requiresPro.errorDescription
        XCTAssertNotNil(description)
        XCTAssertFalse(description!.isEmpty)

        XCTAssertFalse(ThemeEditingGate.lockedShortLabel.isEmpty)
        XCTAssertFalse(ThemeEditingGate.lockedAffordanceLabel.isEmpty)
        XCTAssertFalse(ThemeEditingGate.lockedExistingThemesNote.isEmpty)
    }

    // MARK: - What the gate never touches

    /// Built-in selection is free forever: picking a preset never routes
    /// through the gate, so a locked copy selects and resolves every preset
    /// exactly as an unlocked one does.
    @MainActor
    func testBuiltInSelectionIsUnaffectedWhileLocked() {
        let store = makeSettingsStore()
        let entitlements = ProEntitlementStore(settingsStore: store)
        XCTAssertFalse(entitlements.isUnlocked(.customThemes))

        for preset in Theme.builtInPresets {
            store.settings.themeID = preset.id
            XCTAssertEqual(store.resolvedTheme().id, preset.id, preset.name)
        }
    }

    /// The lapse contract, end to end: a custom theme saved while entitled
    /// stays selectable and resolves byte-for-byte after the entitlement is
    /// gone — the active look never changes underfoot — and deletion (the
    /// escape hatch) keeps working.
    @MainActor
    func testAnExistingCustomThemeStaysSelectableAndResolvesWhileLocked() throws {
        let store = makeSettingsStore()
        let entitlements = ProEntitlementStore(settingsStore: store)

        entitlements.setDeveloperOverride(true)
        var saved = Theme.ivory.duplicated(named: "Saved While Entitled")
        saved.accent = ThemeColor(hex: "#FF00FF")
        try ThemeEditingGate.commit(
            saved, into: &store.settings,
            isProUnlocked: entitlements.isUnlocked(.customThemes)
        )

        entitlements.setDeveloperOverride(false)
        XCTAssertFalse(entitlements.isUnlocked(.customThemes))

        XCTAssertEqual(store.resolvedTheme().id, saved.id)
        XCTAssertEqual(store.resolvedTheme(), saved, "a lapse must not alter the saved look in any way")

        // Switching away and back is selection, not editing.
        store.settings.themeID = Theme.oneDark.id
        XCTAssertEqual(store.resolvedTheme().id, Theme.oneDark.id)
        store.settings.themeID = saved.id
        XCTAssertEqual(store.resolvedTheme().id, saved.id)

        // Editing the stored copy is refused while locked…
        var edited = saved
        edited.accent = ThemeColor(hex: "#00FF00")
        XCTAssertThrowsError(
            try ThemeEditingGate.commit(edited, into: &store.settings, isProUnlocked: false)
        )
        XCTAssertEqual(store.settings.customThemes, [saved])

        // …but deletion is removal, and removal survives a lapse.
        store.settings.customThemes.removeAll { $0.id == saved.id }
        XCTAssertEqual(store.resolvedTheme().id, Theme.defaultTheme.id)
    }

    // MARK: - Unlock, and flipping live

    @MainActor
    func testUnlockedCommitAppendsSelectsAndReplacesById() throws {
        let store = makeSettingsStore()
        let entitlements = ProEntitlementStore(settingsStore: store)
        entitlements.setDeveloperOverride(true)

        let fork = Theme.oneDark.duplicated(named: "Mine")
        try ThemeEditingGate.commit(
            fork, into: &store.settings,
            isProUnlocked: entitlements.isUnlocked(.customThemes)
        )
        XCTAssertEqual(store.settings.customThemes, [fork])
        XCTAssertEqual(store.settings.themeID, fork.id, "save selects — the user must see what they saved")

        // Committing the same id again is an edit: replace, not append.
        var edited = fork
        edited.accent = ThemeColor(hex: "#00FF00")
        try ThemeEditingGate.commit(
            edited, into: &store.settings,
            isProUnlocked: entitlements.isUnlocked(.customThemes)
        )
        XCTAssertEqual(store.settings.customThemes, [edited])
        XCTAssertEqual(store.settings.themeID, edited.id)
    }

    /// The gate is a pure function of the entitlement answer, so a flip
    /// takes effect on the very next call — no relaunch, no cached denial.
    @MainActor
    func testTheGateFollowsALiveEntitlementFlip() throws {
        let store = makeSettingsStore()
        let entitlements = ProEntitlementStore(settingsStore: store)
        let fork = Theme.oneDark.duplicated(named: "Mine")

        XCTAssertThrowsError(
            try ThemeEditingGate.commit(
                fork, into: &store.settings,
                isProUnlocked: entitlements.isUnlocked(.customThemes)
            )
        )
        XCTAssertEqual(store.settings.customThemes, [])

        entitlements.setDeveloperOverride(true)
        try ThemeEditingGate.commit(
            fork, into: &store.settings,
            isProUnlocked: entitlements.isUnlocked(.customThemes)
        )
        XCTAssertEqual(store.settings.themeID, fork.id)

        // Lapse: editing shuts on the next call, the saved theme keeps
        // resolving (the contract tested in full above).
        entitlements.setDeveloperOverride(false)
        XCTAssertThrowsError(
            try ThemeEditingGate.authorize(isProUnlocked: entitlements.isUnlocked(.customThemes))
        ) { error in
            XCTAssertEqual(error as? ThemeEditingError, .requiresPro)
        }
        XCTAssertEqual(store.resolvedTheme().id, fork.id)
    }
}
