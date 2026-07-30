import SwiftUI
import MacStatKit

/// Tab 1 — Dashboard (plan §12.1): device picker, freshness banner, the
/// `BatteryHeroCard`, `SleepStatusCard`, and the 7-card `metricCardsGrid`
/// (CPU/GPU/ANE/Memory/Disk/Network/Thermals), all bound to
/// `viewModel.latestSnapshot`. See `BatteryHeroCard.swift`,
/// `SleepStatusCard.swift`, and `MetricCards.swift` for the individual
/// cards' rationale — this file's job is just assembling them under the
/// shell below.
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

    /// Now sourced from the environment rather than hardcoded. Until the
    /// Settings tab existed, this was `ThemePalette(theme: .terminal, ...)`
    /// computed locally, with a doc comment noting "no theme picker exists
    /// yet on this platform." `RootTabView` (the shared ancestor of all four
    /// tabs) now resolves the user's `@AppStorage("selectedThemeID")`
    /// selection once and injects it via `.environment(\.themePalette:)`, so
    /// this view reads it the same way `PlaceholderCard` below already did
    /// — no local `ColorScheme` plumbing or hardcoded theme left here.
    @Environment(\.themePalette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: palette.spacing * 1.5) {
                demoDataBanner
                devicePicker
                freshnessBanner
                BatteryHeroCard(battery: viewModel.latestSnapshot?.battery)
                SleepStatusCard(assertion: viewModel.latestSnapshot?.sleepAssertion)
                metricCardsGrid
            }
            .padding(palette.spacing * 2)
        }
        .background(palette.background)
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

    /// Built fresh from `viewModel.latestSnapshot` on every render via
    /// `DashboardMetricCardFactory` (`MetricCards.swift`) — each factory
    /// method takes the relevant optional sub-struct straight off the
    /// snapshot, so a module a Mac doesn't support (or hasn't reported yet)
    /// renders its own card as honestly "Unavailable" rather than the whole
    /// grid needing a placeholder fallback.
    private var metricCardsGrid: some View {
        let snapshot = viewModel.latestSnapshot
        let columns = [GridItem(.adaptive(minimum: 150), spacing: palette.spacing)]
        return LazyVGrid(columns: columns, spacing: palette.spacing) {
            DashboardMetricCardFactory.cpu(snapshot?.cpu, palette: palette)
            DashboardMetricCardFactory.gpu(snapshot?.gpu, palette: palette)
            DashboardMetricCardFactory.ane(snapshot?.ane, palette: palette)
            DashboardMetricCardFactory.memory(snapshot?.memory, palette: palette)
            DashboardMetricCardFactory.disk(snapshot?.disk, palette: palette)
            DashboardMetricCardFactory.network(snapshot?.network, palette: palette)
            DashboardMetricCardFactory.thermal(snapshot?.thermal, palette: palette)
        }
    }
}
