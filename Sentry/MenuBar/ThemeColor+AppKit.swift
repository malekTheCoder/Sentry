import AppKit

// The `ThemeColor -> NSColor` bridge that used to live here died with the
// themed bar: `MenuBarPalette` is monochrome and derives every token from the
// menu bar's appearance alone, so no AppKit code resolves theme hex strings
// anymore (the SwiftUI-side parser in `ThemeColor+SwiftUI` covers every
// themed surface). Only the appearance helper below is still consumed.

// MARK: - Appearance

extension NSAppearance {
    /// `bestMatch` rather than a raw `name ==` comparison so accessibility
    /// appearances (increased contrast, vibrant variants) still resolve to one
    /// of the two buckets a `ThemeColor` actually carries.
    var sentryIsDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
