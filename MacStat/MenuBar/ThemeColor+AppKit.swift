import AppKit
import MacStatKit

// MARK: - ThemeColor -> NSColor

extension ThemeColor {
    /// Resolves this token against a concrete `NSAppearance`.
    ///
    /// Takes the appearance as a parameter rather than reading
    /// `NSApp.effectiveAppearance` internally because the status item's
    /// appearance is not always the app's: the menu bar can be dark while the
    /// app is light. Callers pass the drawing view's `effectiveAppearance` at
    /// draw time so a light/dark switch is picked up on the next redraw.
    func nsColor(for appearance: NSAppearance) -> NSColor {
        nsColor(dark: appearance.macStatIsDark)
    }

    func nsColor(dark: Bool) -> NSColor {
        let hex = dark ? self.dark : self.light
        guard let rgba = ThemeColor.rgbaComponents(hex: hex) else {
            // P5: a malformed imported theme must not crash or paint an
            // invisible bar item. Neutral gray reads as "obviously wrong"
            // without disappearing.
            return NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: clampedBarOpacity)
        }
        return NSColor(
            srgbRed: rgba.r,
            green: rgba.g,
            blue: rgba.b,
            alpha: rgba.a * clampedBarOpacity
        )
    }

    private var clampedBarOpacity: CGFloat { CGFloat(min(max(opacity, 0), 1)) }

    /// Accepts `RGB`, `RRGGBB` and `RRGGBBAA`, with or without a leading `#`.
    /// Returns nil for anything else — never a force-unwrap, never a trap.
    ///
    /// Deliberately named differently from the SwiftUI-side parser so the two
    /// extensions on `ThemeColor` in this same target can't collide; the data
    /// model intentionally stores unvalidated strings, so every rendering
    /// layer needs its own tolerant read of them.
    static func rgbaComponents(hex raw: String) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard !hex.isEmpty, hex.allSatisfy({ $0.isHexDigit }) else { return nil }

        let expanded: String
        switch hex.count {
        case 3: expanded = hex.map { "\($0)\($0)" }.joined()
        case 6, 8: expanded = hex
        default: return nil
        }

        guard let value = UInt64(expanded, radix: 16) else { return nil }
        if expanded.count == 8 {
            return (
                CGFloat((value >> 24) & 0xFF) / 255,
                CGFloat((value >> 16) & 0xFF) / 255,
                CGFloat((value >> 8) & 0xFF) / 255,
                CGFloat(value & 0xFF) / 255
            )
        }
        return (
            CGFloat((value >> 16) & 0xFF) / 255,
            CGFloat((value >> 8) & 0xFF) / 255,
            CGFloat(value & 0xFF) / 255,
            1.0
        )
    }
}

// MARK: - Appearance

extension NSAppearance {
    /// `bestMatch` rather than a raw `name ==` comparison so accessibility
    /// appearances (increased contrast, vibrant variants) still resolve to one
    /// of the two buckets a `ThemeColor` actually carries.
    var macStatIsDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
