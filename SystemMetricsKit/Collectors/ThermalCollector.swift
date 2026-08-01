import Foundation
import MacStatKit
#if canImport(Darwin)
import Darwin
#endif

/// Collects thermal pressure and (best-effort) SoC/fan sensor data.
///
/// Two tiers, per plan §5.8:
///  1. `ProcessInfo.thermalState` — always available on every Mac, zero
///     risk, and the tier every UI surface can rely on unconditionally.
///  2. `IOHIDEventSystemClient` — a private HID bridge (not declared in any
///     public SDK header) that can expose raw SoC temperature on Apple
///     Silicon. Resolved at runtime via dlopen/dlsym per §14.4 so a
///     missing or renamed symbol on a future macOS degrades this one field
///     instead of crashing the app. If the bridge is unavailable for any
///     reason, `collect()` still returns a full `ThermalStats` built from
///     tier 1 alone — the whole snapshot is never sacrificed for one
///     fragile field.
public final class ThermalCollector: Collector {
    public typealias Sample = ThermalStats

    private let hidBridge: HIDSensorBridge

    public init() {
        self.hidBridge = HIDSensorBridge.shared
    }

    public func collect() -> ThermalStats? {
        let pressureLevel = Self.mapThermalState(ProcessInfo.processInfo.thermalState)

        // .fair shows up under ordinary load (a video call, a Spotlight
        // reindex) and isn't worth alarming the user about; .serious is
        // where macOS itself starts throttling meaningfully and where
        // tools like Macs Fan Control / TG Pro raise a warning badge. So
        // the throttling flag trips at .serious rather than .fair.
        let isThrottling = pressureLevel == .serious || pressureLevel == .critical

        return ThermalStats(
            socTemperatureCelsius: hidBridge.readTemperature(),
            // Fans come from the SMC key protocol, not the HID bridge —
            // see `SMCFanBridge` for why the HID path stayed a refusal.
            fanRPMs: SMCFanBridge.shared.readFanRPMs(),
            pressureLevel: pressureLevel,
            isThrottling: isThrottling,
            perSensorCelsius: hidBridge.readAllTemperatures()
        )
    }

    private static func mapThermalState(_ state: ProcessInfo.ThermalState) -> ThermalStats.PressureLevel {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}

/// Best-effort bridge to the private `IOHIDEventSystemClient` API used to
/// read Apple Silicon SoC temperature sensors (plan §5.8). This is
/// deliberately conservative: every symbol is resolved with `dlsym` rather
/// than link-time-required (§14.4 rule 1), every returned pointer is
/// treated as optional and never force-unwrapped (rule 3), every CF
/// iteration is bounded (rule 4), and every owned reference is released
/// (rule 5). If any step fails — dlopen returns null, a symbol is missing,
/// matching finds zero services, or a reading is outside a physically
/// plausible range — the bridge simply reports "no data" rather than
/// propagating an error or crashing.
///
/// Fan RPM extraction deliberately does *not* live here: the HID path's
/// field selector for fans is undocumented and guessing wrong risks
/// silently showing a fabricated number. Fans are read through the SMC key
/// protocol instead — see `SMCFanBridge`, whose constants are verified
/// against real hardware rather than reversed by guesswork. The
/// temperature path here uses `kIOHIDEventTypeTemperature` (15), a
/// long-standing, widely corroborated reversed constant, so it's
/// implemented for real.
final class HIDSensorBridge {
    static let shared = HIDSensorBridge()

    // kHIDPage_AppleVendor / usage constants per plan §5.8.
    private static let appleVendorPage = 0xff00
    private static let temperatureUsage = 0x0005

    // IOHIDEventFieldBase(type) == type << 16; kIOHIDEventTypeTemperature == 15.
    private static let temperatureEventType: Int64 = 15
    private static let temperatureField = Int32(15 << 16)

    // Bound every IOKit/CF iteration (§14.4 rule 4) so a malformed services
    // array or a future macOS oddity can't hang the app.
    private static let maxIterations = 256

    // Plausible SoC die temperature range; anything outside this is almost
    // certainly a misread field rather than a real reading, so it's
    // dropped rather than surfaced.
    private static let plausibleRange: ClosedRange<Double> = -20...150

    private typealias ClientCreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias ClientSetMatchingFn = @convention(c) (CFTypeRef, CFDictionary) -> Void
    private typealias ClientCopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias ServiceCopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias EventGetFloatValueFn = @convention(c) (CFTypeRef, Int32) -> Double
    private typealias ServiceCopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?

    private let clientCreate: ClientCreateFn?
    private let clientSetMatching: ClientSetMatchingFn?
    private let clientCopyServices: ClientCopyServicesFn?
    private let serviceCopyEvent: ServiceCopyEventFn?
    private let eventGetFloatValue: EventGetFloatValueFn?
    private let serviceCopyProperty: ServiceCopyPropertyFn?

    private init() {
        // dlopen is refcounted and idempotent: IOKit.framework is already
        // mapped into this process for the app's public IOKit usage
        // elsewhere, so this call just bumps a refcount rather than
        // touching disk. We still go through the full dlopen/dlsym dance
        // rather than linking against the private symbols directly, so a
        // missing symbol on a future macOS disables this bridge instead of
        // failing app launch.
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            clientCreate = nil
            clientSetMatching = nil
            clientCopyServices = nil
            serviceCopyEvent = nil
            eventGetFloatValue = nil
            serviceCopyProperty = nil
            return
        }

        func load<T>(_ symbol: String, as type: T.Type) -> T? {
            guard let sym = dlsym(handle, symbol) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }

        clientCreate = load("IOHIDEventSystemClientCreate", as: ClientCreateFn.self)
        clientSetMatching = load("IOHIDEventSystemClientSetMatching", as: ClientSetMatchingFn.self)
        clientCopyServices = load("IOHIDEventSystemClientCopyServices", as: ClientCopyServicesFn.self)
        serviceCopyEvent = load("IOHIDServiceClientCopyEvent", as: ServiceCopyEventFn.self)
        eventGetFloatValue = load("IOHIDEventGetFloatValue", as: EventGetFloatValueFn.self)
        // Best-effort only — `readAllTemperatures()` falls back to a
        // positional "Sensor N" label if this symbol is missing, so it's
        // not part of the "every symbol must resolve" gate the other
        // methods use.
        serviceCopyProperty = load("IOHIDServiceClientCopyProperty", as: ServiceCopyPropertyFn.self)
    }

    /// Returns the hottest plausible SoC temperature reading across all
    /// matched sensors, or nil if the bridge is unavailable, matching
    /// found nothing, or no reading fell in a physically plausible range.
    /// (Max, not average: a single hot core/cluster is what users and
    /// throttling behavior actually care about, and averaging would mask
    /// it.)
    func readTemperature() -> Double? {
        // Every symbol must have resolved (§14.4 rule 1) or this bridge is
        // simply unavailable on this macOS build.
        guard let clientCreate, let clientSetMatching, let clientCopyServices,
              let serviceCopyEvent, let eventGetFloatValue
        else {
            return nil
        }

        // `takeRetainedValue()` consumes the +1 from each "Create"/"Copy"
        // call and hands ownership to ARC (CFTypeRef bridges to AnyObject),
        // so no manual CFRelease is needed — the compiler already refuses
        // an explicit one here as unavailable/redundant. §14.4 rule 5 is
        // satisfied by ARC rather than by hand.
        guard let clientRef = clientCreate(nil)?.takeRetainedValue() else { return nil }

        let matching: CFDictionary = [
            "PrimaryUsagePage": Self.appleVendorPage,
            "PrimaryUsage": Self.temperatureUsage
        ] as CFDictionary
        clientSetMatching(clientRef, matching)

        guard let servicesRef = clientCopyServices(clientRef)?.takeRetainedValue() else { return nil }

        let count = min(CFArrayGetCount(servicesRef), Self.maxIterations)
        guard count > 0 else { return nil }

        var hottest: Double?
        for index in 0..<count {
            guard let rawService = CFArrayGetValueAtIndex(servicesRef, index) else { continue }
            let service = Unmanaged<CFTypeRef>.fromOpaque(rawService).takeUnretainedValue()

            guard let eventRef = serviceCopyEvent(
                service, Self.temperatureEventType, 0, 0
            )?.takeRetainedValue() else { continue }

            let value = eventGetFloatValue(eventRef, Self.temperatureField)
            guard value.isFinite, Self.plausibleRange.contains(value) else { continue }

            if hottest == nil || value > (hottest ?? -.infinity) {
                hottest = value
            }
        }

        return hottest
    }

    /// Every plausible reading behind `readTemperature()`'s single max —
    /// Apple Silicon exposes one sensor per cluster (E-cluster, P-cluster0,
    /// P-cluster1, GPU, etc.), not one per physical core, so this is a
    /// per-sensor breakdown, not literally per-core. Named via
    /// `IOHIDServiceClientCopyProperty("Product")` where that symbol
    /// resolved and returned a non-empty string; falls back to a positional
    /// "Sensor N" label otherwise, same "degrade a field, don't drop the
    /// whole read" posture as `readTemperature()`.
    func readAllTemperatures() -> [ThermalSensorReading] {
        guard let clientCreate, let clientSetMatching, let clientCopyServices,
              let serviceCopyEvent, let eventGetFloatValue
        else {
            return []
        }

        guard let clientRef = clientCreate(nil)?.takeRetainedValue() else { return [] }

        let matching: CFDictionary = [
            "PrimaryUsagePage": Self.appleVendorPage,
            "PrimaryUsage": Self.temperatureUsage
        ] as CFDictionary
        clientSetMatching(clientRef, matching)

        guard let servicesRef = clientCopyServices(clientRef)?.takeRetainedValue() else { return [] }

        let count = min(CFArrayGetCount(servicesRef), Self.maxIterations)
        guard count > 0 else { return [] }

        var readings: [ThermalSensorReading] = []
        for index in 0..<count {
            guard let rawService = CFArrayGetValueAtIndex(servicesRef, index) else { continue }
            let service = Unmanaged<CFTypeRef>.fromOpaque(rawService).takeUnretainedValue()

            guard let eventRef = serviceCopyEvent(
                service, Self.temperatureEventType, 0, 0
            )?.takeRetainedValue() else { continue }

            let value = eventGetFloatValue(eventRef, Self.temperatureField)
            guard value.isFinite, Self.plausibleRange.contains(value) else { continue }

            let name = serviceCopyProperty.flatMap { copyProperty -> String? in
                guard let nameRef = copyProperty(service, "Product" as CFString)?.takeRetainedValue() else { return nil }
                let name = nameRef as? String
                return (name?.isEmpty ?? true) ? nil : name
            } ?? "Sensor \(index + 1)"

            readings.append(ThermalSensorReading(name: name, celsius: value))
        }

        return readings.sorted { $0.celsius > $1.celsius }
    }
}
