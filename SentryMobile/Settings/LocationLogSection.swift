import CoreLocation
import MapKit
import SwiftUI
import SentryKit

// MARK: - LocationLogSection: the Settings tab's honest "last known location" card

/// Renders `LocationLogViewModel.lastLocation` as a single pin on a `MapKit`
/// view, or an explicit honest-empty state when there's nothing to show.
/// Lives in the Settings tab (not a 5th tab, not Dashboard) — see this
/// file's placement rationale in `SettingsTabView`'s doc comment update:
/// this is a permission-gated, occasionally-updated piece of Mac state, much
/// closer in kind to the "Devices & sync status" section already on this
/// tab than to Dashboard's live, every-few-seconds metric cards.
///
/// **Never "Find My."** This section's copy says "last known location" and
/// "as of [time]" throughout, never "current location," "tracking," or
/// "Find My [Mac]" — see `MacLocation`/`LocationService`'s doc comments
/// (`SentryKit/Models/MacLocation.swift`, `SentryKit/Services/LocationService.swift`)
/// for why that distinction is load-bearing: there is no public API for a
/// third-party app to plug into Apple's actual Find My network, so this
/// feature is a periodic, permission-gated log, not a tracker, and every
/// string here says so.
///
/// **Three honest states, not two.** A map view with no data would either
/// render blank (confusing) or default to some arbitrary region (misleading
/// — looks like a real reading). This section instead distinguishes:
///   1. No location has ever been received (`lastLocation == nil`) — the map
///      is never shown at all, replaced by an explanatory empty state that
///      names the two most likely reasons (Mac hasn't enabled the feature,
///      or hasn't reported one to this phone yet).
///   2. A location was received — the map shows exactly one pin, and the
///      caption states its `Freshness`/age via `FreshnessBadge`, the same
///      component every other Mac-derived reading in this app uses (plan
///      §12.2), so staleness reads identically everywhere in the app.
struct LocationLogSection: View {
    @ObservedObject var viewModel: LocationLogViewModel

    @Environment(\.themePalette) private var palette

    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing * 0.75) {
            Text("LOCATION LOG")
                .font(palette.font(size: 10, weight: .semibold))
                .foregroundStyle(palette.textTertiary)

            if let location = viewModel.lastLocation {
                mapCard(for: location)
            } else {
                emptyState
            }

            Text("Not Find My — Sentry has no connection to Apple's Find My network. This is a periodic location log: while Sentry is running on your Mac and location access is granted, it occasionally reports its approximate location to this phone over your local Wi-Fi network. It cannot be located while off, asleep, or offline.")
                .font(palette.font(size: 10.5))
                .foregroundStyle(palette.textTertiary)
        }
        .task {
            viewModel.start()
        }
        .onChange(of: viewModel.lastLocation) { _, newValue in
            guard let newValue else { return }
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: newValue.latitude, longitude: newValue.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                )
            )
        }
    }

    // MARK: - Has a reading

    private func mapCard(for location: MacLocation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Map(position: $cameraPosition) {
                Marker("Mac's last known location", coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude))
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                    .stroke(palette.separator, lineWidth: 1)
            )
            .allowsHitTesting(false) // a settings card, not an interactive map screen

            HStack(spacing: 6) {
                Text("As of \(location.timestamp.formatted(date: .omitted, time: .shortened))")
                    .font(palette.font(size: 11))
                    .foregroundStyle(palette.textSecondary)
                Spacer(minLength: 0)
                FreshnessBadge(lastSeen: location.timestamp)
            }

            if let accuracy = location.horizontalAccuracyMeters {
                Text("Approximate — accurate to roughly ±\(Int(accuracy)) meters, not precise GPS.")
                    .font(palette.font(size: 10))
                    .foregroundStyle(palette.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mac's last known location, as of \(location.timestamp.formatted(date: .abbreviated, time: .shortened))")
    }

    // MARK: - Nothing received yet

    private var emptyState: some View {
        HStack(spacing: 6) {
            Image(systemName: "location.slash")
                .font(.system(size: 11))
                .foregroundStyle(palette.textTertiary)
            Text("No location received yet.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Either your Mac hasn't turned on Location Log in its Settings, hasn't been granted location permission, or hasn't reported a location to this phone yet. This is not a live map and cannot show a Mac that has never reported in.")
    }
}
