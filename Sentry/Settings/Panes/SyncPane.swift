import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import SentryKit

/// The sync surface: a real dashboard for the device sync that exists — LAN
/// discovery plus the TLS-PSK Remote Access listener configured right here —
/// and an honest disclosure for the cloud sync that doesn't.
///
/// **Why the cloud half is disclosure rather than UI.** Plan §7's CloudKit
/// sync has no implementation: `Sentry.entitlements` deliberately
/// claims no iCloud container and no `aps-environment` (see its header for
/// why entitlements for unwritten features are not added speculatively), and
/// there is still no `CKContainer`, no push subscription, and no schema
/// promotion anywhere in this app. `SyncService` (`SentryKit/Sync/SyncService.swift`)
/// is real, tested, adaptive-cadence scheduling logic, but it is constructed
/// nowhere in `AppDelegate` and has no `uploadAttempt` closure that talks to a
/// server, because there is no server to talk to. A settings pane that hid
/// behind "coming soon" would leave a user wondering whether sync silently
/// isn't working for *them* specifically; saying plainly why it doesn't exist
/// yet is the honest version of the same disclosure.
///
/// **What this pane refuses to show, on purpose (house rule P5 — "never
/// overclaim").** This codebase has shipped exactly this bug before in
/// different clothes: a settings slider that silently did nothing, and a
/// history pane that reported "no alerts fired" when its database had
/// actually failed to open (`AdvancedPane`/history's honesty footnotes; see
/// `AlertsPane.historyIsAvailable`'s doc comment for the canonical writeup of
/// that second one). Both were bugs of confident-looking UI describing a
/// reality that wasn't true. Applying that lesson here rules out:
///   - Any word implying liveness — "Connected," "Syncing," "Up to date,"
///     "Last synced Xm ago." There has never been a successful upload, ever,
///     on any Mac running this build, because the upload path does not exist.
///   - A spinner, progress bar, or activity indicator of any kind — all of
///     those *read* as "something is happening right now," and nothing is.
///   - Fabricated-looking statistics (record counts, upload history, a
///     "queue" the user could believe is draining). `SyncService.pendingRecordCount()`
///     would always read 0 in this build (nothing calls `enqueue*` because
///     nothing produces `CKRecord`s to enqueue), and showing "0 pending"
///     reads exactly like a working queue that's merely caught up — the
///     specific shape of misleading this pane exists to avoid.
///   - The `cloudKitSyncEnabled` toggle already sitting in `AppSettings`
///     (`SentryKit/Settings/AppSettings.swift`). It has no reader anywhere
///     in the app — flipping it changes a bit in `settings.json` and nothing
///     else observably happens, which is the textbook "slider that silently
///     does nothing" bug. Surfacing it as an interactive control here would
///     manufacture exactly that bug rather than merely inheriting a
///     pre-existing dead field; better to leave it unexposed until something
///     real reads it.
///
/// **What is honest to show: the cadence table, as documentation, not
/// status.** `SyncService.effectiveInterval(onBattery:iPhoneRecentlyActive:)`
/// and the "significant event → immediate" rule are pure, fully-tested logic
/// (see `SyncServiceTests`) — they are correct today independent of whether
/// any instance is running, the same way a function's unit tests are true
/// before the function is ever called from production code. Presenting them
/// as "the rules this build is written to follow once sync is connected" is a
/// claim about the *code*, which is verifiably true, not a claim about
/// *activity*, which would not be. The wording throughout below says
/// "configured to" / "will," never "is" / "currently," to keep that
/// distinction visible on screen and not just in this comment.
///
/// **Why no `SyncService` instance is threaded in here, live or otherwise.**
/// This task considered constructing a real `SyncService` in `AppDelegate`
/// with a no-op `uploadAttempt` closure (`{ _ in .failure(retryAfterSeconds: nil) }`)
/// purely so this pane would have a live object to observe. Rejected:
/// `start()` arms a real, self-rescheduling `DispatchSourceTimer` — cheap
/// relative to `StatsCoordinator`'s, but not free — that would then run for
/// the lifetime of the app, on every user's Mac, forever, in service of a
/// queue nothing ever populates and a closure that always fails. That is a
/// permanent resource cost paid by every installed copy of Sentry for zero
/// current benefit, which is a worse trade than this pane reading purely from
/// `SyncService`'s `static` cadence functions (`effectiveInterval`,
/// `backoffDelay`) — no instance, no timer, no queue, just the same numbers a
/// running instance would compute, shown as reference rather than telemetry.
/// The real instance still belongs in `AppDelegate` the moment there is an
/// `uploadAttempt` closure worth giving it — enrollment unblocks both at
/// once, and this pane's honest-empty-state framing should be revisited
/// alongside that wiring, not before it.
struct SyncPane: View {

    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            remoteAccessSection

            Section {
                Label {
                    Text("iCloud sync isn't available in this build")
                        .fontWeight(.semibold)
                } icon: {
                    Image(systemName: "icloud.slash")
                        .foregroundStyle(.secondary)
                }

                Text("iCloud sync doesn't exist in this build — no iCloud container, no account, no server. Nothing has ever cloud-synced on this Mac, and nothing is attempting to; that's true for every copy of this build, not a per-user setting or a bug to troubleshoot. Syncing to your iPhone and Apple Watch is separate: it runs directly over your network — automatic on the same Wi-Fi, and via Remote Access above from anywhere else.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Status")
            }

            Section {
                ForEach(Self.cadenceRows()) { row in
                    LabeledContent(row.condition, value: row.interval)
                }
            } header: {
                Text("Upload Schedule")
            } footer: {
                Text("This is the cadence Sentry's sync engine is built and tested to follow once it's connected — it doesn't describe anything happening right now. A significant change (plugging in, unplugging, an alert firing, or a pull-to-refresh from the iPhone app) is configured to upload immediately rather than waiting out the interval above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Remote access (off-LAN phone connections)

    /// The phone-from-anywhere path: a TLS-PSK listener on a fixed port
    /// (see `SyncSecurity`), guarded by a pairing code shown here and
    /// entered once on the phone. What this section deliberately does NOT
    /// claim: that enabling it makes the Mac reachable from the internet.
    /// Reachability is the user's network arrangement (Tailscale is the
    /// no-configuration way; a router port-forward also works), and the
    /// footer says so instead of pretending a toggle can do it.
    private var remoteAccessSection: some View {
        Section {
            Toggle("Allow connections from other networks", isOn: remoteEnabledBinding)
                .accessibilityLabel("Allow connections from other networks")

            if store.settings.remoteSyncEnabled {
                pairingQRRow
                LabeledContent("Port", value: "\(store.settings.remoteSyncPort)")
                LabeledContent("Pairing code") {
                    HStack(spacing: 8) {
                        Text(store.settings.remoteSyncPairingCode)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(store.settings.remoteSyncPairingCode, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Copy pairing code")
                        Button("Regenerate") {
                            store.settings.remoteSyncPairingCode = SyncSecurity.generatePairingCode()
                        }
                        .accessibilityHint("Invalidates the old code — the phone must be re-paired")
                    }
                }
            }
        } header: {
            Text("Remote Access")
        } footer: {
            Text(store.settings.remoteSyncEnabled
                ? "Scan the QR code with your iPhone's Camera app to pair in one step — or enter this Mac's address, the port, and the pairing code in the iPhone app's Settings by hand. The connection is encrypted and refuses any client without the code. Reaching this Mac from another network is up to your network: a VPN like Tailscale needs no configuration (the QR uses the Mac's Tailscale address automatically when it has one); otherwise forward the port on your router. Regenerating the code disconnects any paired phone until it's updated."
                : "Lets the Sentry iPhone app connect when it isn't on this Wi-Fi — encrypted, and only with the pairing code shown here after enabling. Off means the Mac only answers phones on the local network, as before.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - QR pairing (scan with the iPhone's Camera app)

    /// The address candidates this Mac found for itself, refreshed each
    /// time the section appears — interfaces change (Tailscale toggled,
    /// Wi-Fi network switched) and a stale QR would encode an address the
    /// Mac no longer holds.
    @State private var hostCandidates: [RemotePairing.HostCandidate] = []

    /// The address the QR currently encodes. Defaults to the top-ranked
    /// candidate (Tailscale first — see `RemotePairing.hostCandidates()`);
    /// the picker only appears when there's actually a choice to make.
    @State private var selectedHost: String = ""

    /// One QR code encoding `sentry://pair?host=…&port=…&code=…`
    /// (`RemotePairing.url(for:)`) — scanned by the iPhone's built-in
    /// Camera app, which opens the Sentry iPhone app with every field
    /// already filled, replacing the type-three-fields-by-hand flow. The
    /// image regenerates reactively off the selected host, the port, and
    /// the code (so "Regenerate" immediately invalidates the on-screen QR
    /// too, keeping screen and truth in agreement).
    private var pairingQRRow: some View {
        LabeledContent("Pair iPhone") {
            VStack(alignment: .trailing, spacing: 8) {
                if let qr = Self.qrImage(
                    host: selectedHost,
                    port: store.settings.remoteSyncPort,
                    code: store.settings.remoteSyncPairingCode
                ) {
                    Image(nsImage: qr)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 132, height: 132)
                        .padding(6)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("QR code for pairing an iPhone")
                    if hostCandidates.count > 1 {
                        Picker("Address in the code", selection: $selectedHost) {
                            ForEach(hostCandidates) { candidate in
                                Text(candidateLabel(candidate)).tag(candidate.address)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        .accessibilityLabel("Address encoded in the QR code")
                    } else if let only = hostCandidates.first {
                        Text(candidateLabel(only))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No usable address found on this Mac's interfaces — enter the address on the phone manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 220, alignment: .trailing)
                }
            }
        }
        .onAppear(perform: refreshHostCandidates)
    }

    private func candidateLabel(_ candidate: RemotePairing.HostCandidate) -> String {
        switch candidate.kind {
        case .tailscale: return "\(candidate.address) — Tailscale/VPN"
        case .lan: return "\(candidate.address) — this Wi-Fi only"
        }
    }

    private func refreshHostCandidates() {
        hostCandidates = RemotePairing.hostCandidates()
        if !hostCandidates.contains(where: { $0.address == selectedHost }) {
            selectedHost = hostCandidates.first?.address ?? ""
        }
    }

    /// Renders the pairing link as a QR NSImage at the generator's native
    /// module size — the view scales it up with interpolation off, so the
    /// modules stay crisp without pre-scaling through CoreImage transforms.
    /// `nil` when there's no address/code to encode (the row shows honest
    /// fallback copy instead of an empty white square).
    static func qrImage(host: String, port: Int, code: String) -> NSImage? {
        guard let url = RemotePairing.url(
            for: RemotePairing.Endpoint(host: host, port: UInt16(clamping: port), code: code)
        ) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// Enabling for the first time mints the pairing code — a toggle that
    /// opened a listener with no code would be a lock with no key.
    private var remoteEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.remoteSyncEnabled },
            set: { enabled in
                if enabled && store.settings.remoteSyncPairingCode.isEmpty {
                    store.settings.remoteSyncPairingCode = SyncSecurity.generatePairingCode()
                }
                store.settings.remoteSyncEnabled = enabled
            }
        )
    }

    // MARK: - Cadence table (pure, testable, no SyncService instance required)

    /// One row of the plan §7.4 cadence table, formatted for display.
    /// `Identifiable` by `condition` since the table is small and fixed —
    /// two rows can never share a condition string.
    struct CadenceRow: Identifiable, Equatable {
        var id: String { condition }
        let condition: String
        let interval: String
    }

    /// Builds the cadence table entirely from `SyncService`'s `static`
    /// functions and default constants — no `SyncService` instance, timer,
    /// or queue involved (see this file's top-level doc comment for why that
    /// matters). Kept `static` and free of view state so it's unit-testable
    /// without a view hierarchy, matching `AlertsPane.humanDuration`'s
    /// convention elsewhere in this codebase.
    static func cadenceRows() -> [CadenceRow] {
        [
            CadenceRow(
                condition: "On AC power, iPhone active in the last 10 min",
                interval: intervalLabel(
                    SyncService.effectiveInterval(onBattery: false, iPhoneRecentlyActive: true)
                )
            ),
            CadenceRow(
                condition: "On AC power, iPhone idle",
                interval: intervalLabel(
                    SyncService.effectiveInterval(onBattery: false, iPhoneRecentlyActive: false)
                )
            ),
            CadenceRow(
                condition: "On battery power",
                interval: intervalLabel(
                    SyncService.effectiveInterval(onBattery: true, iPhoneRecentlyActive: false)
                )
            ),
            CadenceRow(
                condition: "Significant event or manual refresh",
                interval: "Immediately"
            ),
        ]
    }

    /// Spells a cadence interval out the way a person would say it —
    /// "Every 30 seconds," "Every 5 minutes" — rather than a raw
    /// `TimeInterval`. Deliberately simpler than `AlertsPane.humanDuration`:
    /// every value this pane ever passes in comes from
    /// `SyncService.effectiveInterval`'s own default constants (30 s / 300 s /
    /// 600 s), which are always whole numbers of seconds or whole numbers of
    /// minutes, so there is no fractional case to handle.
    static func intervalLabel(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return String(localized: "Immediately") }
        // Whole localized sentences per plural branch rather than a spliced
        // "s" — suffix-gluing assumes English pluralization and leaves a
        // translator with an untranslatable fragment.
        if seconds < 60 {
            let value = Int(seconds.rounded())
            let valueText = String(value)
            return value == 1
                ? String(localized: "Every 1 second")
                : String(localized: "Every \(valueText) seconds")
        }
        let minutes = Int((seconds / 60).rounded())
        let minutesText = String(minutes)
        return minutes == 1
            ? String(localized: "Every 1 minute")
            : String(localized: "Every \(minutesText) minutes")
    }
}
