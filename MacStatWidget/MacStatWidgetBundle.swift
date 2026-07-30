import MacStatKit
import SwiftUI
import WidgetKit

// MARK: - MacStatWidgetEntryView: family dispatch

/// Routes to one of the five family-specific views (plan §12.3's table) by
/// `\.widgetFamily`. All five ultimately read the same `entry.snapshot` —
/// see `Provider.getTimeline`'s doc comment on why every entry in a
/// timeline carries an identical, polled-not-pushed cache read — so there
/// is exactly one place (`WidgetSnapshotStore`) any family's data can be
/// stale or wrong, not five independent read paths to keep in sync.
struct MacStatWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: Provider.Entry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(snapshot: entry.snapshot)
        case .systemMedium:
            MediumWidgetView(snapshot: entry.snapshot)
        case .systemLarge:
            LargeWidgetView(snapshot: entry.snapshot)
        case .accessoryCircular:
            AccessoryCircularWidgetView(snapshot: entry.snapshot)
        case .accessoryRectangular:
            AccessoryRectangularWidgetView(snapshot: entry.snapshot)
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

// MARK: - MacStatWidget

struct MacStatWidget: Widget {
    let kind: String = "MacStatWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            MacStatWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("MacStat")
        // The gallery-level honesty disclosure — see `WidgetDemoDataCaption`'s
        // doc comment for why the in-widget caption only exists on
        // `.systemLarge`; every family still gets this sentence at the
        // moment a user is choosing to add the widget, which is arguably
        // the more important moment for the disclosure to land (before
        // they've committed a home screen slot to it), not after.
        .description("Battery, CPU, and sleep status for your Mac. This build shows demo data — there's no live iCloud sync yet, so nothing here comes from a real Mac.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryCircular,
            .accessoryRectangular,
        ])
    }
}

@main
struct MacStatWidgetBundle: WidgetBundle {
    var body: some Widget {
        MacStatWidget()
    }
}
