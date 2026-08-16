import Foundation

// MARK: - KeepAwakeRequest: the one spelling of a remote keep-awake ask

/// Builds the `parametersJSON` for a `keepAwake` `ControlCommand`, and
/// answers the one question every remote surface phrasing its outcome has
/// to get right: *is this request indefinite?*
///
/// **Why this exists.** Four surfaces construct the same `keepAwake`
/// command — the iPhone Siri intent (`SentryMobile/Intents/
/// SentryIntents.swift`), the Watch Siri intent and the Watch app's own
/// Keep Awake page (`SentryWatch/Intents/SentryWatchIntents.swift`,
/// `SentryWatch/ContentView.swift`), and the Control Center toggle
/// (`SentryWidget/Intents/MacAwakeControlWidget.swift`). Before this type,
/// each spelled the JSON by hand, and they had already drifted on the case
/// that matters: the Watch app's page carefully *omitted* `durationSeconds`
/// for an indefinite hold, while both Siri intents sent an explicit
/// `"durationSeconds":0` — which only means "indefinite" because
/// `LocalCommandExecutor.executeKeepAwake`'s `> 0` guard happens to coerce
/// it to `nil`. `ContentView.send(_:)`'s comment called that exact shape
/// "right answer, wrong reason — and it would stop being right the moment
/// either side changed"; a shared encoder is that argument promoted from a
/// warning comment on one caller to the behavior of all of them. Worse,
/// both intents then *spoke* the wrong reason: "Your Mac will stay awake
/// for 0 minutes," for a hold that in fact has no end. `isIndefinite`
/// exists so a caller's success sentence branches on the same predicate
/// the wire encoding branched on, and the two can no longer disagree.
///
/// **Why `minutes <= 0` means indefinite rather than being rejected.** It
/// is the contract the Mac's own Siri intent already ships ("0 keeps it
/// awake until you release it" — `KeepMacAwakeIntent.durationMinutes`'s
/// parameter description) and the reading `MCPXPCService.keepAwake` gives
/// a non-positive `durationSeconds` over MCP. One meaning for zero across
/// every surface, or Siri on two devices answers the same utterance two
/// different ways. Negatives fold into the same case: there is no coherent
/// "keep awake for −5 minutes" to preserve, and the Mac-side zero-duration
/// guard (`startAssertionInternal`) exists precisely because a degenerate
/// duration must not be forwarded in the hope someone downstream handles it.
///
/// **Why `mode` is fixed at `systemOnly`.** Every remote surface listed
/// above already hardcodes it: a phone, watch, or Control Center tap can't
/// see the Mac's display, so "keep the *system* up, let the display do as
/// it likes" is the only mode a remote requester can honestly want.
/// Choosing `displayAndSystem` is a decision for someone looking at the
/// screen they're keeping on — the Mac's own dropdown and Siri intent,
/// which take a real mode parameter and don't come through here.
public enum KeepAwakeRequest {

    /// Whether a request for this many minutes means "until released."
    /// The predicate both the wire encoding below and every caller's
    /// success phrasing must share — see the type doc comment.
    public static func isIndefinite(minutes: Int) -> Bool {
        minutes <= 0
    }

    /// The `parametersJSON` for a `keepAwake` `ControlCommand` holding the
    /// Mac awake for `minutes` — or indefinitely, spelled by *omitting*
    /// `durationSeconds` entirely rather than sending a zero the Mac has to
    /// interpret (see the type doc comment for why the omission is the
    /// contract and the zero was a coincidence).
    public static func parametersJSON(minutes: Int) -> String {
        isIndefinite(minutes: minutes)
            ? #"{"mode":"systemOnly"}"#
            : #"{"durationSeconds":\#(minutes * 60),"mode":"systemOnly"}"#
    }
}
