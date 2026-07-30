import SwiftUI
import MacStatKit

/// Tab 1 — Dashboard (plan §12.1). This task owns the navigation shell and
/// this tab's layout skeleton: device picker, freshness banner, and the
/// placeholder slots for the Battery hero / Sleep-prevention / metric cards
/// that other in-flight work builds out. Everything below `metricCardsGrid`
/// is intentionally a `PlaceholderCard`, not a real card — see that view's
/// doc comment for why a labeled stub beats either an empty space or a
/// fabricated-looking fake card.
///
/// **The demo-data banner is not optional chrome.** Plan §12.2's freshness
/// discipline covers "how old is this reading," but this build has a second,
/// more basic honesty problem: the reading isn't from a Mac at all, it's
/// `MockDataSource`-fabricated (see that type's doc comment — there is no
/// live CloudKit container to sync from). `FreshnessBadge` alone would tell
/// a user "this is 2 minutes old," which is true of the mock's internal
/// clock but still implies a real Mac exists somewhere reporting in. The
/// `demoDataBanner` above it says the thing `FreshnessBadge` structurally
/// cannot: none of this has ever come from a real Mac. Same P5 "never
/// overclaim" discipline `SyncPane` (`MacStat/Settings/Panes/SyncPane.swift`)
/// established on the Mac side, applied to the one thing that's different
/// about the mobile build: it has no live data source at all, not even a
/// broken one.
struct DashboardTabView: View {
    @StateObject private var viewModel = DashboardViewModel()
    @Environment(\.colorScheme) private var systemColorScheme

    /// No theme picker exists yet on this platform (Settings tab, plan
    /// §12.1, is another agent's work) — `.terminal` matches the Mac app's
    /// own default (`Theme.terminal`'s doc comment), so a first launch looks
    /// intentional rather than arbitrary.
    private var palette: ThemePalette {
        ThemePalette(theme: .terminal, scheme: systemColorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: palette.spacing * 1.5) {
                demoDataBanner
                devicePicker
                freshnessBanner
                PlaceholderCard(title: "Battery", systemImage: "battery.75")
                PlaceholderCard(title: "Sleep Prevention", systemImage: "moon.zzz")
                metricCardsGrid
            }
            .padding(palette.spacing * 2)
        }
        .background(palette.background)
        .environment(\.themePalette, palette)
        .task { await viewModel.start() }
    }

    // MARK: - Demo data disclosure

    private var demoDataBanner: some View {
        Label {
            Text("Showing demo data — this build has no live iCloud sync yet")
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
        } icon: {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(palette.warning)
        }
        .padding(palette.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerRadius))
    }

    // MARK: - Device picker

    /// Plan §12.1: "Device picker (if multiple Macs)." `MockDataSource`
    /// only ever reports one device (see its doc comment), so this always
    /// renders the single-device row today — the `Picker` branch below
    /// exists and is exercised by `devices.count > 1`, not dead code,
    /// against the day a device catalog with more than one Mac is real.
    @ViewBuilder
    private var devicePicker: some View {
        if viewModel.devices.count > 1 {
            Picker("Device", selection: $viewModel.selectedDeviceID) {
                ForEach(viewModel.devices, id: \.deviceID) { device in
                    Text(device.deviceName).tag(Optional(device.deviceID))
                }
            }
            .pickerStyle(.menu)
        } else if let device = viewModel.selectedDevice {
            Text(device.deviceName)
                .font(palette.font(size: 18, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
        }
    }

    // MARK: - Freshness banner

    /// Plan §12.2: "Updated 34s ago" / "Mac appears asleep — last seen 2h
    /// ago." Reads `Freshness`/`FreshnessBadge` from `MacStatKit` directly —
    /// no local re-derivation — so this banner and any per-card indicator
    /// other agents add later are guaranteed to agree with each other.
    @ViewBuilder
    private var freshnessBanner: some View {
        if let device = viewModel.selectedDevice {
            FreshnessBadge(lastSeen: device.lastSeen)
        }
    }

    // MARK: - Metric cards (plan §12.1)

    private var metricCardsGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 150), spacing: palette.spacing)]
        return LazyVGrid(columns: columns, spacing: palette.spacing) {
            ForEach(Self.metricPlaceholders, id: \.title) { placeholder in
                PlaceholderCard(title: placeholder.title, systemImage: placeholder.systemImage)
            }
        }
    }

    private static let metricPlaceholders: [(title: String, systemImage: String)] = [
        ("CPU", "cpu"),
        ("GPU", "square.stack.3d.up"),
        ("ANE", "brain"),
        ("Memory", "memorychip"),
        ("Disk", "internaldrive"),
        ("Network", "network"),
        ("Thermals", "thermometer.medium"),
    ]
}

// MARK: - PlaceholderCard

/// A clearly-labeled stand-in for a card this task deliberately doesn't
/// build out. Rejected alternatives: leaving blank space (looks like a
/// layout bug, not an intentional gap) and a fabricated-looking card with
/// invented numbers (this codebase's house rule, per `SyncPane`'s doc
/// comment, is "never overclaim" — a fake battery percentage in a
/// not-yet-real card is exactly the kind of confident-looking lie that rule
/// exists to prevent). A dashed border and "Coming soon" caption make the
/// gap legible to whoever opens this screen next, including the other
/// agents building the real version.
struct PlaceholderCard: View {
    let title: String
    let systemImage: String
    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(palette.font(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text("Coming soon")
                .font(.caption2)
                .foregroundStyle(palette.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(palette.spacing)
        .background(
            RoundedRectangle(cornerRadius: palette.cornerRadius)
                .strokeBorder(palette.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }
}
