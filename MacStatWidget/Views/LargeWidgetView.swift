import Charts
import MacStatKit
import SwiftUI

/// `.systemLarge` — plan §12.3: "All of the above [battery + CPU + RAM +
/// sleep-assertion state] + a 24 h battery sparkline." Also the one family
/// with room for `WidgetDemoDataCaption` — see that view's doc comment for
/// why the disclosure lives here and only here among the home screen
/// families.
struct LargeWidgetView: View {
    let snapshot: WidgetSnapshot?

    var body: some View {
        if let snapshot {
            VStack(alignment: .leading, spacing: 10) {
                header(snapshot)
                HStack(spacing: 14) {
                    BatteryArcView(percent: snapshot.batteryPercent, isCharging: snapshot.isCharging)
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        metricRow(label: "CPU", value: "\(Int(snapshot.cpuPercent.rounded()))%")
                        metricRow(label: "RAM", value: "\(Int((snapshot.memoryUsedFraction * 100).rounded()))%")
                        metricRow(label: "Sleep", value: sleepLabel(snapshot.sleepAssertion))
                        if snapshot.isCharging, let watts = snapshot.chargingWatts {
                            metricRow(label: "Charging", value: "\(Int(watts.rounded()))W")
                        }
                    }
                    Spacer(minLength: 0)
                }
                sparkline(snapshot)
                Spacer(minLength: 0)
                WidgetDemoDataCaption()
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            WidgetNoDataView()
        }
    }

    private func header(_ snapshot: WidgetSnapshot) -> some View {
        HStack {
            Text(snapshot.deviceName)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)
            Spacer(minLength: 8)
            FreshnessBadge(lastSeen: snapshot.lastSeen)
        }
    }

    private func metricRow(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.caption.monospacedDigit())
        }
        .frame(minWidth: 90)
    }

    private func sleepLabel(_ assertion: SleepAssertionState) -> String {
        switch assertion {
        case .inactive: return "Normal"
        case .active: return "Awake"
        }
    }

    /// `batteryHistory` is whatever `WidgetBatteryHistory`'s ring buffer
    /// happens to hold this run (see that type and `WidgetSnapshot
    /// .batteryHistory`'s doc comments — this demo build has no real
    /// 24h/15-min-cadence feed, only "recent samples since the phone app
    /// last launched"). A single point can't draw a line, so that case
    /// falls back to the same "No data yet" honesty the whole family uses
    /// for a missing snapshot, rather than a chart that looks meaningful
    /// with one dot on it.
    @ViewBuilder
    private func sparkline(_ snapshot: WidgetSnapshot) -> some View {
        if snapshot.batteryHistory.count >= 2 {
            Chart(snapshot.batteryHistory, id: \.date) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Battery", point.percent)
                )
                .foregroundStyle(.green)
                .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 36)
        } else {
            Text("Battery trend needs a few more minutes of data")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(height: 36)
        }
    }
}
