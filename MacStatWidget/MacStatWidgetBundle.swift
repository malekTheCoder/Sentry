import WidgetKit
import SwiftUI

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        completion(SimpleEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        let entry = SimpleEntry(date: Date())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
}

struct MacStatWidgetEntryView: View {
    var entry: Provider.Entry

    var body: some View {
        Text("MacStat")
    }
}

struct MacStatWidget: Widget {
    let kind: String = "MacStatWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            MacStatWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("MacStat")
        .description("Mac stats at a glance.")
    }
}

@main
struct MacStatWidgetBundle: WidgetBundle {
    var body: some Widget {
        MacStatWidget()
    }
}
