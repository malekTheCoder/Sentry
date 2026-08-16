import Combine
import Foundation
import SentryKit
import WatchConnectivity

// MARK: - WatchRelayManager: the phone's half of the Watch complication

/// Forwards a small, complication-shaped slice of whatever `AppDataSource`
/// is currently receiving (real local-sync data, or `MockDataSource`'s demo
/// data — see that type's doc comment) to a paired Apple Watch, so
/// `SentryWatch`'s complication has something real to show. This is the
/// phone-side half of the Watch feature: a Watch cannot reach the Mac
/// directly (no Bonjour/Network.framework path exists from watchOS in this
/// app), so the already-running, already-connected phone app is the only
/// bridge — exactly the role `WCSession` exists to fill.
///
/// **Also the phone-side half of Watch Siri.** The `WCSessionDelegate`
/// extension below additionally implements `session(_:didReceiveMessage:
/// replyHandler:)`, forwarding a `ControlCommand` a watch Siri intent
/// constructed (`WatchControlBridge`, `SentryWatch/Intents/
/// SentryWatchIntents.swift`) through `AppDataSource.shared.transport` —
/// the same transport (Bonjour or the manual/remote path,
/// `SentryMobile/Data/AppDataSource.swift`) every iPhone Siri intent
/// already uses — and replying with the real `ControlStatus` outcome. Watch
/// control therefore automatically works away from home too, as long as the
/// phone itself is reachable from the watch (ordinary `WCSession`
/// semantics, unrelated to this type).
///
/// **Why a standalone singleton, started at app launch, not something
/// `DashboardViewModel` owns the way it owns `WidgetSnapshotWriter`.**
/// `WidgetSnapshotWriter` only has to run while the Dashboard tab's view
/// model is alive, because the iOS widget only ever needs "whatever the
/// Dashboard last saw." The Watch complication has to keep receiving
/// updates regardless of which tab is on screen (Alerts, Settings — the
/// user could sit there indefinitely), so this is wired up once from
/// `SentryMobileApp`'s root `.task`, next to
/// `AppDataSource.shared.resolveIfNeeded()`, the same way that type
/// documents its own reason for living at the root rather than per-tab.
///
/// **Why this subscribes to `AppDataSource.shared.$transport` directly
/// instead of receiving snapshots from `DashboardViewModel`.**
/// `StatsTransport.snapshots()`'s doc comment is explicit that a transport
/// is free to fan one underlying subscription out to many returned
/// streams — a second subscriber here does not mean a second Bonjour
/// browser/socket, it means a second `AsyncStream` view onto the one
/// `LocalSyncClient` instance `AppDataSource` already owns. That is exactly
/// the fan-out this type exists to support.
///
/// **Why relays are throttled instead of firing on every snapshot.**
/// Complications have a small, system-enforced background-update budget —
/// Apple's own guidance for `WCSession.transferCurrentComplicationUserInfo`
/// is on the order of a handful of updates per hour even for an
/// actively-worn watch, far short of `AppDataSource`'s snapshot cadence.
/// Relaying every tick would exhaust that budget within minutes and get
/// silently throttled/dropped by the system, making the complication *less*
/// current than a deliberately-paced relay, not more — see
/// `WatchRelayPolicy` (`SentryKit/Watch/WatchRelayPolicy.swift`) for the
/// two independent guards this enforces before it will call into
/// `WCSession` at all, and for why the metrics added to the payload for the
/// redesigned watch screen were deliberately kept *out* of the
/// significant-change test.
@MainActor
final class WatchRelayManager: NSObject {
    static let shared = WatchRelayManager()

    private var lastRelayed: WatchRelaySnapshot?
    private var lastRelayedAt: Date?
    private var transportSubscription: AnyCancellable?
    private var snapshotTask: Task<Void, Never>?
    private var deviceNameCache: String?

    private override init() {
        super.init()
    }

    /// Called once from `SentryMobileApp`'s root `.task`. Activating
    /// `WCSession` when the Watch app/`WCSession` isn't supported at all
    /// (e.g. running on an iPad, or a device with no paired Watch ever) is
    /// a documented no-op/early-return case — `WCSession.isSupported()`
    /// guards that so this never crashes or logs noise on those devices.
    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()

        transportSubscription = AppDataSource.shared.$transport
            .sink { [weak self] transport in
                self?.observeSnapshots(transport: transport)
            }
    }

    private func observeSnapshots(transport: any StatsTransport) {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            for await snapshot in transport.snapshots() {
                guard !Task.isCancelled else { return }
                await self?.consider(snapshot)
            }
        }
    }

    /// This phone's own theme, flattened — the fallback when the Mac did not
    /// send a palette. Reads the same `UserDefaults` key `RootTabView` binds
    /// its `@AppStorage` to, for the reason `themeID` above documents: this
    /// is an actor with no SwiftUI environment to read from.
    private static func phonePalette() -> RelayedPalette? {
        let id = UserDefaults.standard.string(forKey: "selectedThemeID") ?? Theme.oneDark.id
        guard let theme = Theme.builtInPresets.first(where: { $0.id == id }) else { return nil }
        let appearance = UserDefaults.standard.string(forKey: WatchRelayAppearance.defaultsKey)
            .flatMap(ThemeAppearance.init(rawValue:)) ?? .dark
        return RelayedPalette(theme: theme, appearance: appearance)
    }

    private func consider(_ snapshot: SystemSnapshot) async {
        if deviceNameCache == nil {
            deviceNameCache = await AppDataSource.shared.devices()
                .first { $0.deviceID == snapshot.deviceID }?.deviceName
        }

        let isDemoData = AppDataSource.shared.transport is MockDataSource
        let candidate = WatchRelaySnapshot(
            deviceName: deviceNameCache ?? snapshot.deviceID,
            lastSeen: snapshot.timestamp,
            relayedAt: Date(),
            sourceIsDemoData: isDemoData,
            batteryPercent: snapshot.battery?.chargePercent ?? 0,
            isCharging: snapshot.battery?.isCharging ?? false,
            isPluggedIn: snapshot.battery?.isPluggedIn ?? false,
            thermalPressure: Self.summarize(snapshot.thermal?.pressureLevel),
            batteryIsReported: snapshot.battery != nil,
            cpuPercent: snapshot.cpu?.totalPercent,
            memoryUsedPercent: Self.memoryUsedPercent(snapshot.memory),
            memoryPressure: Self.summarize(snapshot.memory?.pressureLevel),
            diskUsedPercent: Self.diskUsedPercent(snapshot.disk),
            batteryTimeRemainingMinutes: Self.batteryRunwayMinutes(snapshot.battery),
            isThrottling: snapshot.thermal?.isThrottling,
            awakeIsActive: Self.awakeIsActive(snapshot.sleepAssertion),
            awakeExpiresAt: Self.awakeExpiresAt(snapshot.sleepAssertion),
            awakeModeLabel: Self.awakeModeLabel(snapshot.sleepAssertion),
            // `SystemSnapshot.agentActivitySummary` is what closes the gap
            // `WatchRelaySnapshot`'s doc comment used to describe as
            // permanent — see that type's field comments for the
            // nil-means-not-reported convention this keeps intact end to
            // end. The Mac assigns the summary on every MCP `authorize()`
            // call (`MCPXPCService`), so these three carry real numbers
            // once an agent has been active and read as "not reported"
            // otherwise — driven by the summary's absence, not by this
            // call site never asking.
            agentToolCallCount: snapshot.agentActivitySummary?.toolCallCount,
            agentLastActivityAt: snapshot.agentActivitySummary?.lastActivityAt,
            agentRecentToolNames: snapshot.agentActivitySummary?.recentToolNames,
            agentAccessPaused: snapshot.agentAccessPaused,
            // Read straight from the same `UserDefaults` key `RootTabView`
            // and `SettingsTabView` bind their `@AppStorage` to, rather than
            // taking an injected `Theme`: this type is a plain actor with no
            // SwiftUI environment to read from, and the key is already the
            // app's single source of truth for "which theme" (see
            // `RootTabView`'s doc comment). Defaulted to match those two call
            // sites exactly so a phone that has never opened Settings relays
            // the same theme it is itself rendering.
            themeID: UserDefaults.standard.string(forKey: "selectedThemeID") ?? Theme.oneDark.id,
            // Written by `RootTabView.publishAppearanceForWatch()` — see
            // `WatchRelaySnapshot.themeAppearance` for why the watch cannot
            // work this out for itself. Absent until this phone has drawn a
            // frame, which the watch treats as `.dark`.
            themeAppearance: UserDefaults.standard.string(forKey: WatchRelayAppearance.defaultsKey),
            // **The Mac's own palette wins when it sent one.** It is the
            // device the user is looking at in the screenshots, it is the
            // only one that can have custom themes at all
            // (`AppSettings.customThemes`), and relaying its resolved
            // colours is what lets those reach the wrist — an id could not.
            // Falls back to flattening this phone's own selected theme, so a
            // Mac that predates the field still produces a themed watch
            // rather than a default-coloured one.
            themePalette: snapshot.themePalette ?? Self.phonePalette()
        )

        let now = Date()
        guard WatchRelayPolicy.shouldRelay(
            previous: lastRelayed,
            next: candidate,
            lastRelayedAt: lastRelayedAt,
            now: now
        ) else {
            return
        }
        relay(candidate, at: now)
    }

    /// The four derivations above, each kept a named `static` function
    /// rather than inlined into the initialiser call, because each one has a
    /// nil case worth naming — and because "returns nil when the Mac didn't
    /// report it" is the entire contract the watch's rendering depends on.
    /// None of them may substitute a zero: see `WatchRelaySnapshot`'s
    /// per-field doc comments for what each `nil` means on screen.

    /// `nil` for a Mac that reported no memory module at all, and also for
    /// the arithmetically impossible `totalBytes == 0` — a divide-by-zero
    /// would produce `.nan`/`.infinity`, which `JSONEncoder` refuses to
    /// encode by default and which would therefore silently take the *whole
    /// relay* down (`wcSessionPayload()` returns nil on an encode failure).
    /// Guarding here rather than trusting the collector is the difference
    /// between one absent tile and a watch that stops updating.
    private static func memoryUsedPercent(_ memory: MemoryStats?) -> Double? {
        guard let memory, memory.totalBytes > 0 else { return nil }
        return Double(memory.usedBytes) / Double(memory.totalBytes) * 100
    }

    /// Used, not free — the same orientation as `MetricID.diskUsedPercent`,
    /// so the watch's tile fills up as the disk does and reads the same
    /// direction as the CPU and memory tiles beside it. Same
    /// `totalBytes == 0` guard and the same reason as above.
    private static func diskUsedPercent(_ disk: DiskStats?) -> Double? {
        guard let disk, disk.totalBytes > 0 else { return nil }
        return (Double(disk.totalBytes) - Double(disk.freeBytes)) / Double(disk.totalBytes) * 100
    }

    /// Time-to-full while charging, time-to-empty otherwise — the
    /// disambiguation `WatchRelaySnapshot.batteryTimeRemainingMinutes`
    /// documents, resolved on this side so the watch never has to guess
    /// which one it is holding.
    ///
    /// A non-positive estimate is discarded rather than relayed: macOS
    /// publishes `0` or a negative sentinel while it is still calibrating
    /// after a power-state change, and "0m left" is a far worse thing to
    /// show on a wrist than nothing at all.
    private static func batteryRunwayMinutes(_ battery: BatteryStats?) -> Int? {
        guard let battery else { return nil }
        let raw = battery.isCharging ? battery.timeToFullMinutes : battery.timeToEmptyMinutes
        guard let raw, raw > 0 else { return nil }
        return raw
    }

    /// `SystemSnapshot.sleepAssertion` flattened into the three scalars the
    /// watch's Keep Awake page needs. Split into three functions rather than
    /// one returning a tuple purely so each one's `nil` case can be read at
    /// the call site above without unpacking anything.
    ///
    /// `nil` in, `nil` out, in all three: a Mac that reported no
    /// `sleepAssertion` has said nothing about whether it will sleep, and
    /// `false` would be a claim it did not make. See
    /// `WatchRelaySnapshot.awakeIsActive`.
    private static func awakeIsActive(_ state: SleepAssertionState?) -> Bool? {
        guard let state else { return nil }
        if case .active = state { return true }
        return false
    }

    /// `nil` for both "no assertion" and "an assertion with no expiry" — the
    /// watch does not need to tell those apart, because `awakeIsActive`
    /// already does: active-with-nil-expiry is worded "until released,"
    /// inactive shows no countdown at all.
    private static func awakeExpiresAt(_ state: SleepAssertionState?) -> Date? {
        guard case .active(_, let expiresAt, _) = state else { return nil }
        return expiresAt
    }

    /// Rendered to a display string here, on the phone, rather than relaying
    /// the `AwakeMode` enum — see `WatchRelaySnapshot.awakeModeLabel` for why
    /// (watch framework source list, and forward compatibility with modes a
    /// future Mac adds).
    ///
    /// `SleepAssertionState.active` also carries a `reason` string, which is
    /// deliberately *not* relayed: it is free-form text set by whatever
    /// created the assertion, unbounded in length, and on a watch it would
    /// either be truncated into uselessness or push the actual controls off
    /// screen. The mode is the part that changes what the assertion does.
    private static func awakeModeLabel(_ state: SleepAssertionState?) -> String? {
        guard case .active(let mode, _, _) = state else { return nil }
        // Localized here on the phone: the watch renders this string
        // verbatim, so the phone's locale (which the paired watch shares)
        // is the right place for the words to be chosen.
        switch mode {
        case .displayAndSystem: return String(localized: "Display & system")
        case .systemOnly: return String(localized: "System only")
        case .systemWhileOnAC: return String(localized: "System while on power")
        }
    }

    private static func summarize(_ level: ThermalStats.PressureLevel?) -> ThermalPressureSummary {
        guard let level else { return .unknown }
        switch level {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        }
    }

    /// The memory counterpart. `nil` in, `nil` out — unlike thermal, the
    /// relay payload distinguishes "the Mac reported no pressure reading"
    /// (`nil`) from "it reported a tier we can't name" (`.unknown`, produced
    /// only by the decoder on the watch side), so this must not collapse the
    /// former into the latter. See `MemoryPressureSummary`'s doc comment.
    private static func summarize(_ level: MemoryPressureLevel?) -> MemoryPressureSummary? {
        guard let level else { return nil }
        switch level {
        case .normal: return .normal
        case .warning: return .warning
        case .critical: return .critical
        }
    }

    private func relay(_ snapshot: WatchRelaySnapshot, at now: Date) {
        lastRelayed = snapshot
        lastRelayedAt = now
        guard let payload = snapshot.wcSessionPayload() else { return }

        let session = WCSession.default
        guard session.activationState == .activated else { return }

        // `updateApplicationContext` is cheap and last-value-wins — always
        // send it so the Watch app has *something* current the next time it
        // wakes up for any reason, budget concerns or not (Apple's own docs
        // don't attach a hard daily cap to this API the way they do to
        // `transferUserInfo`/`transferCurrentComplicationUserInfo`).
        try? session.updateApplicationContext(payload)

        // `transferCurrentComplicationUserInfo` is the API that actually
        // nudges the complication's own background reload budget — reserved
        // for when the Watch app is actually installed (calling it
        // otherwise is a documented no-op that still counts against
        // nothing, but there is no reason to call it at all in that case).
        guard session.isWatchAppInstalled else { return }
        session.transferCurrentComplicationUserInfo(payload)
    }
}

// MARK: - WCSessionDelegate

extension WatchRelayManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // Nothing to do here today — `relay(_:at:)` re-checks
        // `activationState` itself before every send rather than caching a
        // "ready" flag off this callback, since the state can also change
        // later (e.g. the paired Watch is unpaired mid-session) and that
        // same check already handles it.
    }

    /// The other half of `WatchControlBridge.sendAndDescribe(_:whenCompleted:)`
    /// (`SentryWatch/Intents/SentryWatchIntents.swift`) — a watch Siri
    /// intent has no direct path to the Mac (see this type's top-level doc
    /// comment: "a Watch cannot reach the Mac directly"), so it sends its
    /// `ControlCommand` here instead, and this phone forwards it through
    /// exactly the same `AppDataSource.shared.transport` every iPhone Siri
    /// intent (`SentryMobile/Intents/SentryIntents.swift`) already uses.
    ///
    /// Reply shape: `["controlStatus": <JSON-encoded ControlStatus>]` on
    /// success, `["error": "<message>"]` otherwise — the watch decides how
    /// to phrase either outcome for its own Siri dialog; this side only
    /// reports what actually happened, never a guess at wording.
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let commandData = message["watchControlCommand"] as? Data else {
            replyHandler(["error": "Unrecognized message from Apple Watch."])
            return
        }
        Task { @MainActor in
            await Self.handleWatchControlCommand(commandData, replyHandler: replyHandler)
        }
    }

    /// `static` (rather than an instance method) since it needs nothing
    /// from `WatchRelayManager` itself — it only touches the app-wide
    /// `AppDataSource.shared`, the same composition root every other
    /// command-sending call site in this app already reads from.
    @MainActor
    private static func handleWatchControlCommand(
        _ commandData: Data,
        replyHandler: @escaping ([String: Any]) -> Void
    ) async {
        guard let command = try? JSONDecoder().decode(ControlCommand.self, from: commandData) else {
            replyHandler(["error": "Couldn't decode that request."])
            return
        }

        let transport = AppDataSource.shared.transport
        // The same demo-mode guard `SentryIntents.sendAndDescribe` and
        // `SleepStatusCard.sendCommand` apply before every send — this
        // forwarder was the one path that skipped it. `MockDataSource
        // .send(command:)` no-ops without throwing and its `awaitStatus`
        // returns `nil` immediately, so without this guard a watch tap in
        // demo mode came back as "Sent to your Mac, but didn't hear back" —
        // claiming a transmission that never happened, about a Mac that
        // doesn't exist. The truthful sentence is the one every other
        // surface already uses.
        guard !(transport is MockDataSource) else {
            replyHandler(["error": SentryIntents.demoModeSendDialog])
            return
        }
        do {
            try await transport.send(command: command)
        } catch {
            replyHandler(["error": error.localizedDescription])
            return
        }

        guard let status = await transport.awaitStatus(forNonce: command.nonce, timeout: SentryIntents.statusTimeout) else {
            replyHandler(["error": "Sent to your Mac, but didn't hear back — check that Sentry is open on your Mac."])
            return
        }
        guard let statusData = try? JSONEncoder().encode(status) else {
            replyHandler(["error": "Got a reply from your Mac, but couldn't encode it to send back."])
            return
        }
        replyHandler(["controlStatus": statusData])
    }

    /// iOS-only requirement (watchOS has no notion of switching to a
    /// different paired counterpart) — required by the protocol on this
    /// platform even though this app has nothing state-bearing to tear down
    /// beyond what `activationDidCompleteWith` already no-ops.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Required alongside `sessionDidBecomeInactive` on iOS specifically so
    /// the system can hand the session off to a newly-paired Watch —
    /// re-activating is the documented way to opt into that, matching
    /// Apple's own sample code exactly.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
