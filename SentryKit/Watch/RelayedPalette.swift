import Foundation

// MARK: - RelayedPalette

/// A `Theme` flattened to exactly the colours the Watch app draws, resolved
/// for one appearance, as plain hex strings.
///
/// **Why this exists when `WatchRelaySnapshot.themeID` already names a
/// theme.** An id only works for a theme both ends can look up, and that is
/// `Theme.builtInPresets` — code, compiled identically into every target.
/// The Mac has a second kind: `AppSettings.customThemes`, forked in the
/// theme editor or imported from a `.sentrytheme` file. Those are the user's
/// *data*, they exist only on that Mac, and no id will ever resolve them
/// anywhere else. A watch handed `"custom.8B12…"` has nothing to render, so
/// it fell back to the default preset — which is the one case where the
/// wrist provably could not match the Mac.
///
/// Carrying the resolved colours instead makes every theme work by the same
/// mechanism, with no special case for custom ones, and has a second benefit
/// worth as much: it is exact by construction. An id-based scheme quietly
/// assumes both ends compiled the same definition of `builtin.ivory`, which
/// stops being true the moment a watch app is a version behind the phone.
///
/// **Why this shape.** The payload crosses `WCSession`, where
/// `WatchRelaySnapshotTests.testAFullyPopulatedPayloadStaysSmall` holds the
/// whole snapshot to a small budget — so this carries the eleven tokens the
/// watch actually draws and the four metric hues it actually needs, not a
/// whole `Theme` (which would also drag typography, geometry, chart and
/// material settings the watch has no use for). Field names are two
/// characters for the same reason: a JSON key is paid for on every relay,
/// forever, and these are read by exactly one file at each end.
///
/// Hex strings rather than parsed components because that is what
/// `ThemeColor` stores and what `ThemeColor.components(fromHex:)` already
/// parses — round-tripping through numbers would add a lossy step for no
/// gain, and a dumped payload stays readable when someone is working out why
/// a wrist is the wrong colour.
public struct RelayedPalette: Codable, Equatable, Sendable {
    /// `background`
    public var bg: String
    /// `surface`
    public var sf: String
    /// `surfaceElevated`
    public var se: String
    /// `textPrimary`
    public var t1: String
    /// `textSecondary`
    public var t2: String
    /// `textTertiary`
    public var t3: String
    /// `accent`
    public var ac: String
    /// `success`
    public var ok: String
    /// `warning`
    public var wn: String
    /// `danger`
    public var dg: String
    /// `separator`
    public var sp: String

    /// The four metric hues the Watch draws, from the theme's `metricColors`.
    /// Each is Optional because a theme need not define one — the watch falls
    /// back to `ac` exactly as `ThemePalette.metricColor` does on the other
    /// two platforms.
    ///
    /// `dsk` reads `disk.read_bytes_per_sec` rather than `disk.used_percent`
    /// because that is the key the presets actually populate; the dial shows
    /// a used-percentage either way and only the hue comes from here. See
    /// `OverviewPage.MetricReadouts.metrics`.
    public var cpu: String?
    public var mem: String?
    public var dsk: String?
    public var bat: String?

    public init(
        bg: String, sf: String, se: String,
        t1: String, t2: String, t3: String,
        ac: String, ok: String, wn: String, dg: String, sp: String,
        cpu: String? = nil, mem: String? = nil, dsk: String? = nil, bat: String? = nil
    ) {
        self.bg = bg; self.sf = sf; self.se = se
        self.t1 = t1; self.t2 = t2; self.t3 = t3
        self.ac = ac; self.ok = ok; self.wn = wn; self.dg = dg; self.sp = sp
        self.cpu = cpu; self.mem = mem; self.dsk = dsk; self.bat = bat
    }

    /// Flattens a theme for one appearance.
    ///
    /// **Resolving the light/dark pair here, on the sender, is the point.**
    /// The watch has no `ColorScheme` to resolve against — that is the whole
    /// reason `WatchRelaySnapshot.themeAppearance` exists — so doing it once
    /// where the answer is actually known beats shipping both halves and
    /// re-deciding downstream. It also halves what goes on the wire.
    ///
    /// `ThemeColor.opacity` is folded in by `hex(for:)`? It is not: that
    /// accessor returns the raw stored string, and `opacity` is a separate
    /// multiplier applied by `rgba(for:)`. So this composes the two, emitting
    /// `RRGGBBAA` when a token carries real transparency — otherwise a
    /// theme's 5%-alpha separator would arrive fully opaque and draw a
    /// hairline several times heavier than the Mac's.
    public init(theme: Theme, appearance: ThemeAppearance) {
        func hex(_ token: ThemeColor) -> String {
            guard let rgba = token.rgba(for: appearance) else { return "808080" }
            func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            let base = String(format: "%02X%02X%02X", byte(rgba.red), byte(rgba.green), byte(rgba.blue))
            guard rgba.alpha < 1 else { return base }
            return base + String(format: "%02X", byte(rgba.alpha))
        }
        func metric(_ id: MetricID) -> String? {
            theme.metricColor(for: id).map(hex)
        }

        self.init(
            bg: hex(theme.background),
            sf: hex(theme.surface),
            se: hex(theme.surfaceElevated),
            t1: hex(theme.textPrimary),
            t2: hex(theme.textSecondary),
            t3: hex(theme.textTertiary),
            ac: hex(theme.accent),
            ok: hex(theme.success),
            wn: hex(theme.warning),
            dg: hex(theme.danger),
            sp: hex(theme.separator),
            cpu: metric(.cpuTotalPercent),
            mem: metric(.memoryUsedBytes),
            dsk: metric(.diskReadBytesPerSec),
            bat: metric(.batteryChargePercent)
        )
    }
}
