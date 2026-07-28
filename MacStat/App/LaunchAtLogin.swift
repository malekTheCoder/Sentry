import AppKit
import ServiceManagement

/// Wraps `SMAppService.mainApp` to register/unregister MacStat as a
/// login item. Default is off (see FR-5).
public enum LaunchAtLogin {

    /// What macOS actually thinks, which is not a boolean.
    public enum State {
        case enabled
        case disabled
        /// `register()` succeeded but macOS is waiting for the user to
        /// approve the login item in System Settings. This is the *normal*
        /// first-registration outcome for a Developer ID app, not an error.
        case requiresApproval
        case notFound
    }

    public static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .disabled
        @unknown default: return .disabled
        }
    }

    /// True when the login item will actually run at next login — which
    /// includes the pending-approval case. Treating `.requiresApproval` as
    /// "off" makes the settings toggle silently flip itself back off after a
    /// successful enable, since macOS reports approval-pending rather than
    /// enabled until the user visits System Settings.
    public static var isEnabled: Bool {
        switch state {
        case .enabled, .requiresApproval: return true
        case .disabled, .notFound: return false
        }
    }

    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Deep-links to Login Items so the pending-approval state is actionable
    /// rather than just explained.
    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
