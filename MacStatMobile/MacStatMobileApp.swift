import SwiftUI

/// Entry point for the iPhone companion app (plan §12 — "iPhone App &
/// Widget"). Was a one-screen `Text("MacStat")` stub before this task;
/// now hands off to `RootTabView`, the plan §12.1 four-tab shell
/// (Dashboard/History/Alerts/Settings).
@main
struct MacStatMobileApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}
