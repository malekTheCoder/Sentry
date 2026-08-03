import SwiftUI
import SentryKit

/// A real `NSVisualEffectView` for SwiftUI surfaces.
///
/// SwiftUI's `Material` inside an ordinary opaque window samples the window's
/// own backing — which renders as a flat gray, not glass. The AppKit effect
/// view with `.behindWindow` blending samples the actual desktop/windows
/// behind the window, which is what "translucent" and "liquid glass" mean.
/// The windows that host these surfaces are made non-opaque with clear
/// backgrounds (`SettingsWindowController` / `HistoryWindowController`) so
/// there is something behind to sample.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        // `.active` rather than `.followsWindowActiveState`: a metrics
        // surface losing its glass every time focus moves to another app
        // reads as flicker, not as deference.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

extension MaterialToken {
    /// `MaterialToken` was designed as a 1:1 mirror of the `NSVisualEffectView`
    /// materials that make sense for these surfaces — this is where the two
    /// meet.
    var nsMaterial: NSVisualEffectView.Material {
        switch self {
        case .menu: return .menu
        case .popover: return .popover
        case .sidebar: return .sidebar
        case .hudWindow: return .hudWindow
        case .underWindowBackground: return .underWindowBackground
        case .contentBackground: return .contentBackground
        }
    }
}
