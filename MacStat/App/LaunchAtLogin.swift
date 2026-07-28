import ServiceManagement

/// Wraps `SMAppService.mainApp` to register/unregister MacStat as a
/// login item. Default is off (see FR-5); a future Settings pane will
/// read `isEnabled` and call `setEnabled(_:)` from a toggle.
public enum LaunchAtLogin {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
