import SentryKit
import SwiftUI
import WidgetKit

// MARK: - SentryWidgetEntryView: family dispatch

/// Routes to one of the five family-specific views (plan §12.3's table) by
/// `\.widgetFamily`. All five ultimately read the same `entry.snapshot` —
/// see `Provider.getTimeline`'s doc comment on why every entry in a
/// timeline carries an identical, polled-not-pushed cache read — so there
/// is exactly one place (`WidgetSnapshotStore`) any family's data can be
/// stale or wrong, not five independent read paths to keep in sync.
struct SentryWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: Provider.Entry

    var body: some View {
        // iOS 17 / macOS 14 WidgetKit requires the container-background API
        // for system families; without it the widget renders as a "please
        // adopt" placeholder. `.background` (the semantic style, not a
        // color) keeps the system's default widget surface in both light
        // and dark, which is exactly the minimal look the app wants.
        familyView
            .containerBackground(.background, for: .widget)
    }

    @ViewBuilder
    private var familyView: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(snapshot: entry.snapshot)
        case .systemMedium:
            MediumWidgetView(snapshot: entry.snapshot)
        case .systemLarge:
            LargeWidgetView(snapshot: entry.snapshot)
        #if !os(macOS)
        case .accessoryCircular:
            AccessoryCircularWidgetView(snapshot: entry.snapshot)
        case .accessoryRectangular:
            AccessoryRectangularWidgetView(snapshot: entry.snapshot)
        #endif
        default:
            // `.systemExtraLarge`/`.accessoryInline`/future families this
            // widget doesn't declare support for (see `supportedFamilies`
            // below) — WidgetKit shouldn't ever request one of these, but a
            // `switch` over a non-frozen-from-our-side enum needs an
            // exhaustive fallback, and "no data" is the honest one rather
            // than a `fatalError()` a future OS's new family could trigger
            // in production.
            WidgetNoDataView(compact: true)
        }
    }
}

// MARK: - SentryWidget

struct SentryWidget: Widget {
    let kind: String = "SentryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            SentryWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Sentry")
        .description(Self.galleryDescription)
        .supportedFamilies(Self.families)
    }

    /// The gallery-level honesty disclosure — see `WidgetDemoDataCaption`'s
    /// doc comment for why the in-widget caption only exists on
    /// `.systemLarge`. Platform-split because the two builds genuinely
    /// differ: the Mac widget is fed live local readings by
    /// `MacWidgetSnapshotWriter`, while the phone build still renders
    /// `MockDataSource` demo data (its writer sets `sourceIsDemoData: true`).
    private static var galleryDescription: String {
        #if os(macOS)
        String(localized: "Battery, CPU, and sleep status for this Mac, live from the Sentry menu bar app.")
        #else
        String(localized: "Battery, CPU, and sleep status for your Mac — live over your local Wi-Fi when Sentry is running on the Mac, demo data otherwise (and labeled as such).")
        #endif
    }

    /// The accessory families are Lock Screen / watch surfaces that don't
    /// exist on macOS — referencing them there doesn't even compile.
    private static var families: [WidgetFamily] {
        #if os(macOS)
        [.systemSmall, .systemMedium, .systemLarge]
        #else
        [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular]
        #endif
    }
}

@main
struct SentryWidgetBundle: WidgetBundle {
    var body: some Widget {
        SentryWidget()
    }
}
