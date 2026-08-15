import SentryKit
import SwiftUI

/// `.systemMedium` — plan §12.3: "Battery + CPU + RAM + sleep-assertion
/// state."
struct MediumWidgetView: View {
    let snapshot: WidgetSnapshot?

    /// The instant this entry goes on screen — `entry.date`, not `Date()`:
    /// WidgetKit archives every entry's view at timeline-build time, so a
    /// `Date()` read here would evaluate once per *reload*, not once per
    /// *display*, and a timeline fanning hours of identical entries would
    /// bake the reload-time verdict into all of them. `entry.date` is what
    /// each entry's on-screen window actually starts at, which is the
    /// honest clock for `sleepRow`'s "has this timed hold certainly ended"
    /// judgment (`SleepAssertionState.isCrediblyActive(asOf:)`).
    let asOf: Date

    var body: some View {
        if let snapshot {
            HStack(spacing: 14) {
                BatteryArcView(percent: snapshot.batteryPercent, isCharging: snapshot.isCharging)
                    .frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 4) {
                    // The tag rides beside the device name — with the data,
                    // where a cropped screenshot keeps it — mirroring
                    // `LargeWidgetView`'s caption without spending a whole
                    // row of this family's four-line budget on it.
                    HStack(spacing: 4) {
                        Text(snapshot.deviceName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        if snapshot.sourceIsDemoData {
                            WidgetDemoDataTag()
                        }
                    }
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

    /// Matches `SleepStatusCard`'s vocabulary (`SentryMobile/Dashboard/SleepStatusCard.swift`)
    /// so a user seeing both the widget and the app doesn't see two
    /// different phrasings of the same state — but restated locally rather
    /// than shared, since `AwakeMode.mobileShortLabel` is declared in
    /// `SentryMobile`, a target this widget extension doesn't import (an
    /// app extension can't depend on its containing app's target; only the
    /// reverse). `nil` (no `sleepAssertion` on the cached snapshot — should
    /// not happen once `WidgetSnapshotWriter` always defaults to `.inactive`,
    /// but the type stays optional-shaped defensively) reads the same as
    /// `.inactive` here, matching `WidgetSnapshotWriter`'s own fallback.
    ///
    /// A cached *timed* hold whose own `expiresAt` predates `asOf` also
    /// reads as "Sleep normal": the hold has certainly released by its
    /// recorded deadline whether or not this cache ever hears about it —
    /// see `SleepAssertionState.isCrediblyActive(asOf:)` for the argument,
    /// and for why a stale *indefinite* hold does not get the same
    /// treatment (no deadline in the value disproves it).
    private func sleepRow(_ assertion: SleepAssertionState) -> some View {
        let credible = assertion.isCrediblyActive(asOf: asOf)
        let text: String
        switch assertion {
        case .active(let mode, _, _) where credible:
            switch mode {
            case .displayAndSystem: text = String(localized: "Awake: display on")
            case .systemOnly: text = String(localized: "Awake: system only")
            case .systemWhileOnAC: text = String(localized: "Awake: while on AC")
            }
        case .active, .inactive:
            text = String(localized: "Sleep normal")
        }
        return HStack(spacing: 4) {
            Image(systemName: credible ? "moon.zzz.fill" : "moon.zzz")
                .font(.caption2)
                .foregroundStyle(credible ? .purple : .secondary)
                .frame(width: 12)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
