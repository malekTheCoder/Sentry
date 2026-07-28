import Foundation
import IOKit

/// Thin wrappers around IOKit registry reads. Nothing outside this file
/// should call IOServiceGetMatchingService / IORegistryEntryCreateCFProperties
/// directly — keeps the unsafe C interop in one place.
public enum IOKitBridge {
    /// Reads all properties of the first service matching `className`, e.g.
    /// "AppleSmartBattery". Returns nil if no matching service exists or the
    /// property dictionary can't be read — never force-unwraps.
    public static func properties(forService className: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(className)
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any]
        else { return nil }

        return dict
    }

    /// Reads properties for every service matching `className`, e.g.
    /// "IOBlockStorageDriver" where multiple drives may be present. Bounded
    /// to `maxIterations` so a misbehaving driver can't hang enumeration.
    public static func propertiesForAllServices(
        matching className: String,
        maxIterations: Int = 256
    ) -> [[String: Any]] {
        var results: [[String: Any]] = []

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return results }
        defer { IOObjectRelease(iterator) }

        var count = 0
        var service = IOIteratorNext(iterator)
        while service != 0, count < maxIterations {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
                count += 1
            }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any]
            else { continue }

            results.append(dict)
        }
        // The cap can be hit with one more matching service still fetched
        // but not yet handed to the loop body/defer above — release it so
        // hitting the (in-practice-unreachable) cap can't leak a handle.
        if service != 0 {
            IOObjectRelease(service)
        }

        return results
    }
}
