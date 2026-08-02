import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Best-effort bridge to the private `libIOReport.dylib` API used by
/// `powermetrics` to read per-component energy counters (CPU, GPU, ANE,
/// DRAM, ...) without root (plan §5.4). This is the single most valuable
/// and most fragile data source in the app, so it follows the exact same
/// defensive shape as `HIDSensorBridge` in `ThermalCollector.swift`: every
/// symbol is resolved with `dlsym` rather than link-time-required (§14.4
/// rule 1), every returned pointer is optional and never force-unwrapped
/// (rule 3), every CF array iteration is bounded (rule 4), and every owned
/// CF reference is released — here that happens automatically via ARC on
/// the `takeRetainedValue()` paths, same as `HIDSensorBridge` (rule 5). If
/// any step fails — dlopen returns null, a symbol is missing, a
/// subscription can't be created, or zero channels enumerate — the whole
/// bridge reports itself unavailable rather than returning zero/garbage
/// energy values.
///
/// DVFS frequency-table parsing (`voltage-states` IORegistry entries,
/// plan §5.2/§5.3) is deliberately **not** implemented here — it's a
/// separate, less-specified piece of work. `IOReportStateGetCount` /
/// `IOReportStateGetNameForIndex` / `IOReportStateGetResidency` are
/// resolved below (so the bridge can report a coherent available/
/// unavailable state as a whole, per §14.4) but nothing calls them yet.
/// TODO: CPU/GPU DVFS residency parsing — future work.
public struct IOReportChannelSample: Sendable {
    public let group: String
    public let subgroup: String?
    public let channelName: String
    public let unitLabel: String?
    public let value: Int64
}

/// A lightweight channel description with no sampled value — what
/// `IOReportCopyAllChannels`/`IOReportCopyChannelsInGroup` hand back before
/// any subscription exists. Used for enumeration (capability probing,
/// `ChannelResolver` alias matching).
public struct IOReportChannelDescriptor: Sendable {
    public let group: String
    public let subgroup: String?
    public let channelName: String
}

/// Wraps a live IOReport subscription (the subscription handle plus the
/// "subscribed channels" dictionary IOReport hands back and expects on
/// every subsequent `IOReportCreateSamples` call). Both are CF objects
/// obtained via `takeRetainedValue()`, so — exactly like `HIDSensorBridge`
/// — ARC releases them when this object deallocates; no manual `CFRelease`
/// is needed or possible here.
public final class IOReportSubscription {
    fileprivate let subscriptionRef: CFTypeRef
    fileprivate let subscribedChannels: CFMutableDictionary

    fileprivate init(subscriptionRef: CFTypeRef, subscribedChannels: CFMutableDictionary) {
        self.subscriptionRef = subscriptionRef
        self.subscribedChannels = subscribedChannels
    }
}

/// dlopen/dlsym wrapper around `libIOReport.dylib`. Not documented in any
/// public SDK header (plan §5.4); the C signatures below are declared by
/// hand and cross-checked against the plan's own shim block plus the
/// shapes used by other open-source IOReport consumers (e.g. macmon).
final class IOReportBridge {
    static let shared = IOReportBridge()

    // Bound every CF array iteration (§14.4 rule 4), matching the rest of
    // the codebase (see HIDSensorBridge.maxIterations, IOKitBridge).
    private static let maxIterations = 256

    // IOReport delta sampling gets noisy below ~500ms (plan §5.4); enforce
    // a 1s floor regardless of what a caller requests.
    static let minimumSampleInterval: TimeInterval = 1.0

    private static let channelsKey = "IOReportChannels" as CFString

    // MARK: - C function types (all CoreFoundation-based, not the
    // CFTypeRef/HID-event style of HIDSensorBridge). "Copy"/"Create" ->
    // +1 owned (Unmanaged, take retained); "Get" -> borrowed (Unmanaged,
    // take unretained), per standard CF naming convention.
    private typealias CopyAllChannelsFn =
        @convention(c) (UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CopyChannelsInGroupFn =
        @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscriptionFn =
        @convention(c) (
            UnsafeMutableRawPointer?,
            CFMutableDictionary,
            UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?,
            UInt64,
            CFTypeRef?
        ) -> Unmanaged<CFTypeRef>?
    private typealias CreateSamplesFn =
        @convention(c) (CFTypeRef, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDeltaFn =
        @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?

    private typealias ChannelGetGroupFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias ChannelGetSubGroupFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias ChannelGetChannelNameFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias ChannelGetUnitLabelFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?

    private typealias SimpleGetIntegerValueFn = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias StateGetCountFn = @convention(c) (CFDictionary) -> Int32
    private typealias StateGetNameForIndexFn = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateGetResidencyFn = @convention(c) (CFDictionary, Int32) -> Int64

    private let copyAllChannels: CopyAllChannelsFn?
    private let copyChannelsInGroup: CopyChannelsInGroupFn?
    private let createSubscription: CreateSubscriptionFn?
    private let createSamples: CreateSamplesFn?
    private let createSamplesDelta: CreateSamplesDeltaFn?
    private let channelGetGroup: ChannelGetGroupFn?
    private let channelGetSubGroup: ChannelGetSubGroupFn?
    private let channelGetChannelName: ChannelGetChannelNameFn?
    private let channelGetUnitLabel: ChannelGetUnitLabelFn?
    private let simpleGetIntegerValue: SimpleGetIntegerValueFn?
    private let stateGetCount: StateGetCountFn?
    private let stateGetNameForIndex: StateGetNameForIndexFn?
    private let stateGetResidency: StateGetResidencyFn?

    /// True only when every symbol this bridge needs resolved. Per §14.4,
    /// a single missing symbol degrades the whole bridge rather than
    /// letting callers hit half-working functionality.
    let isAvailable: Bool

    private init() {
        // Same rationale as HIDSensorBridge: dlopen is refcounted/idempotent,
        // and going through dlopen/dlsym rather than linking the private
        // symbols directly means a missing symbol on a future macOS just
        // disables this bridge instead of failing app launch. The dylib
        // isn't present as a standalone file under /usr/lib on modern
        // macOS (it lives in the dyld shared cache), but dlopen still
        // resolves it by path.
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else {
            copyAllChannels = nil
            copyChannelsInGroup = nil
            createSubscription = nil
            createSamples = nil
            createSamplesDelta = nil
            channelGetGroup = nil
            channelGetSubGroup = nil
            channelGetChannelName = nil
            channelGetUnitLabel = nil
            simpleGetIntegerValue = nil
            stateGetCount = nil
            stateGetNameForIndex = nil
            stateGetResidency = nil
            isAvailable = false
            return
        }

        func load<T>(_ symbol: String, as type: T.Type) -> T? {
            guard let sym = dlsym(handle, symbol) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }

        let copyAllChannels = load("IOReportCopyAllChannels", as: CopyAllChannelsFn.self)
        let copyChannelsInGroup = load("IOReportCopyChannelsInGroup", as: CopyChannelsInGroupFn.self)
        let createSubscription = load("IOReportCreateSubscription", as: CreateSubscriptionFn.self)
        let createSamples = load("IOReportCreateSamples", as: CreateSamplesFn.self)
        let createSamplesDelta = load("IOReportCreateSamplesDelta", as: CreateSamplesDeltaFn.self)
        let channelGetGroup = load("IOReportChannelGetGroup", as: ChannelGetGroupFn.self)
        let channelGetSubGroup = load("IOReportChannelGetSubGroup", as: ChannelGetSubGroupFn.self)
        let channelGetChannelName = load("IOReportChannelGetChannelName", as: ChannelGetChannelNameFn.self)
        let channelGetUnitLabel = load("IOReportChannelGetUnitLabel", as: ChannelGetUnitLabelFn.self)
        let simpleGetIntegerValue = load("IOReportSimpleGetIntegerValue", as: SimpleGetIntegerValueFn.self)
        let stateGetCount = load("IOReportStateGetCount", as: StateGetCountFn.self)
        let stateGetNameForIndex = load("IOReportStateGetNameForIndex", as: StateGetNameForIndexFn.self)
        let stateGetResidency = load("IOReportStateGetResidency", as: StateGetResidencyFn.self)

        self.copyAllChannels = copyAllChannels
        self.copyChannelsInGroup = copyChannelsInGroup
        self.createSubscription = createSubscription
        self.createSamples = createSamples
        self.createSamplesDelta = createSamplesDelta
        self.channelGetGroup = channelGetGroup
        self.channelGetSubGroup = channelGetSubGroup
        self.channelGetChannelName = channelGetChannelName
        self.channelGetUnitLabel = channelGetUnitLabel
        self.simpleGetIntegerValue = simpleGetIntegerValue
        self.stateGetCount = stateGetCount
        self.stateGetNameForIndex = stateGetNameForIndex
        self.stateGetResidency = stateGetResidency

        self.isAvailable = copyAllChannels != nil && copyChannelsInGroup != nil
            && createSubscription != nil && createSamples != nil && createSamplesDelta != nil
            && channelGetGroup != nil && channelGetSubGroup != nil
            && channelGetChannelName != nil && channelGetUnitLabel != nil
            && simpleGetIntegerValue != nil
            && stateGetCount != nil && stateGetNameForIndex != nil && stateGetResidency != nil
    }

    /// Enumerates every channel in `group` (optionally narrowed to
    /// `subgroup`) with no subscription/sampling involved — cheap, used
    /// for capability probing and `ChannelResolver` alias matching.
    /// Returns an empty array (never crashes) if the bridge is
    /// unavailable or the group doesn't exist.
    func allChannels(inGroup group: String, subgroup: String? = nil) -> [IOReportChannelDescriptor] {
        guard isAvailable, let copyChannelsInGroup else { return [] }

        guard let channelsDict = copyChannelsInGroup(
            group as CFString,
            subgroup as CFString?,
            0, 0, 0
        )?.takeRetainedValue() else { return [] }

        return parseDescriptors(channelsDict)
    }

    /// Opens a live subscription to every channel in `group`. Returns nil
    /// if the bridge is unavailable, the group is empty, or subscription
    /// creation fails for any reason.
    func subscribe(toGroup group: String, subgroup: String? = nil) -> IOReportSubscription? {
        guard isAvailable, let copyChannelsInGroup, let createSubscription else { return nil }

        guard let desiredChannels = copyChannelsInGroup(
            group as CFString,
            subgroup as CFString?,
            0, 0, 0
        )?.takeRetainedValue() else { return nil }

        var subscribedChannelsOut: Unmanaged<CFMutableDictionary>?
        guard let subscriptionRef = createSubscription(
            nil, desiredChannels, &subscribedChannelsOut, 0, nil
        )?.takeRetainedValue() else { return nil }

        guard let subscribedChannels = subscribedChannelsOut?.takeRetainedValue() else { return nil }

        return IOReportSubscription(subscriptionRef: subscriptionRef, subscribedChannels: subscribedChannels)
    }

    /// Blocks the calling thread for `max(interval, minimumSampleInterval)`
    /// while taking two samples, then returns the per-channel delta —
    /// energy consumed within that window (plan §5.4) — plus the *measured*
    /// elapsed wall-clock time. `Thread.sleep` is a minimum, not an exact
    /// duration: thread scheduling delays, `.utility` QoS throttling, or
    /// system load can make the real gap between the two samples longer
    /// than requested. Callers computing `power = energy / elapsed` must use
    /// the measured value, not the requested one, or power reads silently
    /// too high whenever the actual window ran long. Callers should invoke
    /// this off the main thread. Returns an empty array (never crashes,
    /// never fabricates a value) on any failure.
    func sampleDelta(
        _ subscription: IOReportSubscription,
        over interval: TimeInterval
    ) -> (samples: [IOReportChannelSample], elapsedSeconds: TimeInterval) {
        let clampedInterval = max(interval, Self.minimumSampleInterval)
        guard isAvailable, let createSamples, let createSamplesDelta else {
            return ([], clampedInterval)
        }

        guard let first = createSamples(
            subscription.subscriptionRef, subscription.subscribedChannels, nil
        )?.takeRetainedValue() else { return ([], clampedInterval) }

        let start = DispatchTime.now()
        Thread.sleep(forTimeInterval: clampedInterval)
        let measuredElapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9

        guard let second = createSamples(
            subscription.subscriptionRef, subscription.subscribedChannels, nil
        )?.takeRetainedValue() else { return ([], clampedInterval) }

        guard let delta = createSamplesDelta(first, second, nil)?.takeRetainedValue() else {
            return ([], clampedInterval)
        }

        // Guard against a near-zero or negative measured interval (clock
        // weirdness) producing a divide-by-near-zero power spike downstream.
        let elapsed = measuredElapsed > 0 ? measuredElapsed : clampedInterval
        return (parseSamples(delta), elapsed)
    }

    // MARK: - Parsing helpers

    /// Both the "channels" dict (from Copy*Channels*) and the "samples
    /// delta" dict (from CreateSamplesDelta) share the same shape: a
    /// top-level `"IOReportChannels"` array of per-channel dictionaries.
    /// CFDictionary/CFArray bridge losslessly to NSDictionary/NSArray
    /// (they're the same underlying object on Apple platforms), so this
    /// stays at the CF level for the fields IOReport itself defines
    /// (group/subgroup/name/value) rather than blindly casting to a
    /// native Swift collection.
    private func channelsArray(from dict: CFDictionary) -> NSArray? {
        (dict as NSDictionary)[Self.channelsKey as String] as? NSArray
    }

    private func parseDescriptors(_ dict: CFDictionary) -> [IOReportChannelDescriptor] {
        guard let channelGetGroup, let channelGetSubGroup, let channelGetChannelName else { return [] }
        guard let array = channelsArray(from: dict) else { return [] }

        let count = min(array.count, Self.maxIterations)
        guard count > 0 else { return [] }

        var results: [IOReportChannelDescriptor] = []
        results.reserveCapacity(count)

        for index in 0..<count {
            guard let channel = array[index] as? NSDictionary else { continue }
            let cfChannel = channel as CFDictionary

            guard let name = channelGetChannelName(cfChannel)?.takeUnretainedValue() as String? else { continue }
            let group = channelGetGroup(cfChannel)?.takeUnretainedValue() as String? ?? ""
            let subgroup = channelGetSubGroup(cfChannel)?.takeUnretainedValue() as String?

            results.append(IOReportChannelDescriptor(group: group, subgroup: subgroup, channelName: name))
        }
        return results
    }

    private func parseSamples(_ dict: CFDictionary) -> [IOReportChannelSample] {
        guard let channelGetGroup, let channelGetSubGroup, let channelGetChannelName,
              let channelGetUnitLabel, let simpleGetIntegerValue
        else { return [] }
        guard let array = channelsArray(from: dict) else { return [] }

        let count = min(array.count, Self.maxIterations)
        guard count > 0 else { return [] }

        var results: [IOReportChannelSample] = []
        results.reserveCapacity(count)

        for index in 0..<count {
            guard let channel = array[index] as? NSDictionary else { continue }
            let cfChannel = channel as CFDictionary

            guard let name = channelGetChannelName(cfChannel)?.takeUnretainedValue() as String? else { continue }
            let group = channelGetGroup(cfChannel)?.takeUnretainedValue() as String? ?? ""
            let subgroup = channelGetSubGroup(cfChannel)?.takeUnretainedValue() as String?
            let unitLabel = channelGetUnitLabel(cfChannel)?.takeUnretainedValue() as String?
            let value = simpleGetIntegerValue(cfChannel, 0)

            results.append(IOReportChannelSample(
                group: group,
                subgroup: subgroup,
                channelName: name,
                unitLabel: unitLabel,
                value: value
            ))
        }
        return results
    }

    /// Converts an IOReport energy unit label ("mJ", "nJ", ...) to a
    /// joules multiplier. Per plan §5.4 this must **never** be hardcoded
    /// per-channel — it's derived from whatever label IOReport itself
    /// reports, which varies by channel and chip generation. Returns nil
    /// (rather than guessing) for any label this doesn't recognize.
    static func joulesScale(forUnitLabel label: String?) -> Double? {
        guard let label else { return nil }
        switch label.trimmingCharacters(in: .whitespaces) {
        case "J": return 1
        case "mJ": return 1e-3
        case "uJ", "\u{b5}J": return 1e-6 // µJ, both ASCII "u" and the micro sign show up in the wild
        case "nJ": return 1e-9
        default: return nil
        }
    }
}

/// Resolves logical energy metrics ("CPU power", "GPU power", ...) to
/// whatever concrete IOReport channel name actually exists on *this*
/// Mac's "Energy Model" group, per plan §5.4's fragility note: channel
/// names have shifted across M1 -> M2 -> M3 -> M4 and across macOS
/// releases, so nothing here hardcodes a single name. Enumerates once at
/// construction (cheap — no subscription/sampling involved), tries a
/// short prioritized alias list per metric, caches whichever one actually
/// matched, and reports nil rather than guessing or crashing when nothing
/// matches.
final class ChannelResolver {
    /// Metric identifiers this resolver knows about, mapped to the
    /// channel-name aliases plan §5.4's own table lists under
    /// group "Energy Model". Kept intentionally short and literal — no
    /// invented channel names beyond what the plan itself documents.
    enum Metric: String, CaseIterable {
        case cpuEnergy
        case gpuEnergy
        case gpuSRAMEnergy
        case aneEnergy
        case dramEnergy
        case dcsEnergy
        case ispEnergy
        case aveEnergy
        case amccEnergy
        case dispEnergy
        case efficiencyCoreEnergy
        case performanceCore0Energy
        case performanceCore1Energy
    }

    private static let aliases: [Metric: [String]] = [
        .cpuEnergy: ["CPU Energy"],
        .gpuEnergy: ["GPU"],
        .gpuSRAMEnergy: ["GPU SRAM"],
        .aneEnergy: ["ANE"],
        .dramEnergy: ["DRAM"],
        .dcsEnergy: ["DCS"],
        .ispEnergy: ["ISP"],
        .aveEnergy: ["AVE"],
        .amccEnergy: ["AMCC"],
        .dispEnergy: ["DISP"],
        .efficiencyCoreEnergy: ["EACC_CPU"],
        .performanceCore0Energy: ["PACC0_CPU"],
        .performanceCore1Energy: ["PACC1_CPU"]
    ]

    private static let energyModelGroup = "Energy Model"

    private let bridge: IOReportBridge

    // `SharedEnergySampler` deliberately dispatches provider calls (GPU/ANE)
    // off the coordinator's queue so a blocking IOReport sample on one tier
    // can't stall another (see StatsCoordinator's concurrency-model doc
    // comment) — which means two collectors really can call into the one
    // shared `ChannelResolver` instance at genuinely the same time. A plain
    // `var` dictionary mutated from two threads concurrently is undefined
    // behavior in Swift (confirmed the hard way: concurrent access here
    // produced a corrupted-object crash, not a clean data race warning), so
    // every read/write of `availableChannelNames`/`resolved`/`hasAnyChannel`
    // is confined to this serial queue.
    private let stateQueue = DispatchQueue(label: "com.sentry.macstat.channelresolver")
    private var availableChannelNames: Set<String> = []
    private var resolved: [Metric: String] = [:]
    private var hasAnyChannelStorage = false

    /// True once at least one "Energy Model" channel enumerated —
    /// `CapabilityProbe` uses this (via `IOReportBridge`) to decide
    /// whether to advertise `hasIOReport`.
    var hasAnyChannel: Bool { stateQueue.sync { hasAnyChannelStorage } }

    init(bridge: IOReportBridge = .shared) {
        self.bridge = bridge
        refresh()
    }

    /// Re-enumerates channels and clears the resolution cache. Call this
    /// if the app suspects the channel set changed (macOS upgrade,
    /// plan §5.9's "re-run on macOS version change").
    func refresh() {
        // Enumeration itself (bridge.allChannels) doesn't touch this
        // instance's mutable state, so it's fine to do off-queue; only the
        // assignment needs to be serialized.
        let descriptors = bridge.allChannels(inGroup: Self.energyModelGroup)
        let names = Set(descriptors.map(\.channelName))
        stateQueue.sync {
            availableChannelNames = names
            hasAnyChannelStorage = !names.isEmpty
            resolved.removeAll()
        }
    }

    /// Returns the actual IOReport channel name backing `metric` on this
    /// Mac, or nil if none of the known aliases are present.
    func resolvedChannelName(for metric: Metric) -> String? {
        stateQueue.sync {
            if let cached = resolved[metric] { return cached }
            guard let candidates = Self.aliases[metric] else { return nil }
            for candidate in candidates where availableChannelNames.contains(candidate) {
                resolved[metric] = candidate
                return candidate
            }
            return nil
        }
    }

    /// Looks up `metric`'s resolved channel in `samples`, converts its
    /// energy delta to average power over `elapsedSeconds` using the
    /// unit label IOReport itself reports (never a hardcoded scale, per
    /// plan §5.4). Returns nil — never zero/garbage — if the metric isn't
    /// resolvable, the sample is missing, the unit label is unrecognized,
    /// or the delta is negative (a counter reset, not a real reading).
    func powerWatts(
        forMetric metric: Metric,
        in samples: [IOReportChannelSample],
        elapsedSeconds: TimeInterval
    ) -> Double? {
        guard elapsedSeconds > 0 else { return nil }
        guard let channelName = resolvedChannelName(for: metric) else { return nil }
        guard let sample = samples.first(where: { $0.channelName == channelName }) else { return nil }
        guard let scale = IOReportBridge.joulesScale(forUnitLabel: sample.unitLabel) else { return nil }

        let energyValue: Int64
        if sample.value >= 0 {
            energyValue = sample.value
        } else {
            // The underlying hardware energy counters IOReport wraps are
            // commonly narrower than the Int64 this API hands back (32-bit
            // is the documented-by-precedent common case — other
            // open-source IOReport consumers, e.g. macmon, apply the same
            // correction). A negative post-delta value is far more likely
            // to be a wrap than a genuine reset, so correct it rather than
            // discarding a real reading; only bail if the "corrected" value
            // still doesn't make sense.
            let corrected = sample.value + (1 << 32)
            guard corrected >= 0 else { return nil }
            energyValue = corrected
        }

        return Double(energyValue) * scale / elapsedSeconds
    }
}
