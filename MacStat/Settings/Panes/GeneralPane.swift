import SwiftUI
import MacStatKit

/// Launch behaviour and the §8.4 sampling controls.
struct GeneralPane: View {

    @ObservedObject var store: SettingsStore

    /// Non-nil while a `LaunchAtLogin` call has failed. Surfaced rather than
    /// swallowed: `SMAppService.register()` genuinely fails (unsigned builds,
    /// an app not in /Applications, MDM policy), and silently leaving the
    /// toggle in the wrong position is the worst possible outcome.
    @State private var launchAtLoginError: String?

    /// Below this the plan asks for an explicit battery warning (§8.4).
    private static let subSecondWarningThreshold: TimeInterval = 1.0

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch MacStat at login", isOn: launchAtLoginBinding)
                    .accessibilityLabel("Launch MacStat at login")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Slider(
                        value: $store.settings.globalRefreshInterval,
                        in: 0.5...30,
                        step: 0.5
                    ) {
                        Text("Refresh interval")
                    } minimumValueLabel: {
                        Text("0.5s")
                    } maximumValueLabel: {
                        Text("30s")
                    }
                    .accessibilityLabel("Refresh interval in seconds")
                    .accessibilityValue(formattedInterval)

                    LabeledContent("Current interval", value: formattedInterval)
                        .font(.callout)

                    if store.settings.globalRefreshInterval < Self.subSecondWarningThreshold {
                        // §9.4: never encode meaning in color alone — the icon
                        // and the sentence both carry it.
                        Label(
                            "Sub-second polling measurably costs battery. Intervals under 1 second keep the CPU awake far more often than the data is worth.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Warning: sub-second polling measurably costs battery")
                    }
                }

                Toggle("Adaptive throttling", isOn: $store.settings.adaptiveThrottlingEnabled)
                    .accessibilityLabel("Adaptive throttling")
                Text("Automatically slows polling when on battery, in Low Power Mode, while the dropdown is closed, or when the display is asleep. Turn this off to sample at the exact interval above — useful while benchmarking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Sampling")
            }

            Section("Updates") {
                Toggle("Check for updates daily", isOn: $store.settings.updateCheckDaily)
                    .accessibilityLabel("Check for updates daily")
                Text("Updates are never installed without asking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reconcileLaunchAtLogin)
        .alert(
            "Couldn't change the login item",
            isPresented: Binding(
                get: { launchAtLoginError != nil },
                set: { if !$0 { launchAtLoginError = nil } }
            )
        ) {
            Button("OK") { launchAtLoginError = nil }
        } message: {
            Text(launchAtLoginError ?? "")
        }
    }

    private var formattedInterval: String {
        String(format: "%.1f s", store.settings.globalRefreshInterval)
    }

    /// Writes through to `SMAppService` first and only records the new value in
    /// settings if the system accepted it, so the stored flag can't drift away
    /// from what macOS actually believes.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { store.settings.launchAtLogin },
            set: { newValue in
                do {
                    try LaunchAtLogin.setEnabled(newValue)
                    store.settings.launchAtLogin = newValue
                } catch {
                    launchAtLoginError = error.localizedDescription
                    // Leave `settings.launchAtLogin` alone; the toggle snaps
                    // back to the truth on the next render.
                }
            }
        )
    }

    /// The login item can be changed outside the app (System Settings > Login
    /// Items), so the system is the source of truth on open, not our file.
    private func reconcileLaunchAtLogin() {
        let actual = LaunchAtLogin.isEnabled
        if store.settings.launchAtLogin != actual {
            store.settings.launchAtLogin = actual
        }
    }
}
