import Foundation

/// The ordered, fully-labelled list of module choices a metric picker should
/// offer — the pure, testable half of the iPhone History tab's per-metric
/// picker (`MacStatMobile/History/PerMetricHistoryBrowser.swift`).
///
/// **Why this lives in `MacStatKit` rather than next to the view.** The unit
/// test bundle (`MacStatTests`) is macOS-hosted and links the *Mac* app plus
/// `MacStatKit`; it cannot see any type declared inside the `MacStatMobile`
/// app target, since app targets aren't importable. `SyntheticDailyHealth`
/// was moved here for exactly this reason (see its doc comment) — anything
/// about the iPhone UI that deserves a test has to be expressible as a plain
/// value type in the framework, with the SwiftUI layer reduced to rendering
/// it. So the *content* of the picker (which modules, in what order, under
/// what label, with which one selected) is decided here and asserted in
/// `MacStatTests/MetricModulePickerTests.swift`; only the chip geometry —
/// the genuinely untestable part from a macOS bundle — stays in the view.
///
/// **Why it isn't just `MetricModule.allCases` at the call site.** Two
/// invariants matter enough to be pinned in one place instead of re-derived
/// per renderer: every module is offered (a picker that silently drops one
/// makes those metrics unreachable, since the browser lists metrics filtered
/// by the selection), and exactly one item carries `isSelected` (which
/// drives both the visual treatment and the `.isSelected` accessibility
/// trait). Both are trivial to get right and trivial to break later.
///
/// **`title` is `MetricModule.displayName`, verbatim and always.** It is
/// deliberately not shortened, abbreviated, or truncated here, and callers
/// must not do so either — see `PerMetricHistoryBrowser`'s doc comment for
/// the ambiguity that abbreviation caused ("Neural Engine" and "Network"
/// both collapsing to "Ne…"). `displayName` goes through
/// `String(localized:)`, so these strings are also longer in some languages
/// than in English; any layout that depends on them being short is wrong.
public enum MetricModulePicker {

    /// One offerable choice: the module, its full localized label, its SF
    /// Symbol, and whether it is the current selection.
    public struct Item: Identifiable, Equatable, Sendable {
        public let module: MetricModule
        /// `module.displayName` — the full localized name, never an
        /// abbreviation. Named `title` rather than `label` to avoid reading
        /// as the accessibility label; it is in fact used for both.
        public let title: String
        public let symbolName: String
        public let isSelected: Bool

        public var id: MetricModule { module }

        public init(module: MetricModule, isSelected: Bool) {
            self.module = module
            self.title = module.displayName
            self.symbolName = module.symbolName
            self.isSelected = isSelected
        }
    }

    /// Every `MetricModule`, in `allCases` (declaration) order, with
    /// `selected` marked.
    ///
    /// Declaration order — battery, cpu, gpu, ane, memory, disk, network,
    /// thermal, system — is kept rather than sorted alphabetically or by
    /// localized name, because it already matches the order the same modules
    /// appear in on the Mac menu bar and in the settings module list, and a
    /// picker whose order changes with the device language would make
    /// muscle memory useless and screenshots/documentation locale-specific.
    public static func items(selected: MetricModule) -> [Item] {
        MetricModule.allCases.map { Item(module: $0, isSelected: $0 == selected) }
    }
}
