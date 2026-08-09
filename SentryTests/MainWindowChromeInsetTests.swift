import XCTest
@testable import Sentry

/// Coverage for `mainWindowChromeInset(...)`, the pure rule that decides how
/// tall the band at the top of the main window is that the system's own
/// chrome owns — see its doc comment in `Sentry/App/MainWindow.swift`.
///
/// **Why this is worth testing at all.** It used to be a constant (52), and a
/// wrong constant only made the top of the window look slightly off. It is
/// load-bearing now: `MainWindowView` clips its tab content to everything
/// *below* this line, because SwiftUI backs a root `ScrollView` with an
/// `NSScrollView` that AppKit promotes over the window's safe area, which is
/// what let scrolled Dashboard and Insights content draw across the traffic
/// lights and the window title. Too small a value and that bug comes back a
/// few points lower down; too large and there is a dead strip of background
/// no tab can ever draw into. The measurement and the chrome have to be the
/// same line, so the arithmetic that picks the number gets tests.
final class MainWindowChromeInsetTests: XCTestCase {

    /// The ordinary case, and the one measured on the shipping window: a
    /// `.unified` toolbar holding the 33pt nav pill reports a 52.0pt safe
    /// area, which is exactly the constant that had been hard-coded.
    func testPrefersTheSafeAreaInsetWhenItIsAvailable() {
        XCTAssertEqual(
            mainWindowChromeInset(
                safeAreaTop: 52,
                contentLayoutInset: 52,
                isFullScreen: false,
                fallback: 99
            ),
            52
        )
    }

    /// `safeAreaInsets.top` wins over the AppKit-level measurement when the
    /// two disagree, because it is the number SwiftUI itself lays out
    /// against — agreeing with SwiftUI is what keeps the clip and the
    /// content on the same line.
    func testSafeAreaWinsOverTheContentLayoutMeasurement() {
        XCTAssertEqual(
            mainWindowChromeInset(
                safeAreaTop: 52,
                contentLayoutInset: 74,
                isFullScreen: false,
                fallback: 99
            ),
            52
        )
    }

    /// A content view that has not been given its safe area yet still has a
    /// window with a truthful `contentLayoutRect`, so the second candidate
    /// carries the answer rather than dropping to the constant.
    func testFallsBackToTheContentLayoutMeasurementWhenSafeAreaIsUnset() {
        XCTAssertEqual(
            mainWindowChromeInset(
                safeAreaTop: 0,
                contentLayoutInset: 64,
                isFullScreen: false,
                fallback: 99
            ),
            64
        )
    }

    /// Neither candidate says anything: reserve what has always shipped
    /// rather than reserve nothing, because reserving nothing is the bug.
    func testFallsBackToTheConstantWhenNothingIsMeasurable() {
        XCTAssertEqual(
            mainWindowChromeInset(
                safeAreaTop: 0,
                contentLayoutInset: 0,
                isFullScreen: false,
                fallback: 52
            ),
            52
        )
    }

    /// A negative inset is not a smaller titlebar, it is a window being read
    /// mid-teardown — `contentLayoutRect` can exceed the frame while a
    /// window is between states. Reject it and keep the constant.
    func testRejectsNegativeMeasurements() {
        XCTAssertEqual(
            mainWindowChromeInset(
                safeAreaTop: -12,
                contentLayoutInset: -3,
                isFullScreen: false,
                fallback: 52
            ),
            52
        )
    }

    /// The upper bound exists for the same reason as the lower one, and it
    /// matters more: a wildly large reading would blank out a third of the
    /// window with a strip nothing can draw into, which is a worse and far
    /// more visible failure than the overlap being fixed here. Note the
    /// *second* candidate is still consulted — one bad reading doesn't
    /// discard a good one.
    func testRejectsAbsurdlyLargeMeasurementsButStillConsultsTheOther() {
        XCTAssertEqual(
            mainWindowChromeInset(
                safeAreaTop: 4000,
                contentLayoutInset: 52,
                isFullScreen: false,
                fallback: 99
            ),
            52
        )
        XCTAssertEqual(
            mainWindowChromeInset(
                safeAreaTop: 4000,
                contentLayoutInset: 4000,
                isFullScreen: false,
                fallback: 52
            ),
            52
        )
    }

    /// The boundary itself is accepted — `maximum` is the largest believable
    /// chrome, not the first unbelievable one.
    func testAcceptsTheMaximumExactly() {
        XCTAssertEqual(
            mainWindowChromeInset(
                safeAreaTop: 200,
                contentLayoutInset: 52,
                isFullScreen: false,
                fallback: 99,
                maximum: 200
            ),
            200
        )
        XCTAssertEqual(
            mainWindowChromeInset(
                safeAreaTop: 201,
                contentLayoutInset: 52,
                isFullScreen: false,
                fallback: 99,
                maximum: 200
            ),
            52
        )
    }

    /// NaN and infinity are what a measurement taken against a zero-sized or
    /// half-built window can produce, and both would poison a SwiftUI frame
    /// height rather than merely look wrong.
    func testRejectsNonFiniteMeasurements() {
        XCTAssertEqual(
            mainWindowChromeInset(
                safeAreaTop: .nan,
                contentLayoutInset: .infinity,
                isFullScreen: false,
                fallback: 52
            ),
            52
        )
    }

    /// Full screen takes the traffic lights away and auto-hides the toolbar,
    /// so there is no chrome for content to hide under and reserving a band
    /// would leave a permanent dead strip. It wins over every measurement,
    /// including a plausible-looking one — during the transition AppKit will
    /// happily still report the windowed titlebar's height.
    func testFullScreenReservesNothingWhateverIsMeasured() {
        XCTAssertEqual(
            mainWindowChromeInset(
                safeAreaTop: 52,
                contentLayoutInset: 52,
                isFullScreen: true,
                fallback: 52
            ),
            0
        )
    }

    /// The compiled-in default has to be a value this function would itself
    /// accept, or the fallback path would hand back a number the validity
    /// rules reject. Pins that invariant to the real constant.
    @MainActor
    func testTheShippingDefaultIsItselfAValidInset() {
        XCTAssertEqual(
            mainWindowChromeInset(
                safeAreaTop: MainWindowView.navHeight,
                contentLayoutInset: 0,
                isFullScreen: false,
                fallback: 0
            ),
            MainWindowView.navHeight
        )
    }
}
