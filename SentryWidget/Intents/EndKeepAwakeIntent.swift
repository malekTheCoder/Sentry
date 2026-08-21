// MARK: - iOS-only: there is no Lock Screen to put a button on elsewhere

// `SentryWidget/` is one source directory compiled by *three* targets — the
// iOS widget extension, the macOS widget extension, and (for this file
// alone, see `project.yml`) the iPhone app. ActivityKit and
// `LiveActivityIntent` exist on none of the macOS SDKs this project builds
// against, and `@available` would not help: the declarations still have to
// type-check against a macOS 14 SDK that has never heard of them. Same
// compile-time fence, same reason, as `MacAwakeControlWidget.swift` next
// door.
#if os(iOS)

import ActivityKit
import AppIntents
import Foundation
import SentryKit

// MARK: - EndKeepAwakeIntent

/// The Live Activity's End button: releases the Mac's keep-awake hold from
/// the Lock Screen or the Dynamic Island, without unlocking the phone and
/// without opening the app.
///
/// **Why this file is compiled into two targets.** `LiveActivityIntent` is
/// documented as being performed in the *containing app's* process rather
/// than the widget extension's, which means the app's binary has to contain
/// the intent — while the extension's binary also has to, because that is
/// where `Button(intent:)` names the type. Adding one file to a second
/// target is Apple's own answer to this, and it is why the implementation
/// below touches nothing target-specific: no `AppDataSource`, no
/// `WidgetSnapshotStore`, only `SentryKit` symbols that both binaries link.
/// The alternatives were worse. Declaring it twice would put a control
/// surface's failure handling in two places that can drift — the exact
/// disease `KeepAwakeRequest` was created to cure for the keep-awake
/// *encoding*. Declaring it only in the extension would rely on the system
/// falling back to running it there, which is not what the API contract
/// says.
///
/// **Why it does not go through `AppDataSource.shared`.** Because it cannot:
/// half its copies run in an app extension, a separate process with no
/// access to the app's singleton and no way to import the app's target at
/// all. `KeepAwakeCommandSender` (`SentryKit/Sync/KeepAwakeCommandSender.swift`)
/// is the shared substitute, and it sends a byte-identical
/// `releaseAwake` `ControlCommand` — same command type, same empty
/// parameters, same five-minute expiry — to the one every other release
/// surface sends: `ReleaseAwakeIntent` for Siri, `SleepStatusCard`'s "End
/// Now" button in the app, `ToggleMacAwakeIntent` for Control Center. The
/// Mac's `LocalCommandExecutor` cannot tell which surface a release came
/// from, which is the point.
///
/// **What happens when the Mac is unreachable** — the requirement this
/// intent is most likely to be judged on. Nothing optimistic. The activity
/// is *not* dismissed, the hold stays described exactly as it was, and a
/// sentence naming the actual failure appears underneath it
/// (`KeepAwakeCommandOutcome.failureMessage`), with the activity marked
/// stale so the system's own aged treatment says the same thing a second
/// way. All four non-success outcomes stay distinguishable — no Mac to send
/// to, the send threw, sent-but-silent, and the Mac actively declined are
/// four different things that happened, and collapsing them into one
/// "couldn't end it" is how a user ends up power-cycling a Mac that was
/// answering fine and simply said no. This is `SentryIntents
/// .sendAndDescribe(_:whenCompleted:)`'s honesty rule, transplanted to a
/// surface that has room for one line instead of a spoken sentence.
struct EndKeepAwakeIntent: LiveActivityIntent {

    static var title: LocalizedStringResource = "End Mac Keep-Awake"

    static var description = IntentDescription(
        "Releases your Mac's keep-awake hold from the Lock Screen. Needs Sentry open on a Mac on the same Wi-Fi network."
    )

    /// Not offered in Shortcuts or to Siri. `ReleaseAwakeIntent`
    /// (`SentryMobile/Intents/SentryIntents.swift`) is already the
    /// discoverable, phrase-registered way to ask for this, and it speaks a
    /// full spoken outcome; this one exists to be wired to a button whose
    /// context is a specific running activity, and it would be a confusing
    /// duplicate in a list of phrases.
    static var isDiscoverable: Bool { false }

    /// The activity the button belongs to. Passed rather than inferred so
    /// the outcome lands on the row the user actually tapped — the
    /// single-activity invariant `KeepAwakeActivityPresenter` enforces makes
    /// this belt-and-braces today, but "update whatever activity happens to
    /// be first" is the kind of shortcut that turns into the wrong row the
    /// moment the invariant changes.
    @Parameter(title: "Activity")
    var activityID: String

    init() {}

    init(activityID: String) {
        self.activityID = activityID
    }

    func perform() async throws -> some IntentResult {
        let outcome = await KeepAwakeCommandSender.shared.send(KeepAwakeRequest.releaseCommand())
        await KeepAwakeActivityPresenter.applyEndOutcome(outcome, activityID: activityID)
        // Deliberately no thrown error, unlike `ToggleMacAwakeIntent`. A
        // thrown `perform()` is meaningful for a `SetValueIntent` because
        // Control Center reverts the toggle in response; a Live Activity
        // button has no state to revert, and the system's error presentation
        // for a Lock Screen intent is a transient alert that the user may
        // never see. The failure is written into the activity itself
        // instead, where it stays until the Mac says something that
        // supersedes it.
        return .result()
    }
}

#endif
