import SwiftUI
import MacStatKit

/// Retention (§6.3, with the live disk projection the plan asks for), alert
/// throttling, and the reset escape hatch.
struct AdvancedPane: View {

    @ObservedObject var store: SettingsStore

    /// Opens the Phase 1 exit-criterion debug window (raw `SystemSnapshot`
    /// dump). `nil` by default so this pane keeps working — button just
    /// absent — wherever it's constructed without a debug window controller
    /// wired up (e.g. a future preview or test harness).
    var onShowDebugWindow: (() -> Void)?

    @State private var isConfirmingReset = false

    var body: some View {
        Form {
            Section {
                retentionSlider(
                    title: "Raw samples",
                    value: Binding(
                        get: { Double(store.settings.rawRetentionHours) },
                        set: { store.settings.rawRetentionHours = Int($0.rounded()) }
                    ),
                    range: 6...168,
                    step: 1,
                    valueLabel: "\(store.settings.rawRetentionHours) h",
                    accessibilityLabel: "Raw sample retention in hours",
                    estimate: DiskEstimate.rawBytes(
                        hours: store.settings.rawRetentionHours,
                        interval: store.settings.globalRefreshInterval
                    )
                )

                retentionSlider(
                    title: "Hourly rollups",
                    value: Binding(
                        get: { Double(store.settings.hourlyRetentionDays) },
                        set: { store.settings.hourlyRetentionDays = Int($0.rounded()) }
                    ),
                    range: 7...365,
                    step: 1,
                    valueLabel: "\(store.settings.hourlyRetentionDays) d",
                    accessibilityLabel: "Hourly rollup retention in days",
                    estimate: DiskEstimate.hourlyBytes(days: store.settings.hourlyRetentionDays)
                )

                LabeledContent("Daily rollups") {
                    Text("Kept forever — \(DiskEstimate.formatted(DiskEstimate.dailyBytesPerDecade)) per decade")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Projected total") {
                    Text(DiskEstimate.formatted(totalProjectedBytes))
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
                .accessibilityLabel("Projected total database size")
                .accessibilityValue(DiskEstimate.formatted(totalProjectedBytes))
            } header: {
                Text("History Retention")
            } footer: {
                Text("Estimates assume roughly 40 metrics recorded at your current \(String(format: "%.1f", store.settings.globalRefreshInterval)) s refresh interval. Actual size varies with how many modules you enable and how well SQLite packs the rows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Do Not Disturb", isOn: $store.settings.doNotDisturb)
                    .accessibilityLabel("Do Not Disturb")
                    .accessibilityValue(store.settings.doNotDisturb ? "On" : "Off")

                Stepper(
                    value: $store.settings.notificationRateCapPerHour,
                    in: 1...60
                ) {
                    LabeledContent(
                        "Notification cap",
                        value: "\(store.settings.notificationRateCapPerHour) per hour"
                    )
                }
                .accessibilityLabel("Maximum notifications per hour")
                .accessibilityValue("\(store.settings.notificationRateCapPerHour)")

                Stepper(
                    value: $store.settings.alertCooldownMinutes,
                    in: 1...240
                ) {
                    LabeledContent(
                        "Alert cooldown",
                        value: "\(store.settings.alertCooldownMinutes) min"
                    )
                }
                .accessibilityLabel("Cooldown between repeated alerts, in minutes")
                .accessibilityValue("\(store.settings.alertCooldownMinutes)")
            } header: {
                Text("Alerts")
            } footer: {
                Text("Do Not Disturb is a master mute: while it's on, no rule delivers a notification, menu bar highlight, or sleep-assertion release, no matter what its own quiet hours say. Nothing is recorded in History while muted this way, the same as a rule's own quiet hours — see the Alerts pane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Reset") {
                Button(role: .destructive) {
                    isConfirmingReset = true
                } label: {
                    Text("Reset All Settings to Defaults")
                }
                .accessibilityLabel("Reset all settings to defaults")

                Text("Restores every setting, including your menu bar layout and theme, to the shipped defaults. Recorded history is not deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let onShowDebugWindow {
                Section("Developer") {
                    Button("Show Debug Window…") {
                        onShowDebugWindow()
                    }
                    .accessibilityLabel("Show debug window")

                    Text("Dumps every field of the current snapshot — every sub-struct, every raw value, nils shown as \"nil\" — for cross-checking against Activity Monitor, System Settings, or powermetrics. Not user-facing; nothing here is rounded or hidden the way the rest of the app formats it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Reset all settings to defaults?",
            isPresented: $isConfirmingReset
        ) {
            Button("Reset Everything", role: .destructive) {
                store.resetToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your menu bar layout, theme, enabled modules, and all other preferences will be restored to their defaults. This can't be undone.")
        }
    }

    private var totalProjectedBytes: Double {
        DiskEstimate.rawBytes(
            hours: store.settings.rawRetentionHours,
            interval: store.settings.globalRefreshInterval
        )
        + DiskEstimate.hourlyBytes(days: store.settings.hourlyRetentionDays)
        + DiskEstimate.dailyBytesPerDecade
    }

    private func retentionSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueLabel: String,
        accessibilityLabel: String,
        estimate: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Slider(value: value, in: range, step: step) {
                Text(title)
            }
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue("\(valueLabel), about \(DiskEstimate.formatted(estimate))")

            HStack {
                Text("\(title): \(valueLabel)")
                Spacer()
                Text("≈ \(DiskEstimate.formatted(estimate))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }
}

// MARK: - Disk projection (plan §6.3)

/// Linear projections anchored to the plan's §6.3 table, which is the only
/// measured data available: ~1.15 M raw rows across ~40 metrics over 48 h at
/// 3 s ≈ 40 MB; hourly ≈ 2 MB / 90 d; daily ≈ 1 MB / 10 yr. Dividing each by
/// its row count gives the per-row costs below, so the numbers on screen are
/// derived from the plan rather than invented.
enum DiskEstimate {

    private static let metricCount: Double = 40

    /// Plan §6.3's raw row is "~1.15 M rows/day, ~40 MB" — but the 40 MB is
    /// the table size at its **48 h** retention, i.e. 2.304 M rows, not the
    /// 1.15 M *per-day* figure. Dividing the 48 h size by the 1-day row
    /// count double-counts and makes the projection 2x too expensive.
    /// 40 MB / 2.304 M rows ≈ 18 bytes per raw row.
    private static let rawBytesPerRow: Double = 18

    /// 2 MB / (40 metrics × 24 h × 90 d = 86,400 rows) ≈ 24 bytes per row.
    /// Higher than a raw row's payload because a rollup carries min/avg/max.
    private static let hourlyBytesPerRow: Double = 24

    /// 1 MB per decade, straight from the table.
    static let dailyBytesPerDecade: Double = 1_048_576

    static func rawBytes(hours: Int, interval: TimeInterval) -> Double {
        // A zero or negative interval would divide by zero; the slider can't
        // produce one, but the settings file is user-editable.
        let safeInterval = max(interval, 0.5)
        let samplesPerMetric = (Double(hours) * 3600) / safeInterval
        return samplesPerMetric * metricCount * rawBytesPerRow
    }

    static func hourlyBytes(days: Int) -> Double {
        Double(days) * 24 * metricCount * hourlyBytesPerRow
    }

    static func formatted(_ bytes: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        // Same rounding trap as `MetricFormatter.clampToInt64`: `Double(Int64.max)`
        // rounds up to 2^63 on conversion, which then traps `Int64(...)` for
        // a huge input. `rawBytes`/`hourlyBytes` are driven by user-editable
        // settings-file integers the UI slider can't produce but a
        // hand-edited file can, so this is reachable, not just theoretical.
        return formatter.string(fromByteCount: Int64(min(max(bytes, 0), Double(Int64.max).nextDown)))
    }
}
