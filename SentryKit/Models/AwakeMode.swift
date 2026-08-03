import Foundation

/// The three sleep-prevention modes exposed to the UI (plan §10.1).
///
/// Deliberately a plain, platform-agnostic data type in `Models/`, not
/// declared alongside `PowerControlService` (which is `#if os(macOS)`-only,
/// since it drives real `IOPMAssertion`s). `SleepAssertionState` — a shared
/// model that both `SystemSnapshot` and, eventually, the iOS app's CloudKit
/// sync payload carry — has a case holding an `AwakeMode`, and that type
/// needs to compile and decode on iOS too (Phase 5, plan §12: "check your
/// Mac's battery from anywhere" means the phone reads a `SleepAssertionState`
/// synced down from the Mac, it never creates an assertion of its own). The
/// macOS-only mapping from each case to a real `IOKit.pwr_mgt` assertion-type
/// constant lives in `PowerControlService.swift`'s `#if os(macOS)` block as
/// an extension instead, so the assertion-creation logic stays exactly where
/// it always was.
public enum AwakeMode: String, Codable, CaseIterable, Sendable {
    /// Screen stays on. Implies system stays awake too.
    case displayAndSystem
    /// System stays awake; display may sleep. Good for long downloads/builds.
    case systemOnly
    /// Prevent sleep only while on AC power (Apple's recommended type for this).
    case systemWhileOnAC
}
