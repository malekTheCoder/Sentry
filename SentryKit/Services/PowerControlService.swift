import Foundation
import os

#if os(macOS)
import IOKit.pwr_mgt
import AppKit
import Darwin

/// Maps each `AwakeMode` case to the real `IOKit.pwr_mgt` assertion-type
/// constant `PowerControlService` passes to `IOPMAssertionCreateWithProperties`.
/// A computed extension, not a member of the enum itself, because
/// `IOKit.pwr_mgt` only exists on macOS — see `AwakeMode`'s own doc comment
/// (`SentryKit/Models/AwakeMode.swift`) for why the enum had to move out of
/// this `#if os(macOS)` block in the first place.
extension AwakeMode {
    var assertionType: String {
        switch self {
        case .displayAndSystem: return kIOPMAssertionTypeNoDisplaySleep
        case .systemOnly: return kIOPMAssertionTypePreventUserIdleSystemSleep
        case .systemWhileOnAC: return kIOPMAssertionTypePreventSystemSleep
        }
    }
}

/// A condition-based release trigger (plan §10.3's "last three" duration
/// options, later extended with two more — see below) — what elevates this
/// above a plain Caffeine clone. Evaluated one of three ways: by feeding live
/// `SystemSnapshot`s through `evaluate(_:)` (`.batteryBelowPercent`,
/// `.cpuAbovePercent`, `.whileProcessRunning`, `.whileDownloadActive`,
/// `.scheduledWindow` — everything that either rides the snapshot itself or
/// is cheap enough to poll on the same tick); by observing app-termination
/// notifications directly (`.whileAppRunning` — see `PowerControlService`'s
/// `NSWorkspace` observer); there is no third, timer-driven path — see
/// `.scheduledWindow`'s doc comment for why a dedicated `Timer` was
/// considered and rejected for it specifically.
///
/// **What's deliberately absent: "while the display is closed."** A
/// competitive review of keep-awake utilities flagged this as a gap, but
/// it is not one — a clamshell close is one of the two explicit exceptions
/// `PowerControlService`'s own type doc calls out ("none of the assertion
/// types used here override an explicit user Sleep ... or a clamshell
/// close. That's correct, intended OS behavior"). Implementing a trigger
/// whose entire purpose is to fight that OS behavior would mean acquiring a
/// `kIOPMAssertionTypePreventUserIdleDisplaySleep`-style assertion that
/// actively defeats clamshell sleep — the one keep-awake behavior this
/// codebase has already decided, deliberately, not to offer. Do not add it;
/// see the file-level type doc comment above `PowerControlService` before
/// reconsidering.
public enum ReleaseCondition: Codable, Equatable, Sendable {
    case batteryBelowPercent(Double)
    /// Sustained: the CPU must stay above `Double`% for at least
    /// `TimeInterval` seconds continuously. Dropping below the threshold at
    /// any point resets the sustained-duration clock.
    case cpuAbovePercent(Double, for: TimeInterval)
    case whileAppRunning(bundleIdentifier: String)
    /// Holds the assertion while a *process* with this executable name is
    /// running — `claude`, `codex`, `xcodebuild`, `node` — and releases when
    /// it exits. The agent-ops sibling of `.whileAppRunning`: CLI tools and
    /// build daemons never appear in `NSWorkspace`'s app lifecycle
    /// notifications, so this one is polled per snapshot tick in
    /// `evaluate(_:)` via a libproc scan instead. Name matching is
    /// case-insensitive and exact (no substring matching — "node" must not
    /// hold the machine awake because "com.apple.noded" exists).
    case whileProcessRunning(name: String)

    /// Holds the assertion while `~/Downloads` has been written to within
    /// the last `idleTimeout` seconds — the competitive-parity trigger for
    /// "keep awake while a download is running."
    ///
    /// **Why a polled mtime heuristic, not a real download-completion
    /// signal.** There is no public, cross-browser API for "is a download in
    /// progress" — each browser (and CLI tool: `curl`, `git clone`, `scp`)
    /// tracks its own transfers privately. What every one of them shares is
    /// that a file actively downloading is a file whose modification time
    /// keeps advancing, written into (by convention) `~/Downloads`. So "any
    /// file under `~/Downloads` modified within the last few seconds" is the
    /// closest system-level proxy available, evaluated the same way
    /// `.whileProcessRunning` evaluates its libproc scan: polled per
    /// snapshot tick in `evaluate(_:)` via `PowerControlService.downloadProbe`,
    /// not a separate watcher.
    ///
    /// **Why polling, not `FSEventStream`.** `FSEventStream` would notify
    /// asynchronously on writes under `~/Downloads`, but it reports *paths*,
    /// not *timestamps* — turning an FSEvent into "was this modified in the
    /// last N seconds" still means `stat()`-ing the changed path afterward,
    /// so FSEvents buys asynchronous delivery at the cost of a second API
    /// surface (a dispatch-queue-driven C callback, run-loop scheduling,
    /// careful stream teardown in `deinit`) for a condition that's already
    /// being polled once per snapshot tick regardless, on the same cadence
    /// `.whileProcessRunning`'s full-machine `proc_listallpids` scan already
    /// rides. A `~/Downloads`-sized, non-recursive directory enumeration
    /// plus a handful of `contentModificationDate` reads is negligible next
    /// to that existing scan on the same tick, so there's no performance
    /// case for the heavier mechanism here — see
    /// `PowerControlService.mostRecentDownloadsModification(in:fileManager:)`.
    ///
    /// **The honest caveat.** This cannot distinguish a genuine in-progress
    /// download from a file in `~/Downloads` merely being edited, renamed
    /// into, or re-saved within the timeout window — the same spirit as
    /// `.whileProcessRunning`'s "exact name match, not a real identity
    /// check" caveat above. `~/Downloads` plus a very recent write is a
    /// reasonable proxy, not a certainty.
    ///
    /// Unlike `.whileProcessRunning`, there is no consecutive-miss grace
    /// window here: `idleTimeout` itself is already the slack (a brief pause
    /// between chunks reads as "still active" until the timeout elapses on
    /// its own), so stacking a second grace mechanism on top would only
    /// extend the hold well past the point the heuristic itself considers
    /// the download finished.
    case whileDownloadActive(idleTimeout: TimeInterval)

    /// Holds the assertion during a recurring day-of-week/time-of-day
    /// window — the competitive-parity "scheduled" trigger. `weekdays` uses
    /// `Calendar.Component.weekday`'s 1...7 (Sunday = 1) convention, matching
    /// `Calendar` itself rather than inventing a zero-based one. `startMinute`
    /// and `endMinute` are minutes after local midnight (0...1440), the same
    /// representation `AgentGuardrailSettings.quietHoursStartMinute`/
    /// `quietHoursEndMinute` use (`SentryKit/Services/AgentGuardrails.swift`)
    /// — chosen for the same reason: it's DST-proof (no `DateComponents`
    /// wall-clock-vs-absolute-time ambiguity to resolve) and round-trips
    /// through JSON with no `Calendar`/`TimeZone` riding along in `Codable`.
    /// `endMinute` may be `1440` to mean "through the end of the day" (a
    /// same-day window with no natural minute-1439 boundary to name, e.g. an
    /// all-day weekend schedule) — see
    /// `PowerControlService.isWithinScheduledWindow(weekdays:startMinute:endMinute:date:calendar:)`
    /// for the exact comparison, including midnight-crossing.
    ///
    /// **Why `evaluate(_:)`, not a dedicated `Timer`.** A schedule sounds
    /// timer-shaped — "fire an event at 22:00" — but what this condition
    /// actually needs checked is not an edge, it's a level: "is *now* inside
    /// the window," the same shape `.batteryBelowPercent` already polls off
    /// `snapshot.battery`. Arming a `Timer` for the next boundary would mean
    /// duplicating `expiryTimer`'s generation-guarded stale-fire protection
    /// (see `assertionGeneration`'s doc comment) for a second, independent
    /// timer with its own race between "fires" and "the main-actor task
    /// actually runs" — real complexity purchased for a case `evaluate(_:)`
    /// already handles for free on the tick cadence every other condition
    /// already pays for.
    case scheduledWindow(weekdays: Set<Int>, startMinute: Int, endMinute: Int)
}

/// Wraps an `IOReturn` failure from `IOPMAssertionCreateWithProperties`.
public enum PowerControlError: Error, LocalizedError, Sendable, Equatable {
    case assertionFailed(IOReturn)
    /// Thrown by `adjustAssertion(bySeconds:)` when there's nothing to
    /// adjust — see that method's doc comment for the three cases this covers.
    case noAdjustableAssertion
    /// Thrown when arming a `ReleaseCondition` while
    /// `conditionalKeepAwakeAuthorized` answers false — the service half of
    /// the `ProFeature.conditionalKeepAwake` gate. The description names the
    /// tier and enumerates nothing: every surface that renders errors
    /// verbatim (`SleepControlCard.startError`, and any future caller) would
    /// otherwise leak the locked triggers' vocabulary to the free tier.
    case conditionalKeepAwakeLocked

    public var errorDescription: String? {
        switch self {
        case .assertionFailed(let code):
            return "Couldn't prevent sleep (IOKit error \(code))."
        case .noAdjustableAssertion:
            return "No timed keep-awake session is running to adjust."
        case .conditionalKeepAwakeLocked:
            return "Conditional release rules are part of Sentry Pro. Timed and indefinite keep-awake stay free."
        }
    }
}

/// Why a keep-awake hold ended. Exists because of a field incident this file
/// now guards against end to end: an indefinite hold silently vanished at
/// lid-open wake, and the `pmset -g log` release entry — the only trace —
/// could not distinguish "user clicked End Now" from "wake reconciliation
/// tore it down over a damaged record." Every teardown funnel in this
/// service now logs one of these, so the next such incident names its own
/// cause. A plain enum with a `logDescription` rather than a free string, so
/// call sites can't drift into unsearchable prose.
public enum KeepAwakeReleaseTrigger: Equatable, Sendable {
    /// A person asked — the dropdown toggle/End Now, a Siri intent, the
    /// iPhone sleep card, or an alert rule the user configured. The default
    /// on the public `releaseAssertion(trigger:)` because every pre-existing
    /// external call site is, in fact, a user-intent surface.
    case userEnded
    /// A timed hold's window elapsed (app-level timer or the wake path's
    /// prompt equivalent). Expected and announced in advance by the
    /// countdown, so no user notification accompanies it.
    case timedExpiry
    /// An armed `ReleaseCondition` was satisfied. Also expected — the user
    /// armed the condition.
    case conditionMet
    /// A new hold in the same slot replaced this one ("only ever one at a
    /// time" — per slot, see the type doc comment).
    case replacedByNewHold
    /// An agent asked to end its own hold (`release_awake` over MCP).
    case agentRequest
    /// Policy released an agent hold — kill switch, per-agent stop, or
    /// guardrail auto-revocation. Announced by `AppDelegate
    /// .announceAgentRevocation`, never silent.
    case agentRevoked
    /// A restore attempt failed and the hold it described could not be
    /// brought back — the one *policy-driven* drop of a user hold this
    /// service can still perform, and the one that must be loud. See
    /// `policyReleaseNotifier`.
    case restoreFailed

    var logDescription: String {
        switch self {
        case .userEnded: return "user ended"
        case .timedExpiry: return "timed expiry"
        case .conditionMet: return "release condition met"
        case .replacedByNewHold: return "replaced by a new hold"
        case .agentRequest: return "agent released its own hold"
        case .agentRevoked: return "agent hold revoked by policy"
        case .restoreFailed: return "restore failed"
        }
    }
}

/// Sleep-prevention service (plan §10). Owns at most one live
/// `IOPMAssertionID` **per intent slot** and mirrors the presented union
/// into `state` for the UI.
///
/// **Two slots, one visible state — the separate-intents invariant.** A
/// keep-awake hold answers to exactly one of two masters: the *user* (the
/// dropdown toggle, Siri, the iPhone card, a restore of the user's own
/// standing intent) or an *agent* (the `keep_awake` MCP tool). These used to
/// share a single `IOPMAssertionID`, which made them structurally able to
/// destroy each other: an agent's `keep_awake` replaced the user's hold, an
/// agent's `release_awake` released it, and an agent session's timeout
/// expiring took the user's indefinite hold down with it. No amount of
/// ownership *tagging* fixes that — a tag describes who owns the one
/// assertion, it cannot make two intents outlive each other. So the intents
/// are now two real, independent OS assertions: the user slot
/// (`assertionID`/`state`-through-`userHold`) and the agent slot
/// (`agentAssertionID`/`agentHold`), each with its own expiry timer and
/// generation guard. An agent hold expiring, being revoked, or being
/// released over MCP can never touch the user's; the user's expiring can
/// never touch the agent's. The alternative — refcounting one assertion —
/// was rejected because the two intents can want *different modes* (the
/// user's "screen stays on" versus an agent's "system only"), and one
/// assertion can only have one type.
///
/// `state` presents the union: the user's hold when one is active, else the
/// agent's, else `.inactive`. That keeps every existing consumer honest —
/// the menu-bar `.whenAssertionActive` rule, the widgets, and the dropdown
/// all still see "something is holding this Mac awake, and here is its
/// reason" — while the slots underneath stay independent. The dropdown's
/// toggle-off (`releaseAssertion(trigger:)`) is a deliberate *master off*:
/// it ends both slots, because the user reaching for the off switch means
/// "let my Mac sleep," and a toggle that flips itself back on because an
/// agent still holds a hidden assertion would read as broken. Agents get no
/// such master switch — `releaseAgentAssertion` and the MCP `release_awake`
/// path end only the agent slot.
///
/// **Why `IOPMAssertionCreateWithProperties`, not the simpler
/// `IOPMAssertionCreateWithName`:** only the properties variant accepts
/// `kIOPMAssertionTimeoutKey`/`kIOPMAssertionTimeoutActionKey`, which arm an
/// OS-level timeout that releases the assertion even if this process is
/// killed outright (force-quit, crash, `kill -9`). That's belt-and-braces
/// alongside the app-level `Timer`s below: the `Timer` only fires while this
/// process is alive and updates `state` promptly; the OS timeout is what
/// still protects the machine if it isn't. A leaked assertion is close to
/// the worst failure mode this feature has — the Mac silently never
/// sleeps again until reboot — so both mechanisms exist deliberately, not
/// redundantly.
///
/// **What this does *not* do:** per plan §10.1, none of the assertion types
/// used here override an explicit user Sleep (Apple menu → Sleep) or a
/// clamshell close. That's correct, intended OS behavior — do not "fix" it
/// into overriding the user's explicit choice.
///
/// `@MainActor`-isolated rather than queue-confined like `StatsCoordinator`:
/// this service is driven by user-initiated UI actions and infrequent system
/// notifications (wake, app termination), not a hot polling loop, so there's
/// no contention to protect against with a private serial queue.
@MainActor
public final class PowerControlService: ObservableObject {

    private static let logger = Logger(subsystem: "dev.malekswilam.sentry.kit", category: "PowerControlService")
    private static let defaultsKey = "dev.malekswilam.sentry.powercontrol.state"

    /// The persistence suite used under `xcodebuild test`, instead of
    /// `.standard`. See `defaultPersistenceDomain(processInfo:)`.
    public static let testHostSuiteName = "dev.malekswilam.sentry.powercontrol.testhost"

    /// The presented union of the two slots — the user's hold when active,
    /// else the agent's hold, else `.inactive`. Recomputed by
    /// `refreshPresentedState()` after every slot mutation. This is what the
    /// dropdown card binds to, what `AppDelegate` mirrors into
    /// `StatsCoordinator.sleepAssertionState`, and therefore what the
    /// menu-bar visibility rule and widgets see — deliberately the *union*,
    /// because "an assertion is holding this Mac awake" is true regardless
    /// of which slot holds it, and hiding an agent's hold from those
    /// surfaces would be the P5 lie in the other direction.
    @Published public private(set) var state: SleepAssertionState = .inactive

    // MARK: - User slot

    /// The user slot's own state, kept separately from the presented
    /// `state` union above so persistence and slot logic can never confuse
    /// "the user turned this on" with "an agent turned this on."
    private var userHold: SleepAssertionState = .inactive

    private var assertionID: IOPMAssertionID = 0
    private var expiryTimer: Timer?

    /// Bumped once per successfully created *user-slot* assertion. Exists to
    /// close a stale-expiry race the `expiryTimer` alone cannot: the timer's
    /// block hops onto the main actor via `Task { @MainActor ... }`, so
    /// there is a window between the timer *firing* and that task *running*
    /// in which other main-actor work — a user starting a fresh assertion,
    /// an `adjustAssertion` extension — can replace the assertion the timer
    /// was armed for. `expiryTimer?.invalidate()` prevents future fires but
    /// cannot recall a fire that already happened, so without this guard the
    /// stale task would silently tear down the *new* assertion seconds after
    /// the user created it (e.g. extend a 60-second hold to 8 hours in the
    /// last instant of the old window, and the Mac sleeps 8 hours early
    /// anyway). Each timer captures the generation it was armed for;
    /// `timedAssertionExpired(generation:)` releases only if that generation
    /// is still current. `internal private(set)` rather than `private` so
    /// tests can exercise the stale-generation guard deterministically.
    private(set) var assertionGeneration: UInt64 = 0

    /// The conditional trigger (if any) governing the current *user*
    /// assertion, so `evaluate(_:)` and the app-termination observer know
    /// what to check. Conditions belong to the user slot only — agents pass
    /// durations over MCP, never conditions — which is why the agent slot
    /// has no counterpart.
    private var activeCondition: ReleaseCondition?

    /// First moment `.cpuAbovePercent`'s condition was observed true, for
    /// the "sustained" requirement. `nil` whenever the condition is not
    /// currently true (including "no condition set" / "no CPU sample yet").
    private var conditionSustainedSince: Date?

    /// Consecutive `evaluate(_:)` ticks on which `.whileProcessRunning`'s
    /// process was *not* found. Released only after two consecutive misses,
    /// so a single glitchy `proc_listallpids` enumeration (or a process
    /// observed mid-exec) can't drop a multi-hour hold spuriously.
    private var processMissCount = 0

    // MARK: - Agent slot

    /// One agent-requested hold — everything the kill switch, guardrails,
    /// and session attribution need to know about it, carried on the slot
    /// itself. This *replaces* the old generation-tagged
    /// `agentOwnership` tuple: with the agent hold living in its own slot,
    /// ownership can no longer drift off it (the "ownership drift" bug an
    /// earlier pass fixed with explicit re-tagging at three call sites), so
    /// the tagging machinery and its re-tag choreography are gone rather
    /// than maintained.
    public struct AgentHold: Equatable, Sendable {
        public let mode: AwakeMode
        public let expiresAt: Date?
        public let reason: String
        /// Self-reported MCP client name — a label, not a verified identity;
        /// see `AgentGuardrailSettings`'s trust note.
        public let clientName: String
        /// Per-connection session ID (see `AgentSessionIdentity`) for the
        /// awake-hold ledger's per-session attribution; `nil` for legacy
        /// callers with no session identity.
        public let sessionID: String?
    }

    /// The live agent hold, or `nil`. Not `@Published` — every mutation goes
    /// through `refreshPresentedState()`, and `state` is the published
    /// surface consumers watch.
    public private(set) var agentHold: AgentHold?

    private var agentAssertionID: IOPMAssertionID = 0
    private var agentExpiryTimer: Timer?

    /// The agent slot's own stale-expiry guard — same race, same fix as
    /// `assertionGeneration` above, per slot because the two timers are
    /// independent.
    private(set) var agentAssertionGeneration: UInt64 = 0

    // MARK: - Injectable seams

    /// Injectable for tests — the default scans the live process table.
    /// Called at most once per snapshot tick, and only while a
    /// `.whileProcessRunning` condition is armed.
    public var processProbe: (String) -> Bool = PowerControlService.isProcessRunning(named:)

    /// Injectable for tests — the default scans `~/Downloads` for its most
    /// recently modified file and checks it against `idleTimeout`. Called at
    /// most once per snapshot tick, and only while a `.whileDownloadActive`
    /// condition is armed, mirroring `processProbe`'s convention exactly
    /// (see `ReleaseCondition.whileDownloadActive`'s doc comment for why
    /// this is a poll rather than an `FSEventStream`).
    public var downloadProbe: (TimeInterval) -> Bool = { idleTimeout in
        PowerControlService.isDownloadActive(
            mostRecentModification: PowerControlService.mostRecentDownloadsModification(),
            idleTimeout: idleTimeout
        )
    }

    /// Whether arming a `ReleaseCondition` is authorized right now — the
    /// service half of the `ProFeature.conditionalKeepAwake` gate. A settable
    /// closure like `processProbe`/`downloadProbe` above, for the same
    /// injectability and for the sibling-services rule (`AlertRule.swift`):
    /// this type must not read entitlements itself, so the composition root
    /// wires it to `proEntitlementStore.isUnlocked(.conditionalKeepAwake)`.
    /// Consulted live at each arm rather than mirrored as a pushed `Bool`,
    /// so a license paste or override flip gates/ungates the very next arm
    /// with no re-push step. `@MainActor` so that wiring closure can call
    /// the main-actor entitlement store; every caller here already is.
    ///
    /// Checked in exactly one place — `startAssertionInternal`, and only
    /// when a condition is being armed — which covers both the public
    /// `startConditionalAssertion` entry and the cold-start restore re-arm
    /// in `reconcilePersistedState`. Deliberately never consulted by
    /// `evaluate(_:)`, `releaseAssertion()`, or the expiry/termination
    /// paths: everything that releases must survive a lapsed license, and
    /// an already-armed conditional hold whose entitlement lapses
    /// mid-session keeps running *and keeps releasing on its condition* —
    /// dropping the hold at the lapse instant would sleep the Mac out from
    /// under the workload the user armed it for, which is a worse lie than
    /// letting a paid-for arm finish its job. Note the wake path no longer
    /// consults this at all: waking used to re-*arm* (release + recreate),
    /// which incidentally dropped a lapsed conditional hold; now that wake
    /// keeps the live assertion instead of flapping it (see
    /// `reconcileAfterWake()`), a lapse during sleep behaves exactly like a
    /// lapse mid-session — the armed hold keeps running and keeps releasing
    /// on its condition, which is the *same* policy, applied consistently
    /// instead of depending on whether the Mac happened to sleep.
    ///
    /// Defaults open, unlike `FanControlService.isProUnlocked`'s
    /// default-locked: fan writes move hardware through a root helper, so an
    /// unseeded service must refuse; a conditional keep-awake is an ordinary
    /// unprivileged assertion, and this service is constructed standalone by
    /// tests and previews that exercise condition mechanics, not
    /// entitlements. The production gate is this closure's wiring plus the
    /// UI's own withheld menu — two layers, both in the composition root's
    /// hands.
    public var conditionalKeepAwakeAuthorized: @MainActor () -> Bool = { true }

    /// Called whenever this service ends (or refuses to restore) a hold *by
    /// policy* rather than by the user's own request or a schedule the user
    /// chose — today that is exactly the restore-failure and
    /// lapsed-entitlement drops in `reconcileAtColdStart()`. The composition
    /// root should wire this to a real user notification
    /// (`AlertEngine.deliverGuardrailNotice`, the same pathway
    /// `AppDelegate.announceAgentRevocation` uses) — the follow-up
    /// integration step this file cannot do itself because `AppDelegate` and
    /// `AlertEngine` wiring belong to the composition root, the exact
    /// precedent `CaffeinateArbitrator.enforce`'s doc comment sets for the
    /// same constraint. Until wired, the built-in fallback below still
    /// os_log's every call at `.error`, so a policy drop is *never* silent
    /// even in an unwired build — silence is the one failure mode this hook
    /// exists to abolish (an indefinite hold once vanished with no trace but
    /// a `pmset` release entry; never again).
    public var policyReleaseNotifier: (@MainActor (_ title: String, _ body: String) -> Void)?

    private var wakeObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    private let defaults: UserDefaults

    // MARK: - Persistence record

    /// Small persisted record: everything needed to restore both slots and
    /// the conditional trigger across relaunch/wake, plus who wrote it.
    ///
    /// **Field layout is compatibility-constrained.** `state`, `condition`
    /// and `agentOwnerClientName` are the v1 field names; a v1 record put
    /// *whichever* slot was live into `state` and marked agent ownership
    /// with `agentOwnerClientName`. v2 (this shape) writes `state` as the
    /// *user* slot only, always leaves `agentOwnerClientName` nil, and adds
    /// `agentHold`, `ownerPID` and `ownerProcessName` — all optional, so a
    /// v1 record decodes as v2 (extras nil) and a v2 record read by a v1
    /// build degrades to "the user slot, unowned," which is the safe
    /// direction. `loadPersistedRecord()` normalizes a v1 agent-tagged
    /// record into the v2 shape at read time so the rest of this file only
    /// ever reasons about one layout.
    ///
    /// **Why `ownerPID`/`ownerProcessName` exist — the second-instance
    /// clobber.** This record lives in a UserDefaults domain shared by every
    /// process with this bundle identifier — which is not only the installed
    /// app: a Debug build run from Xcode, or the test host `xcodebuild test`
    /// launches, is a *second live Sentry* writing to the same domain. A
    /// verified field incident: the installed app held a live indefinite
    /// assertion; a test-host instance cold-started, concluded (correctly,
    /// for *its* process) that "process death already released the
    /// assertion," and cleared the record — then, at the next lid-open wake,
    /// the installed app's own reconciliation found no record and released
    /// the user's live hold, silently. The premise "a persisted record with
    /// no live process behind it is stale" is only sound when you can tell
    /// whether the process behind it is live — so the record now names its
    /// writer, and `reconcileAtColdStart()` leaves records owned by a
    /// *different, still-running* Sentry process strictly alone. The name
    /// rides along as a PID-reuse guard: after a reboot the recorded PID is
    /// routinely reassigned to an unrelated process, and liveness of the
    /// number alone would wrongly block the user's own restore.
    private struct PersistedRecord: Codable {
        /// v2: the user slot. (v1: whichever slot was live.)
        var state: SleepAssertionState
        var condition: ReleaseCondition?
        /// v1 legacy marker only — always nil in v2 writes. Non-nil means
        /// this record predates the two-slot split and `state` describes an
        /// *agent* hold owned by this client name.
        var agentOwnerClientName: String?
        /// v2: the agent slot, if an agent hold was live.
        var agentHold: PersistedAgentHold?
        /// v2: `ProcessInfo.processIdentifier` of the writing process.
        var ownerPID: Int32?
        /// v2: the writing process's executable name, for PID-reuse checks.
        var ownerProcessName: String?
    }

    private struct PersistedAgentHold: Codable {
        var mode: AwakeMode
        var expiresAt: Date?
        var reason: String
        var clientName: String
        var sessionID: String?
    }

    // MARK: - Init / deinit

    /// The `UserDefaults` domain keep-awake state persists in: `.standard`,
    /// except under a test run, where it is an isolated suite
    /// (`testHostSuiteName`).
    ///
    /// **Why the test-run carve-out is the *service's* default and not the
    /// tests' discipline.** The tests already inject per-test suites — that
    /// was never the leak. The leak is the *test host*: `xcodebuild test`
    /// launches the real app as its host process, whose `AppDelegate`
    /// constructs a production `PowerControlService` with the default
    /// domain before a single test runs. On a developer's own Mac that
    /// host-process cold-start reconciliation then adjudicates the
    /// *installed, running* app's live record — which is precisely how a
    /// user's indefinite hold got clobbered in the verified incident this
    /// file's persistence comments describe. No test-side convention can fix
    /// a write the host app performs on its own; only the default can. A
    /// `#if DEBUG` split was considered and rejected: a developer running a
    /// Debug build *as their app* is a legitimate user of the real domain,
    /// and config-dependent persistence is a divergence bug factory. The
    /// XCTest environment marker identifies exactly the process that must
    /// be inert, and nothing else.
    public nonisolated static func defaultPersistenceDomain(
        processInfo: ProcessInfo = .processInfo
    ) -> UserDefaults {
        let environment = processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return UserDefaults(suiteName: testHostSuiteName) ?? .standard
        }
        return .standard
    }

    /// - Parameter defaults: override for tests; defaults to
    ///   `defaultPersistenceDomain()` — `.standard` in the app,
    ///   an isolated suite under a test run (see that method's doc comment)
    ///   — matching `RollupJob`'s injectable-`UserDefaults` convention for
    ///   small persisted key-value state (as opposed to `HistoryStore`'s
    ///   GRDB-backed time series, which this state is not).
    public init(defaults: UserDefaults = PowerControlService.defaultPersistenceDomain()) {
        self.defaults = defaults

        // Reconciliation exists because our UserDefaults bookkeeping can
        // outlive the thing it describes: a persisted "I was active" flag is
        // a claim about an OS-level assertion that may no longer exist, and
        // P5 says we must not render a claim we haven't verified (plan
        // §10.4's reconciliation paragraph, which applies locally even
        // without CloudKit).
        //
        // The two entry points are deliberately *not* equivalent — see
        // `reconcileAfterWake()` and `reconcileAtColdStart()`. On wake the
        // process never died, so the live in-process assertions are the
        // authority and the record is subordinate to them; on launch the
        // record is all there is.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconcileAfterWake() }
        }

        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in self?.handleAppTermination(bundleIdentifier: bundleID) }
        }

        reconcileAtColdStart()
    }

    /// `deinit` is `nonisolated` on a `@MainActor` class — it cannot hop
    /// back onto the main actor to call `releaseAssertion()`, the same
    /// constraint `StatsCoordinator.deinit` documents and works around.
    /// Stored-property access and plain C/Foundation calls (the
    /// `IOPMAssertionRelease` call itself has no actor isolation of its
    /// own — only this class's Swift-side bookkeeping does) are fine to do
    /// directly here; only *calling another `@MainActor` method* would not
    /// be. Doing the minimal safe release/cleanup directly, rather than
    /// trying to dispatch `releaseAssertion()` asynchronously, also avoids
    /// `StatsCoordinator`'s documented `deinit` + `queue.async([weak self])`
    /// bug: a dispatch made after `self` is already gone would silently
    /// no-op and leak the assertion — exactly the failure mode this method
    /// exists to prevent.
    deinit {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
        if agentAssertionID != 0 {
            IOPMAssertionRelease(agentAssertionID)
        }
        expiryTimer?.invalidate()
        agentExpiryTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
        }
    }

    // MARK: - Public API (user slot)

    /// Fixed-duration or indefinite assertion (plan §10.2/§10.3).
    /// - Parameter duration: `nil` means indefinite (until `releaseAssertion()`).
    public func startAssertion(mode: AwakeMode, duration: TimeInterval?, reason: String) throws {
        try startAssertionInternal(mode: mode, duration: duration, reason: reason, condition: nil)
    }

    /// Like `startAssertion(mode:duration:reason:)`, but tags the resulting
    /// `AgentAwakeHold` ledger entry with `owner`. Superseded: agent-intent
    /// callers should use `startAgentAssertion`, which lands in the agent
    /// slot; this overload starts a *user-slot* hold whose ledger entry
    /// carries the tag, which is what it always did — kept because it is
    /// public kit API and removing it would be a source break for nothing.
    public func startAssertion(mode: AwakeMode, duration: TimeInterval?, reason: String, owner: String?) throws {
        try startAssertionInternal(mode: mode, duration: duration, reason: reason, condition: nil, owner: owner)
    }

    /// Conditional assertion — any `ReleaseCondition` (battery threshold,
    /// sustained CPU threshold, while a specific app or process runs, while a
    /// download is active, or on a schedule). Indefinite by construction —
    /// it's released when `condition` is satisfied, not on a timer. Feed live
    /// data via `evaluate(_:)` from the same `StatsCoordinator` stream
    /// everything else already consumes; `.whileAppRunning` is handled
    /// internally via an `NSWorkspace` termination observer instead — see
    /// `ReleaseCondition`'s own doc comment for exactly which conditions go
    /// through which path.
    public func startConditionalAssertion(mode: AwakeMode, condition: ReleaseCondition, reason: String) throws {
        try startAssertionInternal(mode: mode, duration: nil, reason: reason, condition: condition)
    }

    /// The master off switch: releases *both* slots, invalidates their
    /// timers, clears any armed conditional trigger, and persists the
    /// now-inactive state. Idempotent — safe to call with nothing active.
    ///
    /// Deliberately ends the agent's hold too, not only the user's: every
    /// caller of this method is a user-intent surface (the dropdown's
    /// toggle/End Now, Siri, the iPhone card, a user-configured alert
    /// action), and a user reaching for the off switch means "let my Mac
    /// sleep" — an off switch that leaves a hidden agent assertion holding
    /// the machine awake, flipping the toggle straight back on, would read
    /// as broken and *be* dishonest. The asymmetric alternative (user off
    /// ends only the user slot) was considered and rejected for exactly
    /// that reason; agents can re-request, users should not have to hunt.
    /// Agent-side code must never call this — it uses
    /// `releaseAgentAssertion`, which cannot touch the user's hold.
    ///
    /// - Parameter trigger: why — logged on every call, defaulted to
    ///   `.userEnded` because every external call site is a user surface.
    public func releaseAssertion(trigger: KeepAwakeReleaseTrigger = .userEnded) {
        releaseUserSlot(trigger: trigger)
        releaseAgentSlot(trigger: trigger)
        persistState()
    }

    /// Extends (positive `delta`) or truncates (negative `delta`) the
    /// remaining duration of the *presented* hold — the same hold whose
    /// countdown the dropdown is showing — preserving its mode, reason, and
    /// (for an agent hold) its ownership, which now rides the slot itself
    /// rather than needing the read-owner-before/re-tag-after choreography
    /// the shared-assertion design required. Throws `.noAdjustableAssertion`
    /// when there's nothing to adjust: no hold is active, the presented one
    /// is indefinite (no `expiresAt` for "remaining time" to mean anything),
    /// or it's a conditional trigger (governed by
    /// `activeCondition`/`evaluate(_:)`, not a clock — see
    /// `ReleaseCondition`). A truncation that lands at or before now
    /// releases that hold immediately rather than starting a new one with a
    /// zero-or-negative duration.
    public func adjustAssertion(bySeconds delta: TimeInterval) throws {
        // User slot first — it is also what `state` presents first.
        if case .active(let mode, let expiresAt, let reason) = userHold, activeCondition == nil {
            guard let expiresAt else { throw PowerControlError.noAdjustableAssertion }
            let newRemaining = expiresAt.timeIntervalSinceNow + delta
            guard newRemaining > 0 else {
                releaseUserSlot(trigger: .userEnded)
                persistState()
                return
            }
            try startAssertionInternal(mode: mode, duration: newRemaining, reason: reason, condition: nil)
            return
        }
        // Else the presented hold, if any, is the agent's — the dropdown's
        // extend/truncate buttons act on what the user is looking at.
        if let hold = agentHold {
            guard let expiresAt = hold.expiresAt else { throw PowerControlError.noAdjustableAssertion }
            let newRemaining = expiresAt.timeIntervalSinceNow + delta
            guard newRemaining > 0 else {
                releaseAgentSlot(trigger: .userEnded)
                persistState()
                return
            }
            try startAgentAssertionInternal(
                mode: hold.mode,
                duration: newRemaining,
                reason: hold.reason,
                clientName: hold.clientName,
                sessionID: hold.sessionID
            )
            return
        }
        throw PowerControlError.noAdjustableAssertion
    }

    /// Feeds a fresh `SystemSnapshot` from the app's single poll loop (plan
    /// §3.2 P3 — this service doesn't own or create that stream) so every
    /// `ReleaseCondition` except `.whileAppRunning` can be checked —
    /// `.batteryBelowPercent` and `.cpuAbovePercent` read straight off the
    /// snapshot, `.whileProcessRunning` and `.whileDownloadActive` piggyback
    /// on the same tick with their own polls (libproc, `~/Downloads` mtime
    /// scan respectively), and `.scheduledWindow` just checks wall-clock time
    /// against the window on the same cadence. A no-op unless a conditional
    /// assertion is currently active. `.whileAppRunning` isn't evaluated here
    /// — there's nothing on a `SystemSnapshot` to check it against — it's
    /// handled by the `NSWorkspace` termination observer registered in
    /// `init`. Conditions live on the user slot only, so a firing condition
    /// releases the user's hold and never an agent's.
    public func evaluate(_ snapshot: SystemSnapshot) {
        guard let condition = activeCondition else { return }

        switch condition {
        case .batteryBelowPercent(let threshold):
            guard let percent = snapshot.battery?.chargePercent else { return }
            if percent < threshold {
                releaseUserSlot(trigger: .conditionMet)
                persistState()
            }

        case .cpuAbovePercent(let threshold, let sustainedFor):
            guard let percent = snapshot.cpu?.totalPercent else {
                // No sample this tick — don't let a transient gap masquerade
                // as "condition held the whole time."
                conditionSustainedSince = nil
                return
            }
            if percent > threshold {
                let startedAt = conditionSustainedSince ?? Date()
                conditionSustainedSince = startedAt
                if Date().timeIntervalSince(startedAt) >= sustainedFor {
                    releaseUserSlot(trigger: .conditionMet)
                    persistState()
                }
            } else {
                // "Sustained" means continuously true — any dip resets the clock.
                conditionSustainedSince = nil
            }

        case .whileAppRunning:
            break

        case .whileProcessRunning(let name):
            if processProbe(name) {
                processMissCount = 0
            } else {
                processMissCount += 1
                if processMissCount >= 2 {
                    releaseUserSlot(trigger: .conditionMet)
                    persistState()
                }
            }

        case .whileDownloadActive(let idleTimeout):
            // No miss-count grace, deliberately — see
            // `ReleaseCondition.whileDownloadActive`'s doc comment for why:
            // `idleTimeout` is already the slack this condition gets.
            if !downloadProbe(idleTimeout) {
                releaseUserSlot(trigger: .conditionMet)
                persistState()
            }

        case .scheduledWindow(let weekdays, let startMinute, let endMinute):
            if !Self.isWithinScheduledWindow(
                weekdays: weekdays,
                startMinute: startMinute,
                endMinute: endMinute,
                date: Date(),
                calendar: .current
            ) {
                releaseUserSlot(trigger: .conditionMet)
                persistState()
            }
        }
    }

    /// Whether any running process's executable name matches `target`
    /// (case-insensitive, exact). Public so the UI can validate "is that
    /// process even running?" at arm time and warn instead of arming a hold
    /// that releases two ticks later.
    ///
    /// `proc_listallpids`/`proc_name` are the same public libproc APIs
    /// `ProcessCollector` already uses; a full scan is a few hundred
    /// microseconds and only runs while a `.whileProcessRunning` hold is
    /// armed, not on every tick of the app's life.
    public nonisolated static func isProcessRunning(named target: String) -> Bool {
        let wanted = target.lowercased()
        guard !wanted.isEmpty else { return false }

        let expected = proc_listallpids(nil, 0)
        guard expected > 0 else { return false }
        // Headroom for processes spawned between the two calls, matching
        // ProcessCollector's convention.
        var pids = [pid_t](repeating: 0, count: Int(expected) + 32)
        let filled = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard filled > 0 else { return false }

        var nameBuffer = [CChar](repeating: 0, count: 128)
        for index in 0..<Int(filled) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            let length = nameBuffer.withUnsafeMutableBufferPointer { pointer in
                proc_name(pid, pointer.baseAddress, UInt32(pointer.count))
            }
            guard length > 0 else { continue }
            if String(cString: nameBuffer).lowercased() == wanted {
                return true
            }
        }
        return false
    }

    /// Every distinct executable name currently on the process table, in the
    /// exact spelling `isProcessRunning(named:)` matches against, sorted
    /// case-insensitively. Backs the keep-awake card's Process *picker* — the
    /// list of names a `.whileProcessRunning` hold can actually be armed with.
    ///
    /// **Why this lives next to `isProcessRunning(named:)` rather than being
    /// derived from `ProcessCollector`.** These two functions have to agree or
    /// the UI ships a menu whose items fail their own arm-time validation:
    /// the picker offers a name, `start()` calls `isProcessRunning(named:)` on
    /// it, and a disagreement between the two enumerations reads to the user
    /// as "the dropdown listed it and then said it isn't running." So this is
    /// deliberately the *same* scan — same `proc_listallpids`, same
    /// `proc_name`, same 128-byte name buffer (`ProcessCollector` uses
    /// `MAXCOMLEN * 2 + 1`, which truncates longer names differently), same
    /// case-insensitive identity — with the early-exit-on-match removed and
    /// the names collected instead of compared. Agreement by construction,
    /// not by two implementations happening to line up.
    ///
    /// **Why not `ProcessCollector`/`ProcessMonitor`/`SystemSnapshot
    /// .topProcesses` at all.** All three are ranked and *capped* — top-N by
    /// CPU — and `ProcessCollector`'s own doc comment states the exact reason
    /// that disqualifies them here: "`claude` at 0.2% CPU is exactly the row
    /// that never makes a top-8 cut." The dropdown's instance is capped at
    /// `limit: 3`. A picker built on any of them would omit precisely the
    /// idle-but-long-running agent process this trigger was built for.
    /// `ProcessCollector` additionally lives in SystemMetricsKit, which
    /// depends on SentryKit rather than the other way round, so this file
    /// could not call it even if the cap weren't disqualifying.
    ///
    /// De-duplicated case-insensitively, keeping the first spelling
    /// encountered: a name like `mdworker_shared` can hold a dozen PIDs at
    /// once, and a picker that lists it a dozen times is noise. Returns an
    /// empty array (not an error) when the scan finds nothing — callers are
    /// expected to treat that as "no list available" and fall back, the same
    /// honest-nil posture `mostRecentDownloadsModification` takes.
    public nonisolated static func runningProcessNames() -> [String] {
        let expected = proc_listallpids(nil, 0)
        guard expected > 0 else { return [] }
        // Same headroom-for-races convention as `isProcessRunning(named:)`.
        var pids = [pid_t](repeating: 0, count: Int(expected) + 32)
        let filled = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard filled > 0 else { return [] }

        var seen = Set<String>()
        var names: [String] = []
        var nameBuffer = [CChar](repeating: 0, count: 128)
        for index in 0..<Int(filled) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            let length = nameBuffer.withUnsafeMutableBufferPointer { pointer in
                proc_name(pid, pointer.baseAddress, UInt32(pointer.count))
            }
            guard length > 0 else { continue }
            let name = String(cString: nameBuffer)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Pure comparison: given the most recent modification time found under
    /// `~/Downloads` (or `nil` when the directory is empty, missing, or
    /// unreadable), is a download "active" under `.whileDownloadActive`'s
    /// heuristic? Split out from `mostRecentDownloadsModification(in:fileManager:)`
    /// specifically so this decision — "is `mostRecentModification` within
    /// `idleTimeout` of `now`" — is unit-testable with a fabricated clock and
    /// a fabricated timestamp, with no real filesystem access involved. The
    /// directory scan itself is *not* meaningfully unit-testable — it depends
    /// on real write activity in a real `~/Downloads`, which a test can't
    /// fabricate deterministically — so it's exercised only by the smoke-style
    /// checks `isProcessRunning`'s tests already model for the equivalent
    /// libproc scan, not asserted against here.
    public nonisolated static func isDownloadActive(
        mostRecentModification: Date?,
        idleTimeout: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        guard let mostRecentModification else { return false }
        return now.timeIntervalSince(mostRecentModification) <= idleTimeout
    }

    /// Scans `directory` (default `~/Downloads`) non-recursively for the most
    /// recent `contentModificationDate` among its entries — the mtime feed
    /// for `isDownloadActive(mostRecentModification:idleTimeout:now:)`.
    /// Non-recursive on purpose: a download in progress writes directly into
    /// `~/Downloads`, and chasing every user-configured subfolder would widen
    /// this from "a reasonable proxy" (see `ReleaseCondition
    /// .whileDownloadActive`'s doc comment) toward false positives from
    /// unrelated file activity elsewhere in the tree. Returns `nil` (not an
    /// error) for a missing/unreadable directory or one with no readable
    /// entries — `isDownloadActive` already treats `nil` as "not active,"
    /// which is the correct read of "we couldn't find evidence of a
    /// download," not "assume one is happening."
    public nonisolated static func mostRecentDownloadsModification(
        in directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Date? {
        let downloadsURL = directory ?? fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard let downloadsURL,
              let items = try? fileManager.contentsOfDirectory(
                  at: downloadsURL,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else { return nil }
        return items.compactMap { url -> Date? in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.max()
    }

    /// Whether `date` falls inside a `.scheduledWindow` — see that case's
    /// doc comment for the representation. Start-inclusive, end-exclusive
    /// (`[startMinute, endMinute)`), matching `AgentGuardrails
    /// .isWithinQuietHours`'s convention exactly, extended with a weekday
    /// set that quiet hours didn't need. `nonisolated static` and pure (no
    /// `Date()`/`Calendar.current` defaults) for the same reason
    /// `AgentGuardrailsTests` pins `isWithinQuietHours` down with a fixed
    /// calendar and fabricated dates rather than the real clock — see
    /// `PowerControlServiceTests`' schedule tests, which mirror that pattern.
    ///
    /// **Midnight-crossing weekday handling.** When `startMinute > endMinute`
    /// (the window crosses midnight, e.g. Fri 22:00–Sat 07:00), the tail of
    /// the window on the *following* calendar day still belongs to the
    /// *starting* day's weekday — the window is "Friday night," not
    /// "Friday, then separately, unrelated Saturday morning." So a moment at
    /// 03:00 on Saturday is inside the window only if `weekdays` contains
    /// *Friday* (`date`'s weekday minus one, wrapping 1...7). A same-day
    /// window (`startMinute < endMinute`) has no such ambiguity: `date`'s own
    /// weekday is checked directly. `startMinute == endMinute` is a
    /// zero-length window (never active) and an empty `weekdays` set is
    /// never active either, both mirroring `isWithinQuietHours`'s
    /// `start == end` guard.
    public nonisolated static func isWithinScheduledWindow(
        weekdays: Set<Int>,
        startMinute: Int,
        endMinute: Int,
        date: Date,
        calendar: Calendar
    ) -> Bool {
        guard startMinute != endMinute, !weekdays.isEmpty else { return false }
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday else { return false }
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)

        if startMinute < endMinute {
            return weekdays.contains(weekday) && minute >= startMinute && minute < endMinute
        }
        // Crosses midnight — see the doc comment above.
        let previousWeekday = weekday == 1 ? 7 : weekday - 1
        return (weekdays.contains(weekday) && minute >= startMinute)
            || (weekdays.contains(previousWeekday) && minute < endMinute)
    }

    // MARK: - Assertion creation

    /// The one real `IOPMAssertionCreateWithProperties` call, shared by both
    /// slots so the OS-timeout belt-and-braces (see the type doc comment)
    /// can't diverge between them.
    private func createRawAssertion(mode: AwakeMode, duration: TimeInterval?, reason: String) throws -> IOPMAssertionID {
        var props: [String: Any] = [
            kIOPMAssertionTypeKey as String: mode.assertionType,
            kIOPMAssertionNameKey as String: reason,
            kIOPMAssertionLevelKey as String: kIOPMAssertionLevelOn
        ]
        // Belt and braces (plan §10.2) — see the type doc comment for why
        // this is the properties API rather than `...CreateWithName`.
        if let duration, duration > 0 {
            props[kIOPMAssertionTimeoutKey as String] = duration
            props[kIOPMAssertionTimeoutActionKey as String] = kIOPMAssertionTimeoutActionRelease
        }

        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithProperties(props as CFDictionary, &id)
        guard result == kIOReturnSuccess else {
            throw PowerControlError.assertionFailed(result)
        }
        return id
    }

    private func startAssertionInternal(
        mode: AwakeMode,
        duration: TimeInterval?,
        reason: String,
        condition: ReleaseCondition?,
        owner: String? = nil
    ) throws {
        // The `ProFeature.conditionalKeepAwake` gate, before the release
        // below on purpose: a denied conditional arm must not cost the user
        // whatever hold is already running (locked user flips "For" to a
        // conditional trigger over a live timed hold — the arm fails, the
        // timed hold survives). Gating here rather than in
        // `startConditionalAssertion` also covers the cold-start restore
        // re-arm in `reconcileAtColdStart`, whose catch logs, drops, and
        // notifies — so a conditional hold whose license lapsed before a
        // relaunch is dropped loudly, not resurrected. Timed/indefinite
        // arms (`condition == nil`) are never gated.
        if condition != nil, !conditionalKeepAwakeAuthorized() {
            throw PowerControlError.conditionalKeepAwakeLocked
        }
        releaseUserSlot(trigger: .replacedByNewHold) // only ever one per slot

        // "Keep awake for zero (or negative) seconds" must not silently
        // become "keep awake forever": below, a non-positive duration is
        // skipped when building the timeout properties and when computing
        // `expiresAt`, so without this guard it would fall through to an
        // *indefinite* assertion — the exact battery-draining failure mode
        // the reconciliation guards exist to prevent, minted fresh from a
        // degenerate input instead of a stale record. The release above has
        // already run, so the net effect is "nothing held," which is the
        // only honest reading of a zero-length request.
        if let duration, duration <= 0 {
            persistState()
            return
        }

        assertionID = try createRawAssertion(mode: mode, duration: duration, reason: reason)
        assertionGeneration &+= 1
        activeCondition = condition
        conditionSustainedSince = nil
        processMissCount = 0

        let expiresAt: Date? = (duration.flatMap { $0 > 0 ? Date().addingTimeInterval($0) : nil })
        userHold = .active(mode: mode, expiresAt: expiresAt, reason: reason)
        refreshPresentedState()
        openAwakeHold(slot: .user, owner: owner)
        Self.logger.notice("Created keep-awake (user slot): mode=\(mode.rawValue, privacy: .public), duration=\(duration.map { String($0) } ?? "indefinite", privacy: .public)")

        if let duration, duration > 0 {
            // App-level mechanism #2 (see type doc): updates `state`
            // promptly while this process is alive, independent of the
            // OS-level timeout above. The captured generation is what makes
            // an already-fired-but-not-yet-run expiry harmless if a newer
            // assertion has replaced this one in the meantime — see
            // `assertionGeneration`'s doc comment for the race.
            let generation = assertionGeneration
            expiryTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.timedAssertionExpired(generation: generation) }
            }
        }

        persistState() // so we can restore across app relaunch (plan §10.2)
    }

    private func startAgentAssertionInternal(
        mode: AwakeMode,
        duration: TimeInterval?,
        reason: String,
        clientName: String,
        sessionID: String?
    ) throws {
        releaseAgentSlot(trigger: .replacedByNewHold) // only ever one per slot

        // Same zero-length no-op contract as the user slot.
        if let duration, duration <= 0 {
            persistState()
            return
        }

        agentAssertionID = try createRawAssertion(mode: mode, duration: duration, reason: reason)
        agentAssertionGeneration &+= 1

        let expiresAt: Date? = (duration.flatMap { $0 > 0 ? Date().addingTimeInterval($0) : nil })
        agentHold = AgentHold(mode: mode, expiresAt: expiresAt, reason: reason, clientName: clientName, sessionID: sessionID)
        refreshPresentedState()
        openAwakeHold(slot: .agent, owner: sessionID)
        Self.logger.notice("Created keep-awake (agent slot, client \(clientName, privacy: .public)): mode=\(mode.rawValue, privacy: .public), duration=\(duration.map { String($0) } ?? "indefinite", privacy: .public)")

        if let duration, duration > 0 {
            let generation = agentAssertionGeneration
            agentExpiryTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.agentTimedAssertionExpired(generation: generation) }
            }
        }

        persistState()
    }

    // MARK: - Slot teardown (the only IOPMAssertionRelease call sites)

    /// Releases the user slot only. Does not persist — callers batch the
    /// `persistState()` so a release-then-recreate (adjust, replace) writes
    /// once, with the final truth.
    private func releaseUserSlot(trigger: KeepAwakeReleaseTrigger) {
        let hadAssertion = assertionID != 0
        if hadAssertion {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        expiryTimer?.invalidate()
        expiryTimer = nil
        activeCondition = nil
        conditionSustainedSince = nil
        processMissCount = 0
        let wasActive = userHold != .inactive
        userHold = .inactive
        closeAwakeHold(slot: .user)
        refreshPresentedState()
        if hadAssertion || wasActive {
            Self.logger.notice("Released keep-awake (user slot): \(trigger.logDescription, privacy: .public)")
        }
    }

    /// Releases the agent slot only — same contract as `releaseUserSlot`.
    private func releaseAgentSlot(trigger: KeepAwakeReleaseTrigger) {
        let hadAssertion = agentAssertionID != 0
        if hadAssertion {
            IOPMAssertionRelease(agentAssertionID)
            agentAssertionID = 0
        }
        agentExpiryTimer?.invalidate()
        agentExpiryTimer = nil
        let hadHold = agentHold != nil
        agentHold = nil
        closeAwakeHold(slot: .agent)
        refreshPresentedState()
        if hadAssertion || hadHold {
            Self.logger.notice("Released keep-awake (agent slot): \(trigger.logDescription, privacy: .public)")
        }
    }

    /// Recomputes the presented `state` union — see `state`'s doc comment.
    /// Assigned only on change so the popover isn't re-rendered by no-op
    /// writes; genuine transitions still emit through the `@Published`
    /// wrapper, including the documented back-to-back inactive→active pair
    /// during a replace (which is why `AppDelegate` mirrors this with a
    /// `sink` rather than `AsyncPublisher` — see its comment).
    private func refreshPresentedState() {
        let presented: SleepAssertionState
        if case .active = userHold {
            presented = userHold
        } else if let agentHold {
            presented = .active(mode: agentHold.mode, expiresAt: agentHold.expiresAt, reason: agentHold.reason)
        } else {
            presented = .inactive
        }
        if state != presented {
            state = presented
        }
    }

    /// Landing point for the user slot's app-level expiry timer. Releases
    /// only when `generation` still identifies the *current* assertion — a
    /// stale fire (timer went off for assertion N, but assertion N+1 was
    /// started before this ran on the main actor) is a no-op rather than a
    /// silent teardown of the newer assertion. See `assertionGeneration`'s
    /// doc comment.
    ///
    /// **The indefinite guard is a hard invariant, not defensiveness.** An
    /// indefinite hold arms no timer, so in a correct program this method
    /// can never fire for one — but "indefinitely means until the user turns
    /// it off" is exactly the promise a verified field incident broke, so it
    /// is enforced here structurally: even a spurious or buggy expiry
    /// callback cannot end a hold that has no deadline. The regression test
    /// pinning this calls it directly with the *current* generation and
    /// asserts the hold survives.
    ///
    /// `internal` rather than `private` so tests can drive the stale case
    /// deterministically; not part of the public API.
    func timedAssertionExpired(generation: UInt64) {
        guard generation == assertionGeneration else { return }
        guard case .active(_, .some, _) = userHold else { return }
        releaseUserSlot(trigger: .timedExpiry)
        persistState()
    }

    /// The agent slot's counterpart to `timedAssertionExpired(generation:)`,
    /// with the same stale-generation and no-deadline guards. This firing
    /// touches only the agent slot — an agent session's window running out
    /// can never take the user's hold down with it, which is the exact
    /// separate-intents invariant the two-slot design exists for.
    func agentTimedAssertionExpired(generation: UInt64) {
        guard generation == agentAssertionGeneration else { return }
        guard agentHold?.expiresAt != nil else { return }
        releaseAgentSlot(trigger: .timedExpiry)
        persistState()
    }

    // MARK: - Notification handlers

    private func handleAppTermination(bundleIdentifier: String?) {
        guard let bundleIdentifier,
              case .whileAppRunning(let watched) = activeCondition,
              watched == bundleIdentifier else { return }
        releaseUserSlot(trigger: .conditionMet)
        persistState()
    }

    // MARK: - Reconciliation

    /// Wake-path reconciliation: the process never died, so the live
    /// in-process slots are the authority and the persisted record is
    /// subordinate to them. Two jobs only:
    ///
    /// 1. **Prompt expiry.** A timed hold whose deadline passed while the
    ///    Mac slept is released now rather than whenever the late-firing
    ///    `Timer` gets around to it (the OS-level timeout has usually
    ///    already released the real assertion; this keeps `state` honest
    ///    promptly).
    /// 2. **Record repair.** If a hold is live but the record is missing,
    ///    inactive, or written by some other process, the *record* is what's
    ///    wrong — so it is rewritten from live state, loudly.
    ///
    /// **What this deliberately no longer does: release-and-recreate.** The
    /// previous implementation re-armed every live hold from the record on
    /// every wake, on a premise its own doc comment had already corrected —
    /// sleep does *not* destroy an `IOPMAssertion`; only process death does.
    /// That flap was worse than wasteful, it was the second half of a
    /// verified silent-shutoff: a second same-bundle-id Sentry process (a
    /// Debug/test-host run) cleared the shared record while the installed
    /// app slept holding a live indefinite assertion, and the wake flap's
    /// "no record → release" branch then tore the live hold down with no
    /// log, no notification, and a toggle that silently read OFF.
    /// A persisted record is bookkeeping *about* the assertion; treating it
    /// as the authority over a hold this process verifiably still owns had
    /// it exactly backwards. (It also bumped generations and re-tagged
    /// ownership on every wake for nothing — machinery the two-slot design
    /// deletes.)
    ///
    /// **When nothing is live in this process, wake touches nothing.** An
    /// active record found here was necessarily written by another process
    /// (this process's own bookkeeping is complete for its lifetime), and
    /// adjudicating other processes' records is cold start's job, where
    /// `ownerPID` liveness can be checked against a process that isn't us.
    /// Resurrecting or clearing it from the wake path is precisely the
    /// cross-instance meddling that caused the incident.
    private func reconcileAfterWake() {
        if case .active(_, .some(let expiresAt), _) = userHold, expiresAt <= Date() {
            releaseUserSlot(trigger: .timedExpiry)
        }
        if let hold = agentHold, let expiresAt = hold.expiresAt, expiresAt <= Date() {
            releaseAgentSlot(trigger: .timedExpiry)
        }

        // The entitlement re-check the old release-and-recreate wake path
        // performed implicitly: recreating went through the gated start, so
        // a license that lapsed while the Mac slept dropped the conditional
        // hold. Keeping live holds without recreating (the incident fix) is
        // right for the free tiers, but it must not quietly grandfather a
        // conditional hold past a gate that would now refuse it — checked
        // explicitly here instead, and loudly, per the no-silent-flips rule.
        // The record is cleared outright rather than persisted-as-inactive
        // so the next cold start doesn't re-adjudicate a hold this branch
        // already refused.
        if userHold != .inactive, activeCondition != nil, !conditionalKeepAwakeAuthorized() {
            Self.logger.notice("Conditional keep-awake is no longer authorized at wake; dropping the hold rather than resurrecting it past the gate.")
            notifyPolicyRelease(
                title: "Keep Awake turned off",
                body: "Your conditional keep-awake rule needs Sentry Pro, so it wasn't resumed after sleep. Timed and indefinite keep-awake stay free."
            )
            releaseUserSlot(trigger: .restoreFailed)
            clearPersistedRecord()
        }

        let anythingLive = userHold != .inactive || agentHold != nil
        guard anythingLive else { return }

        // Record repair: live state is the truth; make the record say so.
        // Detect-and-log before the rewrite so a clobbered record leaves a
        // trace (the incident above was diagnosable only from pmset).
        let record = loadPersistedRecord()
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let recordIsHealthy = record.map { candidate in
            (candidate.ownerPID == nil || candidate.ownerPID == ourPID)
                && (candidate.state != .inactive || candidate.agentHold != nil)
        } ?? false
        if !recordIsHealthy {
            Self.logger.error("Persisted keep-awake record was missing, inactive, or foreign at wake while a live hold exists — repairing it from live state instead of releasing the hold. (A second Sentry instance sharing this defaults domain is the known cause.)")
        }
        persistState()
    }

    /// Cold-start reconciliation: the process just started, so there is no
    /// live in-process state — only the record. Restores what the record
    /// authorizes and this process can honestly own:
    ///
    /// - **A record owned by another live Sentry process is left strictly
    ///   alone** — not restored (that would double-hold something another
    ///   instance is managing), not discarded (the incident this guards
    ///   against: a Debug/test-host instance cold-starting and clearing the
    ///   installed app's live record out from under it). Ownership is the
    ///   recorded PID plus the recorded executable name — the name is the
    ///   PID-reuse guard, because after a reboot the bare PID is routinely
    ///   someone else entirely, and blocking the user's restore on a reused
    ///   number would silently break the relaunch promise below.
    /// - **The user's timed hold restores with its remaining window** (plan
    ///   §10.4's "expiry still in the future"), and an expired one is
    ///   dropped without minting a fresh window.
    /// - **The user's indefinite (and conditional) hold now restores too.**
    ///   This reverses the previous deliberate discard, and the reversal is
    ///   itself deliberate: "Indefinitely" is the user's *standing* intent —
    ///   "keep this Mac awake until I turn it off" — and a quit or reboot is
    ///   not the user turning it off. The old behavior's stated fear
    ///   (re-asserting forever on every login-item launch with nothing on
    ///   screen) conflated *restoring* with *hiding*: the dropdown, the
    ///   menu-bar rule, and the widgets all surface a live hold, and the
    ///   restore logs loudly below. Between the two failure modes — a Mac
    ///   that keeps honoring a switch the user set and can see, versus a
    ///   switch that silently un-sets itself whenever the app restarts (the
    ///   exact "defeats the whole point" complaint that reopened this file)
    ///   — the second is the lie. Conditional holds ride the same
    ///   reasoning and additionally re-arm through the entitlement gate;
    ///   a lapsed license drops them loudly via `policyReleaseNotifier`.
    /// - **An agent's hold restores only when timed and unexpired.** An
    ///   agent's *indefinite* hold does not survive a cold start: the
    ///   requesting session is keyed to a live MCP connection that did not
    ///   survive our process, and resurrecting an unbounded hold nobody
    ///   living asked for is the battery-in-a-bag failure mode — the user
    ///   never chose it, so the user's-standing-intent argument above does
    ///   not transfer. It is dropped with a log line naming the client.
    private func reconcileAtColdStart() {
        guard let record = loadPersistedRecord() else { return }

        let ourPID = ProcessInfo.processInfo.processIdentifier
        if let ownerPID = record.ownerPID,
           ownerPID != ourPID,
           Self.isProcessAlive(pid: ownerPID, named: record.ownerProcessName) {
            Self.logger.notice("Persisted keep-awake record belongs to another live Sentry instance (pid \(ownerPID, privacy: .public)); leaving it untouched.")
            return
        }

        // User slot.
        if case .active(let mode, let expiresAt, let reason) = record.state {
            if let expiresAt, expiresAt <= Date() {
                Self.logger.notice("Persisted timed keep-awake expired while the app wasn't running; not restoring it.")
            } else {
                let remaining = expiresAt.map { $0.timeIntervalSince(Date()) }
                do {
                    try startAssertionInternal(mode: mode, duration: remaining, reason: reason, condition: record.condition)
                    if expiresAt == nil {
                        Self.logger.notice("Re-asserted the user's indefinite keep-awake across a relaunch — their standing intent until they turn it off.")
                    }
                } catch {
                    // Best-effort restore (P5) — if the arm is refused, don't
                    // leave `state` claiming a hold exists that doesn't, and
                    // don't be quiet about a hold the user believes is on.
                    Self.logger.error("Failed to restore the user's keep-awake: \(error.localizedDescription, privacy: .public)")
                    notifyPolicyRelease(
                        title: "Keep Awake didn't resume",
                        body: "Sentry couldn't restore your keep-awake session after relaunch: \(error.localizedDescription)"
                    )
                    releaseUserSlot(trigger: .restoreFailed)
                }
            }
        }

        // Agent slot.
        if let agent = record.agentHold {
            if let expiresAt = agent.expiresAt, expiresAt > Date() {
                do {
                    try startAgentAssertionInternal(
                        mode: agent.mode,
                        duration: expiresAt.timeIntervalSince(Date()),
                        reason: agent.reason,
                        clientName: agent.clientName,
                        sessionID: agent.sessionID
                    )
                } catch {
                    Self.logger.error("Failed to restore \(agent.clientName, privacy: .public)'s keep-awake: \(error.localizedDescription, privacy: .public)")
                    releaseAgentSlot(trigger: .restoreFailed)
                }
            } else if agent.expiresAt == nil {
                Self.logger.notice("Dropping \(agent.clientName, privacy: .public)'s indefinite keep-awake at cold start — its session did not survive the relaunch.")
            }
        }

        // Rewrite the record as this process's own truth — restored holds
        // get our PID; anything dropped above stops being claimed.
        persistState()
    }

    /// Whether `pid` is a live process whose executable name matches
    /// `expectedName` — the "is the record's owner still running" check.
    /// `kill(pid, 0)` is the liveness probe (0 = alive, `EPERM` = alive but
    /// not signalable, `ESRCH` = gone); the name comparison is the PID-reuse
    /// guard.
    ///
    /// The name is read via `proc_name` first and `sysctl(KERN_PROC_PID)`'s
    /// `p_comm` second. The fallback is load-bearing, not belt-and-braces:
    /// `proc_name` needs privilege for another user's process, so with it
    /// alone every root-owned process "fails" the name check and reads as a
    /// recycled PID — the distinction this guard exists to draw would be an
    /// artifact of privilege, not of reality. `p_comm` is readable by anyone
    /// for any process; its one cost is truncation at 16 bytes (MAXCOMLEN),
    /// so a truncated read matches by prefix.
    ///
    /// A name unreadable through *both* routes answers **false** ("not our
    /// owner"): the same-bundle-id siblings this guard protects run as the
    /// same user and are always readable, and answering "alive" for an
    /// unreadable stranger wearing a recycled PID would permanently block
    /// the user's own restore after a reboot.
    nonisolated static func isProcessAlive(pid: Int32, named expectedName: String?) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0 && errno != EPERM {
            return false
        }
        guard let expectedName, !expectedName.isEmpty else { return true }

        var buffer = [CChar](repeating: 0, count: 128)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_name(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        if length > 0 {
            return String(cString: buffer).lowercased() == expectedName.lowercased()
        }

        guard let comm = Self.sysctlProcessName(pid: pid) else { return false }
        let seen = comm.lowercased()
        let expected = expectedName.lowercased()
        // p_comm is capped at MAXCOMLEN (16) bytes; a read that hits the cap
        // may be a truncation of the real name, so match by prefix there.
        return seen == expected || (comm.utf8.count >= 16 && expected.hasPrefix(seen))
    }

    /// The executable name from `sysctl`'s `kinfo_proc.kp_proc.p_comm` —
    /// the unprivileged read that works for any user's process. `nil` when
    /// the PID doesn't resolve (the `p_pid` echo check guards against
    /// `sysctl` succeeding with a zeroed struct for a vanished process).
    nonisolated private static func sysctlProcessName(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size > 0,
              info.kp_proc.p_pid == pid
        else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return name.isEmpty ? nil : name
    }

    private func notifyPolicyRelease(title: String, body: String) {
        // Never silent: the os_log fallback fires whether or not the
        // composition root has wired a real notifier — see
        // `policyReleaseNotifier`'s doc comment.
        Self.logger.error("Policy release: \(title, privacy: .public) — \(body, privacy: .public)")
        policyReleaseNotifier?(title, body)
    }

    // MARK: - Persistence (UserDefaults — small key-value state, not time series)

    private func persistState() {
        let processInfo = ProcessInfo.processInfo
        let record = PersistedRecord(
            state: userHold,
            condition: activeCondition,
            agentOwnerClientName: nil,
            agentHold: agentHold.map {
                PersistedAgentHold(
                    mode: $0.mode,
                    expiresAt: $0.expiresAt,
                    reason: $0.reason,
                    clientName: $0.clientName,
                    sessionID: $0.sessionID
                )
            },
            ownerPID: processInfo.processIdentifier,
            ownerProcessName: processInfo.processName
        )
        do {
            let data = try JSONEncoder().encode(record)
            defaults.set(data, forKey: Self.defaultsKey)
        } catch {
            // Losing the persisted flag only costs us the relaunch/wake
            // restore — never worth throwing out of a method the UI calls
            // freely (P5).
            Self.logger.error("Failed to persist sleep-assertion state: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Loads and *normalizes* the record: a v1 agent-tagged record (see
    /// `PersistedRecord`'s layout comment) comes back with its hold moved
    /// into the `agentHold` slot and `state` set `.inactive`, so every
    /// caller reasons about exactly one layout.
    private func loadPersistedRecord() -> PersistedRecord? {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return nil }
        guard var record = try? JSONDecoder().decode(PersistedRecord.self, from: data) else { return nil }
        if let legacyOwner = record.agentOwnerClientName {
            if case .active(let mode, let expiresAt, let reason) = record.state, record.agentHold == nil {
                record.agentHold = PersistedAgentHold(
                    mode: mode,
                    expiresAt: expiresAt,
                    reason: reason,
                    clientName: legacyOwner,
                    sessionID: nil
                )
            }
            record.state = .inactive
            record.agentOwnerClientName = nil
        }
        return record
    }

    private func clearPersistedRecord() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    // MARK: - Awake-hold ledger (agent-session attribution pass)

    /// Every assertion interval this process has held, tagged with the
    /// requesting session when the request came over MCP — the data source
    /// for `AgentSessionReport.awakeSeconds` ("how long did *that* agent
    /// session keep this Mac awake"). At most one entry is open (`end ==
    /// nil`) *per slot* — the two-slot successor to the old "at most one
    /// open entry" invariant, since the user's hold and an agent's can now
    /// genuinely overlap and both intervals are real held time. In-memory
    /// only, deliberately — see `AgentAwakeHold`'s doc comment
    /// (`SentryKit/Services/AgentSessionReport.swift`) for why a durable
    /// ledger would overclaim.
    public private(set) var awakeHolds: [AgentAwakeHold] = []

    /// Closed holds retained before the oldest are dropped — bounds memory
    /// for a machine that toggles keep-awake constantly for months. Far more
    /// than any dashboard window or session report will ever look back at
    /// within one app run.
    private static let maxAwakeHoldEntries = 512

    private enum HoldSlot: Hashable { case user, agent }

    /// Index into `awakeHolds` of each slot's open entry, maintained across
    /// the trim below. If an open entry ever ages past the trim boundary
    /// (one slot held for months while the other churns hundreds of holds),
    /// its ledger row is sacrificed to the memory bound — the hold itself is
    /// untouched, and the report clamps to its query window anyway.
    private var openHoldIndices: [HoldSlot: Int] = [:]

    private func openAwakeHold(slot: HoldSlot, owner: String?) {
        awakeHolds.append(AgentAwakeHold(owner: owner, start: Date(), end: nil))
        openHoldIndices[slot] = awakeHolds.count - 1
        if awakeHolds.count > Self.maxAwakeHoldEntries {
            let overflow = awakeHolds.count - Self.maxAwakeHoldEntries
            awakeHolds.removeFirst(overflow)
            openHoldIndices = openHoldIndices.compactMapValues { index in
                index - overflow >= 0 ? index - overflow : nil
            }
        }
    }

    /// Closes `slot`'s open ledger entry, if any. Idempotent, like the slot
    /// teardowns that call it.
    private func closeAwakeHold(slot: HoldSlot) {
        guard let index = openHoldIndices.removeValue(forKey: slot),
              awakeHolds.indices.contains(index),
              awakeHolds[index].end == nil else { return }
        let open = awakeHolds[index]
        awakeHolds[index] = AgentAwakeHold(owner: open.owner, start: open.start, end: Date())
    }

    // MARK: - Agent-held assertion API

    /// The client name holding the agent slot, or `nil` when no agent hold
    /// is active. With the hold living in its own slot, this is a plain
    /// read — the generation-tag matching the old shared-assertion design
    /// needed (a stale tag must not stick to a *different* assertion) has no
    /// equivalent failure mode left to guard.
    public var agentAssertionOwner: String? {
        agentHold?.clientName
    }

    /// Starts an agent-slot hold — the entry point `MCPXPCService.keepAwake`
    /// uses so the kill switch and guardrail auto-revocation can tell an
    /// agent's hold from the user's own. The user's hold, if any, is
    /// **untouched**: the two intents are separate assertions (see the type
    /// doc comment), so an agent asking for keep-awake neither replaces nor
    /// inherits whatever the user has running. `sessionID` additionally tags
    /// the awake-hold ledger entry (see `openAwakeHold`), so the same call
    /// feeds both consumers of ownership: the kill switch / guardrails (by
    /// client name) and `AgentSessionReport`'s held-time attribution (by
    /// session). One entry point, two tags, no way for them to drift.
    public func startAgentAssertion(
        mode: AwakeMode,
        duration: TimeInterval?,
        reason: String,
        clientName: String,
        sessionID: String? = nil
    ) throws {
        try startAgentAssertionInternal(
            mode: mode,
            duration: duration,
            reason: reason,
            clientName: clientName,
            sessionID: sessionID
        )
    }

    /// Releases the agent slot only if an agent holds it — and, when
    /// `clientName` is given, only if *that* agent holds it. Returns whether
    /// anything was released, so callers (kill switch, per-agent stop,
    /// guardrail auto-revoke, the MCP `release_awake` tool) can decide
    /// whether there is a revocation to announce. A user-started assertion
    /// is structurally unreachable from this method: terminating agents
    /// must not cost the user their own hold.
    @discardableResult
    public func releaseAgentAssertion(ownedBy clientName: String? = nil) -> Bool {
        guard let owner = agentAssertionOwner else { return false }
        if let clientName, owner != clientName { return false }
        releaseAgentSlot(trigger: .agentRevoked)
        persistState()
        return true
    }

    /// `releaseAgentAssertion(ownedBy:)`'s sibling for the agent's *own*
    /// `release_awake` request — identical teardown, logged as the agent's
    /// choice rather than a revocation so the two are distinguishable in
    /// the field.
    @discardableResult
    public func releaseAgentAssertionAtAgentRequest() -> Bool {
        guard agentHold != nil else { return false }
        releaseAgentSlot(trigger: .agentRequest)
        persistState()
        return true
    }
}
#endif
