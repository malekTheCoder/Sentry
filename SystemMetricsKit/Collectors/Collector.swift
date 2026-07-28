import Foundation

/// A single source of truth for acquiring one metric. Nothing outside a
/// Collector's own implementation talks to IOKit/IOReport/Mach directly.
public protocol Collector {
    associatedtype Sample
    func collect() -> Sample?
}
