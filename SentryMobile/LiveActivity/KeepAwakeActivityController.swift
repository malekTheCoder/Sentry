import ActivityKit
import Combine
import Foundation
import SentryKit

// MARK: - KeepAwakeActivityController: the phone's half of the keep-awake Live Activity

/// Watches the Mac's reported `SleepAssertionState` and keeps the keep-awake
/// Live Activity in agreement with it — starting one when a hold appears,
/// updating it when the hold is extended or truncated, ending it when the
/// hold goes away, and marking it stale the moment the phone stops being
/// able to vouch for any of that.
///
/// **Why a root-level singleton rather than something a view model owns.**
/// The same reason `WatchRelayManager` is one, spelled out in that type's
/// doc comment: `WidgetSnapshotWriter` can live on `DashboardViewModel`
/// because the widget only ever needs "whatever the Dashboard last saw," but
/// a Live Activity is on the Lock Screen regardless of which tab is on
/// screen, or whether any tab is. It is started once from `SentryMobileApp`'s
/// root `.task`, next to `WatchRelayManager.shared.start()` and
/// `AppDataSource.shared.resolveIfNeeded()`.
///
/// **Why it subscribes to `AppDataSource.shared.$transport` itself.**
/// `StatsTransport.snapshots()` is explicitly documented as free to fan one
/// underlying subscription out to many returned streams, so a second
/// subscriber here is a second `AsyncStream` view onto the one
/// `LocalSyncClient` the app already owns — not a second Bonjour browser.
/// Same argument `WatchRelayManager` makes for the same choice.
///
/// **What it does not do: decide anything.** Every rule about when to start,
/// update or end lives in `KeepAwakeActivityLifecycle`, and every rule about
/// what may be claimed lives in `KeepAwakeActivityState` — both in
/// `SentryKit`, both Foundation-only, both consequently covered by
/// `SentryTests` (a macOS bundle that cannot import ActivityKit at all).
/// This file is the wiring: snapshots and connection state in, one
/// `KeepAwakeActivityAction` out, handed to `KeepAwakeActivityPresenter`.
@MainActor
final class KeepAwakeActivityController {

    static let shared = KeepAwakeActivityController()

    /// The `UserDefaults` key behind the Settings toggle. Duplicated as a
    /// string literal in `SettingsTabView` for the reason `RootTabView`'s
    /// doc comment gives about `"selectedThemeID"`: `@AppStorage` resolves
    /// by string key against the default suite, not by any shared Swift
    /// symbol, so the literal is what actually keeps a view and a non-view
    /// reader in sync. Declared here as well because this type is not a
    /// `View` and has no `@AppStorage` to declare.
    static let enabledDefaultsKey = "liveActivityEnabled"

    /// How often the controller re-examines the world without new news.
    ///
    /// This exists for the two things a snapshot stream cannot tell you:
    /// that a timed hold's deadline has *passed* (nothing arrives to
    /// announce it — the Mac may have gone quiet, and the OS-level assertion
    /// timeout released the hold without anybody sending a message), and
    /// that the connection has dropped. Thirty seconds is well inside
    /// `KeepAwakeActivityState.unconfirmedIndefiniteTolerance` and cheap:
    /// a tick with nothing to do performs no ActivityKit calls at all.
    private static let reconcileInterval: TimeInterval = 30

    /// News older than this is not news. Used to decide whether the last
    /// `SleepAssertionState` received still counts as a *report* for
    /// `KeepAwakeActivityLifecycle`'s purposes, or whether the phone should
    /// be treated as having heard nothing.
    ///
    /// `Freshness.liveThreshold` (one minute) rather than a number invented
    /// here — it is already this codebase's boundary for "this reading is
    /// current." The distinction is load-bearing rather than cosmetic:
    /// re-feeding a minutes-old assertion into the lifecycle every tick
    /// would let the confirmation heartbeat re-stamp `lastConfirmedAt` with
    /// the present time, which would make an indefinite hold look
    /// continuously re-confirmed by a Mac that has said nothing since. The
    /// staleness machinery would then be measuring the controller's own
    /// pulse instead of the Mac's.
    private static let reportValidity: TimeInterval = Freshness.liveThreshold

    private let appDataSource: AppDataSource

    private var transportSubscription: AnyCancellable?
    private var connectionSubscription: AnyCancellable?
    private var snapshotTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?

    /// The last assertion the Mac actually reported, and the timestamp *it*
    /// carried — the moment the reading was taken on the Mac, not the moment
    /// this phone decoded it. Same choice `WidgetSnapshotWriter` makes for
    /// the widget cache's `lastSeen`, for the same reason: the network's
    /// latency should not be able to make a reading look fresher than it is.
    private var lastReported: SleepAssertionState?
    private var lastReportedAt: Date?

    /// The reachability last published into the activity's `staleDate`, so a
    /// connection dropping (or coming back) republishes exactly once rather
    /// than on every tick.
    private var publishedReachability: Bool?

    private var deviceName: String = ""

    private init(appDataSource: AppDataSource = .shared) {
        self.appDataSource = appDataSource
    }

    // MARK: - Lifecycle

    /// Called once from `SentryMobileApp`'s root `.task`.
    func start() {
        transportSubscription = appDataSource.$transport
            .sink { [weak self] transport in
                guard let self else { return }
                self.observeSnapshots(transport: transport)
                Task { [weak self] in
                    self?.deviceName = await self?.appDataSource.devices().first?.deviceName ?? ""
                    await self?.reconcile()
                }
            }

        // A dropped connection is not a snapshot, so it would otherwise only
        // be noticed on the next 30-second tick. It is also the single most
        // important thing this controller can react to promptly: it is the
        // moment the Lock Screen's claim stops being backed by anything.
        connectionSubscription = appDataSource.$isLocalSyncConnected
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { [weak self] in await self?.reconcile() }
            }

        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.reconcileInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.reconcile()
            }
        }

        // Adopt whatever survived a previous run of this process before any
        // news arrives. ActivityKit keeps Live Activities alive across app
        // termination, so a phone that was force-quit mid-hold comes back to
        // find its own activity still on the Lock Screen — and the first
        // thing that must happen is the "has this certainly ended?" check,
        // which needs no Mac to be reachable and is what stops a dead hold
        // becoming a permanent ghost.
        Task { [weak self] in await self?.reconcile() }
    }

    private func observeSnapshots(transport: any StatsTransport) {
        snapshotTask?.cancel()
        // Demo data must never reach the Lock Screen. `MockDataSource`'s
        // output is plausible-looking by design and carries a
        // `sleepAssertion` like any other snapshot; the in-app surfaces
        // disclose it with a banner and a tag (`DemoDataDisclosure`), and a
        // Live Activity has nowhere to put either. Same derivation
        // `WidgetSnapshotWriter` and `WatchRelayManager` use — the transport's
        // identity, not the data.
        guard !(transport is MockDataSource) else {
            lastReported = nil
            lastReportedAt = nil
            return
        }
        snapshotTask = Task { [weak self] in
            for await snapshot in transport.snapshots() {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.lastReported = snapshot.sleepAssertion
                self.lastReportedAt = snapshot.timestamp
                await self.reconcile()
            }
        }
    }

    // MARK: - Reconciliation

    /// One pass: read what is on the Lock Screen, read what the Mac last
    /// said, ask the state machine what to do, do it.
    func reconcile(now: Date = Date()) async {
        let showing = KeepAwakeActivityPresenter.currentState
        let reachable = isMacReachable
        let action = KeepAwakeActivityLifecycle.next(
            showing: showing,
            reported: freshReport(asOf: now),
            reportedAt: lastReportedAt,
            isEnabled: isEnabled,
            now: now
        )

        if case .none = action {
            // Nothing to say about the hold — but the *confidence* in what
            // is already displayed may have changed. A connection that just
            // dropped means the activity's `staleDate` should be now rather
            // than whatever future instant it was published with; a
            // connection that just came back means the opposite. Republished
            // only on a flip, so a persistently offline phone doesn't push
            // an update every thirty seconds for the same fact.
            guard let showing, reachable != publishedReachability else { return }
            await KeepAwakeActivityPresenter.apply(
                .update(showing),
                deviceName: deviceName,
                startedAt: now,
                now: now,
                isMacReachable: reachable
            )
            publishedReachability = reachable
            return
        }

        await KeepAwakeActivityPresenter.apply(
            action,
            deviceName: deviceName.isEmpty ? String(localized: "your Mac") : deviceName,
            // Only consulted when starting. `now` is the honest answer for a
            // hold this phone is watching begin; for one already running on
            // the Mac when the app opened, it is the start of the *watched*
            // window rather than of the hold, which is why the progress bar
            // is the secondary readout and the countdown text — computed
            // from `expiresAt` alone and therefore exact either way — is the
            // primary one. There is no field anywhere in `SleepAssertionState`
            // carrying a hold's start, so the alternative is not a better
            // number, it is no bar at all.
            startedAt: now,
            now: now,
            isMacReachable: reachable
        )

        switch action {
        case .start, .update:
            publishedReachability = reachable
        case .end:
            publishedReachability = nil
        case .none:
            break
        }
    }

    /// The last reported assertion, but only while it is recent enough to
    /// still count as news — see `reportValidity`.
    private func freshReport(asOf now: Date) -> SleepAssertionState? {
        guard let lastReported, let lastReportedAt else { return nil }
        guard now.timeIntervalSince(lastReportedAt) < Self.reportValidity else { return nil }
        return lastReported
    }

    /// Whether the phone can currently hear the Mac at all. Read from
    /// `AppDataSource`'s own published connection flag rather than inferred
    /// from snapshot gaps, because it is the direct answer and it flips the
    /// instant `LocalSyncClient`'s connection does.
    private var isMacReachable: Bool {
        appDataSource.isLocalSyncConnected && !(appDataSource.transport is MockDataSource)
    }

    /// The user's opt-out. Defaults to on, so the feature works without
    /// anyone having to find a switch first; `object(forKey:)` rather than
    /// `bool(forKey:)` because the latter returns `false` for an absent key
    /// and would therefore ship the feature off by default while the
    /// Settings toggle showed it on.
    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
    }
}
