#if os(iOS)
import ActivityKit
import Foundation
import os

// MARK: - KeepAwakeActivityPresenter: the only code in this project that calls ActivityKit

/// Carries out a `KeepAwakeActivityAction` — the request/update/end calls
/// ActivityKit actually wants — and nothing else. Every decision about
/// *whether* to do any of it was already made by
/// `KeepAwakeActivityLifecycle`, in a file that compiles on macOS and is
/// therefore covered by `SentryTests`.
///
/// **Why this is in `SentryKit` and not in the phone app.** Two processes
/// drive the same activity. `SentryMobile` owns the session lifecycle
/// (`KeepAwakeActivityController`); `EndKeepAwakeIntent` — a
/// `LiveActivityIntent` compiled into both the app and
/// `SentryWidgetExtension` — has to update or end the very same activity
/// when its End button fails or succeeds. Two implementations of "find the
/// running activity and end it" is exactly one too many for a feature whose
/// entire failure mode is a surface that disagrees with reality, so both go
/// through here.
///
/// **Why there is at most one activity, ever.** A keep-awake hold is a
/// property of one Mac, and `AppDataSource` supports exactly one Mac (its
/// own documented simplification). `start(_:for:)` ends any pre-existing
/// activity before requesting a new one rather than trusting that invariant
/// — a stray second activity would be a second Lock Screen row making claims
/// nothing is updating.
public enum KeepAwakeActivityPresenter {

    private static let log = Logger(subsystem: "dev.malekswilam.sentry.mobile", category: "KeepAwakeLiveActivity")

    /// Whether the system will let this app run Live Activities at all —
    /// the user's per-app switch in Settings, which is *not* the same thing
    /// as this app's own opt-out (`SettingsTabView`'s toggle). Both have to
    /// be true; this one is the OS's answer and cannot be overridden.
    public static var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Every keep-awake activity this app currently has running. Plural for
    /// the same reason `start` ends what it finds: the invariant is enforced
    /// here rather than assumed.
    public static var activities: [Activity<KeepAwakeActivityAttributes>] {
        Activity<KeepAwakeActivityAttributes>.activities
    }

    /// The state currently on the Lock Screen, or `nil` if nothing is
    /// running.
    ///
    /// This is what makes surviving a process kill work: ActivityKit keeps
    /// activities alive across app termination, so on the next launch the
    /// controller reads what is *actually* on screen from the system rather
    /// than from any state of its own, hands it to
    /// `KeepAwakeActivityLifecycle.next(showing:reported:isEnabled:now:)`,
    /// and gets back the same verdict it would have reached had it never
    /// been killed — including "end this, its deadline passed while you were
    /// dead," which needs no Mac to be reachable.
    public static var currentState: KeepAwakeActivityState? {
        activities.first?.content.state
    }

    // MARK: - Applying a lifecycle action

    /// Performs `action`. `deviceName` and `startedAt` are only consulted
    /// when starting — they are the immutable half of the activity.
    public static func apply(
        _ action: KeepAwakeActivityAction,
        deviceName: String,
        startedAt: Date,
        now: Date,
        isMacReachable: Bool
    ) async {
        switch action {
        case .none:
            return
        case .start(let state):
            await start(state, deviceName: deviceName, startedAt: startedAt, now: now, isMacReachable: isMacReachable)
        case .update(let state):
            await update(to: state, now: now, isMacReachable: isMacReachable)
        case .end(let state):
            await end(showing: state, now: now)
        }
    }

    private static func start(
        _ state: KeepAwakeActivityState,
        deviceName: String,
        startedAt: Date,
        now: Date,
        isMacReachable: Bool
    ) async {
        guard areActivitiesEnabled else { return }
        // Enforce the single-activity invariant rather than assume it.
        for activity in activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        let attributes = KeepAwakeActivityAttributes(deviceName: deviceName, startedAt: startedAt)
        do {
            _ = try Activity.request(
                attributes: attributes,
                content: content(for: state, now: now, isMacReachable: isMacReachable),
                // `nil`, and this is the architectural centre of the whole
                // feature rather than an omission. A push type means APNs,
                // which means a server this project does not have and has
                // publicly promised not to have. Everything the Lock Screen
                // shows is therefore either a fact carried inside the
                // content (a deadline) or rendered locally by the system
                // from one (`Text(timerInterval:)`), and everything that
                // could go out of date is governed by `staleDate` instead.
                pushType: nil
            )
        } catch {
            // Requesting can fail for reasons entirely outside this app's
            // control — the user disabled Live Activities between the check
            // above and this call, or the system's per-app budget is full.
            // There is no honest fallback presentation for "the Lock Screen
            // refused us", and inventing one (a local notification, say)
            // would be a different feature the user did not ask for.
            log.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func update(to state: KeepAwakeActivityState, now: Date, isMacReachable: Bool) async {
        guard let activity = activities.first else { return }
        await activity.update(content(for: state, now: now, isMacReachable: isMacReachable))
    }

    /// Ends every running activity, showing `state`'s final frame.
    ///
    /// `.immediate`, not `.default`. `.default` leaves the ended activity on
    /// the Lock Screen for up to four hours, which for most apps is a
    /// courtesy — "your delivery arrived" is worth still being there when
    /// you next look. Here it is the exact failure this branch exists to
    /// prevent: a row that says a Mac is being kept awake, sitting on a Lock
    /// Screen hours after the hold released, with nothing able to correct it
    /// because there is no server to push a correction from. The session is
    /// over; the surface goes with it.
    private static func end(showing state: KeepAwakeActivityState, now: Date) async {
        let final = ActivityContent(state: state, staleDate: now)
        for activity in activities {
            await activity.end(final, dismissalPolicy: .immediate)
        }
    }

    // MARK: - End-button outcomes

    /// Applies the result of an End attempt made from the Lock Screen or the
    /// Dynamic Island.
    ///
    /// The branch is `KeepAwakeActivityState.afterEndAttempt(_:)`'s, not
    /// this function's: a confirmed release ends the activity, and every
    /// other outcome keeps it exactly as it was with a failure sentence
    /// attached. See that method for why a failed End must never dismiss the
    /// activity — a Live Activity that vanishes on tap is the most emphatic
    /// success report this app is capable of making.
    public static func applyEndOutcome(
        _ outcome: KeepAwakeCommandOutcome,
        activityID: String?,
        now: Date = Date()
    ) async {
        let targets = activityID.map { id in activities.filter { $0.id == id } } ?? activities
        for activity in targets {
            guard let annotated = activity.content.state.afterEndAttempt(outcome) else {
                await activity.end(
                    ActivityContent(state: activity.content.state, staleDate: now),
                    dismissalPolicy: .immediate
                )
                continue
            }
            // `staleDate: now` — the phone just tried to talk to the Mac and
            // did not get a confirmation, so by definition it has no current
            // knowledge to present at full confidence. The system's aged
            // treatment plus the failure sentence say the same thing twice,
            // which is the right amount for a claim about a machine nobody
            // can currently hear from.
            await activity.update(ActivityContent(state: annotated, staleDate: now))
        }
    }

    /// Ends everything, unconditionally — the opt-out path, and the
    /// belt-and-braces cleanup for a bundle that somehow ended up with more
    /// activities than the invariant allows.
    public static func endAll(now: Date = Date()) async {
        for activity in activities {
            await activity.end(
                ActivityContent(state: activity.content.state, staleDate: now),
                dismissalPolicy: .immediate
            )
        }
    }

    // MARK: - Content

    private static func content(
        for state: KeepAwakeActivityState,
        now: Date,
        isMacReachable: Bool
    ) -> ActivityContent<KeepAwakeActivityState> {
        ActivityContent(
            state: state,
            staleDate: state.staleDate(asOf: now, isMacReachable: isMacReachable)
        )
    }
}
#endif
