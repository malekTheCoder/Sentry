import Foundation

/// Derives a per-second rate from successive readings of a monotonically
/// increasing counter (network bytes, disk bytes, CPU ticks, ...).
///
/// Counters sourced from 32-bit fields wrap; `rate(for:at:)` treats any
/// decrease as a single wrap from `UInt32.max` rather than producing a
/// negative or huge rate.
public final class DeltaTracker {
    private var previousValue: UInt64?
    private var previousTimestamp: Date?

    public init() {}

    @discardableResult
    public func rate(for value: UInt64, at timestamp: Date = Date()) -> Double? {
        defer {
            previousValue = value
            previousTimestamp = timestamp
        }
        guard let previousValue, let previousTimestamp else { return nil }
        let elapsed = timestamp.timeIntervalSince(previousTimestamp)
        guard elapsed > 0 else { return nil }

        let delta: UInt64
        if value >= previousValue {
            delta = value - previousValue
        } else {
            delta = (UInt64(UInt32.max) - previousValue) + value
        }
        return Double(delta) / elapsed
    }
}
