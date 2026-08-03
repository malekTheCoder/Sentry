import MacStatKit
import SwiftUI

/// `.systemMedium` — plan §12.3: "Battery + CPU + RAM + sleep-assertion
/// state."
struct MediumWidgetView: View {
    let snapshot: WidgetSnapshot?

    var body: some View {
        if let snapshot {
            HStack(spacing: 14) {
                BatteryArcView(percent: snapshot.batteryPercent, isCharging: snapshot.isCharging)
                    .frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.deviceName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    metricRow(systemImage: "cpu", label: String(localized: "CPU"), value: "\(Int(snapshot.cpuPercent.rounded()))%")
                    metricRow(systemImage: "memorychip", label: String(localized: "RAM"), value: "\(Int((snapshot.memoryUsedFraction * 100).rounded()))%")
                    sleepRow(snapshot.sleepAssertion)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            WidgetNoDataView()
        }
    }

    private func metricRow(systemImage: String, label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.caption2.monospacedDigit())
        }
    }

    /// Matches `SleepStatusCard`'s vocabulary (`MacStatMobile/Dashboard/SleepStatusCard.swift`)
    /// so a user seeing both the widget and the app doesn't see two
    /// different phrasings of the same state — but restated locally rather
    /// than shared, since `AwakeMode.mobileShortLabel` is declared in
    /// `MacStatMobile`, a target this widget extension doesn't import (an
    /// app extension can't depend on its containing app's target; only the
    /// reverse). `nil` (no `sleepAssertion` on the cached snapshot — should
    /// not happen once `WidgetSnapshotWriter` always defaults to `.inactive`,
    /// but the type stays optional-shaped defensively) reads the same as
    /// `.inactive` here, matching `WidgetSnapshotWriter`'s own fallback.
    private func sleepRow(_ assertion: SleepAssertionState) -> some View {
        let text: String
        switch assertion {
        case .inactive:
            text = String(localized: "Sleep normal")
        case .active(let mode, _, _):
            switch mode {
            case .displayAndSystem: text = String(localized: "Awake: display on")
            case .systemOnly: text = String(localized: "Awake: system only")
            case .systemWhileOnAC: text = String(localized: "Awake: while on AC")
            }
        }
        return HStack(spacing: 4) {
            Image(systemName: isActive(assertion) ? "moon.zzz.fill" : "moon.zzz")
                .font(.caption2)
                .foregroundStyle(isActive(assertion) ? .purple : .secondary)
                .frame(width: 12)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func isActive(_ assertion: SleepAssertionState) -> Bool {
        if case .active = assertion { return true }
        return false
    }
}
