import Foundation

/// Current sleep-prevention state, owned and mutated by `PowerControlService`
/// (plan §10.2). `mode` was a bare `String` in the Phase 0 stub; changed to
/// `AwakeMode` now that the real service exists, for compile-time safety
/// (an invalid mode string could previously reach `IOPMAssertionCreateWithProperties`
/// undetected). Safe to change: grepping the tree at the time of this change
/// found exactly two references — this file and `SystemSnapshot.swift`, which
/// only declares an optional `SleepAssertionState?` field and never
/// constructs one — so no other call site depended on the old shape.
public enum SleepAssertionState: Codable, Sendable, Equatable {
    case inactive
    case active(mode: AwakeMode, expiresAt: Date?, reason: String)
}
