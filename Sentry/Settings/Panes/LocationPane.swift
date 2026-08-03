import SwiftUI
import SentryKit

/// The "Location Log" settings surface — deliberately never called "Find My"
/// anywhere on this screen. See `LocationService`'s doc comment for the full
/// framing: genuine Find My network integration isn't possible for a
/// third-party app (no public API to register an arbitrary Mac into Apple's
/// mesh, which is reserved for Apple's own devices and MFi accessories via a
/// separate program), so this feature is something smaller and honestly
/// described instead — a periodic, permission-gated location capture, sent
/// to a connected iPhone only while this Mac is online and Sentry is
/// running.
///
/// **Same honesty discipline as `SyncPane`, applied to a feature that
/// actually works.** `SyncPane`'s doc comment lists what an honest "doesn't
/// work yet" pane must avoid claiming. This pane is the opposite case — a
/// feature that *does* work — but the same discipline applies in reverse:
/// it must not claim more than it does. Specifically this pane never says
/// "tracking," "live," or implies the Mac can be found while offline or
/// while Sentry isn't running; every string below says "as of [time]" or
/// "last known," never "current location."
///
/// **Why the toggle doesn't request permission by itself.** `store.settings
/// .locationLogEnabled` is a plain settings bit — flipping it is what
/// `AppDelegate.applySettings` reads to decide whether to call
/// `LocationService.requestAuthorization()` and `start()`/`stop()` (see that
/// method's doc comment). This pane only ever toggles the setting and
/// displays `locationService`'s live `permissionState`/`lastLocation`; it
/// never calls into `CLLocationManager` directly, keeping exactly one place
/// in the app responsible for the request flow.
struct LocationPane: View {

    @ObservedObject var store: SettingsStore
    @ObservedObject var locationService: LocationService

    var body: some View {
        Form {
            Section {
                Toggle("Log this Mac's location", isOn: $store.settings.locationLogEnabled)
                    .accessibilityLabel("Log this Mac's location")

                Text("When on, Sentry periodically asks macOS for this Mac's approximate location (Wi-Fi-based, not precise GPS) and sends the most recent reading to your iPhone the next time it's on the same local network. This only happens while Sentry is running and the Mac is online — it cannot locate this Mac while it's asleep, offline, or Sentry isn't running, and it has no connection to Apple's Find My network.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Location Log")
            } footer: {
                Text("Not Find My. There is no way for a third-party app like Sentry to register a device with Apple's actual Find My network — that requires Apple's own devices or MFi-certified hardware. This is a simple, honest log of where Sentry last saw this Mac, nothing more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                permissionRow
            } header: {
                Text("Permission")
            }

            if store.settings.locationLogEnabled {
                Section {
                    lastKnownRow
                } header: {
                    Text("Last Captured")
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var permissionRow: some View {
        switch locationService.permissionState {
        case .notDetermined:
            Label("Not yet requested — turn on the toggle above to ask macOS for permission.", systemImage: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .authorized:
            Label("Location access granted.", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .denied:
            Label("Location access denied. Enable it for Sentry in System Settings ▸ Privacy & Security ▸ Location Services to use this feature.", systemImage: "location.slash")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .restricted:
            Label("Location access is restricted on this Mac (e.g. by a management profile) and can't be granted here.", systemImage: "lock.circle")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var lastKnownRow: some View {
        if let location = locationService.lastLocation {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Coordinates", value: String(format: "%.3f, %.3f", location.latitude, location.longitude))
                LabeledContent("Captured", value: location.timestamp.formatted(date: .abbreviated, time: .shortened))
                if let accuracy = location.horizontalAccuracyMeters {
                    LabeledContent("Approximate accuracy", value: "±\(Int(accuracy)) m")
                }
            }
            .font(.callout)
        } else {
            Text("No location has been captured yet. This can take a few minutes after enabling the toggle above.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
