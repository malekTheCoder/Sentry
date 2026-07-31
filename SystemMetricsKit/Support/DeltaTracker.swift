import Foundation

/// Derives a per-second rate from successive readings of a monotonically
/// increasing counter (network bytes, disk bytes, CPU ticks, ...).
///
/// A decrease between samples can mean either a genuine counter wrap (true
/// 32-bit fields like BSD `if_data.ifi_ibytes`) or a counter reset (a device
/// re-enumerated, an external drive was unplugged, a summed multi-device
/// total dropped a device). Those need different handling — wrapping a
/// 64-bit-sourced counter through `UInt32.max` math on a reset would
/// underflow and trap — so the caller states which case applies.
public final class DeltaTracker {
    public enum CounterWidth {
        /// Source is a genuine 32-bit counter; a decrease is treated as one
        /// wrap through `UInt32.max`.
        case bits32
        /// Source width isn't guaranteed 32-bit (summed/widened counters,
        /// cumulative disk bytes, etc). A decrease is treated as a reset —
        /// start a fresh baseline and report no rate for this sample — since
        /// there's no safe way to compute "how much it wrapped by" without
        /// knowing the true modulus.
        case bits64
    }

    private let width: CounterWidth
    private var previousValue: UInt64?
    private var previousTimestamp: Date?

    public init(width: CounterWidth = .bits64) {
        self.width = width
    }

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
        } else if width == .bits32, previousValue <= UInt64(UInt32.max) {
            // The modulus is 2^32 (== UInt32.max + 1), so the wrapped delta
            // is (2^32 - previous) + value, not (UInt32.max - previous) +
            // value — the latter undercounts by one byte per wrap.
            delta = (UInt64(UInt32.max) - previousValue) + value + 1
        } else {
            // Reset, not a wrap we can safely account for — no delta available
            // for this sample; the next call establishes a fresh baseline.
            return nil
        }
        return Double(delta) / elapsed
    }
}
