import XCTest

// MARK: - ScreenshotStatesTests: drive the iPhone app to each App Store state

/// The iPhone half of `scripts/asc-screenshots.sh`'s capture pipeline.
///
/// **This is not a test of the app; it is a remote control for it.** Each
/// `test…` method launches the app in forced-demo mode, navigates to one
/// state worth an App Store screenshot, and then *holds* that state while
/// the host script takes the actual picture with `xcrun simctl io <udid>
/// screenshot` — the one capture path that produces the device's exact
/// native pixel size, which App Store Connect requires to the pixel. The
/// hand-off is a pair of files in a directory the script passes in as
/// `SENTRY_SHOT_HANDSHAKE_DIR` (see `ScreenshotHandshake`): the test writes
/// `<state>.ready`, the script captures and writes `<state>.done`, the test
/// moves on. Simulator processes share the host file system, so a plain
/// file is a perfectly good semaphore and needs no networking.
///
/// **Why XCUITest rather than `simctl` alone.** `simctl` can install, launch,
/// screenshot and flip appearance, but it cannot tap a tab bar, and this
/// repo deliberately has no URL routes for tabs. XCUITest is the only
/// headless way to reach the History and Alerts tabs on a simulator with no
/// Simulator.app GUI — and it can also *assert* what is on screen, which is
/// how `ScreenshotHandshake.hold` reports whether the demo banner is
/// present so the script can refuse to call a live-data shot "demo".
///
/// **Honesty.** Every launch here passes `-SentryDemoData`
/// (`AppDataSource.isForcedDemoData`, `#if DEBUG`), which leaves the app on
/// `MockDataSource` exactly as a discovery timeout would. The "Sample data —
/// not from a real Mac" banner is therefore genuinely on screen in every
/// capture, and `hold` fails the test if it is not.
final class ScreenshotStatesTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            // The debug-only hook in `AppDataSource.resolve()`.
            "-SentryDemoData",
            // `UserDefaults` reads `-key value` pairs from the argument
            // domain, which is how `@AppStorage("hasCompletedOnboarding")`
            // sees the walkthrough as already done without the script
            // having to write the simulator's defaults from outside.
            "-hasCompletedOnboarding", "YES",
        ]
        if let theme = ProcessInfo.processInfo.environment["SENTRY_SHOT_THEME"], !theme.isEmpty {
            app.launchArguments += ["-selectedThemeID", theme]
        }
        app.launch()
        XCTAssertTrue(
            app.tabBars.buttons["Dashboard"].waitForExistence(timeout: 30),
            "The tab bar never appeared — the app did not reach RootTabView."
        )
        // Give the mock stream a couple of ticks so the vitals ledger and
        // the 60-second activity chart have something to draw.
        sleep(3)
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testDashboard() throws {
        // Already selected on launch; the script captures this state twice,
        // flipping `simctl ui appearance` between the two — the hold below
        // outlasts that because the script only writes `.done` at the end.
        XCTAssertTrue(waitFor(label: "Battery", timeout: 15), "The battery hero card never rendered.")
        ScreenshotHandshake.hold(state: "iphone-dashboard", isDemo: isDemoBannerVisible)
    }

    func testHistory() throws {
        app.tabBars.buttons["History"].tap()
        // "Populated chart" is the whole point of this state; the health
        // trend is loaded asynchronously from the mock's day series, so
        // insist on it rather than photographing an empty axis.
        XCTAssertTrue(
            waitFor(label: "Battery health trend", timeout: 20),
            "The History tab's battery health trend chart never rendered — is the mock day series empty?"
        )
        sleep(1)
        ScreenshotHandshake.hold(state: "iphone-history", isDemo: isDemoBannerVisible)
    }

    func testAlerts() throws {
        app.tabBars.buttons["Alerts"].tap()
        XCTAssertTrue(app.tabBars.buttons["Alerts"].waitForExistence(timeout: 10))
        sleep(2)
        ScreenshotHandshake.hold(state: "iphone-alerts", isDemo: isDemoBannerVisible)
    }

    // MARK: - Helpers

    /// The pinned `DemoDataBanner` — matched by the leading words of
    /// `DemoDataDisclosure.headline` so a wording tweak elsewhere in that
    /// sentence does not silently turn every capture "live".
    private var isDemoBannerVisible: Bool {
        waitFor(label: "Sample data", timeout: 5)
    }

    /// True once any element whose accessibility label starts with `label`
    /// exists. Labels are matched by prefix because several of this app's
    /// surfaces compose their label from a name plus live numbers.
    private func waitFor(label: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", label)
        return app.descendants(matching: .any).matching(predicate).firstMatch.waitForExistence(timeout: timeout)
    }
}
