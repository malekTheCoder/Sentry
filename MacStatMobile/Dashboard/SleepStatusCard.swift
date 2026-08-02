import SwiftUI
import MacStatKit

/// Plan §12.1 asks for a "Sleep-prevention control card (toggle + duration +
/// countdown)." Historically this was deliberately *not* a control — see the
/// "Why no toggle" section below for the reasoning that still applies to
/// *why a silent no-op button is worse than no button*. What changed: this
/// card now offers extend/truncate/end buttons anyway, because the
/// established `KeepAwakeIntent`/`ReleaseAwakeIntent` precedent
/// (`MacStatMobile/Intents/MacStatIntents.swift`) shows the actual failure
/// mode isn't "a button exists" — it's "a button silently does nothing." A
/// button that visibly, immediately reports "not sent — no connection to
/// your Mac yet" on every tap (see `feedback`/`sendCommand(_:)` below) is the
/// honest version of "coming soon, and here's the control that'll work the
/// day it ships" — the same shape Siri's spoken dialog already uses for
/// `KeepAwakeIntent`.
///
/// **These buttons are real now.** They were originally inert (every tap
/// reported "not sent — no connection to your Mac yet") because
/// `StatsTransport.send(command:)` had no working conformer. It does now:
/// `LocalSyncClient.send(command:)` transmits over the live connection —
/// LAN (Bonjour) or remote (TLS-PSK), whichever `AppDataSource` resolved —
/// and `awaitStatus(forNonce:timeout:)` reports what the Mac actually did.
/// `sendCommand(_:)` below still never claims success unless a real
/// `ControlStatus` said so: a send failure, a silent Mac, and a Mac that
/// actively declined are three distinct messages, never collapsed into one
/// optimistic "Done."
///
/// **Why still no toggle.** A toggle needs a persistent, always-current
/// on/off binding to mean anything; this card has point-in-time taps plus
/// whatever `SystemSnapshot.sleepAssertion` the Mac last reported, with no
/// two-way binding in between. The extend/truncate/end buttons remain the
/// right shape: each tap is its own request-and-report round trip, not a
/// state the UI must keep synchronized between taps.
///
/// **What's real and shown:** the *current* sleep-assertion state as last
/// reported by the Mac, read straight off `SystemSnapshot.sleepAssertion` —
/// formatted with the same vocabulary `SleepControlCard`'s `activeDetail(for:)`
/// uses on the Mac side (mode label, reason string, countdown/"until turned
/// off").
struct SleepStatusCard: View {
    @Environment(\.themePalette) private var palette

    /// `nil` when the snapshot predates `sleepAssertion` being populated, or
    /// the Mac hasn't reported one yet — distinct from `.inactive`, which is
    /// a real "not preventing sleep right now" reading. Rendered as
    /// "Unavailable," never folded into the inactive case, so the two
    /// meanings ("we know it's off" vs "we don't know") stay distinguishable.
    let assertion: SleepAssertionState?

    /// The Mac this card's buttons would target — `Device.deviceID` from
    /// `DashboardViewModel.selectedDevice`, mirroring `ControlCommand
    /// .deviceID`'s doc comment ("Target Mac"). Falls back to `"unknown"`,
    /// the same placeholder `MacStatIntents.swift`'s two intents already use
    /// when nothing better is available — there's no live pairing/device
    /// picker result to be more specific with yet either.
    var deviceID: String = "unknown"

    /// Non-nil for a few seconds right after a button tap — see
    /// `sendCommand(_:)`. Never claims success; always the honest "not
    /// connected yet" line, so a tap always gets a visible reaction instead
    /// of silently doing nothing.
    @State private var feedback: String?
    @State private var feedbackTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            header
            switch assertion {
            case .active(let mode, let expiresAt, let reason):
                activeDetail(mode: mode, expiresAt: expiresAt, reason: reason)
            case .inactive:
                Text("Sleep behaves normally on this Mac.")
                    .font(palette.font(size: 11))
                    .foregroundStyle(palette.textTertiary)
            case nil:
                Text("Unavailable")
                    .font(palette.font(size: 11))
                    .foregroundStyle(palette.textTertiary)
            }
            if let feedback {
                Text(feedback)
                    .font(palette.font(size: 10, weight: .medium))
                    .foregroundStyle(palette.warning)
                    .transition(.opacity)
            } else {
                remoteControlNote
            }
        }
        .padding(palette.spacing * 1.4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(palette)
        .overlay(
            RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                .stroke(isActive ? palette.accent.opacity(0.5) : palette.separator, lineWidth: 1)
        )
        .animation(.default, value: feedback)
    }

    private var isActive: Bool {
        if case .active = assertion { return true }
        return false
    }

    /// Nocturne redesign spec: when active, this card leads with "Preventing
    /// sleep" + an "● Active" status pill in the accent color — the header
    /// used to always say "Sleep Prevention" regardless of state, with the
    /// active/inactive distinction buried in a 10px subtitle underneath.
    private var header: some View {
        HStack(spacing: palette.spacing) {
            Image(systemName: isActive ? "moon.zzz.fill" : "moon.zzz")
                .foregroundStyle(isActive ? palette.accent : palette.textSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(isActive ? "Keeping Mac awake" : "Keep Mac awake")
                    .font(palette.font(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                if !isActive {
                    Text("Reporting from your Mac")
                        .font(palette.font(size: 10))
                        .foregroundStyle(palette.textTertiary)
                }
            }
            Spacer(minLength: palette.spacing)
            if isActive {
                activeStatusPill
            }
        }
    }

    private var activeStatusPill: some View {
        HStack(spacing: 4) {
            Text("●")
                .font(.system(size: 8))
            Text("Active")
                .font(palette.font(size: 11, weight: .semibold))
        }
        .foregroundStyle(palette.accent)
    }

    @ViewBuilder
    private func activeDetail(mode: AwakeMode, expiresAt: Date?, reason: String) -> some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            if let expiresAt {
                // SwiftUI's `.timer` text style redraws itself every second
                // and counts down to `expiresAt` on its own — no local
                // `TimelineView`/tick logic needed to match the Mac card's
                // live countdown. Explicit `design: .monospaced` (true SF
                // Mono), not just `.monospacedDigit()` on the system font,
                // per the redesign spec's "SF Mono tabular for every
                // numeric readout" — this is the one big/hero numeric value
                // on this card, so it gets the 24px treatment.
                Text(expiresAt, style: .timer)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.textPrimary)
                adjustRow
            } else {
                Text("No countdown — ends when turned off on the Mac")
                    .font(palette.font(size: 11))
                    .foregroundStyle(palette.textTertiary)
            }
            DashboardDetailRow(label: "Mode", value: mode.mobileShortLabel)
            Text(reason)
                .font(palette.font(size: 10))
                .foregroundStyle(palette.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            endNowButton
        }
    }

    /// Extend/truncate only apply to a timed hold (an `expiresAt` to move) —
    /// same scoping `PowerControlService.adjustAssertion(bySeconds:)` enforces
    /// on the Mac side, so a tap here would ask for exactly what that method
    /// would accept once a real command reaches it.
    private var adjustRow: some View {
        HStack(spacing: palette.spacing * 0.6) {
            adjustButton("-15m", commandType: "truncateAwake", seconds: -15 * 60)
            adjustButton("+15m", commandType: "extendAwake", seconds: 15 * 60)
            adjustButton("+1h", commandType: "extendAwake", seconds: 60 * 60)
        }
    }

    private func adjustButton(_ title: String, commandType: String, seconds: TimeInterval) -> some View {
        Button(title) {
            sendCommand(
                ControlCommand(
                    deviceID: deviceID,
                    issuedAt: Date(),
                    commandType: commandType,
                    parametersJSON: #"{"deltaSeconds":\#(Int(seconds))}"#,
                    nonce: UUID().uuidString,
                    expiresAt: Date().addingTimeInterval(5 * 60)
                )
            )
        }
        .buttonStyle(.plain)
        .font(palette.font(size: 10, weight: .medium))
        .foregroundStyle(palette.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerRadius * 0.6, style: .continuous))
    }

    private var endNowButton: some View {
        Button("End Now") {
            sendCommand(
                ControlCommand(
                    deviceID: deviceID,
                    issuedAt: Date(),
                    commandType: "releaseAwake",
                    parametersJSON: "{}",
                    nonce: UUID().uuidString,
                    expiresAt: Date().addingTimeInterval(5 * 60)
                )
            )
        }
        .buttonStyle(.plain)
        .font(palette.font(size: 10, weight: .medium))
        .foregroundStyle(palette.danger)
    }

    /// Constructs and "sends" a real `ControlCommand` — through the app-wide
    /// `AppDataSource.shared.transport` (`MacStatMobile/Data/AppDataSource.swift`)
    /// every other call site in this app now reads from, not a locally
    /// constructed `MockDataSource()` — then always shows the honest
    /// result, never a fabricated success. Both `MockDataSource.send
    /// (command:)` and `LocalSyncClient.send(command:)` are honest about not
    /// delivering anything today (the former is a documented no-op, the
    /// latter `throw`s "not supported yet" — see that type's doc comment),
    /// so `try?` swallowing the result and always showing the same "not
    /// sent" copy remains accurate either way. Mirrors `KeepAwakeIntent
    /// .perform()`'s "construct, send, report what actually happened" shape.
    private func sendCommand(_ command: ControlCommand) {
        feedbackTask?.cancel()
        feedback = "Sending…"
        feedbackTask = Task {
            let transport = await AppDataSource.shared.transport
            do {
                try await transport.send(command: command)
            } catch {
                feedback = "Not sent — \(error.localizedDescription)"
                await clearFeedbackAfterDelay()
                return
            }
            guard let status = await transport.awaitStatus(
                forNonce: command.nonce,
                timeout: MacStatIntents.statusTimeout
            ) else {
                feedback = "Sent, but no reply from your Mac yet."
                await clearFeedbackAfterDelay()
                return
            }
            feedback = status.state == "completed" ? "Done." : status.message
            await clearFeedbackAfterDelay()
        }
    }

    private func clearFeedbackAfterDelay() async {
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        guard !Task.isCancelled else { return }
        feedback = nil
    }

    private var remoteControlNote: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text("Reaches your Mac over local Wi-Fi, or from anywhere if you've set up Remote Access. MacStat must be open on your Mac.")
                .font(palette.font(size: 10))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(palette.textTertiary)
    }
}

// MARK: - AwakeMode labels (mobile)

/// iOS-local vocabulary for `AwakeMode`, mirroring
/// `MacStat/Dropdown/SleepControlCard.swift`'s `shortLabel` extension. Kept
/// separate rather than shared for the same reason as that file's own doc
/// comment: `MacStatKit` is shared with the MCP tool, which shouldn't inherit
/// either app's UI phrasing, and the Mac extension lives in the `MacStat` app
/// target this target can't import.
extension AwakeMode {
    var mobileShortLabel: String {
        switch self {
        case .displayAndSystem: return "Keep display on"
        case .systemOnly: return "System only"
        case .systemWhileOnAC: return "Only while plugged in"
        }
    }
}
