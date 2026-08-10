import SwiftUI
import SentryKit

/// Plan §10.5: the sleep-prevention control that lives in the dropdown — a
/// toggle, a duration/trigger menu, an `AwakeMode` menu, and a live countdown
/// while an assertion is running.
///
/// **Layout.** Two states, one grid. Off, this is two rows: the switch, and a
/// summary of what flipping it will do ("Indefinitely · Screen stays on")
/// which doubles as the disclosure for the pickers behind it. On, it is the
/// countdown plus the controls that move it — *and the same pickers*, see
/// "Editable while running" below. Nothing is boxed — the section is
/// bounded by the hairlines `DropdownView` draws above and below it, and the
/// labels/values sit on `DropdownGrid`, so the keep-awake rows and the vitals
/// rows above them share a left edge, a right edge and a row height.
///
/// The pickers used to be visible at all times, which put four rows and a
/// two-line explanation permanently under a switch that most users flip
/// without changing anything. They're one click away now instead, and the
/// collapsed summary states the current selection so the disclosure never
/// hides *what will happen* — only *how to change it*.
///
/// **Editable while running (and what "apply" means).** The pickers used to
/// render only in the inactive branch: turning keep-awake on was a one-way
/// door, and changing your mind about the mode or the end condition meant
/// ending the session and starting a new one — which is both an extra step
/// and a moment where the Mac is genuinely allowed to sleep. They now render
/// in both branches, *below* the countdown (the countdown is what the user
/// opened the popover for; the controls that change it are secondary).
///
/// Committing a change is an explicit **Apply**, not an immediate re-assert
/// on every edit. Immediate-apply was written first and rejected for two
/// concrete reasons, both of which are worse than one extra click:
///
/// - *A half-configured trigger would arm itself.* Switching "For" from
///   "Indefinitely" to "Until battery is low" would immediately re-arm at
///   whatever battery floor happened to be left in the stepper, and then
///   re-arm *again* when the user dialed in the number they actually wanted
///   — a period of live, wrong behavior plus two teardowns, produced by a
///   user who did nothing but start typing their intent.
/// - *Every edit is a real IOKit teardown.* `startAssertionInternal` begins
///   with `releaseAssertion()`, so each re-assert releases and recreates the
///   OS-level assertion, bumps `assertionGeneration`, and closes and reopens
///   an `awakeHolds` ledger entry. A `Stepper` held down, or a `DatePicker`
///   typed into, would do that per tick and per keystroke.
///
/// Apply's semantics depend on *what* changed, because the two rows mean
/// different things. The **For** row and its threshold row define when the
/// hold ends, so changing them re-arms from scratch — the new end point is
/// measured from now, exactly as if the user had started fresh. The **Mode**
/// row defines what the hold prevents and says nothing about when it ends,
/// so changing only the mode re-asserts with the new mode and **preserves
/// the running deadline**: switching from "screen stays on" to "screen may
/// sleep" forty minutes into an hour must not silently hand the user a fresh
/// hour. `KeepAwakeChange` is that distinction, computed by comparing the
/// shown selection against the one this card last handed to the service.
///
/// **Why an always-available Apply rather than one that appears only when
/// something differs.** For a hold this card started, it can tell. For one
/// it didn't — restored across a relaunch by `reconcilePersistedState`, or
/// created over MCP by `startAgentAssertion` — it cannot: `SleepAssertionState`
/// carries `mode`, `expiresAt` and `reason`, while the `ReleaseCondition`
/// itself is private to `PowerControlService`, so there is no honest way to
/// diff the "For" row against what is actually armed. That case is
/// `KeepAwakeChange.unknown` and it says so in words rather than pretending
/// to a comparison it can't make (P5). The one axis that *does* survive into
/// `SleepAssertionState` is `mode`, so the Mode row is seeded from the live
/// assertion in that case — see `syncWithRunningHold()`.
///
/// **Scope, and what's deliberately missing.** Plan §10.3 lists six trigger
/// kinds; a later competitive pass against other keep-awake utilities added
/// two more (download-active, scheduled) and, later still, a clock-time
/// trigger. Seven of those eight are here (indefinite, fixed presets, battery
/// threshold, sustained-CPU threshold, process running, download active,
/// scheduled window, until a specific time — see below). One is not:
///
/// - *While a specific app is running* needs a running-app browser.
///
/// That would roughly double this card's height inside a 320pt popover whose
/// remaining space belongs to the vitals. It's deferred to the Settings
/// window, not dropped: `ReleaseCondition.whileAppRunning` already exists and
/// is fully handled by `PowerControlService`'s `NSWorkspace` termination
/// observer — it needs no service-layer work to land later, only UI. Note
/// that the Process picker below is *not* that feature arriving early: it
/// drives `.whileProcessRunning` (an executable name matched against the
/// process table) and adds no rows to this card, whereas `.whileAppRunning`
/// is a `NSWorkspace` bundle-identifier trigger that still wants a browser
/// with icons and app names. The two triggers stay distinct.
///
/// **Why the Process field is a picker with no text field.** It was a
/// `TextField` plus a five-item preset menu, and free text was a correctness
/// bug rather than a convenience: `.whileProcessRunning` matches an *exact*
/// executable name, so `xcodbuild` is not a typo the user gets told about —
/// it's a keep-awake session that silently never holds, which is the single
/// worst failure mode a control whose entire job is "don't let the Mac sleep
/// during my long build" can have. The picker offers what is actually on the
/// process table (`PowerControlService.runningProcessNames()`), which makes
/// the spelling correct by construction *and* is exactly the set of names
/// `start()`'s arm-time validation will accept — offering anything else
/// would be offering a guaranteed failure. See `KeepAwakeProcessMenu` for
/// how ~900 running names are made navigable, and for the alternatives
/// (flat list, hard cap, current-user filter) that were measured and
/// rejected.
///
/// **Why the scheduled trigger is preset-only, not a free-form day/time
/// picker.** `ReleaseCondition.scheduledWindow` can express any weekday set
/// plus any minute-of-day window, but this card exposes only a handful of
/// named `KeepAwakeSchedule` presets through the same `Menu`-of-`Button`s
/// idiom `pickers` already uses for `trigger` and `mode` (see `optionMenu`).
/// A real weekday multi-select plus two time pickers is exactly the kind of
/// "roughly double this card's height" control the paragraph above already
/// ruled out for the two deferred triggers — free-form scheduling belongs in
/// the Settings window for the same reason. The presets cover the common
/// cases (every night, weeknights, work hours, weekends) without adding a
/// new visual idiom to this surface.
///
/// **Why the download-active trigger has no threshold row.** Its idle-timeout
/// is fixed at `downloadIdleTimeout` rather than exposed, the same call
/// `cpuSustainedWindow` below already makes for `.cpuAbove`: a user-tunable
/// "how many idle seconds counts as still downloading" invites values (0s)
/// that quietly defeat the heuristic.
///
/// **Why the card re-reads `powerControl.state` instead of mirroring it.**
/// The service is the single source of truth and can end an assertion without
/// this view asking: the expiry timer fires, a conditional trigger fires, or
/// wake/relaunch reconciliation decides the persisted assertion can't be
/// restored. Any locally cached "I turned it on" flag would keep claiming an
/// assertion that no longer exists, which is precisely the P5 lie this
/// codebase forbids. The only local state here is the user's *pending*
/// selection (what to start next) and the last start error.
struct SleepControlCard: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var powerControl: PowerControlService

    /// Where the Process picker's candidate names come from. Injected as a
    /// closure with a real default rather than read straight from the static
    /// so previews and tests can hand this card a fabricated process table —
    /// the same reason `PowerControlService.processProbe` is a settable
    /// closure over the very same scan. Both existing call sites
    /// (`DropdownView`, `DashboardView`) construct this card as
    /// `SleepControlCard(powerControl:)` and are unaffected: a stored
    /// property with a default value becomes a defaulted memberwise
    /// parameter.
    var runningProcessNamesProvider: () -> [String] = { PowerControlService.runningProcessNames() }

    @State private var trigger: SleepTriggerOption = .indefinite
    @State private var mode: AwakeMode = .displayAndSystem
    @State private var batteryThreshold: Double = 20
    @State private var cpuThreshold: Double = 80
    /// Executable name for `.processRunning`. Defaults to the tool this
    /// feature was built for — an agent CLI chewing through a long task is
    /// the canonical "hold the Mac awake until it's done" workload — but is
    /// re-pointed at something that is genuinely running by
    /// `refreshRunningProcesses()` if this default isn't, so the picker never
    /// opens already showing a name that cannot arm.
    @State private var processName: String = "claude"

    /// Snapshot of the process table, refreshed on the events listed in
    /// `refreshRunningProcesses()`. Cached in `@State` rather than scanned
    /// inside `body` because `body` runs far more often than the process
    /// table meaningfully changes, and this scan walks every PID on the
    /// machine — putting it on the render path would pay for a full
    /// enumeration every time the countdown ticks.
    @State private var runningProcesses: [String] = []

    /// The selection this card last successfully handed to
    /// `PowerControlService`, or `nil` when this card didn't start what's
    /// running (relaunch restore, an MCP-created hold, or nothing running at
    /// all). The baseline `KeepAwakeChange` diffs against — see the type doc
    /// comment's "always-available Apply" paragraph for why `nil` is a
    /// distinct, user-visible case rather than something to paper over.
    @State private var applied: KeepAwakeSelection?

    /// `.scheduledWindow`'s selection — one of `KeepAwakeSchedule`'s named
    /// presets. See the type doc comment for why this is preset-only rather
    /// than a free-form weekday/time picker.
    @State private var schedule: KeepAwakeSchedule = .weeknights
    /// `.untilTime`'s picked clock time — only the hour/minute components
    /// are read (`SleepTriggerOption.resolvedDuration(untilTime:)`), so the
    /// day/month/year `DatePicker(.hourAndMinute)` leaves this at are never
    /// used. Defaults to 10 PM, the same "end of evening" instinct
    /// `KeepAwakeSchedule.everyNight`/`.weeknights` already encode.
    @State private var untilTime: Date = {
        Calendar.current.date(bySettingHour: 22, minute: 0, second: 0, of: Date()) ?? Date()
    }()

    /// Whether the trigger/mode pickers are disclosed. Local and not
    /// persisted: it's a "I'm about to change something" state, not a
    /// preference, and re-opening the popover should show the calm form.
    @State private var showsOptions = false

    /// Non-nil only when the most recent `startAssertion` attempt threw. Shown
    /// verbatim instead of a success state (P5) and cleared by the next
    /// successful start or by turning the toggle off.
    @State private var startError: String?

    /// `.cpuAbovePercent`'s sustained window. Fixed at the plan's five
    /// minutes rather than exposed: the point of the sustained clock is to
    /// stop a momentary dip from releasing a long build's assertion, and a
    /// user-tunable "how long" control invites values (0s, 1s) that quietly
    /// defeat it.
    private static let cpuSustainedWindow: TimeInterval = 5 * 60

    /// `.whileDownloadActive`'s idle timeout — how many seconds without a
    /// write to `~/Downloads` before the heuristic considers a download
    /// finished. Fixed, not exposed — see the type doc comment above for why
    /// — and chosen from the middle of `ReleaseCondition
    /// .whileDownloadActive`'s documented 5–10s range: long enough to ride
    /// out the brief pause between chunks a slow or throttled transfer can
    /// have, short enough that the hold doesn't outlive the download by very
    /// much once it genuinely finishes.
    private static let downloadIdleTimeout: TimeInterval = 8

    private var activeState: (mode: AwakeMode, expiresAt: Date?, reason: String)? {
        guard case .active(let mode, let expiresAt, let reason) = powerControl.state else { return nil }
        return (mode, expiresAt, reason)
    }

    private var isActive: Bool { activeState != nil }

    /// The options block renders in *both* states now (see the type doc
    /// comment's "Editable while running"), always below `activeDetail` so a
    /// running session's countdown stays the first thing under the switch.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let activeState {
                activeDetail(for: activeState)
            }
            optionsDisclosure
            if showsOptions {
                pickers
            }
            if let startError {
                errorRow(startError)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // Only pay for the scan when the picker is (or is one row from
            // being) on screen. It walks every PID on the machine, and the
            // overwhelming majority of popover opens never expand these
            // controls at all — the drawer-open and trigger-pick handlers
            // cover the rest.
            if showsOptions || trigger == .processRunning {
                refreshRunningProcesses()
            }
            syncWithRunningHold()
        }
        // The service can end or replace an assertion without this view
        // asking (expiry, a conditional trigger firing, wake reconciliation),
        // and a hold created over MCP can appear while the popover is open —
        // so the mode/baseline sync is driven off the service's own state
        // rather than only off this card's actions.
        .onChange(of: powerControl.state) { _, _ in
            syncWithRunningHold()
        }
    }

    // MARK: Header

    /// The section's title row. `.medium` on `textPrimary` rather than a size
    /// jump: this is a heading among data rows, and the surface has exactly one
    /// slot for large type (the verdict line, above).
    private var header: some View {
        HStack(spacing: palette.spacingTight) {
            Text("Keep Awake")
                .font(palette.font(size: 11, weight: .medium))
                .foregroundStyle(palette.textPrimary)
            Spacer(minLength: palette.spacingTight)
            Toggle("", isOn: toggleBinding)
                .labelsHidden()
                // The row this branch was opened about. It was
                // `.toggleStyle(.switch).controlSize(.mini).tint(palette.accent)`
                // — and `.tint` only ever reaches the *on* track, so the off
                // state kept AppKit's system grey and disappeared into Ivory's
                // `#E6E3D8` card. `ThemedToggleStyle` draws both states from
                // the palette; this card is `surfaceElevated`, not the
                // dropdown `background` that `DropdownView` applies, so the
                // grading backdrop is overridden here.
                .themedToggles(on: .surfaceElevated)
                .accessibilityLabel("Keep awake")
                // Two whole `Text`s rather than a String ternary: a ternary of
                // two bare literals resolves to `String`, which silently picks
                // the non-localizing `accessibilityValue(_: String)` overload.
                .accessibilityValue(isActive ? Text("On, preventing sleep") : Text("Off, sleep behaves normally"))
        }
        .padding(.horizontal, palette.spacingTight)
        .frame(height: DropdownGrid.rowHeight)
    }

    /// Writes go straight to the service; reads come straight back from it.
    /// If `startAssertion` throws, `powerControl.state` stays `.inactive`, so
    /// the switch springs back on its own — the UI can't get stuck showing
    /// "on" for an assertion IOKit refused to create.
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { isActive },
            set: { wantsOn in wantsOn ? start() : stop() }
        )
    }

    // MARK: Inactive — configuration

    /// Collapsed and inactive, this row *is* the answer to "what happens if I
    /// flip that switch"; expanded, it becomes the group's label. Never both,
    /// because a summary sitting directly above the two controls it summarises
    /// is redundancy the eye still has to read.
    ///
    /// Collapsed and **active**, it deliberately does *not* restate
    /// `selectionSummary`. Two reasons: the truth about the running session is
    /// already spelled out immediately above it by the countdown and the
    /// verbatim `reason` line, and — more importantly — `selectionSummary` is
    /// built from this card's *pending* picker values, which for a restored or
    /// MCP-created hold describe nothing that is actually armed. Rendering it
    /// as a collapsed summary there would be a confident claim about state we
    /// don't have (P5). It reads as a verb instead.
    private var optionsDisclosure: some View {
        let collapsedTitle = isActive ? String(localized: "Change options") : selectionSummary
        return DropdownDisclosureRow(
            title: showsOptions ? String(localized: "Options") : collapsedTitle,
            isExpanded: showsOptions,
            accessibilityLabel: showsOptions
                ? String(localized: "Hide keep awake options")
                : (isActive
                    ? String(localized: "Change keep awake options")
                    : String(localized: "Keep awake options, currently \(selectionSummary)"))
        ) {
            withAnimation(ThemePalette.disclosureMotion(reduceMotion: reduceMotion)) {
                showsOptions.toggle()
            }
            if showsOptions {
                // Opening the drawer is the one moment the process list is
                // about to be read, and the cheapest place to make sure it
                // isn't stale from a previous popover session.
                refreshRunningProcesses()
            }
        }
    }

    private var selectionSummary: String {
        let triggerText = trigger.menuLabel(
            batteryThreshold: batteryThreshold,
            cpuThreshold: cpuThreshold,
            processName: processName,
            schedule: schedule,
            untilTime: untilTime
        )
        return "\(triggerText) · \(mode.shortLabel)"
    }

    private var pickers: some View {
        VStack(alignment: .leading, spacing: 0) {
            optionMenu(
                title: String(localized: "For"),
                selection: trigger.menuLabel(
                    batteryThreshold: batteryThreshold,
                    cpuThreshold: cpuThreshold,
                    processName: processName,
                    schedule: schedule,
                    untilTime: untilTime
                )
            ) {
                ForEach(SleepTriggerOption.allOptions) { option in
                    Button(option.pickerLabel) {
                        trigger = option
                        // Picking the process trigger is the moment its list
                        // is about to be needed; the user may have opened this
                        // drawer minutes ago.
                        if case .processRunning = option { refreshRunningProcesses() }
                    }
                }
            }
            thresholdStepper
            modeRow
            Text(mode.explanation)
                .font(palette.font(size: 10))
                .foregroundStyle(palette.textTertiary)
                // Three, not two: every explanation now states both axes —
                // what stays awake *and* under what power condition — which
                // is the whole point of the rewrite and costs a line.
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, palette.spacingTight)
                .padding(.bottom, palette.spacingTight)
            if isActive {
                applyBlock
            }
        }
        .transition(.opacity)
    }

    /// The mode picker, grouped by power condition.
    ///
    /// **Why sections rather than three flat items.** The three `AwakeMode`
    /// cases describe two different things at once, which is what made the
    /// old list ("Keep display on" / "System only (display may sleep)" /
    /// "Only while plugged in") unreadable: the first two answer *what stays
    /// awake* and the third answers *when the rule applies*, so a user
    /// comparing them had no way to know that "Only while plugged in" also
    /// lets the display sleep — the two axes were collapsed onto one list and
    /// the third item silently carried both. Splitting the menu on the power
    /// axis puts each axis on its own visual level: the section header is the
    /// *when*, the item is the *what*. Two items now read identically apart
    /// from their header, which is correct — `.systemOnly` and
    /// `.systemWhileOnAC` genuinely differ only in power condition — and is
    /// exactly the fact the flat list hid.
    ///
    /// **Why the item text carries the explanation rather than a subtitle
    /// under it.** The obvious "show the per-option explanation in the menu"
    /// implementation is a two-`Text` menu-item label, and this file already
    /// documents what AppKit does to a menu label built from more than one
    /// view (see `optionMenu`: it flattened an `HStack` down to one glyph and
    /// one string, shipping a control whose selection was never drawn).
    /// Rather than re-litigate that at the item level, each item is a single
    /// self-contained sentence naming both axes, and the fuller sentence
    /// stays under the closed picker where a `Text` renders predictably.
    private var modeRow: some View {
        optionMenu(title: String(localized: "Mode"), selection: mode.shortLabel) {
            ForEach(AwakeModePowerScope.allCases) { scope in
                Section(scope.menuHeader) {
                    ForEach(scope.modes, id: \.self) { candidate in
                        Button(candidate.longLabel) { mode = candidate }
                    }
                }
            }
        }
    }

    // MARK: Applying changes to a running session

    /// What pressing Apply right now would do to the running hold.
    private var pendingChange: KeepAwakeChange {
        KeepAwakeChange.between(applied: applied, current: currentSelection)
    }

    private var currentSelection: KeepAwakeSelection {
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

    /// The Apply control and the sentence explaining what it will do to the
    /// countdown. The sentence is not decoration: "restarts the countdown"
    /// versus "keeps the current end time" is the entire difference between
    /// the two commit paths, and a user who changed the mode of a four-hour
    /// hold deserves to know which one they're about to get *before* they
    /// click, not by watching the clock jump afterwards.
    @ViewBuilder
    private var applyBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if pendingChange.isApplicable {
                HStack(spacing: 2) {
                    Spacer(minLength: palette.spacingTight)
                    DropdownInlineButton(
                        title: String(localized: "Apply"),
                        accessibilityLabel: String(localized: "Apply changes to the running keep awake session")
                    ) {
                        apply()
                    }
                }
                .padding(.horizontal, palette.spacingTight)
                .frame(height: DropdownGrid.rowHeight)
            }
            Text(pendingChange.caption)
                .font(palette.font(size: 10))
                .foregroundStyle(palette.textTertiary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, palette.spacingTight)
                .padding(.bottom, palette.spacingTight)
        }
    }

    /// Only the conditional triggers with something for the user to tune
    /// show an extra row here — `.downloadActive`'s idle timeout is fixed
    /// (see `downloadIdleTimeout`'s doc comment), so it joins `.indefinite`
    /// and `.fixed` in showing nothing.
    @ViewBuilder
    private var thresholdStepper: some View {
        switch trigger {
        case .untilTime:
            untilTimeRow
        case .batteryBelow:
            percentStepper(String(localized: "Battery floor"), value: $batteryThreshold, range: 5...95)
        case .cpuAbove:
            percentStepper(String(localized: "CPU floor"), value: $cpuThreshold, range: 10...100)
        case .processRunning:
            processPickerRow
        case .scheduledWindow:
            scheduleRow
        case .indefinite, .fixed, .downloadActive:
            EmptyView()
        }
    }

    /// `.untilTime`'s clock-time picker — see `SleepTriggerOption.untilTime`'s
    /// doc comment for why this is a real `DatePicker`, not the `optionMenu`
    /// preset idiom `scheduleRow`/`mode` use. `.compact` keeps it to the same
    /// single-row height as every other threshold control here; `.hourAndMinute`
    /// excludes the date component this trigger never reads.
    private var untilTimeRow: some View {
        HStack(spacing: palette.spacingTight) {
            Text("Until")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
            Spacer(minLength: palette.spacingTight)
            DatePicker("", selection: $untilTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.compact)
                .labelsHidden()
                .font(palette.numericFont(size: 11, weight: .medium))
        }
        .padding(.horizontal, palette.spacingTight)
        .padding(.bottom, palette.spacingTight)
    }

    /// `.scheduledWindow`'s preset picker — the same `optionMenu` idiom the
    /// `mode` row uses, chosen over a bespoke weekday/time control per the
    /// type doc comment's "preset-only" rationale.
    private var scheduleRow: some View {
        optionMenu(title: String(localized: "Schedule"), selection: schedule.label) {
            ForEach(KeepAwakeSchedule.presets) { preset in
                Button(preset.label) { schedule = preset }
            }
        }
    }

    /// `.processRunning`'s executable-name picker — the same `optionMenu`
    /// idiom `scheduleRow` and `modeRow` use, with **no text entry at all**.
    /// See the type doc comment ("Why the Process field is a picker with no
    /// text field") for why free text was a correctness bug rather than a
    /// convenience, and `KeepAwakeProcessMenu` for the shape of the list.
    private var processPickerRow: some View {
        let contents = processMenuContents
        return optionMenu(
            title: String(localized: "Process"),
            selection: processName.isEmpty ? String(localized: "Choose…") : processName
        ) {
            processMenuItems(contents)
        }
    }

    private var processMenuContents: KeepAwakeProcessMenu.Contents {
        KeepAwakeProcessMenu.contents(running: runningProcesses)
    }

    /// The suggested names sit at the top level where they're one click away;
    /// the long tail goes behind a submenu, and behind a letter submenu
    /// inside that, because the raw list is hundreds of names long (see
    /// `KeepAwakeProcessMenu`). When nothing suggested is running there's no
    /// top-level section worth drawing, so the letter groups are promoted
    /// rather than hiding the entire menu behind a single "All running
    /// processes" item that the user would have to open to find anything.
    @ViewBuilder
    private func processMenuItems(_ contents: KeepAwakeProcessMenu.Contents) -> some View {
        if contents.suggested.isEmpty {
            letterGroupMenus(contents.groups)
        } else {
            Section(contents.suggestedHeader) {
                ForEach(contents.suggested, id: \.self) { name in
                    Button(name) { processName = name }
                }
            }
            if !contents.groups.isEmpty {
                Menu(String(localized: "All running processes")) {
                    letterGroupMenus(contents.groups)
                }
            }
        }
    }

    @ViewBuilder
    private func letterGroupMenus(_ groups: [KeepAwakeProcessMenu.LetterGroup]) -> some View {
        ForEach(groups) { group in
            Menu(group.title) {
                ForEach(group.names, id: \.self) { name in
                    Button(name) { processName = name }
                }
            }
        }
    }

    private func percentStepper(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        Stepper(value: value, in: range, step: 5) {
            HStack(spacing: palette.spacingTight) {
                Text(label)
                    .font(palette.font(size: 11))
                    .foregroundStyle(palette.textTertiary)
                Spacer(minLength: palette.spacingTight)
                Text(MetricFormatting.percent(value.wrappedValue))
                    .font(palette.numericFont(size: 11, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
            }
        }
        .controlSize(.mini)
        .padding(.horizontal, palette.spacingTight)
        .frame(height: DropdownGrid.rowHeight)
        .accessibilityLabel("\(label) \(MetricFormatting.percent(value.wrappedValue))")
    }

    /// A `Menu` rather than a `Picker`: `Picker`'s macOS pop-up button draws
    /// its own bezel, which is the one piece of system chrome this surface has
    /// nowhere to put.
    ///
    /// **The label is a single `Text` on purpose — this is a bug fix.** The
    /// previous version handed `Menu` an `HStack { Text(title); Spacer();
    /// Text(selection); Image(chevron) }` as its label. AppKit's borderless
    /// pop-up cannot host an arbitrary view hierarchy: it flattened the label
    /// down to one glyph and one string, so both rows shipped rendering as a
    /// stray up/down chevron next to "For" — the *current selection was never
    /// drawn at all*, and the control looked broken because, functionally, it
    /// was: the only way to see what was selected was to open the menu. The
    /// title now lives outside the `Menu` where we control it, the menu's own
    /// label is nothing but the selection string, and the system indicator is
    /// left visible (rather than hidden and re-drawn by hand) so the affordance
    /// can't disappear again. It lands in the same chevron column the vitals
    /// rows reserve, so the row still lines up.
    private func optionMenu<Content: View>(
        title: String,
        selection: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: palette.spacingTight) {
            Text(title)
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
            Spacer(minLength: palette.spacingTight)
            Menu {
                content()
            } label: {
                Text(selection)
                    .font(palette.font(size: 11, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("\(title), \(selection)")
        }
        .padding(.horizontal, palette.spacingTight)
        .frame(height: DropdownGrid.rowHeight)
    }

    // MARK: Active — countdown

    @ViewBuilder
    private func activeDetail(for active: (mode: AwakeMode, expiresAt: Date?, reason: String)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let expiresAt = active.expiresAt {
                // `TimelineView` is scoped to this branch on purpose: an
                // indefinite or condition-released assertion has nothing that
                // changes once per second, and a 1 Hz redraw of the whole
                // dropdown for a static string is exactly the kind of idle
                // wakeup plan §3.2 tells us not to add.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    countdownRow(remaining: expiresAt.timeIntervalSince(context.date))
                }
            } else {
                valueRow(label: String(localized: "Ends"), value: String(localized: "When you turn it off"))
            }
            valueRow(label: String(localized: "Mode"), value: active.mode.shortLabel)
            // Extend/truncate only mean something with an `expiresAt` to
            // adjust — an indefinite hold or a conditional trigger (both
            // `expiresAt == nil`) has no clock for these buttons to move,
            // matching `PowerControlService.adjustAssertion(bySeconds:)`'s
            // own `.noAdjustableAssertion` guard.
            adjustRow(hasClock: active.expiresAt != nil)
            // `reason` is the string handed to IOKit at start time and is the
            // only record of a conditional trigger that survives an app
            // relaunch (the condition itself is private to the service), so
            // it — not a locally remembered selection — is what's shown.
            Text(active.reason)
                .font(palette.font(size: 10))
                .foregroundStyle(palette.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, palette.spacingTight)
                .padding(.bottom, palette.spacingTight)
        }
    }

    /// Quick +/- adjustments to the running countdown, and the labelled way to
    /// end the session. `-15m` is allowed to end the assertion outright (via
    /// `adjustAssertion`'s own below-zero clamp) rather than being disabled
    /// once remaining time drops under 15 minutes — matching the "truncate"
    /// half of "extended or truncated or ended" the way a user would actually
    /// expect it to behave.
    ///
    /// "End Now" is a duplicate of the header switch, kept because a labelled
    /// verb next to the countdown is the discoverable version of "ended" once
    /// the timing controls are what the eye is on.
    private func adjustRow(hasClock: Bool) -> some View {
        HStack(spacing: 2) {
            if hasClock {
                adjustButton("−15m", delta: -15 * 60)
                adjustButton("+15m", delta: 15 * 60)
                adjustButton("+1h", delta: 60 * 60)
            }
            Spacer(minLength: palette.spacingTight)
            endNowButton
        }
        .padding(.horizontal, palette.spacingTight)
        .frame(height: DropdownGrid.rowHeight)
    }

    private func adjustButton(_ title: String, delta: TimeInterval) -> some View {
        DropdownInlineButton(
            title: title,
            accessibilityLabel: delta < 0
                ? String(localized: "Shorten by \(SleepCountdownFormatting.presetLabel(-delta))")
                : String(localized: "Extend by \(SleepCountdownFormatting.presetLabel(delta))")
        ) {
            adjust(bySeconds: delta)
        }
    }

    /// Neutral at rest and `danger` only under the cursor: a permanently red
    /// word on an otherwise monochrome surface reads as an error message rather
    /// than a control, but the colour is genuinely useful at the moment the
    /// user is about to commit to ending the session.
    private var endNowButton: some View {
        DropdownInlineButton(
            title: String(localized: "End Now"),
            hoverTint: palette.danger,
            accessibilityLabel: String(localized: "End keep awake now"),
            action: stop
        )
    }

    private func countdownRow(remaining: TimeInterval) -> some View {
        valueRow(label: String(localized: "Remaining"), value: SleepCountdownFormatting.countdown(remaining))
    }

    /// The same label-left/value-right geometry as a vitals detail row, ending
    /// on the same right edge, so the keep-awake block and the vitals block
    /// read as one table rather than two.
    private func valueRow(label: String, value: String) -> some View {
        HStack(spacing: palette.spacingTight) {
            Text(label)
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
            Spacer(minLength: palette.spacingTight)
            Text(value)
                .font(palette.numericFont(size: 11, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
        }
        .padding(.leading, palette.spacingTight)
        .padding(.trailing, DropdownGrid.valueTrailingInset(palette))
        .frame(height: DropdownGrid.detailRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }

    // MARK: Error

    /// No tinted panel behind it. `danger` text plus a glyph is already two
    /// signals; a third (a filled rounded rectangle) is the "error card" idiom
    /// this surface spent the redesign removing.
    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
            Text(message)
                .font(palette.font(size: 11))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(palette.danger)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, palette.spacingTight)
        .padding(.bottom, palette.spacingTight)
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    /// The one and only command path into `PowerControlService` for arming a
    /// hold — the header switch, and Apply on a running session, both land
    /// here. Deliberately not forked into a second "re-assert" method: the
    /// arm-time process validation, the reason string, the conditional
    /// -versus-timed decision and the error handling are all things a
    /// re-assert needs to get exactly as right as a fresh start, and two
    /// copies of that is how they drift.
    ///
    /// - Parameter keepingDeadline: preserve the running assertion's
    ///   `expiresAt` instead of recomputing the duration from the trigger.
    ///   Set only by the `KeepAwakeChange.modeOnly` path — see the type doc
    ///   comment for why a mode switch must not silently restart the clock.
    ///   Irrelevant to conditional triggers, which have no `expiresAt` to
    ///   preserve and take no duration at all.
    private func start(keepingDeadline: Bool = false) {
        let wasActive = isActive
        let preservedDeadline = keepingDeadline ? activeState?.expiresAt : nil

        // Arm-time validation for the process trigger: a hold on a process
        // that isn't running would release itself two ticks later, which
        // reads as "the switch is broken". Saying why beats a silent bounce.
        // Still enforced even though the picker only offers running processes
        // — the list is a snapshot, and the chosen process can exit between
        // the menu opening and the switch being flipped.
        if case .processRunning = trigger {
            let name = processName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                startError = String(localized: "Choose a process first.")
                return
            }
            processName = name
            guard PowerControlService.isProcessRunning(named: name) else {
                startError = String(localized: "No process named “\(name)” is running right now.")
                return
            }
        }
        let reason = trigger.assertionReason(
            batteryThreshold: batteryThreshold,
            cpuThreshold: cpuThreshold,
            processName: processName,
            schedule: schedule,
            untilTime: untilTime
        )
        do {
            if let condition = trigger.releaseCondition(
                batteryThreshold: batteryThreshold,
                cpuThreshold: cpuThreshold,
                cpuSustainedFor: Self.cpuSustainedWindow,
                processName: processName,
                downloadIdleTimeout: Self.downloadIdleTimeout,
                schedule: schedule
            ) {
                try powerControl.startConditionalAssertion(mode: mode, condition: condition, reason: reason)
            } else {
                let duration: TimeInterval?
                if let preservedDeadline {
                    let remaining = preservedDeadline.timeIntervalSinceNow
                    // A mode switch inside the last instant of a hold: the
                    // expiry timer is already about to fire, and handing
                    // `startAssertionInternal` a non-positive duration is a
                    // documented no-op that would release without replacing
                    // — i.e. the click would *end* the session instead of
                    // re-pointing it. Leave the expiry to do its job.
                    guard remaining > 0 else { return }
                    duration = remaining
                } else {
                    // `resolvedDuration`, not `duration`: `.untilTime` needs `now`
                    // (read fresh right here at start-time, not when the trigger
                    // was picked) to turn a clock time into a countdown — see
                    // that method's doc comment.
                    duration = trigger.resolvedDuration(untilTime: untilTime)
                }
                try powerControl.startAssertion(mode: mode, duration: duration, reason: reason)
            }
            startError = nil
            applied = currentSelection
            // The options were a means to starting this session; leaving them
            // open would push the countdown the user now cares about down the
            // popover behind controls that no longer apply. Only on the
            // inactive → active transition, though: collapsing the drawer out
            // from under someone who is mid-adjustment on a *running* session
            // would make every Apply feel like a punishment.
            if !wasActive {
                showsOptions = false
            }
        } catch {
            // `PowerControlError.assertionFailed` is a `LocalizedError`; the
            // `localizedDescription` fallback covers anything else IOKit
            // surprises us with later.
            startError = error.localizedDescription
        }
    }

    /// Commits the shown options to the running session. Routes to the same
    /// `start` above; the only decision here is whether the running deadline
    /// survives, which is exactly what `KeepAwakeChange` encodes.
    private func apply() {
        switch pendingChange {
        case .none:
            return
        case .modeOnly:
            start(keepingDeadline: true)
        case .retrigger, .unknown:
            start(keepingDeadline: false)
        }
    }

    private func stop() {
        powerControl.releaseAssertion()
        startError = nil
        applied = nil
    }

    /// Re-reads the process table and keeps the shown selection honest.
    ///
    /// Called from the events where the list is about to matter — the card
    /// appearing, the options drawer opening, and the process trigger being
    /// picked — rather than on a timer: this walks every PID on the machine,
    /// and a menu-bar popover lives for seconds at a time, so a scan per
    /// user-initiated moment is both fresh enough and far cheaper than any
    /// polling cadence would be.
    ///
    /// The re-point at the end matters more than it looks. `processName`
    /// defaults to `claude`, which on most Macs most of the time is not
    /// running — so without this, selecting "While a process runs" would show
    /// a name that `start()`'s own validation is guaranteed to reject, i.e.
    /// the picker would open already broken. Only ever re-points to a
    /// *suggested* (curated agent/build tool) name, never to an arbitrary
    /// daemon that happens to sort first: silently arming the user onto
    /// `AMPArtworkAgent` would be worse than the stale default.
    private func refreshRunningProcesses() {
        runningProcesses = runningProcessNamesProvider()
        processName = KeepAwakeProcessMenu.resolvedSelection(
            current: processName,
            contents: processMenuContents
        )
    }

    /// Keeps this card's local state consistent with a hold it may not have
    /// started. Nothing running means there is no baseline to diff against,
    /// so `applied` is dropped; a hold with no baseline is one this card
    /// didn't create (relaunch restore, or `startAgentAssertion` over MCP),
    /// and `mode` is the single axis `SleepAssertionState` preserves — so at
    /// minimum the Mode row can be made to tell the truth about it, even
    /// though the "For" row can't be (`ReleaseCondition` is private to the
    /// service). See the type doc comment.
    private func syncWithRunningHold() {
        guard let activeState else {
            applied = nil
            return
        }
        if applied == nil {
            mode = activeState.mode
        }
    }

    private func adjust(bySeconds delta: TimeInterval) {
        do {
            try powerControl.adjustAssertion(bySeconds: delta)
            startError = nil
        } catch {
            startError = error.localizedDescription
        }
    }
}

// MARK: - Shared row controls

/// A full-width row that expands something below it. Same 28pt height, same
/// hover highlight and same reserved chevron column as a vitals row, because
/// it is the same kind of thing: a line you click to see more.
struct DropdownDisclosureRow: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let isExpanded: Bool
    let accessibilityLabel: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: palette.spacingTight) {
                Text(title)
                    .font(palette.font(size: 11))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: palette.spacingTight)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(palette.textTertiary)
                    .frame(width: DropdownGrid.chevronWidth, alignment: .trailing)
            }
            .padding(.horizontal, palette.spacingTight)
            .frame(height: DropdownGrid.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                    .fill(palette.surface)
            }
        }
        .onHover { hovering in
            withAnimation(ThemePalette.motion(reduceMotion: reduceMotion)) { isHovered = hovering }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }
}

/// A compact text button for controls that sit several-to-a-row (`+15m`,
/// `End Now`). No fill and no border at rest — the hover highlight is the
/// affordance, and it's the same highlight every other clickable line in the
/// dropdown uses.
struct DropdownInlineButton: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    /// Defaults to `textPrimary`; `End Now` overrides it to `danger`.
    var hoverTint: Color? = nil
    let accessibilityLabel: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(palette.font(size: 11, weight: .medium))
                .foregroundStyle(isHovered ? (hoverTint ?? palette.textPrimary) : palette.textSecondary)
                .padding(.horizontal, palette.spacingTight)
                .frame(height: DropdownGrid.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                    .fill(palette.surface)
            }
        }
        .onHover { hovering in
            withAnimation(ThemePalette.motion(reduceMotion: reduceMotion)) { isHovered = hovering }
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Trigger options

/// The subset of plan §10.3's trigger list this card offers. Not
/// `CaseIterable`-synthesizable (two cases carry payloads), so the menu order
/// is spelled out in `allOptions` — which also lets the fixed presets appear
/// in ascending order between "Indefinite" and the conditional triggers.
///
/// Thresholds live on the *view*, not in these cases, so that flipping between
/// "battery below" and "CPU above" doesn't discard the number the user already
/// dialed in for the other one.
enum SleepTriggerOption: Hashable, Identifiable {
    case indefinite
    case fixed(TimeInterval)
    case batteryBelow
    case cpuAbove
    case processRunning
    /// Competitive-parity trigger added by the competitive review — see
    /// `ReleaseCondition.whileDownloadActive`'s doc comment.
    case downloadActive
    /// Competitive-parity trigger added by the competitive review — see
    /// `ReleaseCondition.scheduledWindow`'s doc comment.
    case scheduledWindow
    /// Other keep-awake utilities' "Other Time/Until" — the one clock-time trigger, as
    /// opposed to `.scheduledWindow`'s recurring weekly window. Unlike
    /// `.scheduledWindow`, this is a genuine `DatePicker(.hourAndMinute)`
    /// row rather than a preset menu: the type doc comment's "preset-only"
    /// rationale is about avoiding a *weekday-plus-time* control (roughly
    /// doubling this card's height), and a single compact hour/minute wheel
    /// doesn't have that cost. A curated preset list would also just be
    /// worse here — "until 5 PM" only matters if 5 PM is the number the user
    /// actually wants right now, which a fixed menu can't guess as well as
    /// picking it can.
    case untilTime

    static let allOptions: [SleepTriggerOption] = [
        .indefinite,
        .fixed(15 * 60),
        .fixed(30 * 60),
        .fixed(60 * 60),
        .fixed(2 * 60 * 60),
        .fixed(4 * 60 * 60),
        .fixed(8 * 60 * 60),
        .untilTime,
        .batteryBelow,
        .cpuAbove,
        .processRunning,
        .downloadActive,
        .scheduledWindow
    ]

    var id: String {
        switch self {
        case .indefinite: return "indefinite"
        case .fixed(let seconds): return "fixed-\(Int(seconds))"
        case .untilTime: return "until-time"
        case .batteryBelow: return "battery"
        case .cpuAbove: return "cpu"
        case .processRunning: return "process"
        case .downloadActive: return "download"
        case .scheduledWindow: return "schedule"
        }
    }

    /// `nil` for everything that isn't a fixed window — both "indefinite" and
    /// the conditional triggers are open-ended as far as `PowerControlService`
    /// is concerned. `.untilTime` needs `now` and the picked clock time to
    /// compute a duration, so it's handled by `resolvedDuration(untilTime:)`
    /// below rather than here — this property stays a pure function of the
    /// case itself, matching every other member on this type.
    var duration: TimeInterval? {
        if case .fixed(let seconds) = self { return seconds }
        return nil
    }

    /// Seconds from now until the next occurrence of `untilTime`'s
    /// hour/minute — rolling to tomorrow if that time of day has already
    /// passed today, the same "always in the future" rule a keep-awake
    /// utility's user relies on ("until 9 AM" typed at 11 PM means tomorrow morning,
    /// not a negative duration). Floored at 60s: a pick that lands inside the
    /// next minute (DST edges, or the sheet sitting open past the target
    /// second) becomes "basically now," which is confusing as a keep-awake
    /// duration — rolling it to the following day instead is the same
    /// "always meaningfully in the future" guarantee for a boundary case
    /// that's otherwise a fraction-of-a-second race.
    func resolvedDuration(untilTime: Date, now: Date = Date(), calendar: Calendar = .current) -> TimeInterval? {
        guard case .untilTime = self else { return duration }
        let components = calendar.dateComponents([.hour, .minute], from: untilTime)
        var candidate = calendar.date(
            bySettingHour: components.hour ?? 0,
            minute: components.minute ?? 0,
            second: 0,
            of: now
        ) ?? now
        if candidate.timeIntervalSince(now) < 60 {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return candidate.timeIntervalSince(now)
    }

    func releaseCondition(
        batteryThreshold: Double,
        cpuThreshold: Double,
        cpuSustainedFor: TimeInterval,
        processName: String,
        downloadIdleTimeout: TimeInterval,
        schedule: KeepAwakeSchedule
    ) -> ReleaseCondition? {
        switch self {
        case .indefinite, .fixed, .untilTime:
            return nil
        case .batteryBelow:
            return .batteryBelowPercent(batteryThreshold)
        case .cpuAbove:
            return .cpuAbovePercent(cpuThreshold, for: cpuSustainedFor)
        case .processRunning:
            return .whileProcessRunning(name: processName)
        case .downloadActive:
            return .whileDownloadActive(idleTimeout: downloadIdleTimeout)
        case .scheduledWindow:
            return .scheduledWindow(
                weekdays: schedule.weekdays,
                startMinute: schedule.startMinute,
                endMinute: schedule.endMinute
            )
        }
    }

    /// Menu-item text: self-contained, since a menu item has no adjacent
    /// threshold control to read the number off.
    var pickerLabel: String {
        switch self {
        case .indefinite: return String(localized: "Indefinitely")
        case .fixed(let seconds): return SleepCountdownFormatting.presetLabel(seconds)
        case .untilTime: return String(localized: "Until a time")
        case .batteryBelow: return String(localized: "Until battery is low")
        case .cpuAbove: return String(localized: "While CPU is busy")
        case .processRunning: return String(localized: "While a process runs")
        case .downloadActive: return String(localized: "While a download is active")
        case .scheduledWindow: return String(localized: "On a schedule")
        }
    }

    /// Collapsed label for the closed menu, where the chosen threshold has to
    /// be visible without opening anything.
    func menuLabel(batteryThreshold: Double, cpuThreshold: Double, processName: String, schedule: KeepAwakeSchedule, untilTime: Date) -> String {
        switch self {
        case .indefinite, .fixed, .downloadActive:
            return pickerLabel
        case .untilTime:
            return String(localized: "Until \(untilTime.formatted(date: .omitted, time: .shortened))")
        case .batteryBelow:
            return String(localized: "Battery < \(MetricFormatting.percent(batteryThreshold))")
        case .cpuAbove:
            return String(localized: "CPU > \(MetricFormatting.percent(cpuThreshold))")
        case .processRunning:
            // The fallback noun is localized separately so a translator sees
            // both the sentence and the placeholder word, instead of an
            // English "process" being glued into a translated sentence.
            let name = processName.isEmpty ? String(localized: "process") : processName
            return String(localized: "While \(name) runs")
        case .scheduledWindow:
            // `schedule.label` already reads as a summary ("Weeknights, 10
            // PM–7 AM"), so there's nothing to compose here beyond it — same
            // shape as `.downloadActive` falling back to `pickerLabel`.
            return schedule.label
        }
    }

    /// The `reason` string handed to IOKit — visible in `pmset -g assertions`
    /// and, more importantly, the only description of a conditional trigger
    /// that survives into `SleepAssertionState` for the active card to show.
    /// Prefixed with the app name because that's what shows up in system power
    /// diagnostics next to every other process's assertions.
    ///
    /// Deliberately NOT localized (l10n audit): this string is dual-purpose —
    /// it is both the UI caption on the active card *and* the reason handed to
    /// IOKit, where it lands in `pmset -g assertions` output, power logs, and
    /// bug reports. Keeping it English keeps those diagnostics greppable and
    /// comparable across machines regardless of the user's locale, which is
    /// the same trade Apple's own daemons make. If the card ever needs a
    /// localized caption, derive it separately at display time rather than
    /// localizing what gets persisted into the assertion.
    func assertionReason(batteryThreshold: Double, cpuThreshold: Double, processName: String, schedule: KeepAwakeSchedule, untilTime: Date) -> String {
        switch self {
        case .indefinite:
            return "Sentry — keep awake until turned off"
        case .fixed(let seconds):
            return "Sentry — keep awake for \(SleepCountdownFormatting.presetLabel(seconds))"
        case .untilTime:
            return "Sentry — keep awake until \(untilTime.formatted(date: .omitted, time: .shortened))"
        case .batteryBelow:
            return "Sentry — keep awake until battery drops below \(MetricFormatting.percent(batteryThreshold))"
        case .cpuAbove:
            return "Sentry — keep awake while CPU stays above \(MetricFormatting.percent(cpuThreshold))"
        case .processRunning:
            return "Sentry — keep awake while \(processName) is running"
        case .downloadActive:
            return "Sentry — keep awake while a download is active"
        case .scheduledWindow:
            return "Sentry — keep awake on schedule (\(schedule.label))"
        }
    }
}

/// A named `.scheduledWindow` preset — see `SleepControlCard`'s type doc
/// comment ("Why the scheduled trigger is preset-only") for why this card
/// offers a fixed menu of these rather than a free-form weekday/time picker.
/// `weekdays` uses `Calendar.Component.weekday`'s 1...7 (Sunday = 1)
/// convention, matching `ReleaseCondition.scheduledWindow` exactly so these
/// values pass straight through with no translation step.
struct KeepAwakeSchedule: Hashable, Identifiable {
    var id: String { label }
    let label: String
    let weekdays: Set<Int>
    let startMinute: Int
    let endMinute: Int

    /// Every night, 22:00–07:00 — crosses midnight (`ReleaseCondition
    /// .scheduledWindow`'s `startMinute > endMinute` case).
    static let everyNight = KeepAwakeSchedule(
        label: String(localized: "Every night, 10 PM–7 AM"),
        weekdays: Set(1...7),
        startMinute: 22 * 60,
        endMinute: 7 * 60
    )

    /// Sunday through Thursday nights, 22:00–07:00 — the "school night"
    /// schedule. Encoded as weekdays 1...5 (Sun–Thu) because a midnight-
    /// crossing window belongs to the day it *starts* on (see
    /// `PowerControlService.isWithinScheduledWindow`'s doc comment): a
    /// Thursday-night window's early-morning tail lands on Friday morning,
    /// which is exactly the boundary that should stop a "weeknight" schedule
    /// before Saturday.
    static let weeknights = KeepAwakeSchedule(
        label: String(localized: "Weeknights, 10 PM–7 AM"),
        weekdays: [1, 2, 3, 4, 5],
        startMinute: 22 * 60,
        endMinute: 7 * 60
    )

    /// Weekdays, 09:00–17:00 — same-day window, no midnight crossing.
    static let workHours = KeepAwakeSchedule(
        label: String(localized: "Weekdays, 9 AM–5 PM"),
        weekdays: [2, 3, 4, 5, 6],
        startMinute: 9 * 60,
        endMinute: 17 * 60
    )

    /// Saturday and Sunday, all day. `endMinute: 1440` is the documented
    /// "through the end of the day" value (`ReleaseCondition
    /// .scheduledWindow`'s doc comment) — there's no natural minute-1439
    /// boundary to name for an all-day window.
    static let weekend = KeepAwakeSchedule(
        label: String(localized: "Weekends, all day"),
        weekdays: [1, 7],
        startMinute: 0,
        endMinute: 1440
    )

    static let presets: [KeepAwakeSchedule] = [.everyNight, .weeknights, .workHours, .weekend]
}

// MARK: - Process picker contents

/// Shapes the `.processRunning` trigger's picker from a raw list of running
/// executable names. Pure and free of SwiftUI so the whole rule — what gets
/// suggested, how the long tail is grouped, when the fallback kicks in — is
/// unit-testable against a fabricated process table, exactly the split
/// `DropdownProcessList.topThree(_:)` makes for the same reason.
///
/// **The problem this solves.** "Offer the processes actually running" sounds
/// like a one-liner until you count them: a measurement on a developer Mac
/// mid-session found **931 distinct executable names** across 1,715
/// processes, the overwhelming majority of them XPC services and system
/// daemons nobody would ever hold a Mac awake for. Three simpler shapes were
/// tried against that number and rejected:
///
/// - *One flat alphabetical menu.* Nine hundred items in a popover menu is
///   not a picker, it's a scroll-hunt, and it buries the five names this
///   trigger actually exists for somewhere around the letter C.
/// - *Cap the list.* Any cap silently drops somebody's process, which is the
///   exact "the control is dead for me specifically" failure this whole
///   change set out to remove — trading a typo you can't see for an omission
///   you can't see is not progress.
/// - *Filter to the current user's processes.* Sounds principled, measured
///   useless: 931 names became 721, because modern macOS runs most of its
///   per-user agent and XPC zoo as the logged-in user too.
///
/// So the list is *ranked*, not filtered, and nothing is dropped. The names
/// this trigger was built for surface at the top level; everything else is
/// still reachable, one submenu plus one letter submenu away. Letter
/// grouping rather than a cap because it's bounded work for the user
/// (~26 groups) with an unbounded list behind it, and because it's the
/// idiom macOS already uses for long menus.
///
/// **Where "suggested" comes from.** `ProcessMonitor.agentProcessNames` — the
/// curated agent/build-tool set this codebase already maintains for the
/// Dashboard's agent-activity view — unioned with this card's own preset
/// list. Reused rather than re-declared: a second hand-maintained list of
/// "what counts as an agent workload" would drift from the first, and the two
/// answer the same question.
enum KeepAwakeProcessMenu {

    /// The names the Process field shipped as a preset menu before it became
    /// a picker. Still meaningful in exactly one place — the fallback below —
    /// and folded into `suggestedNames` so they rank to the top when running.
    static let presets: [String] = ["claude", "codex", "xcodebuild", "node", "python3"]

    /// Lowercased, matching `ProcessMonitor.agentProcessNames`' own convention
    /// and `PowerControlService.isProcessRunning(named:)`'s case-insensitive
    /// comparison.
    static let suggestedNames: Set<String> = ProcessMonitor.agentProcessNames
        .union(presets.map { $0.lowercased() })

    /// Bucket title for names that don't start with a letter (`-zsh`,
    /// `(node)`), sorted after the letters rather than before them: the
    /// alphabet is what a user scans for.
    static let otherBucketTitle = "#"

    struct LetterGroup: Equatable, Identifiable {
        var id: String { title }
        let title: String
        let names: [String]
    }

    struct Contents: Equatable {
        /// Curated agent/build tools that are currently running — or, when
        /// `isFallback`, the preset list standing in for a scan that came
        /// back empty.
        var suggested: [String]
        /// Everything else that's running, bucketed by initial letter.
        var groups: [LetterGroup]
        /// The process table couldn't be read (or is implausibly empty), so
        /// `suggested` is the preset list rather than an observation. Drives
        /// both the menu's section header and `resolvedSelection`'s refusal
        /// to overrule the user on no evidence.
        var isFallback: Bool

        /// "Suggested" is a claim about what's running; the fallback isn't
        /// entitled to make it.
        var suggestedHeader: String {
            isFallback ? String(localized: "Common tools") : String(localized: "Suggested")
        }

        /// Case-insensitive, matching how the name will eventually be
        /// compared by `isProcessRunning(named:)`.
        func offers(_ name: String) -> Bool {
            let wanted = name.lowercased()
            guard !wanted.isEmpty else { return false }
            if suggested.contains(where: { $0.lowercased() == wanted }) { return true }
            return groups.contains { $0.names.contains { $0.lowercased() == wanted } }
        }
    }

    /// - Parameter running: distinct executable names from
    ///   `PowerControlService.runningProcessNames()`. An empty array means
    ///   "couldn't enumerate", which yields the preset fallback — a picker
    ///   with no items would be a dead control, and a dead control on the
    ///   only row that can arm this trigger is worse than a stale list.
    static func contents(running: [String]) -> Contents {
        var seen = Set<String>()
        var deduped: [String] = []
        for name in running {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            deduped.append(trimmed)
        }
        // De-duplicated here as well as in `runningProcessNames()` because
        // this function's contract is about its own input, not about who
        // happened to produce it — the same "state the contract locally"
        // reasoning `DropdownProcessList.topThree(_:)` documents for
        // re-sorting an already-sorted array.
        guard !deduped.isEmpty else {
            return Contents(suggested: presets, groups: [], isFallback: true)
        }

        let sorted = deduped.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let suggested = sorted.filter { suggestedNames.contains($0.lowercased()) }
        let rest = sorted.filter { !suggestedNames.contains($0.lowercased()) }
        return Contents(suggested: suggested, groups: letterGroups(rest), isFallback: false)
    }

    /// The selection to show given what the picker can actually offer.
    ///
    /// Re-points a selection the menu doesn't contain onto the first
    /// suggested name, because such a selection cannot arm — `start()`
    /// validates against the same process table this list came from — so
    /// leaving it in place would be showing the user a value whose only
    /// possible outcome is an error. Two deliberate refusals to re-point:
    /// on a fallback (no evidence the current value is wrong, so overruling
    /// it would be guessing), and when nothing suggested is running (the
    /// alternative would be snapping the user onto whichever daemon sorts
    /// first, which is a worse lie than a stale name).
    static func resolvedSelection(current: String, contents: Contents) -> String {
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        guard !contents.isFallback else {
            return trimmed.isEmpty ? (contents.suggested.first ?? trimmed) : trimmed
        }
        if contents.offers(trimmed) { return trimmed }
        return contents.suggested.first ?? trimmed
    }

    static func bucketTitle(for name: String) -> String {
        guard let first = name.first, first.isLetter else { return otherBucketTitle }
        return String(first).uppercased()
    }

    private static func letterGroups(_ names: [String]) -> [LetterGroup] {
        var buckets: [String: [String]] = [:]
        // `names` arrives sorted, so each bucket is built in order and needs
        // no second sort of its own.
        for name in names {
            buckets[bucketTitle(for: name), default: []].append(name)
        }
        return buckets
            .map { LetterGroup(title: $0.key, names: $0.value) }
            .sorted { lhs, rhs in
                let lhsIsOther = lhs.title == otherBucketTitle
                let rhsIsOther = rhs.title == otherBucketTitle
                if lhsIsOther != rhsIsOther { return rhsIsOther }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }
}

// MARK: - Editing a running session

/// Everything the card hands to `PowerControlService` when it arms a hold,
/// captured so a later state of the same pickers can be compared against it.
/// A plain value type rather than a pile of individual `@State` mirrors: the
/// comparison below is the only reason it exists, and it should be impossible
/// to add a picker without also deciding whether it belongs in the diff.
struct KeepAwakeSelection: Equatable {
    var trigger: SleepTriggerOption
    var mode: AwakeMode
    var batteryThreshold: Double
    var cpuThreshold: Double
    var processName: String
    var schedule: KeepAwakeSchedule
    var untilTime: Date

    /// The parts of this selection that actually reach the service *for the
    /// currently chosen trigger*, collapsed into one comparable string.
    ///
    /// This is why the diff isn't a plain `==` on the whole struct. Thresholds
    /// live on the view rather than in `SleepTriggerOption`'s cases
    /// specifically so switching between "battery below" and "CPU above"
    /// doesn't discard the number dialed in for the other one (see that
    /// type's doc comment) — which means an inactive-but-remembered value
    /// changes constantly while meaning nothing. A whole-struct comparison
    /// would report "you changed the trigger" because the user nudged a CPU
    /// floor that the running battery-threshold hold has never read, and
    /// then restart their countdown for it.
    ///
    /// `.untilTime` compares hour and minute only, matching exactly what
    /// `SleepTriggerOption.resolvedDuration(untilTime:)` reads — the
    /// `DatePicker` leaves a day/month/year on the `Date` that no code path
    /// looks at, and rolling past midnight with the drawer open should not
    /// count as an edit the user made.
    func triggerKey(calendar: Calendar = .current) -> String {
        switch trigger {
        case .indefinite, .fixed, .downloadActive:
            return trigger.id
        case .untilTime:
            let components = calendar.dateComponents([.hour, .minute], from: untilTime)
            return "\(trigger.id):\(components.hour ?? 0):\(components.minute ?? 0)"
        case .batteryBelow:
            return "\(trigger.id):\(batteryThreshold)"
        case .cpuAbove:
            return "\(trigger.id):\(cpuThreshold)"
        case .processRunning:
            // Lowercased for the same reason `isProcessRunning(named:)`
            // lowercases: `Node` and `node` are the same hold, and re-arming
            // for a change of case would be a teardown for nothing.
            return "\(trigger.id):\(processName.lowercased())"
        case .scheduledWindow:
            return "\(trigger.id):\(schedule.id)"
        }
    }
}

/// What pressing Apply would do to the running hold — and, just as
/// importantly, what the card is allowed to *say* it would do. See
/// `SleepControlCard`'s type doc comment for the reasoning behind the
/// mode-only/retrigger split and for why `unknown` is a real case rather
/// than a defensive default.
enum KeepAwakeChange: Equatable {
    /// The shown options are the ones this card armed. Nothing to do.
    case none
    /// Only `mode` differs: re-assert with the new mode, keep the deadline.
    case modeOnly
    /// The end condition itself differs: re-arm from scratch, clock and all.
    case retrigger
    /// This card didn't arm what's running, so no comparison is possible.
    case unknown

    static func between(
        applied: KeepAwakeSelection?,
        current: KeepAwakeSelection,
        calendar: Calendar = .current
    ) -> KeepAwakeChange {
        guard let applied else { return .unknown }
        guard applied.triggerKey(calendar: calendar) == current.triggerKey(calendar: calendar) else {
            return .retrigger
        }
        return applied.mode == current.mode ? .none : .modeOnly
    }

    var isApplicable: Bool { self != .none }

    /// One sentence, shown under the Apply button, naming the consequence
    /// the user cannot otherwise predict: whether the countdown survives.
    var caption: String {
        switch self {
        case .none:
            return String(localized: "No changes to apply.")
        case .modeOnly:
            return String(localized: "Apply switches the mode and keeps the current end time.")
        case .retrigger:
            return String(localized: "Apply restarts this session with these settings, including its countdown.")
        case .unknown:
            return String(localized: "This session was started elsewhere. Apply replaces it with these settings.")
        }
    }
}

// MARK: - Formatting

/// Duration text specific to the sleep card. Separate from `MetricFormatting`
/// because these aren't metric values: a countdown is a clock readout (fixed
/// `mm:ss` field width so the digits don't jitter once a second under
/// `monospacedDigit`), whereas `MetricFormatter.uptime` deliberately drops the
/// seconds field entirely and would render every countdown under a minute as
/// a motionless "0m".
enum SleepCountdownFormatting {

    /// `1:04:09` / `4:09` / `0:09`. Clamped at zero: the assertion's release
    /// is driven by a `Timer` and an OS-level timeout, either of which can
    /// land a fraction of a second after the deadline, and a card flashing
    /// "-0:01" on the way out would be a bug the user sees.
    static func countdown(_ remaining: TimeInterval) -> String {
        guard remaining.isFinite else { return MetricFormatting.placeholder }
        // Rounding up means a fresh "15 min" assertion reads 15:00, not
        // 14:59, for the tick before the first second elapses.
        let total = Int(min(max(remaining.rounded(.up), 0), Double(Int32.max)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// `15 min` / `1 h` / `2 h 30 min`, for naming a preset that hasn't
    /// started yet (no seconds — a preset is a round number by construction).
    static func presetLabel(_ duration: TimeInterval) -> String {
        let total = Int(max(duration, 0).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        switch (hours, minutes) {
        case (0, let m): return "\(m) min"
        case (let h, 0): return "\(h) h"
        case (let h, let m): return "\(h) h \(m) min"
        }
    }
}

// MARK: - AwakeMode labels

/// UI vocabulary for `AwakeMode`. Kept in the app target rather than on the
/// model in SentryKit: the kit is shared with the iOS app and the MCP tool,
/// neither of which should inherit this card's phrasing.
///
/// **This wording is a bug fix, and the bug was structural.** The three cases
/// used to read "Keep display on" / "System only (display may sleep)" /
/// "Only while plugged in", and users could not tell them apart — for a
/// reason that is not a matter of taste. `AwakeMode` varies along *two*
/// independent axes:
///
/// | case | what stays awake | when the rule applies |
/// |---|---|---|
/// | `.displayAndSystem` | screen and system | battery or power |
/// | `.systemOnly` | system; screen may sleep | battery or power |
/// | `.systemWhileOnAC` | system; screen may sleep | power only |
///
/// The old labels named the first axis for two cases and the second axis for
/// the third, so nothing in the list told you that "Only while plugged in"
/// *also* lets your screen go dark — the one case that differs on both axes
/// was described by neither of them fully. Every label below now states both
/// axes, and `AwakeModePowerScope` splits the menu on the second so the list
/// stops mixing them. `explanation` additionally names the workload each mode
/// suits, since "which one do I want" is really a question about what the
/// user is doing.
///
/// Deliberately labels only: `AwakeMode`'s cases and their IOKit mapping
/// (`SentryKit/Models/AwakeMode.swift`, `PowerControlService`'s
/// `assertionType`) are untouched. The modes were never wrong — only the
/// words for them were.
extension AwakeMode {
    /// Collapsed-picker and active-session text. Must survive on one short
    /// line next to a label, so it leads with the screen — the axis the user
    /// can *see* being wrong — and qualifies the power condition only where
    /// it differs from "always".
    var shortLabel: String {
        switch self {
        case .displayAndSystem: return String(localized: "Screen stays on")
        case .systemOnly: return String(localized: "Screen may sleep")
        case .systemWhileOnAC: return String(localized: "Screen may sleep, power only")
        }
    }

    /// Menu-item text. Self-contained on purpose even though
    /// `AwakeModePowerScope`'s section header already states the power
    /// condition: the existing test that every mode's user-facing text is
    /// distinct is worth keeping true, and an item that only makes sense
    /// under its header is an item that silently breaks if the sections are
    /// ever flattened. The redundancy costs three words in one item.
    var longLabel: String {
        switch self {
        case .displayAndSystem: return String(localized: "Screen and Mac both stay awake")
        case .systemOnly: return String(localized: "Mac stays awake, screen may sleep")
        case .systemWhileOnAC: return String(localized: "Mac stays awake on power only, screen may sleep")
        }
    }

    var explanation: String {
        switch self {
        case .displayAndSystem:
            return String(localized: "The screen stays on and the Mac never idle-sleeps, on battery or power. Best for presenting or watching.")
        case .systemOnly:
            return String(localized: "The Mac never idle-sleeps, but the screen can turn off. On battery or power. Best for builds and downloads.")
        case .systemWhileOnAC:
            return String(localized: "Same as “screen may sleep”, but only while plugged in — on battery the Mac sleeps normally. Best for overnight jobs.")
        }
    }

    /// Which `AwakeModePowerScope` section this mode belongs to. The one
    /// place the two-axis split is encoded; `AwakeModePowerScope.modes`
    /// derives from it so the grouping can't disagree with itself.
    var powerScope: AwakeModePowerScope {
        switch self {
        case .displayAndSystem, .systemOnly: return .anyPower
        case .systemWhileOnAC: return .onPowerOnly
        }
    }
}

/// The "when does this rule apply" axis of `AwakeMode`, used as the mode
/// menu's section headers — see `SleepControlCard.modeRow` for why the menu
/// is split at all, and the `AwakeMode` extension above for the two-axis
/// table this is one column of.
enum AwakeModePowerScope: String, CaseIterable, Identifiable {
    case anyPower
    case onPowerOnly

    var id: String { rawValue }

    var menuHeader: String {
        switch self {
        case .anyPower: return String(localized: "On battery or power")
        case .onPowerOnly: return String(localized: "Only on power")
        }
    }

    /// Derived from `AwakeMode.powerScope` rather than listed by hand, so a
    /// fourth mode cannot be added to the enum and silently fail to appear in
    /// the menu. `allCases` order is the declaration order of `AwakeMode`,
    /// which is the order this card has always shown them in.
    var modes: [AwakeMode] {
        AwakeMode.allCases.filter { $0.powerScope == self }
    }
}

// MARK: - Preview

#Preview {
    SleepControlCard(powerControl: PowerControlService(defaults: UserDefaults(suiteName: "preview.sleepcard")!))
        .padding()
        .frame(width: 320)
        .environment(\.themePalette, ThemePalette(theme: .defaultTheme, scheme: .dark))
        .background(ThemePalette(theme: .defaultTheme, scheme: .dark).background)
}
