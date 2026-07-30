import SwiftUI
import MacStatKit

/// Plan §12.1 asks for a "Sleep-prevention control card (toggle + duration +
/// countdown)." This is deliberately *not* a control — it's read-only status.
///
/// **Why no toggle.** A toggle here would need to round-trip a
/// `ControlCommand` to the Mac and observe a `ControlStatus` reply through a
/// real, connected CloudKit container to mean anything. That container
/// doesn't exist in this build — same constraint documented at length in
/// `MacStat/Settings/Panes/SyncPane.swift` and `MacStatMobile/Data/MockDataSource.swift`
/// (`send(command:)` is a logged no-op; there is no Mac on the other end).
/// `SyncPane` establishes the precedent this card follows: its doc comment
/// explains why it deliberately leaves `AppSettings.cloudKitSyncEnabled`
/// unexposed rather than wiring it to a toggle that "has no reader anywhere
/// in the app" — flipping it would "manufacture exactly that bug," the
/// textbook P5 violation of a control that silently does nothing. A sleep
/// toggle here — even disabled, even captioned — is worse than that toggle:
/// an *enabled-looking* switch invites a tap, and a tap that changes nothing
/// on the actual Mac is the exact "the app feels broken" failure `Freshness`'s
/// doc comment (`MacStatKit/Sync/Freshness.swift`) says this whole codebase
/// exists to avoid. Omitting the control entirely, with a one-line
/// explanation of why, is the honest version of "coming soon."
///
/// **What's real and shown:** the *current* sleep-assertion state as last
/// reported by the Mac, read straight off `SystemSnapshot.sleepAssertion` —
/// formatted with the same vocabulary `SleepControlCard`'s `activeDetail(for:)`
/// uses on the Mac side (mode label, reason string, countdown/"until turned
/// off"), so a user who has both apps open sees matching text, just without
/// any button to press on the phone.
struct SleepStatusCard: View {
    @Environment(\.themePalette) private var palette

    /// `nil` when the snapshot predates `sleepAssertion` being populated, or
    /// the Mac hasn't reported one yet — distinct from `.inactive`, which is
    /// a real "not preventing sleep right now" reading. Rendered as
    /// "Unavailable," never folded into the inactive case, so the two
    /// meanings ("we know it's off" vs "we don't know") stay distinguishable.
    let assertion: SleepAssertionState?

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
            remoteControlNote
        }
        .padding(palette.spacing * 1.4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                .stroke(isActive ? palette.accent.opacity(0.5) : palette.separator, lineWidth: 1)
        )
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
                Text(isActive ? "Preventing sleep" : "Sleep Prevention")
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
        }
    }

    private var remoteControlNote: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text("Control from your Mac — remote control isn't available in this build yet.")
                .font(palette.font(size: 10))
                .lineLimit(2)
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
