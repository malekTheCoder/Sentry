import AppKit
import XCTest
@testable import SentryKit

/// Guards `MetricModule.symbolName` against naming an SF Symbol that does not
/// exist.
///
/// **Why this test exists.** `.cpu` returned `"cpuchip"`, which is not a real
/// symbol. `NSImage(systemSymbolName:accessibilityDescription:)` returns `nil`
/// for an unknown name, and `BarModuleRenderer.tintedSymbol(for:color:)`
/// propagates that `nil` up to `drawSymbol`, which simply returns without
/// drawing. So the failure mode was not a crash, a log line, or a placeholder
/// glyph — every CPU icon in the menu bar and in the settings preview strip
/// drew *nothing*, leaving a silent empty gap that looked like a layout bug
/// rather than a missing asset. Nothing in the type system or the build catches
/// a typo'd symbol name, and nothing at runtime complains about one.
///
/// A test is the only place this can be caught, and it is cheap: the symbol set
/// is a fixed property of the OS, so resolving all nine names once per suite run
/// costs nothing and fails loudly the moment someone adds a module with a
/// guessed symbol name — or the moment Apple retires one this app depends on,
/// which is the more likely future break.
final class MetricModuleSymbolTests: XCTestCase {

    func testEveryModuleSymbolResolvesOnThisSystem() {
        for module in MetricModule.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: module.symbolName, accessibilityDescription: nil),
                """
                MetricModule.\(module) names SF Symbol "\(module.symbolName)", which does not \
                resolve on this system. The menu bar will draw an empty gap where this \
                module's icon should be, silently — see this test's doc comment.
                """
            )
        }
    }

    /// Two modules sharing a glyph is not a crash, but at a 16pt menu-bar size
    /// it is indistinguishable from a bug: the user cannot tell which module a
    /// given icon belongs to. This is the same failure the iOS module picker was
    /// rebuilt to avoid, where "Neural Engine" and "Network" both truncated to
    /// "Ne…".
    func testNoTwoModulesShareASymbol() {
        var seen: [String: MetricModule] = [:]
        for module in MetricModule.allCases {
            if let existing = seen[module.symbolName] {
                XCTFail("\(existing) and \(module) both use \"\(module.symbolName)\"; at menu-bar size they would be indistinguishable.")
            }
            seen[module.symbolName] = module
        }
    }

    /// `displayName` feeds the iOS module picker's chips and the Mac settings
    /// UI. Two modules with the same name would be ambiguous wherever they are
    /// listed together, in any language.
    func testNoTwoModulesShareADisplayName() {
        var seen: [String: MetricModule] = [:]
        for module in MetricModule.allCases {
            if let existing = seen[module.displayName] {
                XCTFail("\(existing) and \(module) both display as \"\(module.displayName)\".")
            }
            seen[module.displayName] = module
        }
    }
}
