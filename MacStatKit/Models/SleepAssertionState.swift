import Foundation

/// Phase 0 skeleton — real assertion lifecycle lands in Phase 3 (plan §10).
public enum SleepAssertionState: Codable, Sendable, Equatable {
    case inactive
    case active(mode: String, expiresAt: Date?, reason: String)
}
