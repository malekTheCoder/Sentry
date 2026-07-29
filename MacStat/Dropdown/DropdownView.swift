import SwiftUI
import MacStatKit

/// Root of the menu-bar dropdown, laid out top-to-bottom per plan §8.3:
/// header, battery hero card, module cards, footer.
///
/// The footer actions are injected closures rather than AppKit calls so the
/// AppDelegate stays the composition root and this view stays previewable.
struct DropdownView: View {
    @ObservedObject private var viewModel: DropdownViewModel
    /// Observed here rather than only inside `SleepControlCard` so the card's
    /// position in the layout can't be the thing that decides whether state
    /// changes propagate; the service is owned by the AppDelegate composition
    /// root, same as the view model.
    @ObservedObject private var powerControl: PowerControlService
    @Environment(\.colorScheme) private var systemColorScheme

    private let theme: Theme
    private let enabledModules: Set<MetricModule>
    private let cardListMaxHeight: CGFloat
    private let onOpenSettings: () -> Void
    private let onOpenHistory: () -> Void
    private let onQuit: () -> Void

    /// `@MainActor` because `PowerControlService` is main-actor isolated and
    /// this init stores one. Costs callers nothing: every one (AppDelegate,
    /// `#Preview`) is already main-actor isolated, as any code building a
    /// SwiftUI view hierarchy must be.
    @MainActor
    init(
        viewModel: DropdownViewModel,
        // Second, next to the other injected object it belongs with.
        //
        // Required, not optional-with-a-local-fallback: a locally constructed
        // service would read and write the same persisted assertion record as
        // the app's real one under `UserDefaults.standard`, so two live
        // instances would each try to reconcile (and re-create) the other's
        // assertion on wake. The composition root owns exactly one.
        powerControl: PowerControlService,
        theme: Theme = .terminal,
        enabledModules: Set<MetricModule> = Set(MetricModule.allCases),
        // Callers pass the actual anchor screen's height so this scales with
        // the display the status item lives on rather than a guess — a
        // fixed 420pt looked fine on paper but read as "half the cards are
        // missing and there's no way to see them" in practice (small popover
        // window against a much taller screen).
        cardListMaxHeight: CGFloat = 480,
        onOpenSettings: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._powerControl = ObservedObject(wrappedValue: powerControl)
        self.theme = theme
        self.enabledModules = enabledModules
        self.cardListMaxHeight = cardListMaxHeight
        self.onOpenSettings = onOpenSettings
        self.onOpenHistory = onOpenHistory
        self.onQuit = onQuit
    }

    private var palette: ThemePalette {
        ThemePalette(theme: theme, scheme: systemColorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            DropdownHeader(thermal: viewModel.snapshot?.thermal)
            BatteryHeroCard(
                battery: viewModel.snapshot?.battery,
                powerSeries: viewModel.series(for: .power)
            )
            // Above the scroll view, not inside it: a control the user came
            // to press shouldn't be reachable only after scrolling past the
            // metric cards, and the live countdown is the one thing here
            // worth keeping permanently visible.
            SleepControlCard(powerControl: powerControl)
            ScrollView(.vertical, showsIndicators: false) {
                ModuleCardStack(
                    snapshot: viewModel.snapshot,
                    history: viewModel.history,
                    enabledModules: enabledModules
                )
                .padding(.bottom, 2)
            }
            .frame(maxHeight: cardListMaxHeight)
            DropdownFooter(
                onOpenSettings: onOpenSettings,
                onOpenHistory: onOpenHistory,
                onQuit: onQuit
            )
        }
        .padding(palette.spacing * 1.5)
        .frame(width: 320)
        .background(palette.background)
        .environment(\.themePalette, palette)
    }
}

// MARK: - Header

/// Plan §8.3 item 1. The sync-status dot is deliberately absent — CloudKit
/// sync doesn't exist yet, and a permanently gray dot would imply a state the
/// app can't actually report.
private struct DropdownHeader: View {
    @Environment(\.themePalette) private var palette

    let thermal: ThermalStats?

    /// Recomputed per body evaluation (i.e. per snapshot) rather than on a
    /// timer of its own — a minute-resolution readout doesn't justify a
    /// second wakeup source.
    private var uptime: String {
        MetricFormatting.uptime(ProcessInfo.processInfo.systemUptime)
    }

    private var machineName: String {
        // `Host.current().localizedName` is the user-facing "Malek's MacBook
        // Pro"; hostName is the network name and only a fallback.
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: palette.spacing) {
            VStack(alignment: .leading, spacing: 1) {
                Text(machineName)
                    .font(palette.font(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Text(uptime)
                    .font(palette.font(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(palette.textTertiary)
            }
            Spacer(minLength: palette.spacing)
            thermalPill
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var thermalPill: some View {
        if let thermal {
            let color = pillColor(for: thermal.pressureLevel)
            HStack(spacing: 4) {
                Image(systemName: thermal.isThrottling ? "exclamationmark.triangle.fill" : "thermometer.medium")
                    .font(.system(size: 9))
                Text(thermal.pressureLevel.displayName)
                    .font(palette.font(size: 10, weight: .medium))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1))
            .accessibilityLabel("Thermal pressure \(thermal.pressureLevel.displayName)")
        } else {
            Text("Thermal —")
                .font(palette.font(size: 10))
                .foregroundStyle(palette.textTertiary)
        }
    }

    private func pillColor(for level: ThermalStats.PressureLevel) -> Color {
        switch level {
        case .nominal: return palette.success
        case .fair: return palette.warning
        case .serious, .critical: return palette.danger
        }
    }
}

// MARK: - Footer

/// Plan §8.3 item 5.
private struct DropdownFooter: View {
    @Environment(\.themePalette) private var palette

    let onOpenSettings: () -> Void
    let onOpenHistory: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: palette.spacing) {
            Rectangle()
                .fill(palette.separator)
                .frame(height: 1)
            HStack(spacing: palette.spacing) {
                footerButton("Settings…", symbol: "gearshape", action: onOpenSettings)
                footerButton("History", symbol: "clock.arrow.circlepath", action: onOpenHistory)
                Spacer(minLength: 0)
                footerButton("Quit MacStat", symbol: "power", action: onQuit)
            }
        }
    }

    private func footerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(palette.font(size: 11))
            }
            .foregroundStyle(palette.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

// MARK: - Preview

#Preview {
    DropdownView(
        viewModel: DropdownViewModel(),
        // Throwaway suite so the preview never reads or writes the real app's
        // persisted assertion record.
        powerControl: PowerControlService(defaults: UserDefaults(suiteName: "preview.dropdown")!),
        theme: .terminal,
        onOpenSettings: {},
        onOpenHistory: {},
        onQuit: {}
    )
}
