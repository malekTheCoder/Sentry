import Foundation

// MARK: - Read-side honesty for a SleepAssertionState observed at a distance

/// Display-side judgments about a `SleepAssertionState` that reached a
/// surface *other than* the live `PowerControlService` that minted it — the
/// iPhone dashboard card (a snapshot that crossed Wi-Fi), the home-screen
/// widgets and Control Center toggle (an App-Group cache that may be hours
/// old), the Watch relay (two hops stale). A new file rather than an
/// addition to `SleepAssertionState.swift` so the model type itself stays
/// exactly the small Codable value the service owns; nothing here is
/// service logic, and nothing here may ever *mutate* an assertion.
///
/// **The one claim a stale reading can make with certainty.** A timed hold
/// carries its own end inside the value: `PowerControlService`'s type doc
/// commits to arming the OS-level `kIOPMAssertionTimeoutKey`/
/// `kIOPMAssertionTimeoutActionRelease` alongside its app-level timer
/// precisely so the hold ends at `expiresAt` *even if the Mac app crashed,
/// was force-quit, or never got another word out*. So once `expiresAt` has
/// passed, "this hold is over" is not a guess about a machine we can't
/// reach — it is the recorded deadline doing exactly what both mechanisms
/// exist to guarantee. A cached `.active` past its own `expiresAt` is the
/// one state a remote surface can safely stop presenting as "keeping the
/// Mac awake," and *should*: a widget showing "Awake" for a hold that
/// certainly released an hour ago is the polished, confident lie
/// `WidgetSnapshot.sourceIsDemoData`'s doc comment warns this app is one
/// careless surface away from telling.
///
/// **What a stale reading can never conclude: that an *indefinite* hold
/// ended.** An indefinite or conditional hold has no deadline in the value,
/// and every path that ends one (the user's own release, a satisfied
/// `ReleaseCondition`, a guardrail revocation) happens on the Mac, out of a
/// remote reader's sight. `isCrediblyActive` therefore keeps answering
/// `true` for a stale indefinite hold — last-reported state, presented with
/// whatever staleness treatment the surface already owes its reader
/// (`Freshness`, an "unreachable" qualifier), is honest; flipping to "off"
/// because the reading is old would fabricate a release nobody observed.
/// The asymmetry is the point: these helpers only ever *withdraw* a claim
/// the data itself disproves, never invent one.
extension SleepAssertionState {

    /// Whether this state is a timed hold whose recorded deadline has
    /// passed as of `date` — the sub-case a countdown UI must not render as
    /// a live countdown (`Text(_, style: .timer)` silently counts *up* past
    /// its date, reading as "held for three minutes" instead of "ended
    /// three minutes ago" — the trap `KeepAwakePage.countdown` documents
    /// and this helper lets every other surface dodge the same way).
    /// `false` for `.inactive` (nothing ended — nothing was held) and for
    /// an indefinite hold (no deadline exists to have passed; see the type
    /// doc comment for why absence-of-news is not evidence of an ending).
    public func hasCertainlyEnded(asOf date: Date) -> Bool {
        guard case .active(_, let expiresAt, _) = self, let expiresAt else { return false }
        return expiresAt <= date
    }

    /// Whether a surface reading this state at `date` may honestly present
    /// it as "keeping the Mac awake": `.active`, minus the timed-and-past-
    /// deadline case `hasCertainlyEnded(asOf:)` disproves. This is the
    /// predicate for on/off chrome — the Control Center toggle's value, a
    /// widget's moon glyph, the dashboard's card promotion — not a
    /// replacement for the raw state, which detail surfaces should keep
    /// rendering (an ended hold is worth *explaining*, not blanking).
    public func isCrediblyActive(asOf date: Date) -> Bool {
        guard case .active = self else { return false }
        return !hasCertainlyEnded(asOf: date)
    }
}
