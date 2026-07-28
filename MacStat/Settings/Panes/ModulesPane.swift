import SwiftUI
import MacStatKit

/// Which metric modules the rest of the UI surfaces. Backed by
/// `settings.enabledModules`, a `Set`, so each row owns a derived binding
/// rather than the pane keeping a parallel array.
struct ModulesPane: View {

    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                ForEach(MetricModule.allCases, id: \.self) { module in
                    Toggle(isOn: binding(for: module)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(module.displayName)
                            Text(Self.subtitle(for: module))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    // Without this the accessibility label would concatenate
                    // the title and the whole subtitle sentence.
                    .accessibilityLabel(module.displayName)
                }
            } header: {
                Text("Enabled Modules")
            } footer: {
                Text("Disabled modules stop appearing in the dropdown. Metrics already in your menu bar layout keep working — remove them in the Menu Bar pane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for module: MetricModule) -> Binding<Bool> {
        Binding(
            get: { store.settings.enabledModules.contains(module) },
            set: { isOn in
                if isOn {
                    store.settings.enabledModules.insert(module)
                } else {
                    store.settings.enabledModules.remove(module)
                }
            }
        )
    }

    /// One honest line per module, drawn from the plan's §2.1 metrics catalog.
    private static func subtitle(for module: MetricModule) -> String {
        switch module {
        case .battery:
            return "Charge, charging wattage, adapter profile, health, cycles, and temperature."
        case .cpu:
            return "Total and per-core utilization, E/P-core split, frequency, package power, load averages."
        case .gpu:
            return "Device, renderer, and tiler utilization, frequency, VRAM in use, and GPU power."
        case .ane:
            return "Neural Engine power draw. There is no public ANE utilization figure — power is the standard proxy."
        case .memory:
            return "Used, wired, compressed, and cached memory, memory pressure, and swap."
        case .disk:
            return "Read/write throughput and IOPS, free space, and percentage used."
        case .network:
            return "Receive and transmit throughput, session totals, and Wi-Fi signal and link rate."
        case .thermal:
            return "SoC temperature, thermal pressure level, and whether the system is throttling."
        case .system:
            return "Uptime, process count, and whether a sleep assertion is active."
        }
    }
}
