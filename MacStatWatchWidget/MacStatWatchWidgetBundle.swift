import SwiftUI
import WidgetKit

// MARK: - MacStatWatchWidget

struct MacStatWatchWidget: Widget {
    let kind: String = "MacStatWatchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            ComplicationView(entry: entry)
        }
        // Product name is Sentry (bundle IDs and module names stay MacStat)
        // — matches `MacStatWidget`'s `configurationDisplayName("Sentry")`.
        .configurationDisplayName("Sentry")
        .description("Battery and thermal status for your Mac, relayed from the Sentry iPhone app when you're on the same Wi-Fi as your Mac.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

@main
struct MacStatWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        MacStatWatchWidget()
    }
}
