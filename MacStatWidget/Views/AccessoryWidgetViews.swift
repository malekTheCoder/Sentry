import MacStatKit
import SwiftUI
import WidgetKit

// MARK: - AccessoryCircularWidgetView

/// `.accessoryCircular` — plan §12.3: "Lock screen: battery arc." Lock
/// screen accessory families render through the system's own tinted/
/// monochrome/vibrant rendering modes (the user's lock screen theme, not
/// this app's), which is exactly what `Gauge`'s `.accessoryCircular` style
/// exists for — unlike `BatteryArcView` (used by the full-color home screen
/// families), a hand-drawn `Circle().trim` here would fight the system's
/// tinting instead of adopting it.
struct AccessoryCircularWidgetView: View {
    let snapshot: WidgetSnapshot?

    var body: some View {
        if let snapshot {
            Gauge(value: min(max(snapshot.batteryPercent, 0), 100), in: 0...100) {
                Image(systemName: snapshot.isCharging ? "bolt.fill" : "battery.100")
            } currentValueLabel: {
                Text("\(Int(snapshot.batteryPercent.rounded()))")
            }
            .gaugeStyle(.accessoryCircular)
        } else {
            Gauge(value: 0, in: 0...100) {
                Image(systemName: "questionmark")
            } currentValueLabel: {
                Text("--")
            }
            .gaugeStyle(.accessoryCircular)
        }
    }
}

// MARK: - AccessoryRectangularWidgetView

/// `.accessoryRectangular` — plan §12.3's own example string, verbatim:
/// "MBP 78% · 45W · CPU 12%." Lock screen rectangular widgets render as
/// plain (possibly monochrome/vibrant-tinted) text — no custom colors, no
/// arc glyph — so this is deliberately just `Text`, matching the system's
/// own accessory-family conventions rather than `BatteryArcView`'s or
/// `AccessoryCircularWidgetView`'s richer rendering.
struct AccessoryRectangularWidgetView: View {
    let snapshot: WidgetSnapshot?

    var body: some View {
        if let snapshot {
            VStack(alignment: .leading, spacing: 1) {
                Text(shortDeviceName(snapshot.deviceName))
                    .font(.headline)
                    .lineLimit(1)
                Text(statLine(snapshot))
                    .font(.caption2)
                    .lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text("Sentry")
                    .font(.headline)
                Text("No data yet")
                    .font(.caption2)
            }
        }
    }

    /// Plan §12.3's example abbreviates "Malek's MacBook Pro" to "MBP" — a
    /// lock screen rectangular widget has roughly one line of headline
    /// space, nowhere near enough for a full device name plus the stat
    /// line. This is a best-effort initialism (first letter of each
    /// capitalized word, dropping possessives/"the"), not a guarantee of
    /// matching the plan's exact abbreviation for every possible device
    /// name — there's no model/name-shortening data anywhere else in this
    /// codebase to draw a better mapping from.
    private func shortDeviceName(_ name: String) -> String {
        let words = name
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'s")) }
            .filter { !$0.isEmpty && $0.first?.isUppercase == true }
        guard words.count >= 2 else { return name }
        let initials = words.compactMap { $0.first }.map(String.init).joined()
        return initials.isEmpty ? name : initials
    }

    private func statLine(_ snapshot: WidgetSnapshot) -> String {
        var parts = ["\(Int(snapshot.batteryPercent.rounded()))%"]
        if snapshot.isCharging, let watts = snapshot.chargingWatts {
            parts.append("\(Int(watts.rounded()))W")
        }
        parts.append("CPU \(Int(snapshot.cpuPercent.rounded()))%")
        return parts.joined(separator: " · ")
    }
}
