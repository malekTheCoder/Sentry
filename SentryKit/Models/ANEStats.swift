import Foundation

/// Phase 0 skeleton — fields fleshed out in Phase 1 per plan §5.4.
/// There is no public ANE utilization percentage; power draw above the idle
/// floor is the industry-standard activity proxy. Label it "ANE Power" in UI.
public struct ANEStats: Codable, Sendable {
    public var powerWatts: Double?
    public var isActive: Bool?

    public init(powerWatts: Double? = nil, isActive: Bool? = nil) {
        self.powerWatts = powerWatts
        self.isActive = isActive
    }
}
