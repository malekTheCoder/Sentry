import SwiftUI
import WidgetKit

// MARK: - SentryWatchWidget

struct SentryWatchWidget: Widget {
    let kind: String = "SentryWatchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            ComplicationView(entry: entry)
        }
        // Product name is Sentry (bundle IDs and module names stay Sentry)
        // — matches `SentryWidget`'s `configurationDisplayName("Sentry")`.
        .configurationDisplayName("Sentry")
        .description("Battery and thermal status for your Mac, relayed from the Sentry iPhone app when you're on the same Wi-Fi as your Mac.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

@main
struct SentryWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        SentryWatchWidget()
    }
}
