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
    /// **This section used to be split by an entitlement.** Off-LAN
    /// reachability was the paid half: the toggle was relabelled to its
    /// free scope, the QR dropped tunnel addresses, a locked row explained
    /// the refusal, and `LocalSyncServer` turned off-LAN peers away at
    /// accept time. None of that exists now — one toggle, one label, one
    /// footer, and the pairing code is the only thing standing between a
    /// phone and this Mac, which is what the trust model always said.
    private var remoteAccessSection: some View {
        Section {
            Toggle(Self.remoteToggleLabel, isOn: remoteEnabledBinding)
                .accessibilityLabel(Self.remoteToggleLabel)

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
            Text(Self.remoteAccessFooter(enabled: store.settings.remoteSyncEnabled))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Remote-access copy (pure, testable — same convention as cadenceRows)

    /// The toggle names what it actually does. One label now, where there
    /// used to be two: the entitlement-narrowed variant ("Allow a paired
    /// iPhone to control this Mac") existed because a locked listener
    /// answered only this network, and claiming "other networks" would have
    /// been false the moment it was read. Nothing narrows it any more, so
    /// the broader sentence is simply true.
    static let remoteToggleLabel = String(localized: "Allow connections from other networks")

    /// Two honest footers, down from four. The locked pair stated a
    /// this-network-only scope that no longer exists; these are the
    /// unlocked pair, unchanged from before the gate, which is the accurate
    /// description of what the toggle does for everyone.
    static func remoteAccessFooter(enabled: Bool) -> String {
        enabled
            ? String(localized: "Scan the QR code with your iPhone's Camera app to pair in one step — or enter this Mac's address, the port, and the pairing code in the iPhone app's Settings by hand. The connection is encrypted and refuses any client without the code. Reaching this Mac from another network is up to your network: a VPN like Tailscale needs no configuration (the QR uses the Mac's Tailscale address automatically when it has one); otherwise forward the port on your router. Regenerating the code disconnects any paired phone until it's updated.")
            : String(localized: "Lets the Sentry iPhone app connect when it isn't on this Wi-Fi — encrypted, and only with the pairing code shown here after enabling. Off means the Mac only answers phones on the local network, as before.")
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
        // Every candidate this Mac has, Tailscale-first as
        // `RemotePairing.hostCandidates()` ranks them. A filter used to sit
        // here stripping tunnel addresses out for unlicensed copies.
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
