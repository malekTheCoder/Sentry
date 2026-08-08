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
    /// Alpha mask over the material. Where the mask is opaque the effect
    /// shows; where it is clear the effect vanishes. This is what makes a
    /// *progressive* blur possible: a vertical gradient mask fades the blur
    /// out instead of ending it at a hard edge.
    var maskImage: NSImage?

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.maskImage = maskImage
        // `.active` rather than `.followsWindowActiveState`: a metrics
        // surface losing its glass every time focus moves to another app
        // reads as flicker, not as deference.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.maskImage = maskImage
    }
}

extension VisualEffect {
    /// A resizable image that is fully opaque at the top and fades to clear
    /// at the bottom, for use as `maskImage`. Drawn once per distinct height;
    /// AppKit stretches it across the view's width.
    static func topFadeMask(height: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 1, height: height), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext,
                  let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [
                        CGColor(gray: 0, alpha: 1),
                        CGColor(gray: 0, alpha: 0.9),
                        CGColor(gray: 0, alpha: 0),
                    ] as CFArray,
                    // Hold full strength through the titlebar region, then
                    // ease out — an even ramp reads as a smear, not a fade.
                    locations: [1.0, 0.55, 0.0]
                  )
            else { return false }
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: rect.maxY),
                end: CGPoint(x: 0, y: rect.minY),
                options: []
            )
            return true
        }
        image.resizingMode = .stretch
        return image
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
