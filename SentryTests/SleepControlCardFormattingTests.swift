import XCTest
@testable import Sentry
@testable import SentryKit

/// Covers the pure logic behind the dropdown's sleep-prevention card
/// (Sentry/Dropdown/SleepControlCard.swift): countdown/preset text and the
/// `SleepTriggerOption` → `PowerControlService` argument mapping. The SwiftUI
/// body itself isn't tested here — this is the part that can be wrong without
/// looking wrong.
final class SleepControlCardFormattingTests: XCTestCase {

    // MARK: countdown

    func testCountdownShowsMinutesAndSecondsUnderAnHour() {
        XCTAssertEqual(SleepCountdownFormatting.countdown(249), "4:09")
        XCTAssertEqual(SleepCountdownFormatting.countdown(9), "0:09")
        XCTAssertEqual(SleepCountdownFormatting.countdown(59 * 60), "59:00")
    }

    func testCountdownShowsHoursWhenPresent() {
        XCTAssertEqual(SleepCountdownFormatting.countdown(3849), "1:04:09")
        XCTAssertEqual(SleepCountdownFormatting.countdown(8 * 3600), "8:00:00")
    }

    /// A fresh 15-minute assertion must read 15:00 on the first tick, not
    /// 14:59 — the deadline is a hair under 900s by the time the view formats it.
    func testCountdownRoundsUpSoAFreshPresetShowsItsFullDuration() {
        XCTAssertEqual(SleepCountdownFormatting.countdown(899.998), "15:00")
    }

    /// The releasing `Timer` can land a moment late; the card must never
    /// flash a negative clock on the way out.
    func testCountdownClampsAtZero() {
        XCTAssertEqual(SleepCountdownFormatting.countdown(0), "0:00")
        XCTAssertEqual(SleepCountdownFormatting.countdown(-30), "0:00")
    }

    func testCountdownRejectsNonFiniteValues() {
        XCTAssertEqual(SleepCountdownFormatting.countdown(.infinity), MetricFormatting.placeholder)
        XCTAssertEqual(SleepCountdownFormatting.countdown(.nan), MetricFormatting.placeholder)
    }

    // MARK: presetLabel

    func testPresetLabelsMatchThePlansDurationMenu() {
        let labels = SleepTriggerOption.allOptions.compactMap { $0.duration }.map(SleepCountdownFormatting.presetLabel)
        XCTAssertEqual(labels, ["15 min", "30 min", "1 h", "2 h", "4 h", "8 h"])
    }

    func testPresetLabelCombinesHoursAndMinutes() {
        XCTAssertEqual(SleepCountdownFormatting.presetLabel(90 * 60), "1 h 30 min")
    }

    // MARK: trigger mapping

    /// Shared no-op arguments for the two new conditional triggers, so the
    /// pre-existing tests below (battery/CPU/process/fixed/indefinite) don't
    /// need to care about download timeouts or schedules they aren't
    /// exercising.
    private let noDownloadTimeout: TimeInterval = 8
    private let noSchedule = KeepAwakeSchedule.weeknights
    private let noUntilTime = Date(timeIntervalSince1970: 1_700_000_000)

    func testFixedTriggersCarryADurationAndNoCondition() {
        let option = SleepTriggerOption.fixed(30 * 60)
        XCTAssertEqual(option.duration, 1800)
        XCTAssertNil(option.releaseCondition(batteryThreshold: 20, cpuThreshold: 80, cpuSustainedFor: 300, processName: "claude", downloadIdleTimeout: noDownloadTimeout, schedule: noSchedule))
    }

    func testIndefiniteTriggerCarriesNeitherDurationNorCondition() {
        XCTAssertNil(SleepTriggerOption.indefinite.duration)
        XCTAssertNil(SleepTriggerOption.indefinite.releaseCondition(batteryThreshold: 20, cpuThreshold: 80, cpuSustainedFor: 300, processName: "claude", downloadIdleTimeout: noDownloadTimeout, schedule: noSchedule))
    }

    /// Conditional triggers must stay open-ended: handing a duration to
    /// `startConditionalAssertion` would arm an expiry timer that releases the
    /// assertion before its condition ever fires.
    func testConditionalTriggersHaveNoDurationAndMapToReleaseConditions() {
        XCTAssertNil(SleepTriggerOption.batteryBelow.duration)
        XCTAssertNil(SleepTriggerOption.cpuAbove.duration)
        XCTAssertEqual(
            SleepTriggerOption.batteryBelow.releaseCondition(batteryThreshold: 15, cpuThreshold: 80, cpuSustainedFor: 300, processName: "claude", downloadIdleTimeout: noDownloadTimeout, schedule: noSchedule),
            .batteryBelowPercent(15)
        )
        XCTAssertEqual(
            SleepTriggerOption.cpuAbove.releaseCondition(batteryThreshold: 20, cpuThreshold: 70, cpuSustainedFor: 300, processName: "claude", downloadIdleTimeout: noDownloadTimeout, schedule: noSchedule),
            .cpuAbovePercent(70, for: 300)
        )
    }

    func testProcessTriggerMapsToWhileProcessRunning() {
        XCTAssertNil(SleepTriggerOption.processRunning.duration)
        XCTAssertEqual(
            SleepTriggerOption.processRunning.releaseCondition(
                batteryThreshold: 20, cpuThreshold: 80, cpuSustainedFor: 300, processName: "xcodebuild",
                downloadIdleTimeout: noDownloadTimeout, schedule: noSchedule
            ),
            .whileProcessRunning(name: "xcodebuild")
        )
        XCTAssertTrue(
            SleepTriggerOption.processRunning
                .assertionReason(batteryThreshold: 20, cpuThreshold: 80, processName: "xcodebuild", schedule: noSchedule, untilTime: noUntilTime)
                .contains("xcodebuild"),
            "process reason should name the watched process"
        )
    }

    func testDownloadActiveTriggerMapsToWhileDownloadActive() {
        XCTAssertNil(SleepTriggerOption.downloadActive.duration)
        XCTAssertEqual(
            SleepTriggerOption.downloadActive.releaseCondition(
                batteryThreshold: 20, cpuThreshold: 80, cpuSustainedFor: 300, processName: "claude",
                downloadIdleTimeout: 8, schedule: noSchedule
            ),
            .whileDownloadActive(idleTimeout: 8)
        )
    }

    func testScheduledWindowTriggerMapsToScheduledWindowUsingTheChosenPreset() {
        XCTAssertNil(SleepTriggerOption.scheduledWindow.duration)
        XCTAssertEqual(
            SleepTriggerOption.scheduledWindow.releaseCondition(
                batteryThreshold: 20, cpuThreshold: 80, cpuSustainedFor: 300, processName: "claude",
                downloadIdleTimeout: noDownloadTimeout, schedule: .workHours
            ),
            .scheduledWindow(weekdays: [2, 3, 4, 5, 6], startMinute: 9 * 60, endMinute: 17 * 60)
        )
    }

    func testMenuOrderMatchesPlanSection103() {
        XCTAssertEqual(
            SleepTriggerOption.allOptions.map(\.id),
            ["indefinite", "fixed-900", "fixed-1800", "fixed-3600", "fixed-7200", "fixed-14400", "fixed-28800", "until-time", "battery", "cpu", "process", "download", "schedule"]
        )
    }

    // MARK: untilTime

    /// `.untilTime` has no fixed `duration` — it needs `now` to turn a clock
    /// time into a countdown, which `resolvedDuration` alone provides.
    func testUntilTimeHasNoFixedDuration() {
        XCTAssertNil(SleepTriggerOption.untilTime.duration)
        XCTAssertNil(SleepTriggerOption.untilTime.releaseCondition(batteryThreshold: 20, cpuThreshold: 80, cpuSustainedFor: 300, processName: "claude", downloadIdleTimeout: noDownloadTimeout, schedule: noSchedule))
    }

    /// The ordinary case: the picked time is later today.
    func testUntilTimeResolvesToTheRemainderOfToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 14, minute: 0))!
        let untilTime = calendar.date(from: DateComponents(year: 1970, month: 1, day: 1, hour: 22, minute: 30))!
        let resolved = try XCTUnwrap(SleepTriggerOption.untilTime.resolvedDuration(untilTime: untilTime, now: now, calendar: calendar))
        XCTAssertEqual(resolved, 8 * 3600 + 30 * 60, accuracy: 0.001)
    }

    /// A time already passed today rolls to tomorrow rather than going
    /// negative — the same "always in the future" guarantee a keep-awake
    /// utility's own "Until" trigger should give.
    func testUntilTimeRollsToTomorrowWhenTheTimeHasAlreadyPassedToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 14, minute: 0))!
        let untilTime = calendar.date(from: DateComponents(year: 1970, month: 1, day: 1, hour: 9, minute: 0))!
        let resolved = try XCTUnwrap(SleepTriggerOption.untilTime.resolvedDuration(untilTime: untilTime, now: now, calendar: calendar))
        XCTAssertEqual(resolved, 19 * 3600, accuracy: 0.001)
    }

    /// Inside the 60s floor — treated the same as "already passed," rolling
    /// to tomorrow rather than arming a near-zero assertion.
    func testUntilTimeInsideTheFloorRollsToTomorrow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 14, minute: 0, second: 45))!
        let untilTime = calendar.date(from: DateComponents(year: 1970, month: 1, day: 1, hour: 14, minute: 1))!
        let resolved = SleepTriggerOption.untilTime.resolvedDuration(untilTime: untilTime, now: now, calendar: calendar)!
        XCTAssertGreaterThan(resolved, 23 * 3600, "a sub-minute gap should roll to tomorrow, not resolve to ~15 seconds")
    }

    func testUntilTimeMenuLabelNamesTheClockTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let untilTime = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 22, minute: 30))!
        let label = SleepTriggerOption.untilTime.menuLabel(batteryThreshold: 20, cpuThreshold: 80, processName: "claude", schedule: noSchedule, untilTime: untilTime)
        XCTAssertTrue(label.contains("Until"), "menu label should read as an 'Until <time>' sentence, got: \(label)")
    }

    /// The reason string is the only description of a conditional trigger that
    /// survives into `SleepAssertionState` (the condition itself is private to
    /// `PowerControlService`), so the active card renders it verbatim — it has
    /// to name the actual threshold.
    func testAssertionReasonNamesTheChosenThreshold() {
        XCTAssertTrue(
            SleepTriggerOption.batteryBelow.assertionReason(batteryThreshold: 25, cpuThreshold: 80, processName: "claude", schedule: noSchedule, untilTime: noUntilTime).contains("25%"),
            "battery reason should name its threshold"
        )
        XCTAssertTrue(
            SleepTriggerOption.cpuAbove.assertionReason(batteryThreshold: 20, cpuThreshold: 65, processName: "claude", schedule: noSchedule, untilTime: noUntilTime).contains("65%"),
            "CPU reason should name its threshold"
        )
    }

    func testDownloadAndScheduleAssertionReasonsAreDescriptive() {
        XCTAssertTrue(
            SleepTriggerOption.downloadActive.assertionReason(batteryThreshold: 20, cpuThreshold: 80, processName: "claude", schedule: noSchedule, untilTime: noUntilTime).contains("download"),
            "download reason should mention what it's watching"
        )
        XCTAssertTrue(
            SleepTriggerOption.scheduledWindow.assertionReason(batteryThreshold: 20, cpuThreshold: 80, processName: "claude", schedule: .workHours, untilTime: noUntilTime).contains(KeepAwakeSchedule.workHours.label),
            "schedule reason should name the chosen preset"
        )
    }

    // MARK: KeepAwakeSchedule presets

    func testEveryKeepAwakeSchedulePresetHasADistinctLabel() {
        let labels = Set(KeepAwakeSchedule.presets.map(\.label))
        XCTAssertEqual(labels.count, KeepAwakeSchedule.presets.count)
    }

    func testWeekendPresetCoversTheFullDayViaEndMinute1440() {
        XCTAssertEqual(KeepAwakeSchedule.weekend.startMinute, 0)
        XCTAssertEqual(KeepAwakeSchedule.weekend.endMinute, 1440)
    }

    // MARK: mode labels

    func testEveryAwakeModeHasDistinctUserFacingText() {
        let shorts = Set(AwakeMode.allCases.map(\.shortLabel))
        let longs = Set(AwakeMode.allCases.map(\.longLabel))
        let explanations = Set(AwakeMode.allCases.map(\.explanation))
        XCTAssertEqual(shorts.count, AwakeMode.allCases.count)
        XCTAssertEqual(longs.count, AwakeMode.allCases.count)
        XCTAssertEqual(explanations.count, AwakeMode.allCases.count)
    }

    /// The regression the label rewrite exists for. `.systemWhileOnAC` used
    /// to read "Only while plugged in" everywhere, which named the power
    /// axis and said nothing at all about the display — so a user picking it
    /// had no way to learn that, unlike `.displayAndSystem`, it lets the
    /// screen go dark. Every user-facing string for it must now name both
    /// axes. See the `AwakeMode` extension's two-axis table.
    func testPowerOnlyModeNamesBothTheDisplayAndThePowerAxis() {
        let mode = AwakeMode.systemWhileOnAC
        for text in [mode.shortLabel, mode.longLabel, mode.explanation] {
            XCTAssertTrue(
                text.localizedCaseInsensitiveContains("screen"),
                "power-only mode must say what happens to the display, got: \(text)"
            )
        }
        XCTAssertTrue(
            mode.longLabel.localizedCaseInsensitiveContains("power"),
            "power-only mode's menu item must stand on its own outside its section header"
        )
        XCTAssertTrue(
            mode.explanation.localizedCaseInsensitiveContains("battery"),
            "the explanation must say what happens when you unplug"
        )
    }

    /// The two modes that never idle-sleep the system but do let the display
    /// sleep must say so in the same words, or the list re-acquires the
    /// ambiguity the sections were introduced to remove.
    func testBothScreenMaySleepModesDescribeTheDisplayTheSameWay() {
        for mode in [AwakeMode.systemOnly, .systemWhileOnAC] {
            XCTAssertTrue(
                mode.longLabel.localizedCaseInsensitiveContains("screen may sleep"),
                "\(mode) should describe the display the same way, got: \(mode.longLabel)"
            )
        }
    }

    // MARK: mode menu grouping

    /// The mode menu is built by walking `AwakeModePowerScope.allCases` and
    /// asking each for its `modes`. If that partition ever stopped covering
    /// every case, a mode would simply vanish from the picker with nothing
    /// failing to compile.
    func testPowerScopesPartitionEveryAwakeModeExactlyOnce() {
        let grouped = AwakeModePowerScope.allCases.flatMap(\.modes)
        XCTAssertEqual(Set(grouped), Set(AwakeMode.allCases))
        XCTAssertEqual(grouped.count, AwakeMode.allCases.count, "no mode may appear in two sections")
    }

    func testPowerScopesSeparateTheAlwaysModesFromThePowerOnlyMode() {
        XCTAssertEqual(AwakeModePowerScope.anyPower.modes, [.displayAndSystem, .systemOnly])
        XCTAssertEqual(AwakeModePowerScope.onPowerOnly.modes, [.systemWhileOnAC])
    }

    func testPowerScopeHeadersAreDistinct() {
        let headers = Set(AwakeModePowerScope.allCases.map(\.menuHeader))
        XCTAssertEqual(headers.count, AwakeModePowerScope.allCases.count)
    }

    // MARK: process picker contents

    /// A stand-in process table: a couple of curated agent/build tools plus
    /// the kind of daemon noise that makes up the bulk of a real one.
    private let sampleProcesses = [
        "WindowServer", "node", "mdworker_shared", "claude", "Finder", "-zsh", "bird"
    ]

    func testSuggestedListsOnlyCuratedToolsThatAreActuallyRunning() {
        let contents = KeepAwakeProcessMenu.contents(running: sampleProcesses)
        XCTAssertFalse(contents.isFallback)
        XCTAssertEqual(contents.suggested, ["claude", "node"])
    }

    /// The whole point of ranking rather than filtering: a name that isn't
    /// curated is still reachable. Nothing the scan returned may be dropped.
    func testEveryRunningNameIsReachableSomewhereInTheMenu() {
        let contents = KeepAwakeProcessMenu.contents(running: sampleProcesses)
        for name in sampleProcesses {
            XCTAssertTrue(contents.offers(name), "\(name) must be selectable somewhere in the menu")
        }
        let grouped = contents.groups.flatMap(\.names)
        XCTAssertEqual(
            Set(grouped + contents.suggested).count,
            Set(sampleProcesses.map { $0.lowercased() }).count
        )
    }

    func testLongTailIsGroupedByInitialLetterWithNonLettersLast() {
        let contents = KeepAwakeProcessMenu.contents(running: sampleProcesses)
        XCTAssertEqual(contents.groups.map(\.title), ["B", "F", "M", "W", "#"])
        XCTAssertEqual(contents.groups.last?.names, ["-zsh"], "non-letter names bucket to # and sort last")
    }

    func testNamesWithinAGroupStaySortedCaseInsensitively() {
        let contents = KeepAwakeProcessMenu.contents(running: ["bird", "Bluetoothd", "backupd"])
        XCTAssertEqual(contents.groups.first?.names, ["backupd", "bird", "Bluetoothd"])
    }

    /// A single name can hold a dozen PIDs (`mdworker_shared` routinely
    /// does); listing it a dozen times would be noise.
    func testDuplicateNamesAreCollapsedCaseInsensitively() {
        let contents = KeepAwakeProcessMenu.contents(running: ["node", "Node", "NODE", "bird"])
        XCTAssertEqual(contents.suggested, ["node"])
        XCTAssertEqual(contents.groups.flatMap(\.names), ["bird"])
    }

    func testOffersMatchesCaseInsensitivelyAndRejectsEmpty() {
        let contents = KeepAwakeProcessMenu.contents(running: sampleProcesses)
        XCTAssertTrue(contents.offers("CLAUDE"))
        XCTAssertTrue(contents.offers("windowserver"))
        XCTAssertFalse(contents.offers("xcodebuild"))
        XCTAssertFalse(contents.offers(""))
    }

    // MARK: process picker fallback

    /// An unreadable process table must not produce an empty menu — a dead
    /// control on the only row that can arm this trigger is worse than a
    /// stale list.
    func testEmptyProcessTableFallsBackToThePresetList() {
        let contents = KeepAwakeProcessMenu.contents(running: [])
        XCTAssertTrue(contents.isFallback)
        XCTAssertEqual(contents.suggested, KeepAwakeProcessMenu.presets)
        XCTAssertTrue(contents.groups.isEmpty)
    }

    /// Whitespace-only junk from the scan is the same "nothing usable" case.
    func testBlankProcessNamesAreTreatedAsAnEmptyTable() {
        let contents = KeepAwakeProcessMenu.contents(running: ["", "   "])
        XCTAssertTrue(contents.isFallback)
        XCTAssertEqual(contents.suggested, KeepAwakeProcessMenu.presets)
    }

    /// "Suggested" is a claim about what's running; the fallback isn't
    /// entitled to make it.
    func testFallbackHeaderDoesNotClaimTheNamesAreRunning() {
        XCTAssertNotEqual(
            KeepAwakeProcessMenu.contents(running: []).suggestedHeader,
            KeepAwakeProcessMenu.contents(running: sampleProcesses).suggestedHeader
        )
    }

    func testPresetsAreAllTreatedAsSuggestedNames() {
        for preset in KeepAwakeProcessMenu.presets {
            XCTAssertTrue(
                KeepAwakeProcessMenu.suggestedNames.contains(preset.lowercased()),
                "\(preset) should rank into the suggested section when running"
            )
        }
    }

    // MARK: process picker selection

    /// The default selection is `claude`, which on most Macs isn't running.
    /// Left alone it would show a name `start()`'s validation is guaranteed
    /// to reject — the picker would open already broken.
    func testSelectionThatIsNotRunningRepointsToASuggestedProcess() {
        let contents = KeepAwakeProcessMenu.contents(running: ["node", "bird"])
        XCTAssertEqual(KeepAwakeProcessMenu.resolvedSelection(current: "claude", contents: contents), "node")
    }

    func testSelectionThatIsRunningIsLeftAlone() {
        let contents = KeepAwakeProcessMenu.contents(running: sampleProcesses)
        XCTAssertEqual(KeepAwakeProcessMenu.resolvedSelection(current: "Finder", contents: contents), "Finder")
        XCTAssertEqual(KeepAwakeProcessMenu.resolvedSelection(current: "  claude ", contents: contents), "claude")
    }

    /// No evidence the current value is wrong, so overruling it would be
    /// guessing.
    func testFallbackNeverOverrulesTheCurrentSelection() {
        let contents = KeepAwakeProcessMenu.contents(running: [])
        XCTAssertEqual(KeepAwakeProcessMenu.resolvedSelection(current: "ffmpeg", contents: contents), "ffmpeg")
    }

    /// Snapping the user onto whichever daemon happens to sort first would
    /// be a worse lie than a stale name.
    func testSelectionIsLeftAloneWhenNothingSuggestedIsRunning() {
        let contents = KeepAwakeProcessMenu.contents(running: ["WindowServer", "bird"])
        XCTAssertTrue(contents.suggested.isEmpty)
        XCTAssertEqual(KeepAwakeProcessMenu.resolvedSelection(current: "claude", contents: contents), "claude")
    }

    // MARK: applying changes to a running session

    private func selection(
        trigger: SleepTriggerOption = .indefinite,
        mode: AwakeMode = .displayAndSystem,
        batteryThreshold: Double = 20,
        cpuThreshold: Double = 80,
        processName: String = "claude",
        schedule: KeepAwakeSchedule = .weeknights,
        untilTime: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> KeepAwakeSelection {
        KeepAwakeSelection(
            trigger: trigger,
            mode: mode,
            batteryThreshold: batteryThreshold,
            cpuThreshold: cpuThreshold,
            processName: processName,
            schedule: schedule,
            untilTime: untilTime
        )
    }

    /// A hold this card didn't arm — restored across relaunch, or created
    /// over MCP — has no baseline to diff against, and `ReleaseCondition` is
    /// private to `PowerControlService`, so there is nothing honest to
    /// compare. Apply must offer a full replacement and say so.
    func testNoBaselineMeansTheChangeIsUnknown() {
        XCTAssertEqual(KeepAwakeChange.between(applied: nil, current: selection()), .unknown)
        XCTAssertTrue(KeepAwakeChange.unknown.isApplicable)
    }

    func testAnUntouchedSelectionHasNothingToApply() {
        let current = selection()
        XCTAssertEqual(KeepAwakeChange.between(applied: current, current: current), .none)
        XCTAssertFalse(KeepAwakeChange.none.isApplicable)
    }

    /// The distinction the whole split exists for: a mode switch must not
    /// hand the user a fresh countdown.
    func testChangingOnlyTheModeKeepsTheDeadline() {
        XCTAssertEqual(
            KeepAwakeChange.between(
                applied: selection(trigger: .fixed(3600), mode: .displayAndSystem),
                current: selection(trigger: .fixed(3600), mode: .systemOnly)
            ),
            .modeOnly
        )
    }

    func testChangingTheTriggerRestartsTheSession() {
        XCTAssertEqual(
            KeepAwakeChange.between(
                applied: selection(trigger: .fixed(3600)),
                current: selection(trigger: .fixed(7200))
            ),
            .retrigger
        )
    }

    /// Thresholds live on the view so switching triggers doesn't discard the
    /// other one's number — which means a value the running hold has never
    /// read changes constantly. A whole-struct comparison would restart the
    /// user's countdown because they nudged a stepper the assertion ignores.
    func testAThresholdTheRunningTriggerIgnoresIsNotAChange() {
        XCTAssertEqual(
            KeepAwakeChange.between(
                applied: selection(trigger: .batteryBelow, cpuThreshold: 80),
                current: selection(trigger: .batteryBelow, cpuThreshold: 55)
            ),
            .none
        )
        XCTAssertEqual(
            KeepAwakeChange.between(
                applied: selection(trigger: .indefinite, processName: "claude"),
                current: selection(trigger: .indefinite, processName: "node")
            ),
            .none
        )
    }

    func testAThresholdTheRunningTriggerReadsIsAChange() {
        XCTAssertEqual(
            KeepAwakeChange.between(
                applied: selection(trigger: .batteryBelow, batteryThreshold: 20),
                current: selection(trigger: .batteryBelow, batteryThreshold: 35)
            ),
            .retrigger
        )
        XCTAssertEqual(
            KeepAwakeChange.between(
                applied: selection(trigger: .cpuAbove, cpuThreshold: 80),
                current: selection(trigger: .cpuAbove, cpuThreshold: 55)
            ),
            .retrigger
        )
        XCTAssertEqual(
            KeepAwakeChange.between(
                applied: selection(trigger: .scheduledWindow, schedule: .weeknights),
                current: selection(trigger: .scheduledWindow, schedule: .workHours)
            ),
            .retrigger
        )
    }

    /// `isProcessRunning(named:)` matches case-insensitively, so a change of
    /// case is the same hold — re-arming for it would be a teardown for
    /// nothing.
    func testProcessNameComparisonIsCaseInsensitive() {
        XCTAssertEqual(
            KeepAwakeChange.between(
                applied: selection(trigger: .processRunning, processName: "Node"),
                current: selection(trigger: .processRunning, processName: "node")
            ),
            .none
        )
        XCTAssertEqual(
            KeepAwakeChange.between(
                applied: selection(trigger: .processRunning, processName: "node"),
                current: selection(trigger: .processRunning, processName: "xcodebuild")
            ),
            .retrigger
        )
    }

    /// `.untilTime` only ever reads hour and minute
    /// (`resolvedDuration(untilTime:)`), so the day/month/year the
    /// `DatePicker` leaves behind must not register as an edit.
    func testUntilTimeComparesOnlyTheHourAndMinuteItActuallyReads() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 22, minute: 30)))
        let tuesday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 6, hour: 22, minute: 30)))
        let later = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 22, minute: 45)))

        XCTAssertEqual(
            KeepAwakeChange.between(
                applied: selection(trigger: .untilTime, untilTime: monday),
                current: selection(trigger: .untilTime, untilTime: tuesday),
                calendar: calendar
            ),
            .none
        )
        XCTAssertEqual(
            KeepAwakeChange.between(
                applied: selection(trigger: .untilTime, untilTime: monday),
                current: selection(trigger: .untilTime, untilTime: later),
                calendar: calendar
            ),
            .retrigger
        )
    }

    /// A trigger change *and* a mode change is still a full re-arm — the
    /// deadline it would have preserved no longer means anything.
    func testChangingBothTheTriggerAndTheModeRestarts() {
        XCTAssertEqual(
            KeepAwakeChange.between(
                applied: selection(trigger: .fixed(3600), mode: .displayAndSystem),
                current: selection(trigger: .indefinite, mode: .systemOnly)
            ),
            .retrigger
        )
    }

    /// The caption is the only place the user learns whether their countdown
    /// survives the click, so the four outcomes must not read alike.
    func testEveryChangeOutcomeExplainsItselfDistinctly() {
        let outcomes: [KeepAwakeChange] = [.none, .modeOnly, .retrigger, .unknown]
        XCTAssertEqual(Set(outcomes.map(\.caption)).count, outcomes.count)
        XCTAssertTrue(KeepAwakeChange.modeOnly.caption.localizedCaseInsensitiveContains("keeps"))
        XCTAssertTrue(KeepAwakeChange.retrigger.caption.localizedCaseInsensitiveContains("restarts"))
    }
}
