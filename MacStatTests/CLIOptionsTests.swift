import XCTest
@testable import MacStatKit

/// Coverage for `CLIOptions` (`MacStatKit/CLI/CLIOptions.swift`), the
/// argument grammar behind `macstat watch` and `macstat statusline`. Pure
/// `[String] -> Result` functions — the whole reason they live in
/// MacStatKit instead of the untested CLI tool target. The cases that
/// matter most are the rejections: `watch` is a long-running data producer,
/// so a typo that silently parsed as "defaults" (`--intreval 5` running at
/// 2s) would misrepresent a stream's cadence for an entire session.
final class CLIOptionsTests: XCTestCase {

    // MARK: - Helpers

    private func watch(_ args: [String]) -> Result<CLIOptions.WatchOptions, CLIOptions.ParseError> {
        CLIOptions.WatchOptions.parse(args)
    }

    private func statusline(_ args: [String]) -> Result<CLIOptions.StatuslineOptions, CLIOptions.ParseError> {
        CLIOptions.StatuslineOptions.parse(args)
    }

    private func assertFails<T>(
        _ result: Result<T, CLIOptions.ParseError>,
        containing fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("expected a parse error containing '\(fragment)'", file: file, line: line)
        case .failure(let error):
            XCTAssertTrue(
                error.message.contains(fragment),
                "'\(error.message)' should contain '\(fragment)'",
                file: file, line: line
            )
        }
    }

    // MARK: - watch: defaults and happy paths

    func testWatchDefaults() {
        XCTAssertEqual(try? watch([]).get(), CLIOptions.WatchOptions(intervalSeconds: 2, count: nil, timeoutSeconds: nil))
    }

    func testWatchEqualsFormIsTheHouseStyle() {
        // Same grammar `check`/`wait`/`session-report` already use.
        XCTAssertEqual(
            try? watch(["--interval=0.5", "--count=10", "--timeout=30"]).get(),
            CLIOptions.WatchOptions(intervalSeconds: 0.5, count: 10, timeoutSeconds: 30)
        )
    }

    func testWatchTwoTokenFormIsAcceptedToo() {
        // The copy-paste-from-getopt-muscle-memory form — see CLIOptions's
        // doc comment for why both spellings parse.
        XCTAssertEqual(
            try? watch(["--interval", "5", "--count", "3"]).get(),
            CLIOptions.WatchOptions(intervalSeconds: 5, count: 3, timeoutSeconds: nil)
        )
    }

    // MARK: - watch: rejections

    func testWatchIntervalBelowFloorIsAnErrorNotAClamp() {
        // A silent clamp would misrepresent the stream's cadence — the
        // user asked for 10Hz and would believe they got it.
        assertFails(watch(["--interval=0.1"]), containing: "--interval")
    }

    func testWatchIntervalRejectsNonNumbersAndNonFinite() {
        assertFails(watch(["--interval=fast"]), containing: "--interval")
        assertFails(watch(["--interval=inf"]), containing: "--interval")
        assertFails(watch(["--interval"]), containing: "--interval")
    }

    func testWatchCountMustBeAPositiveInteger() {
        assertFails(watch(["--count=0"]), containing: "--count")
        assertFails(watch(["--count=-3"]), containing: "--count")
        assertFails(watch(["--count=2.5"]), containing: "--count")
    }

    func testWatchTimeoutMustBePositive() {
        assertFails(watch(["--timeout=0"]), containing: "--timeout")
        assertFails(watch(["--timeout=-1"]), containing: "--timeout")
    }

    func testWatchUnknownFlagFailsFastWithTheOffendingToken() {
        assertFails(watch(["--intreval", "5"]), containing: "--intreval")
    }

    func testWatchBareWordIsRejectedNotSwallowed() {
        // The older subcommands' `--flag=`-prefix scan would skip this
        // silently; here a stray word is surfaced back to the user.
        assertFails(watch(["fast"]), containing: "fast")
    }

    // MARK: - statusline: defaults and happy paths

    func testStatuslineDefaultsToAllSegmentsNoColor() {
        XCTAssertEqual(
            try? statusline([]).get(),
            CLIOptions.StatuslineOptions(segments: [.cpu, .mem, .battery], color: false)
        )
    }

    func testStatuslineSegmentsPreserveCallerOrder() {
        // Order is positional status-line real estate, not membership.
        XCTAssertEqual(try? statusline(["--segments=battery,cpu"]).get().segments, [.battery, .cpu])
    }

    func testStatuslineSegmentsTolerateSpacesAndDropRepeats() {
        XCTAssertEqual(try? statusline(["--segments=cpu, mem, cpu"]).get().segments, [.cpu, .mem])
    }

    func testStatuslineColorFlag() {
        XCTAssertEqual(try? statusline(["--color"]).get().color, true)
        XCTAssertEqual(
            try? statusline(["--color", "--segments", "cpu"]).get(),
            CLIOptions.StatuslineOptions(segments: [.cpu], color: true)
        )
    }

    // MARK: - statusline: rejections

    func testStatuslineUnknownSegmentNamesTheVocabulary() {
        assertFails(statusline(["--segments=cpu,disk"]), containing: "disk")
        assertFails(statusline(["--segments=cpu,disk"]), containing: "cpu, mem, battery")
    }

    func testStatuslineEmptySegmentsIsAnError() {
        assertFails(statusline(["--segments="]), containing: "--segments")
        assertFails(statusline(["--segments"]), containing: "--segments")
    }

    func testStatuslineColorTakesNoValue() {
        assertFails(statusline(["--color=1"]), containing: "--color")
    }

    func testStatuslineUnknownFlagFailsFast() {
        assertFails(statusline(["--segemnts=cpu"]), containing: "--segemnts")
    }
}
