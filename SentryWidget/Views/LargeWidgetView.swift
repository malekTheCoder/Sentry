import Charts
import SentryKit
import SwiftUI

/// `.systemLarge` — plan §12.3: "All of the above [battery + CPU + RAM +
/// sleep-assertion state] + a 24 h battery sparkline." Also the one family
/// with room for `WidgetDemoDataCaption` — see that view's doc comment for
/// why the disclosure lives here and only here among the home screen
/// families.
struct LargeWidgetView: View {
    let snapshot: WidgetSnapshot?

    /// `entry.date`, not `Date()` — see `MediumWidgetView.asOf` for why the
    /// entry's own on-screen instant is the only clock an archived widget
    /// view can honestly judge a timed hold's expiry against.
    let asOf: Date

    var body: some View {
        if let snapshot {
            VStack(alignment: .leading, spacing: 10) {
                header(snapshot)
                HStack(spacing: 14) {
                    BatteryArcView(percent: snapshot.batteryPercent, isCharging: snapshot.isCharging)
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        metricRow(label: String(localized: "CPU"), value: "\(Int(snapshot.cpuPercent.rounded()))%")
                        metricRow(label: String(localized: "RAM"), value: "\(Int((snapshot.memoryUsedFraction * 100).rounded()))%")
                        metricRow(label: String(localized: "Sleep"), value: sleepLabel(snapshot.sleepAssertion))
                        if snapshot.isCharging, let watts = snapshot.chargingWatts {
                            metricRow(label: String(localized: "Charging"), value: "\(Int(watts.rounded()))W")
                        }
                    }
                    Spacer(minLength: 0)
                }
                sparkline(snapshot)
                Spacer(minLength: 0)
                if snapshot.sourceIsDemoData {
                    WidgetDemoDataCaption()
                }
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

    /// "Awake" only while the cached hold is still credible as of this
    /// entry's on-screen instant — a timed hold past its own `expiresAt`
    /// reads "Normal", because its release is guaranteed by the recorded
    /// deadline, not contingent on this cache being fresh. Same judgment,
    /// same helper, as `MediumWidgetView.sleepRow` and the Control Center
    /// toggle (`SleepAssertionState.isCrediblyActive(asOf:)`).
    private func sleepLabel(_ assertion: SleepAssertionState) -> String {
        assertion.isCrediblyActive(asOf: asOf)
            ? String(localized: "Awake")
            : String(localized: "Normal")
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
