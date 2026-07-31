import MacStatKit
import SwiftUI

// MARK: - ContentView: the Watch app's one screen

/// A deliberately plain "last known state" screen — this app exists mostly
/// to host `WatchSessionController` and satisfy the "a complication needs a
/// companion app" requirement, not to be a second dashboard. Every value
/// shown here is exactly what `ComplicationView`
/// (`MacStatWatchWidget/ComplicationView.swift`) shows too, following the
/// same honesty convention `FreshnessBadge` establishes on iOS: never a bare
/// number, always paired with how old it is.
struct ContentView: View {
    @EnvironmentObject private var sessionController: WatchSessionController

    var body: some View {
        VStack(spacing: 8) {
            if let snapshot = sessionController.latestSnapshot {
                Text(snapshot.deviceName)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: snapshot.isCharging ? "bolt.fill" : "battery.100")
                    Text("\(Int(snapshot.batteryPercent.rounded()))%")
                        .font(.title2)
                        .monospacedDigit()
                }

                Text(thermalLabel(snapshot.thermalPressure))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                FreshnessBadge(lastSeen: snapshot.lastSeen)
                    .font(.caption2)

                if snapshot.sourceIsDemoData {
                    Text("Demo data")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else {
                Image(systemName: "applewatch.radiowaves.left.and.right")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("No data yet")
                    .font(.callout)
                Text("Open Sentry on your iPhone while on the same Wi-Fi as your Mac.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }

    private func thermalLabel(_ pressure: ThermalPressureSummary) -> String {
        switch pressure {
        case .nominal: return "Thermal: Normal"
        case .fair: return "Thermal: Fair"
        case .serious: return "Thermal: Serious"
        case .critical: return "Thermal: Critical"
        case .unknown: return "Thermal: Unknown"
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(WatchSessionController())
}
