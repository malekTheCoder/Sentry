import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import SentryKit

/// The sync surface: the TLS-PSK Remote Access listener — its toggle, port,
/// pairing code, and QR pairing flow — for the device sync that actually
/// exists (LAN discovery via Bonjour plus the off-LAN path configured
/// here; see `LocalSyncServer`/`LocalSyncClient`).
///
/// This pane once also carried an honest-disclosure Status section and a
/// reference cadence table for a CloudKit sync layer that was never wired
/// to a real container. That layer has been deleted outright (see git
/// history for `SyncService`/`CKMapper` and the disclosure copy), so the
/// pane no longer needs to explain a cloud feature's absence — the
/// local-network sync below is the whole story, and the house P5 rule
/// ("never overclaim") now simply means describing it accurately.
struct SyncPane: View {

    @ObservedObject var store: SettingsStore

    /// Whether this copy is entitled to `ProFeature.remoteSync`. Resolved by
    /// the composition root's `LicenseProEntitlementStore` and passed down
    /// through `SettingsView` per render — this pane never queries an
    /// entitlement store itself, matching how `AdvancedPane` takes its
    /// `isProUnlocked` from the same caller rather than owning one.
    /// Defaults locked: a pane nobody seeded must not offer the Pro
    /// surface, and every entitlement input (override flip, license paste)
    /// rides a settings emission that re-renders `SettingsView`, so the
    /// value here is never stale.
    var isProUnlocked: Bool = false

    var body: some View {
        Form {
            remoteAccessSection
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
    ///
    /// **The `ProFeature.remoteSync` gate splits this section, not hides
    /// it.** The toggle, code, and QR stay constructible while locked
    /// because the listener's trust model (`LocalSyncServer`'s doc comment)
    /// gives them a free job: commands from the phone — the sleep card,
    /// ending a keep-awake — are only accepted over this authenticated
    /// path, *even on the LAN*, and an affordance that releases must never
    /// sit behind the paywall. What Sentry Pro sells is reachability from
    /// other networks, and while locked that is exactly what's withheld:
    /// `LocalSyncServer` refuses off-LAN peers at accept time
    /// (`RemoteAccessGate`), the QR never encodes a tunnel address
    /// (`refreshHostCandidates`), the toggle's label stops claiming "other
    /// networks", and `lockedOffLANRow` says all of this in words — a
    /// locked row, not a disabled control, per house rule P5 and the
    /// `LockedInsightRowView` precedent. A license that lapses with this
    /// already enabled gets the same treatment, disclosed on this screen
    /// rather than silently: LAN pairing keeps working, off-LAN peers are
    /// turned away.
    private var remoteAccessSection: some View {
        Section {
            Toggle(Self.remoteToggleLabel(isProUnlocked: isProUnlocked), isOn: remoteEnabledBinding)
                .accessibilityLabel(Self.remoteToggleLabel(isProUnlocked: isProUnlocked))

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

            if !isProUnlocked {
                lockedOffLANRow
            }
        } header: {
            Text("Remote Access")
        } footer: {
            Text(Self.remoteAccessFooter(
                enabled: store.settings.remoteSyncEnabled,
                isProUnlocked: isProUnlocked
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The locked half of the section: the off-LAN grant, shown as a row
    /// rather than a disabled toggle (`LockedInsightRowView` and
    /// `ThemePane`'s locked editor row are the precedents — a greyed-out
    /// "Allow connections from other networks" would be a confident-looking
    /// control describing a reality that isn't true). No Buy button, ever:
    /// checkout does not exist, and the copy admits it in the same words
    /// `ProUpsellCard` does.
    private var lockedOffLANRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Connections from other networks")
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.secondary)
            }
            Text(Self.lockedOffLANExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.lockedPurchaseNotice)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Remote-access copy (pure, testable — same convention as cadenceRows)

    /// The toggle names what it actually does in each entitlement state.
    /// Unlocked, it grants what it always granted. Locked, the listener it
    /// opens only answers this network (`LocalSyncServer`'s accept gate),
    /// so a label claiming "other networks" would be false the moment it
    /// was read — the control is relabeled to its true, free scope rather
    /// than disabled or hidden.
    static func remoteToggleLabel(isProUnlocked: Bool) -> String {
        isProUnlocked
            ? String(localized: "Allow connections from other networks")
            : String(localized: "Allow a paired iPhone to control this Mac")
    }

    /// True in every entitlement state: while locked, off-LAN peers are
    /// refused at accept time even when `remoteSyncEnabled` is on — which
    /// is exactly the lapsed-license case, disclosed here rather than
    /// silently enforced.
    static let lockedOffLANExplanation = String(
        localized: "Connecting from outside this Mac's own network is part of Sentry Pro. While it's locked, this Mac turns away connections from other networks even when they hold the pairing code; pairing and control on this Wi-Fi stay free."
    )

    /// Verbatim the admission `ProUpsellCard` and `ThemePane` make — one
    /// sentence, no Buy button wired to a checkout that doesn't exist.
    static let lockedPurchaseNotice = String(
        localized: "Purchasing isn't available yet — Sentry's license checkout hasn't opened. Checkout is coming in an update."
    )

    /// Four honest footers. The unlocked pair is unchanged from before the
    /// gate; the locked pair stops promising Tailscale/port-forward
    /// reachability (that is the withheld feature) and states the
    /// this-network-only scope plainly.
    static func remoteAccessFooter(enabled: Bool, isProUnlocked: Bool) -> String {
        switch (isProUnlocked, enabled) {
        case (true, true):
            return String(localized: "Scan the QR code with your iPhone's Camera app to pair in one step — or enter this Mac's address, the port, and the pairing code in the iPhone app's Settings by hand. The connection is encrypted and refuses any client without the code. Reaching this Mac from another network is up to your network: a VPN like Tailscale needs no configuration (the QR uses the Mac's Tailscale address automatically when it has one); otherwise forward the port on your router. Regenerating the code disconnects any paired phone until it's updated.")
        case (true, false):
            return String(localized: "Lets the Sentry iPhone app connect when it isn't on this Wi-Fi — encrypted, and only with the pairing code shown here after enabling. Off means the Mac only answers phones on the local network, as before.")
        case (false, true):
            return String(localized: "Scan the QR code with your iPhone's Camera app to pair in one step — or enter this Mac's address, the port, and the pairing code in the iPhone app's Settings by hand. The connection is encrypted, refuses any client without the code, and — while Sentry Pro is locked — only answers devices on this network. Regenerating the code disconnects any paired phone until it's updated.")
        case (false, false):
            return String(localized: "Pairing lets the Sentry iPhone app control this Mac — extend, shorten or end a keep-awake — over an encrypted connection on this Wi-Fi. Off means the Mac only streams read-only vitals, as before. Connecting from other networks is part of Sentry Pro.")
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
        // An entitlement flip while this row is on screen (license pasted,
        // override toggled, lapse landing via a settings reload) must
        // re-filter the candidates immediately — a locked copy showing a
        // tunnel address until the pane is next reopened would leak the
        // withheld value.
        .onChange(of: isProUnlocked) { _, _ in refreshHostCandidates() }
    }

    private func candidateLabel(_ candidate: RemotePairing.HostCandidate) -> String {
        switch candidate.kind {
        case .tailscale: return "\(candidate.address) — Tailscale/VPN"
        case .lan: return "\(candidate.address) — this Wi-Fi only"
        }
    }

    private func refreshHostCandidates() {
        // Locked copies never see a Tailscale/VPN candidate: the tunnel
        // address is the off-LAN value the Pro gate withholds, and a QR
        // encoding it would walk a free user into a connection the Mac
        // then refuses at accept time. See `RemoteAccessGate
        // .visibleHostCandidates`.
        hostCandidates = RemoteAccessGate.visibleHostCandidates(
            RemotePairing.hostCandidates(),
            isProUnlocked: isProUnlocked
        )
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
    ///
    /// Minting is deliberately not Pro-gated: the code is the free tier's
    /// LAN pairing secret (command auth on this Wi-Fi rides the same
    /// TLS-PSK listener — see `remoteAccessSection`'s doc comment), not
    /// the withheld off-LAN grant.
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

}
