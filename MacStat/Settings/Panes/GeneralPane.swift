import SwiftUI
import MacStatKit

/// Launch behaviour and the §8.4 sampling controls, including the FR-2
/// per-tier medium/slow refresh sliders (see the "Tier Intervals" section
/// below).
struct GeneralPane: View {

    @ObservedObject var store: SettingsStore

    /// Backs the Updates section. `nil` means this settings surface was
    /// built without an update channel at all — a legitimate configuration
    /// (see `SettingsView.updateController`), and one the section says
    /// plainly rather than papering over with a disabled button.
    var updateController: UpdateController?

    @Environment(\.themePalette) private var palette

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
                Toggle("Launch Sentry at login", isOn: launchAtLoginBinding)
                    .accessibilityLabel("Launch Sentry at login")
            }

            Section {
                Toggle("Detailed charts", isOn: $store.settings.detailedCharts)
                    .accessibilityLabel("Detailed charts")
                Text("Dashboard charts are simplified by default — no axes or gridlines, with an average/peak summary line instead. Turn this on to read exact values off the plot: gridlines, a value axis, and intermediate time labels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Charts")
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

            // FR-2, additive: "refresh interval user-adjustable per module."
            // `StatsCoordinator` schedules by tier (fast/medium/slow), not
            // per collector, so this section is deliberately titled and
            // captioned as tier-level control rather than claiming
            // per-module granularity the app doesn't actually have — see
            // `StatsCoordinator.setBaseInterval`'s doc comment for why that
            // scope call was made instead of a per-collector scheduler
            // rewrite.
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Slider(
                        value: $store.settings.mediumTierRefreshInterval,
                        in: 1...60,
                        step: 1
                    ) {
                        Text("Medium tier interval")
                    } minimumValueLabel: {
                        Text("1s")
                    } maximumValueLabel: {
                        Text("60s")
                    }
                    .accessibilityLabel("Medium tier refresh interval in seconds")
                    .accessibilityValue(formattedMediumInterval)

                    LabeledContent("ANE, temperatures, fan RPM", value: formattedMediumInterval)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Slider(
                        value: $store.settings.slowTierRefreshInterval,
                        // Matches StatsCoordinator.setSlowInterval's actual
                        // clamp: every tier's *effective* interval is capped
                        // at 60s by adaptive throttling regardless of this
                        // base value, so a wider slider would silently lie
                        // about what setting it to, say, 180s does.
                        in: 5...60,
                        step: 5
                    ) {
                        Text("Slow tier interval")
                    } minimumValueLabel: {
                        Text("5s")
                    } maximumValueLabel: {
                        Text("60s")
                    }
                    .accessibilityLabel("Slow tier refresh interval in seconds")
                    .accessibilityValue(formattedSlowInterval)

                    LabeledContent("Battery %, health, cycle count", value: formattedSlowInterval)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Tier Intervals")
            } footer: {
                Text("The refresh interval above controls the fast tier (CPU, GPU, memory, network, disk). These two sliders control the other two tiers — every module assigned to a tier shares that tier's interval, so this is per-tier control, not independently adjustable per module.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            updatesSection
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

    // MARK: - Updates

    /// **Why this section exists again, and what changed since it didn't.**
    ///
    /// This is where a comment used to sit explaining that there was no
    /// Updates section on purpose: `AppSettings.updateCheckDaily` was a
    /// persisted field with no reader anywhere in the app, Sparkle was
    /// declared in `project.yml` but neither linked nor embedded nor
    /// imported, and a toggle promising daily checks that nothing performed
    /// is precisely the "slider that silently does nothing" bug `SyncPane`'s
    /// doc comment refuses to ship. That reasoning was right, and it has not
    /// been discarded — it has been *satisfied*. `UpdateController`
    /// (`MacStat/App/UpdateController.swift`) is constructed in `AppDelegate`
    /// alongside `powerControl`/`localSyncServer`, and `AppDelegate
    /// .applySettings` now reads `updateCheckDaily` on every emission and
    /// pushes it into Sparkle's scheduler. The toggle below moves a real
    /// dial.
    ///
    /// **The refusal has moved down a level, not away.** Sparkle can only
    /// install an update it can verify against the Ed25519 public key baked
    /// into this build, and this build ships a *placeholder* key (see
    /// `UpdateFeedConfiguration.placeholderPublicKey` and
    /// `docs/sparkle-release-signing.md` — generating the real pair is the
    /// developer's job, because the private half is a secret that must never
    /// pass through tooling and that permanently orphans every install if
    /// lost). So on this build `availability` is `.publicKeyPlaceholder`,
    /// and the section renders the second shape below.
    ///
    /// **What that second shape deliberately does and doesn't include**,
    /// following `FanControlPane`'s two precedents exactly:
    ///   - The automatic-check toggle is shown but `.disabled`, with a lock
    ///     row naming the actual blocker — the same treatment the fan mode
    ///     picker gets. It's visible so the feature is legible, and inert so
    ///     it can't be believed.
    ///   - "Check for Updates…" is **absent**, not present-and-greyed —
    ///     the same call `FanControlPane` makes for "Return to Auto." A
    ///     greyed button implies a working mechanism behind a temporary
    ///     block; there isn't one. And the specific failure a live button
    ///     would produce is worse than an error: Sparkle would fetch the
    ///     feed, reject every item's signature, and report "You're up to
    ///     date!" — a false statement that stops the user looking.
    @ViewBuilder
    private var updatesSection: some View {
        Section {
            if let controller = updateController {
                let availability = controller.availability

                if availability.canCheckForUpdates {
                    Toggle("Check for updates automatically", isOn: $store.settings.updateCheckDaily)
                        .accessibilityLabel("Check for updates automatically")
                    Text("Sentry looks for a new version about once a day in the background, and tells you when one is ready. It never installs anything without asking.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Check for Updates…") { controller.checkForUpdates() }
                        .accessibilityLabel("Check for updates now")
                } else {
                    // §9.4: never encode meaning in color alone — the icon
                    // and the sentence both carry it.
                    Label {
                        Text(availability.headline)
                            .fontWeight(.semibold)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(palette.warning)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    Text(availability.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Check for updates automatically", isOn: $store.settings.updateCheckDaily)
                        .disabled(true)
                        .accessibilityLabel("Check for updates automatically")
                        .accessibilityHint("Unavailable: \(availability.headline)")

                    Label {
                        Text("This preference is saved, but nothing acts on it in this build.")
                            .font(.callout)
                    } icon: {
                        Image(systemName: "lock")
                            .foregroundStyle(palette.warning)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label {
                    Text("This copy of Sentry has no update channel.")
                        .fontWeight(.semibold)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(palette.warning)
                }
                .fixedSize(horizontal: false, vertical: true)

                Text("No updater was wired into this build, so Sentry will never notice a new version. Check for one manually.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Sentry is distributed outside the Mac App Store, so updates come from Sentry itself rather than from the App Store. Every update is checked against a signing key built into this copy before it's installed — one that can't be verified is refused rather than run.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var formattedInterval: String {
        String(format: "%.1f s", store.settings.globalRefreshInterval)
    }

    private var formattedMediumInterval: String {
        String(format: "%.0f s", store.settings.mediumTierRefreshInterval)
    }

    private var formattedSlowInterval: String {
        String(format: "%.0f s", store.settings.slowTierRefreshInterval)
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
