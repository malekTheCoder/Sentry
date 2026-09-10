import XCTest

// MARK: - WatchScreenshotStatesTests: drive the Watch app to each App Store page

/// The Watch half of `scripts/asc-screenshots.sh` — see
/// `SentryMobileUITests/ScreenshotStatesTests.swift` for the protocol and
/// the reasoning; this file only differs in what it launches and how it
/// navigates.
///
/// **Data.** The Watch app already has the fixture hook the iPhone app had
/// to grow for this: `-SentryWatchDemo <fixture>` (`SentryWatchApp
/// .makeController()`, `#if DEBUG`) seeds `WatchSessionController` with a
/// `PreviewFixture` whose every case carries `sourceIsDemoData: true`, so
/// the Overview page shows its "Demo" chip in every capture. `fullyPopulated`
/// is the one to photograph: every readout present and a keep-awake hold in
/// progress with a countdown, which is the Keep Awake page's best case.
/// `-SentryWatchAppearance` and `-SentryWatchTheme` are passed through from
/// the script's environment so the watch renders the same half of the same
/// theme as the iPhone shots.
///
/// **Navigation.** `ContentView` is a horizontally paged `TabView`; the
/// Keep Awake page is one swipe left of Overview. There is no launch
/// argument for the page and none is needed — a swipe is the honest way to
/// get there and XCUITest can perform one on watchOS.
final class WatchScreenshotStatesTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        app.launchArguments = ["-SentryWatchDemo", env["SENTRY_SHOT_WATCH_FIXTURE"].flatMap { $0.isEmpty ? nil : $0 } ?? "fullyPopulated"]
        if let appearance = env["SENTRY_SHOT_WATCH_APPEARANCE"], !appearance.isEmpty {
            app.launchArguments += ["-SentryWatchAppearance", appearance]
        }
        if let theme = env["SENTRY_SHOT_THEME"], !theme.isEmpty {
            app.launchArguments += ["-SentryWatchTheme", theme]
        }
        app.launch()
        XCTAssertTrue(
            waitFor(label: "Demo MacBook Pro", timeout: 30),
            "The Overview page never showed the fixture's device name — did `-SentryWatchDemo` stop being honoured?"
        )
        sleep(2)
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testOverview() throws {
        ScreenshotHandshake.hold(state: "watch-overview", isDemo: isDemoChipVisible)
    }

    func testKeepAwake() throws {
        let demo = isDemoChipVisible
        app.swipeLeft()
        XCTAssertTrue(
            waitFor(label: "Keeping awake", timeout: 15),
            "The Keep Awake page did not appear after one swipe left, or the fixture's hold is not active."
        )
        sleep(2)
        // The Keep Awake page carries no chip of its own — the disclosure is
        // the Overview page's job — so the demo verdict is the one taken on
        // Overview before swiping, from the same launch.
        ScreenshotHandshake.hold(state: "watch-keep-awake", isDemo: demo)
    }

    // MARK: - Helpers

    /// `OverviewPage`'s `DemoDataChip`, by its VoiceOver label.
    private var isDemoChipVisible: Bool {
        waitFor(label: "Demo data", timeout: 5)
    }

    private func waitFor(label: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", label)
        return app.descendants(matching: .any).matching(predicate).firstMatch.waitForExistence(timeout: timeout)
    }
}
