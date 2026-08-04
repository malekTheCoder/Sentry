import XCTest
@testable import Sentry

/// Coverage for `processMonitorShouldRun(windowVisible:selectedTab:)`, the
/// pure rule `AppDelegate.updateProcessMonitorState()` uses to narrow
/// `ProcessMonitor.start()`/`stop()` to "window visible AND Dashboard tab
/// selected" — see that function's doc comment in
/// `Sentry/App/MainWindow.swift` for why the second condition matters
/// (`MainWindowView` keeps all three tabs alive via `.opacity`, so
/// window-visible alone isn't the same as Dashboard-visible).
final class ProcessMonitorGatingTests: XCTestCase {

    func testRunsOnlyWhenWindowVisibleAndDashboardTabSelected() {
        XCTAssertTrue(processMonitorShouldRun(windowVisible: true, selectedTab: .dashboard))
    }

    func testDoesNotRunWhenWindowVisibleButOnAnotherTab() {
        XCTAssertFalse(processMonitorShouldRun(windowVisible: true, selectedTab: .insights))
        XCTAssertFalse(processMonitorShouldRun(windowVisible: true, selectedTab: .settings))
    }

    /// The window-visibility gate remains the outer bound: even on the
    /// Dashboard tab, a hidden window must never keep the monitor running —
    /// this is what stops `ProcessMonitor` from surviving as a background
    /// timer after the window closes.
    func testDoesNotRunWhenWindowIsHiddenRegardlessOfTab() {
        for tab in MainTab.allCases {
            XCTAssertFalse(processMonitorShouldRun(windowVisible: false, selectedTab: tab), "\(tab)")
        }
    }
}
