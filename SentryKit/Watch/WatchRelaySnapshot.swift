import Foundation

// MARK: - WatchRelaySnapshot: the sliver of a SystemSnapshot relayed to the Watch

/// The minimal payload `SentryMobile` relays to a paired Apple Watch over
/// `WCSession`, and what `SentryWatch`'s complication ultimately renders.
///
/// **Why this exists separately from `WidgetSnapshot`.** `WidgetSnapshot`
/// (`SentryKit/Sync/WidgetSnapshot.swift`) crosses an App-Group boundary
/// *within one device* (the iPhone app process and the iPhone widget
/// extension process both read the same container on the same phone). The
/// Watch is a different physical device with no access to the iPhone's App
/// Group at all — the Mac cannot reach the Watch directly either (no
/// Bonjour/Network.framework path from watchOS in this app), so the only
/// channel across that boundary is `WCSession`
/// (`updateApplicationContext`/`transferCurrentComplicationUserInfo`), whose
/// payloads must be small, plist-safe dictionaries and which carry their
/// own, much stricter size/budget constraints than an App Group write. This
/// type is deliberately narrower than `WidgetSnapshot` — no battery-history
/// sparkline, no memory fraction — a complication has no room to render
/// either, and shipping them would spend part of a scarce budget on values
/// nothing on the Watch displays.
///
/// **Why it lives in `SentryKit`, not `SentryMobile` or `SentryWatch`.**
/// Both the phone (sender) and the watch app + its widget extension
/// (receivers) need the exact same `Codable` shape. Same reasoning as
/// `WidgetSnapshot`'s doc comment on why that type lives here rather than in
/// either endpoint's target — except this one also has to compile against
/// `SentryKit_watchOS`, which is why this file (plus `Freshness.swift`/
/// `FreshnessBadge.swift`, both already platform-agnostic) is deliberately
/// kept free of any macOS/iOS-only import so it can be shared by all three
/// platform variants of `SentryKit` without `#if os(...)` splitting.
///
/// **Why the second wave of fields (CPU, memory, disk, battery runway,
/// throttling) are all Optional, and why this type hand-writes
/// `init(from:)`.** The phone app and the watch app are separately
/// installed bundles that a user updates independently — watchOS will
/// happily leave an old `SentryWatch` on the wrist for days after the
/// iPhone app updates, and the reverse happens too when a watch app is
/// installed from a TestFlight build the phone hasn't caught up with.
/// `WatchRelaySnapshot` is therefore a wire format between two versions of
/// this codebase, not an internal struct, and both directions must survive:
///
/// - **Old phone → new watch.** The relay contains only the v1 keys. Every
///   field added after v1 is Optional and read with `decodeIfPresent`, so
///   it decodes cleanly with the new fields `nil`. That `nil` is then
///   rendered as absent/"—", never as `0` — see `ContentView`'s tiles.
///   "This Mac didn't report it" and "zero" are different claims, and plan
///   §3.2 P5 (the same rule that makes every `SystemSnapshot` sub-struct
///   Optional) says the UI must not conflate them.
/// - **New phone → old watch.** `JSONDecoder` ignores keys it has no
///   property for, so an older `SentryWatch` decodes the v1 subset and
///   renders exactly what it always did. This is the reason new
///   information is only ever *added* as new keys — renaming or retyping an
///   existing key would break this direction silently, and the failure
///   would surface as a complication that simply stopped updating.
///
/// The hand-written decoder exists for one case synthesis gets wrong:
/// `ThermalPressureSummary` and `MemoryPressureSummary` are `String`-raw
/// enums, and `Codable`'s synthesized decoding *throws* on a raw value it
/// doesn't recognise. A future phone that adds a fifth thermal tier would
/// therefore make an older watch fail to decode the **entire** payload —
/// losing battery, freshness and the demo-data disclosure over one
/// unfamiliar word. Both enums are instead decoded as `String` and mapped
/// through their initialiser with an `.unknown` fallback, so an
/// unrecognised tier costs exactly the one field it describes.
public struct WatchRelaySnapshot: Codable, Sendable, Equatable {
    /// Human-readable label for the Mac this reading came from — e.g.
    /// `Device.deviceName`, same convention as `WidgetSnapshot.deviceName`.
    public var deviceName: String

    /// When the *underlying reading* was taken on the Mac —
    /// `SystemSnapshot.timestamp`'s equivalent for this projection. This is
    /// what `Freshness(lastSeen:)` should be computed against on the Watch,
    /// not `relayedAt` below — a relay sent seconds ago from a reading that
    /// is itself an hour stale must still render as stale, matching
    /// `WidgetSnapshot.lastSeen`'s exact reasoning.
    public var lastSeen: Date

    /// When the phone actually called into `WCSession` with this value.
    /// Kept separate from `lastSeen` for the same diagnostic reason
    /// `WidgetSnapshot.writtenAt` is — "the phone hasn't relayed in N hours"
    /// (a phone-side or connectivity problem) is a different failure mode
    /// than "the Mac hasn't reported in N hours" (a Mac-side one).
    public var relayedAt: Date

    /// Whether this value was fabricated by `MockDataSource` rather than
    /// synced from a real Mac — travels with the data for the exact reason
    /// `WidgetSnapshot.sourceIsDemoData` does (see that type's doc comment):
    /// a complication pinned to a watch face has no companion banner to
    /// disclose this any other way.
    public var sourceIsDemoData: Bool

    public var batteryPercent: Double
    public var isCharging: Bool
    public var isPluggedIn: Bool

    public var thermalPressure: ThermalPressureSummary

    // MARK: Added after v1 — all Optional, see this type's doc comment

    /// Whether the Mac reported a battery at all.
    ///
    /// **This field exists to close an honesty hole in v1.** `batteryPercent`
    /// is non-Optional, and `WatchRelayManager` has always filled it with
    /// `snapshot.battery?.chargePercent ?? 0` — so a Mac mini, Mac Studio or
    /// Mac Pro, none of which have a battery, has been relaying a confident
    /// `0%` to the wrist. That is the fake zero this codebase forbids
    /// everywhere else, sitting in the largest number on the screen.
    ///
    /// It is a new `Bool?` rather than a retyping of `batteryPercent` to
    /// `Double?` for the compatibility reason in this type's doc comment:
    /// making a v1 key Optional (or absent) is the one change that breaks
    /// new-phone → old-watch, and it would break it *silently*, as a
    /// complication that quietly stops refreshing.
    ///
    /// The three states are all distinct and all rendered differently:
    /// - `true` — the Mac has a battery; `batteryPercent` is real.
    /// - `false` — the Mac has no battery (or IOKit refused the read);
    ///   `ContentView` shows "—" where the percentage would be and promotes
    ///   CPU to the hero position, because a desktop's headline fact is what
    ///   it is doing, not a charge level it does not have.
    /// - `nil` — the payload came from a phone predating this field, which
    ///   says nothing either way. `batteryPercent` is shown as before. That
    ///   preserves the v1 wart for v1 senders rather than inventing a
    ///   guess; the watch cannot retroactively know whether an old phone's
    ///   `0` meant "empty" or "no battery," and pretending otherwise would
    ///   trade one wrong claim for another.
    public var batteryIsReported: Bool?

    /// `CPUStats.totalPercent`, 0...100. The single most useful thing to
    /// add: "is my Mac busy" is the question a glance at a *remote* machine
    /// is actually asking most of the time — a render finished, an export
    /// stalled, something ran away while the lid was shut. Unlike the rate
    /// metrics deliberately left out below, an aggregate CPU percentage
    /// stays roughly meaningful across the tens of seconds to minutes of
    /// relay latency: a Mac pinned at 95% is still pinned a minute later,
    /// and the `Freshness` label shown alongside it already tells the user
    /// how old the claim is.
    ///
    /// `nil` when `SystemSnapshot.cpu` was absent. Rendered "—".
    public var cpuPercent: Double?

    /// `memory.usedBytes / memory.totalBytes * 100`, computed on the phone
    /// so the watch never has to carry two `UInt64`s (and never has to
    /// guess at a divide-by-zero) — the same derivation
    /// `VitalsLedger.memoryUsedPercent` and `DashboardViewModel` already
    /// use, so the watch and the phone cannot disagree about what "memory
    /// used" means.
    ///
    /// **Read this together with `memoryPressure`.** On macOS a high
    /// used-percent is normal and usually harmless — the kernel will happily
    /// hold cached file pages until something else wants the RAM — so this
    /// number on its own is the most misinterpretable value in the payload.
    /// That is exactly why `memoryPressure` travels next to it rather than
    /// being dropped as redundant: pressure, not percent, is the field that
    /// says whether the number is a problem.
    public var memoryUsedPercent: Double?

    /// `MemoryStats.pressureLevel`, coarsened the same way
    /// `thermalPressure` coarsens `ThermalStats.PressureLevel`.
    ///
    /// **Why Optional here when `thermalPressure` is not.** `nil` means the
    /// Mac reported no memory-pressure reading at all (or reported no memory
    /// module); `.unknown` means it reported a tier *this build of the watch
    /// app doesn't recognise* (see the decoder). `thermalPressure` predates
    /// this distinction and folds both into `.unknown`, which is a small
    /// existing wart deliberately not "fixed" by making it Optional —
    /// retyping a v1 key is precisely the change that breaks the new-phone →
    /// old-watch direction described above.
    public var memoryPressure: MemoryPressureSummary?

    /// Percentage of the boot volume in use, 0...100 — the same
    /// `(total - free) / total` derivation as `MetricID.diskUsedPercent`.
    ///
    /// Earns its place not because it is urgent but because it is the one
    /// number here that nothing else in the user's day will surface until it
    /// is already a problem: a Mac at 3% free stops taking Time Machine
    /// snapshots and starts failing saves, and nobody notices until it
    /// does. It also costs nothing to relay — it moves slowly enough that it
    /// deliberately does *not* participate in the significant-change test
    /// (`WatchRelayPolicy`), so it rides along on the heartbeat and never
    /// causes a relay of its own.
    public var diskUsedPercent: Double?

    /// Minutes of battery runway. **Which runway depends on `isCharging`**:
    /// `BatteryStats.timeToFullMinutes` while charging, `timeToEmptyMinutes`
    /// otherwise. One field rather than two because the two are never
    /// meaningful simultaneously and `isCharging` — already in the payload
    /// since v1 — disambiguates them for free; `ContentView` phrases it as
    /// "1h 12m to full" or "3h 40m left" accordingly and never prints the
    /// bare number without that word.
    ///
    /// `nil` is common and expected, not an error: a desktop Mac has no
    /// battery, and even on a laptop macOS withholds an estimate for the
    /// first minutes after a power-state change rather than publishing a
    /// wild one. That absence is rendered by *omitting the line*, not by
    /// showing "0m" — "your Mac dies in zero minutes" is the single most
    /// alarming thing a fake zero could say here.
    public var batteryTimeRemainingMinutes: Int?

    /// `ThermalStats.isThrottling` — whether the Mac is *currently having
    /// its clocks cut*, which `thermalPressure` does not tell you.
    ///
    /// Worth a whole extra bit because it is the difference between a
    /// description and a consequence: "Thermal: Serious" is a state the user
    /// has to interpret, "Throttling" is the sentence that explains why the
    /// export they are waiting on is crawling. It is also the rarest
    /// transition in the payload, which is why it is safe to include in the
    /// significant-change test (see `WatchRelayPolicy`).
    ///
    /// Optional rather than defaulting to `false`: a payload from a phone
    /// that predates this field must not assert "not throttling" about a Mac
    /// that never said so.
    public var isThrottling: Bool?

    // MARK: Keep Awake — the watch app's second page

    /// Whether a sleep-prevention assertion is currently held on the Mac —
    /// `SystemSnapshot.sleepAssertion` flattened to a tri-state.
    ///
    /// `true` = `.active`, `false` = `.inactive`, **`nil` = the Mac reported
    /// no `sleepAssertion` at all, or the phone predates this field**. The
    /// third state is not a formality: the Keep Awake page renders a control
    /// that claims to describe the Mac's current state, and there is a real
    /// difference between "your Mac will sleep normally" and "we don't know
    /// whether your Mac will sleep." `ContentView` refuses to draw the
    /// control in the `nil` case rather than defaulting it to off — an
    /// inert-looking toggle that silently misreports a live assertion is
    /// exactly the "control that silently misleads" this codebase forbids.
    public var awakeIsActive: Bool?

    /// When the active assertion expires, as an **absolute instant**, not a
    /// remaining duration.
    ///
    /// That choice is what makes this field survive the relay budget. A
    /// relayed "47 minutes remaining" is wrong by however long the payload
    /// sat in flight — up to the full `WatchRelayPolicy.minimumRelayInterval`
    /// — and would tick down from a lie. An absolute deadline stays exactly
    /// correct no matter how stale the relay is: the watch subtracts its own
    /// `Date()` and gets the right answer. It is the one value in this
    /// payload that is genuinely live rather than a claim about the past,
    /// which is also why it is deliberately *not* in
    /// `WatchRelayPolicy.isSignificantChange` — nothing needs re-relaying for
    /// the countdown to stay honest.
    ///
    /// `nil` while `awakeIsActive == true` means an assertion with no
    /// expiry — held until something releases it — which the page words as
    /// "until released", never as "0m left".
    public var awakeExpiresAt: Date?

    /// A display label for the active assertion's `AwakeMode` — "Display &
    /// system", "System only", "System while on power".
    ///
    /// Sent as a pre-rendered `String` rather than the `AwakeMode` enum for
    /// two reasons. It keeps `SentryKit_watchOS`'s source list from having
    /// to grow `AwakeMode.swift` just to name three cases (that target
    /// deliberately compiles a hand-picked handful of files — see
    /// `project.yml`), and it means a mode added on the Mac later shows up on
    /// the wrist as its real name instead of as a case an old watch build
    /// would have to decode into `.unknown` and refuse to say out loud.
    /// The cost is that this string is not localisable on the watch side; it
    /// is generated on the phone, which is where the user's locale actually
    /// is, so that is where it should have been generated anyway.
    public var awakeModeLabel: String?

    // MARK: Agent activity — the watch app's third page

    /// How many MCP tool calls an AI agent has made against this Mac
    /// recently, the most recent activity timestamp, and the tool names.
    ///
    /// **These are wired end-to-end on the watch and always `nil` today, and
    /// that is deliberate rather than unfinished-looking.** There is no path
    /// for this data to reach the phone at all: the Mac→iPhone transport
    /// (`LocalSyncFraming.LocalSyncMessage`) carries exactly three message
    /// kinds — `snapshot`, `command`, `status` — and the snapshot it carries
    /// is `SystemSnapshot`, which has no agent-activity field. On the Mac the
    /// data exists in two places, neither of them reachable from here:
    /// `MCPActivityLog` (an in-memory, session-scoped ring buffer, explicitly
    /// documented as not persisted) and `HistoryStore.logAgentActivity`'s
    /// table, which is queried locally by `AgentActivityCard` and never
    /// synced.
    ///
    /// Closing that gap means adding a field to `SystemSnapshot`, having
    /// `StatsCoordinator.buildSnapshot()` carry it, and pushing the activity
    /// summary into the coordinator the way `sleepAssertionState` already is
    /// — a change in the Mac app, on the far side of a boundary this branch
    /// does not touch. The fields are defined here so that when that lands,
    /// the phone and watch need no wire change; until then the Agent Activity
    /// page renders its own honest "nothing reported" state, which is a true
    /// statement about what the watch knows, and is a much better outcome
    /// than a page that shows a confident `0` for a Mac that ran fifty tool
    /// calls this morning.
    public var agentToolCallCount: Int?

    /// See `agentToolCallCount`. `nil` means "no agent activity has been
    /// reported to this watch," which today is always the case.
    public var agentLastActivityAt: Date?

    /// See `agentToolCallCount`. Deliberately `[String]?` rather than
    /// `[String]` so an empty array can keep meaning "an agent has been
    /// active but named no tools we kept" rather than being indistinguishable
    /// from "we were told nothing." Whoever populates this should cap it at a
    /// handful of names — this is a `WCSession` payload, and an unbounded
    /// list of tool names is exactly the kind of growth that turns a small
    /// message into a rejected one.
    public var agentRecentToolNames: [String]?

    // MARK: Agent guardrails kill switch — the resume path this page needs

    /// Mirrors the Mac's `AppSettings.agentGuardrails.killSwitchEngaged`
    /// (`SentryKit/Services/AgentGuardrails.swift`,
    /// `SentryKit/Settings/AppSettings.swift`) — whether all AI agent access
    /// is currently paused.
    ///
    /// Follows the exact three-state convention `batteryIsReported`'s doc
    /// comment establishes, because the same ambiguity applies here with
    /// more weight (this field gates a *button*, not a display value):
    /// - `true` — agent access is paused right now. `AgentActivityPage`
    ///   shows a "Resume Agents" control (`WatchResumeAgentsIntent`,
    ///   `SentryWatch/Intents/SentryWatchIntents.swift`).
    /// - `false` — agent access is active. No resume control; the existing
    ///   "Stop Agents on Mac" button is what applies.
    /// - `nil` — either a phone predating this field, or (today, always) a
    ///   Mac that predates the field reaching `SystemSnapshot` at all — see
    ///   `SystemSnapshot.agentAccessPaused`'s doc comment for the one-line
    ///   hook still needed at the composition root before a live value ever
    ///   flows through this. `nil` must never be read as "not paused": a
    ///   resume button that silently failed to appear because the read
    ///   side defaulted an unknown state to `false` would be exactly the
    ///   kind of silently-misleading control this codebase forbids (see
    ///   `awakeIsActive`'s doc comment for the same argument applied to
    ///   sleep state).
    ///
    /// This is what closes the gap `WatchStopAgentsIntent`'s doc comment
    /// used to describe as permanent — "resuming belongs where the paused
    /// state is visible" no longer excludes the watch once the watch can
    /// actually see the state.
    public var agentAccessPaused: Bool?

    /// New parameters are defaulted so every existing call site — previews,
    /// tests, and `WatchRelayManager`'s own construction before it was
    /// taught the new fields — keeps compiling and keeps meaning exactly
    /// what it meant: "this build did not have a value for that."
    public init(
        deviceName: String,
        lastSeen: Date,
        relayedAt: Date,
        sourceIsDemoData: Bool,
        batteryPercent: Double,
        isCharging: Bool,
        isPluggedIn: Bool,
        thermalPressure: ThermalPressureSummary,
        batteryIsReported: Bool? = nil,
        cpuPercent: Double? = nil,
        memoryUsedPercent: Double? = nil,
        memoryPressure: MemoryPressureSummary? = nil,
        diskUsedPercent: Double? = nil,
        batteryTimeRemainingMinutes: Int? = nil,
        isThrottling: Bool? = nil,
        awakeIsActive: Bool? = nil,
        awakeExpiresAt: Date? = nil,
        awakeModeLabel: String? = nil,
        agentToolCallCount: Int? = nil,
        agentLastActivityAt: Date? = nil,
        agentRecentToolNames: [String]? = nil,
        agentAccessPaused: Bool? = nil
    ) {
        self.deviceName = deviceName
        self.lastSeen = lastSeen
        self.relayedAt = relayedAt
        self.sourceIsDemoData = sourceIsDemoData
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.thermalPressure = thermalPressure
        self.batteryIsReported = batteryIsReported
        self.cpuPercent = cpuPercent
        self.memoryUsedPercent = memoryUsedPercent
        self.memoryPressure = memoryPressure
        self.diskUsedPercent = diskUsedPercent
        self.batteryTimeRemainingMinutes = batteryTimeRemainingMinutes
        self.isThrottling = isThrottling
        self.awakeIsActive = awakeIsActive
        self.awakeExpiresAt = awakeExpiresAt
        self.awakeModeLabel = awakeModeLabel
        self.agentToolCallCount = agentToolCallCount
        self.agentLastActivityAt = agentLastActivityAt
        self.agentRecentToolNames = agentRecentToolNames
        self.agentAccessPaused = agentAccessPaused
    }

    /// How urgently `SentryWatchWidget`'s complication deserves to surface
    /// itself in watchOS's Smart Stack, on WidgetKit's 0...100
    /// `TimelineEntryRelevance` scale. Lives here rather than in the widget
    /// extension itself so it is plain `Float` math — `TimelineEntryRelevance`
    /// isn't `Equatable` and the extension target has no test bundle of its
    /// own — that `SentryTests` (linked against `SentryKit_macOS`, which
    /// compiles this same file) can assert on directly.
    ///
    /// Scored from whichever *live* problem is currently worst: throttling,
    /// thermal pressure, memory pressure — the same fields `ContentView`'s
    /// vitals page already treats as "the Mac needs attention" signals, not
    /// a new judgment invented for this property. A snapshot with no problem
    /// at all scores 0 rather than some baseline "still alive" value, since
    /// a healthy Mac is exactly the case where the Smart Stack should *not*
    /// pull this complication forward over something the user asked to see.
    public var timelineRelevanceScore: Float {
        var score: Float = 0

        // Throttling is the consequence, not just the description — it
        // outranks a merely "serious" pressure reading that hasn't yet cut
        // clocks.
        if isThrottling == true {
            score = max(score, 95)
        }

        switch thermalPressure {
        case .critical: score = max(score, 100)
        case .serious: score = max(score, 65)
        case .fair: score = max(score, 25)
        case .nominal, .unknown: break
        }

        switch memoryPressure {
        case .critical: score = max(score, 80)
        case .warning: score = max(score, 35)
        case .normal, .unknown, nil: break
        }

        return score
    }
}

// MARK: - Complication battery/CPU swap

extension WatchRelaySnapshot {
    /// Whether a Watch surface should render `batteryPercent` as a real
    /// reading, or fall back to a different headline metric (CPU, per
    /// `OverviewPage.HeroReadout.subject`).
    ///
    /// Mirrors `OverviewPage.HeroReadout.showsBattery`
    /// (`SentryWatch/Pages/OverviewPage.swift`) exactly, and follows the same
    /// v1-compatibility convention `batteryIsReported`'s own doc comment
    /// spells out: `false` means a Mac that genuinely has no battery (Mac
    /// mini/Studio/Pro), and `nil` means a phone predating the field, which
    /// said nothing either way and must not be read as "no battery" — so,
    /// like `OverviewPage`, the missing case defaults to `true`, never to
    /// `false`.
    ///
    /// Added for `ComplicationView.swift`
    /// (`SentryWatchWidget/ComplicationView.swift`), which previously read
    /// `batteryPercent` directly in every complication family and so
    /// rendered a confident, unchanging "0%" on any desktop Mac — precisely
    /// the fake zero `batteryIsReported` exists to prevent. Defined here
    /// rather than duplicated once per family view, and here rather than in
    /// `SentryWatch` because `SentryWatchWidgetExtension` only compiles
    /// `SentryKit_watchOS` (see `project.yml`), not the `SentryWatch` app
    /// target's own helper types.
    public var showsBattery: Bool {
        batteryIsReported ?? true
    }
}

// MARK: - Additive-tolerant decoding

extension WatchRelaySnapshot {
    /// Hand-written for the two reasons in this type's doc comment: every
    /// post-v1 key is `decodeIfPresent`, and the two `String`-raw pressure
    /// enums are decoded via their raw value so an unrecognised tier from a
    /// newer phone degrades to `.unknown` instead of throwing the whole
    /// payload away.
    ///
    /// The v1 keys are decoded strictly (`decode`, not `decodeIfPresent`).
    /// That is deliberate: they have been in the format since the first
    /// build that ever relayed anything, nothing can produce a payload
    /// without them, and treating a payload missing `batteryPercent` as
    /// "battery unknown" would mean silently accepting a corrupted or
    /// foreign message as a valid reading. `WatchRelayStore.read()` and
    /// `from(wcSessionPayload:)` both already funnel a decode failure into
    /// the same honest "no data yet" state, which is the correct outcome for
    /// a payload that isn't one of ours.
    ///
    /// `encode(to:)` stays synthesized — it writes every key including the
    /// Optionals (absent ones as omitted keys, since `KeyedEncodingContainer`
    /// skips `nil` for Optionals by default), which is exactly the shape the
    /// decoder above expects to read back.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        relayedAt = try container.decode(Date.self, forKey: .relayedAt)
        sourceIsDemoData = try container.decode(Bool.self, forKey: .sourceIsDemoData)
        batteryPercent = try container.decode(Double.self, forKey: .batteryPercent)
        isCharging = try container.decode(Bool.self, forKey: .isCharging)
        isPluggedIn = try container.decode(Bool.self, forKey: .isPluggedIn)

        let thermalRaw = try container.decode(String.self, forKey: .thermalPressure)
        thermalPressure = ThermalPressureSummary(rawValue: thermalRaw) ?? .unknown

        batteryIsReported = try container.decodeIfPresent(Bool.self, forKey: .batteryIsReported)
        cpuPercent = try container.decodeIfPresent(Double.self, forKey: .cpuPercent)
        memoryUsedPercent = try container.decodeIfPresent(Double.self, forKey: .memoryUsedPercent)
        // Absent key -> nil ("not reported"); present-but-unrecognised ->
        // `.unknown` ("reported something this build can't name"). The two
        // are rendered differently, so they must decode differently.
        if let memoryRaw = try container.decodeIfPresent(String.self, forKey: .memoryPressure) {
            memoryPressure = MemoryPressureSummary(rawValue: memoryRaw) ?? .unknown
        } else {
            memoryPressure = nil
        }
        diskUsedPercent = try container.decodeIfPresent(Double.self, forKey: .diskUsedPercent)
        batteryTimeRemainingMinutes = try container.decodeIfPresent(Int.self, forKey: .batteryTimeRemainingMinutes)
        isThrottling = try container.decodeIfPresent(Bool.self, forKey: .isThrottling)
        awakeIsActive = try container.decodeIfPresent(Bool.self, forKey: .awakeIsActive)
        awakeExpiresAt = try container.decodeIfPresent(Date.self, forKey: .awakeExpiresAt)
        awakeModeLabel = try container.decodeIfPresent(String.self, forKey: .awakeModeLabel)
        agentToolCallCount = try container.decodeIfPresent(Int.self, forKey: .agentToolCallCount)
        agentLastActivityAt = try container.decodeIfPresent(Date.self, forKey: .agentLastActivityAt)
        agentRecentToolNames = try container.decodeIfPresent([String].self, forKey: .agentRecentToolNames)
        agentAccessPaused = try container.decodeIfPresent(Bool.self, forKey: .agentAccessPaused)
    }
}

/// A deliberately coarser mirror of `ThermalStats.PressureLevel`
/// (`SentryKit/Models/ThermalStats.swift`) — same four named tiers, plus
/// `.unknown` for a `SystemSnapshot` whose `thermal` field wasn't reported.
/// Redeclared here rather than reusing `ThermalStats.PressureLevel` directly
/// so this file has zero dependency on the rest of `SentryKit/Models/`,
/// keeping `SentryKit_watchOS`'s source list (`project.yml`) exactly the
/// three files it actually needs rather than pulling in `ThermalStats.swift`
/// and whatever *it* transitively expects to compile alongside it.
public enum ThermalPressureSummary: String, Codable, Sendable, Equatable {
    case nominal, fair, serious, critical, unknown
}

/// The memory-pressure counterpart of `ThermalPressureSummary`, mirroring
/// `MemoryPressureLevel` (`SentryKit/Models/MemoryStats.swift`) — same
/// three tiers, plus `.unknown` for a value a newer phone named and this
/// build cannot.
///
/// **Why a `String` raw value when `MemoryPressureLevel` uses `Int`.** That
/// type's raw values are the kernel's own `DISPATCH_MEMORYPRESSURE_*`
/// bitmask constants (1/2/4), which are meaningful *because* they are those
/// numbers. Nothing on this wire needs the bitmask, and a `String` raw
/// value makes the payload self-describing when someone is staring at a
/// dumped JSON blob trying to work out why a watch is showing the wrong
/// thing — the same reason `ThermalPressureSummary` is a `String` rather
/// than an ordinal. The mapping between the two lives in exactly one place,
/// `WatchRelayManager.summarize(_:)`.
public enum MemoryPressureSummary: String, Codable, Sendable, Equatable {
    case normal, warning, critical, unknown
}

// MARK: - WCSession wire format

extension WatchRelaySnapshot {
    /// The one key both sides agree on inside the `[String: Any]`
    /// dictionaries `WCSession`'s `updateApplicationContext`/
    /// `transferCurrentComplicationUserInfo` APIs require.
    private static let payloadKey = "dev.malekswilam.sentry.watchRelay.v1"

    /// `WCSession`'s context/user-info APIs require a plain
    /// `[String: Any]` of property-list-compatible values, not an arbitrary
    /// `Encodable` — wrapping the JSON-encoded bytes as one `Data` value
    /// under a single fixed key sidesteps hand-mapping every field to a
    /// plist type individually (and keeps this the one place the wire
    /// format is defined, matching `WidgetSnapshotStore`'s single
    /// `storageKey` precedent), while still surviving `WCSession`'s plist
    /// coercion, since `Data` is natively plist-safe.
    public func wcSessionPayload() -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return [Self.payloadKey: data]
    }

    /// The receiving half of `wcSessionPayload()` — used by both
    /// `session(_:didReceiveApplicationContext:)` and
    /// `session(_:didReceiveUserInfo:)` on the Watch side, since both
    /// deliver the same dictionary shape.
    public static func from(wcSessionPayload dictionary: [String: Any]) -> WatchRelaySnapshot? {
        guard let data = dictionary[payloadKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchRelaySnapshot.self, from: data)
    }
}
