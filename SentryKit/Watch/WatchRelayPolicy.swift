import Foundation

// MARK: - WatchRelayPolicy: when a relay is worth spending budget on

/// The pure "should the phone spend a relay on this reading" decision,
/// extracted from `WatchRelayManager` (`SentryMobile/Watch/WatchRelayManager.swift`).
///
/// **Why it lives here rather than as a `static func` on the manager, where
/// it used to.** That method's own doc comment claimed it was "factored out
/// of `consider(_:)` so it's testable without a live `WCSession`/
/// `StatsTransport` — see `WatchRelayManagerTests` in `SentryTests`". No
/// such test file has ever existed, and it could not have: `SentryTests` is
/// a macOS-hosted bundle that links `Sentry` and `SentryKit_macOS`, and
/// `WatchRelayManager` is compiled only into the iOS app target, which that
/// bundle does not and cannot link. The logic was factored for testability
/// and then left somewhere no test could reach. Moving it into `SentryKit`
/// — which `SentryTests` already links, and which the manager already
/// imports — makes the claim true instead of deleting it, and is what let
/// the widened change-detection rules below be checked at all rather than
/// argued for in a commit message.
///
/// Nothing here touches WatchConnectivity or any platform API; it is
/// arithmetic over two `WatchRelaySnapshot` values and two dates. It sits in
/// `SentryKit/Watch/` next to the payload it reasons about, which means the
/// watch-side framework variant (`SentryKit_watchOS`, whose source list is
/// that whole directory) compiles it too. That is dead weight on the watch —
/// nothing on watchOS decides when to relay — but it is a few hundred bytes
/// of pure Foundation, and splitting the directory to avoid it would cost
/// more in `project.yml` complexity than it saves.
public enum WatchRelayPolicy {

    /// Baseline heartbeat: even with no "significant" change, relay at
    /// least this often so a Watch that's been asleep/out of range still
    /// gets caught up promptly once reachable again, and so the
    /// complication's staleness label keeps advancing against real data
    /// rather than going quiet indefinitely just because nothing crossed a
    /// threshold.
    public static let minimumRelayInterval: TimeInterval = 5 * 60

    /// A shorter floor that still applies even when a "significant change"
    /// would otherwise trigger an immediate relay — stops a value
    /// oscillating right at a boundary (charge sitting at 100%, thermal
    /// pressure flapping between tiers under bursty load) from turning into
    /// a rapid-fire sequence of relays that would burn the complication's
    /// background-update budget just as fast as relaying every tick would.
    public static let significantChangeCooldown: TimeInterval = 30

    /// - A `nil` `lastRelayedAt` (nothing relayed yet this run) always
    ///   relays immediately — the Watch should get *something* as soon as
    ///   one exists, not wait a full `minimumRelayInterval`.
    /// - Otherwise: relay if `minimumRelayInterval` has elapsed regardless
    ///   of content, OR if `isSignificantChange(from:to:)` and at least
    ///   `significantChangeCooldown` has elapsed.
    public static func shouldRelay(
        previous: WatchRelaySnapshot?,
        next: WatchRelaySnapshot,
        lastRelayedAt: Date?,
        now: Date
    ) -> Bool {
        guard let lastRelayedAt else { return true }
        let age = now.timeIntervalSince(lastRelayedAt)
        if age >= minimumRelayInterval { return true }
        guard age >= significantChangeCooldown, let previous else { return false }
        return isSignificantChange(from: previous, to: next)
    }

    /// The change test, and the part of this file worth arguing about.
    ///
    /// **The rule that decides membership: does this field change *rarely*
    /// and mean something *when it changes*.** Every member below is a
    /// discrete transition a person would notice and care about — a plug
    /// went in, the machine started throttling, memory pressure went amber —
    /// and each one happens on the order of a few times a day, not a few
    /// times a minute. The budget maths is unforgiving: Apple's guidance for
    /// `transferCurrentComplicationUserInfo` is a handful of updates per
    /// hour, and `significantChangeCooldown` caps this at 120/hour in the
    /// worst case, so the set has to stay one that realistically fires a
    /// small number of times per hour rather than one that fires whenever it
    /// legally can.
    ///
    /// **Why `cpuPercent`, `memoryUsedPercent` and `diskUsedPercent` are
    /// deliberately NOT members, even though they are new and the watch now
    /// renders all three.** They are continuous values sampled every few
    /// seconds; CPU in particular almost never reports the same rounded
    /// percentage twice in a row on a machine that is doing anything at all.
    /// Including any of them would make `isSignificantChange` return `true`
    /// on essentially every tick, which reduces the whole policy to "relay
    /// every 30 seconds forever" — the exact failure `WatchRelayManager`'s
    /// doc comment describes, where the complication ends up *less* current
    /// than a paced relay because the system starts silently dropping the
    /// transfers. Adding fields to the payload must not turn into adding
    /// fields to this test; the three new percentages ride the
    /// `minimumRelayInterval` heartbeat, which is what they were budgeted
    /// for. `batteryPercent` is the one continuous value that is a member,
    /// and it survives on the arithmetic: it is compared at whole-point
    /// resolution and a real battery moves about one point every several
    /// minutes, so it cannot fire faster than the cooldown allows anyway.
    ///
    /// **`isPluggedIn` is new to this test, though not to the payload.** It
    /// was carried in v1 and never compared, because nothing on the watch
    /// rendered it. The redesigned `ContentView` does — a Mac sitting at
    /// 100% on the charger and one at 100% that has just been unplugged look
    /// identical without it — so a transition that now changes what is on
    /// screen is one the relay should react to. It very nearly always
    /// coincides with `isCharging` flipping anyway, so in practice this adds
    /// no relays at all; it adds correctness for the plugged-but-not-
    /// charging case, which is the whole reason the two are separate fields.
    ///
    /// **Why `batteryTimeRemainingMinutes` is not a member** despite being
    /// discrete: macOS's own estimate jitters by tens of minutes between
    /// consecutive samples, especially right after a power-state change. It
    /// is a fine thing to *display* (with the freshness label next to it
    /// saying how old it is) and a terrible thing to spend budget chasing.
    ///
    /// **`awakeIsActive` is a member; `awakeExpiresAt` is not.** The watch's
    /// Keep Awake page draws a live control off the active flag, and a user
    /// who just told their Mac to stay awake — from the wrist, from the phone
    /// or from the Mac itself — should not be looking at a page that still
    /// says "sleeping normally" for the next five minutes. The transition
    /// happens a handful of times a day at most and is always user-initiated,
    /// which is as good as a change-detection candidate gets. The expiry
    /// deliberately stays out because it does not need to be current to be
    /// correct: it is relayed as an absolute deadline, so the watch counts
    /// down from its own clock and stays right however stale the relay is
    /// (see `WatchRelaySnapshot.awakeExpiresAt`). An "extend by 30 minutes"
    /// therefore reaches the wrist on the heartbeat rather than on a relay of
    /// its own — the countdown is briefly short, never wrong in a way that
    /// tells the user their Mac will sleep sooner than it will *after* the
    /// heartbeat lands.
    ///
    /// **`agentToolCallCount`/`agentLastActivityAt`/`agentRecentToolNames`
    /// are not compared by value, and should not be** now that
    /// `SystemSnapshot.agentActivitySummary` actually populates them: tool
    /// calls arrive in bursts of dozens per minute from a chatty MCP client,
    /// which is the single chattiest thing that could possibly be wired into
    /// this test — comparing `agentToolCallCount` directly would relay on
    /// every single tool call, every time, defeating the entire point of a
    /// "significant change" test. What *is* a member is coarser: whether the
    /// summary is reported at all. `nil` -> non-`nil` (the composition-root
    /// hook on `StatsCoordinator.agentActivitySummary` finally landing, or
    /// this being the first tool call of a run) and non-`nil` -> `nil`
    /// (a relaunch that hasn't seen a call yet) are each a handful of
    /// occurrences over the life of a run, not a burst — the same "discrete,
    /// rare transition" shape `awakeIsActive` and `agentAccessPaused` are
    /// members for, applied to "do we have a reading at all" instead of to
    /// the reading's value. A user who just triggered the very first agent
    /// call on a freshly-hooked-up Mac should not wait up to
    /// `minimumRelayInterval` for `AgentActivityPage` to leave its permanent
    /// "not reported" state.
    ///
    /// **`agentAccessPaused` is a member, for the same reason
    /// `awakeIsActive` is.** It is a discrete, user-initiated transition —
    /// someone hit the kill switch, on the Mac, the phone, or the watch
    /// itself — a handful of times a day at most, and it now gates a real
    /// control (`AgentActivityPage`'s "Resume Agents" button). A user who
    /// just paused agent access from their wrist should not be looking at a
    /// page that still offers a "Stop" button for the next five minutes
    /// because nothing forced an early relay.
    ///
    /// **`themeID` is a member, and is the rarest one here by a wide
    /// margin.** Picking a theme is a deliberate act someone performs a
    /// handful of times ever, and its entire purpose is to be seen — a user
    /// who switches the phone to Nord and then raises their wrist to a watch
    /// still rendering One Dark will reasonably conclude the watch does not
    /// follow the theme at all. It cannot fire in a burst by construction:
    /// nothing changes this value except a person tapping a different row in
    /// Settings.
    public static func isSignificantChange(
        from previous: WatchRelaySnapshot,
        to next: WatchRelaySnapshot
    ) -> Bool {
        if previous.isCharging != next.isCharging { return true }
        if previous.isPluggedIn != next.isPluggedIn { return true }
        if previous.thermalPressure != next.thermalPressure { return true }
        if previous.isThrottling != next.isThrottling { return true }
        if previous.memoryPressure != next.memoryPressure { return true }
        if previous.awakeIsActive != next.awakeIsActive { return true }
        if previous.agentAccessPaused != next.agentAccessPaused { return true }
        if (previous.agentToolCallCount == nil) != (next.agentToolCallCount == nil) { return true }
        if previous.themeID != next.themeID { return true }
        // Same argument as `themeID` immediately above, and the same rarity:
        // this flips when the phone crosses into or out of dark mode, which
        // is at most a couple of times a day and is exactly the moment a
        // glance at the wrist would otherwise show the wrong half of the
        // user's theme.
        if previous.themeAppearance != next.themeAppearance { return true }
        // Covers the case `themeID` cannot: editing a *custom* theme's
        // colours changes no id at all, so without this the wrist would keep
        // the old palette until the next heartbeat. Same rarity argument —
        // nothing moves this value except a person in the theme editor.
        if previous.themePalette != next.themePalette { return true }
        if Int(previous.batteryPercent.rounded()) != Int(next.batteryPercent.rounded()) { return true }
        return false
    }
}
