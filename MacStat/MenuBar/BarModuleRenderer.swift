import AppKit
import CoreText
import MacStatKit

/// Theme color tokens resolved once for a given appearance.
///
/// Hex parsing allocates; the bar redraws every few seconds forever (P6), so
/// tokens are resolved when the theme or the appearance changes and never
/// per frame.
struct MenuBarPalette {
    let textPrimary: NSColor
    let textSecondary: NSColor
    let textTertiary: NSColor
    let accent: NSColor
    let success: NSColor
    let warning: NSColor
    let danger: NSColor
    let separator: NSColor
    let chartFill: [NSColor]
    /// Keyed by `MetricID.rawValue` — `Theme.metricColors` is string-keyed so
    /// it can carry templated ids (`cpu.core.3_percent`) that have no case.
    let metricColors: [String: NSColor]

    init(theme: Theme, dark: Bool) {
        textPrimary = theme.textPrimary.nsColor(dark: dark)
        textSecondary = theme.textSecondary.nsColor(dark: dark)
        textTertiary = theme.textTertiary.nsColor(dark: dark)
        accent = theme.accent.nsColor(dark: dark)
        success = theme.success.nsColor(dark: dark)
        warning = theme.warning.nsColor(dark: dark)
        danger = theme.danger.nsColor(dark: dark)
        separator = theme.separator.nsColor(dark: dark)
        let stops = theme.chartFill.map { $0.nsColor(dark: dark) }
        // A one-stop gradient is degenerate and an empty `chartFill` is legal
        // in the data model, so fall back to a fade of the accent.
        chartFill = stops.count >= 2
            ? stops
            : [accent.withAlphaComponent(0.35), accent.withAlphaComponent(0)]
        metricColors = theme.metricColors.mapValues { $0.nsColor(dark: dark) }
    }
}

/// Where a value sits in a `.thresholdGradient` ramp.
///
/// Exists because §9.4 forbids encoding state in hue alone: the band is what
/// lets the renderer draw a non-color cue and the view speak the state, so a
/// red "8%" also reads as "critical" to someone who can't see the red.
enum BarSeverity: String {
    case nominal
    case warning
    case critical

    /// Appended to the VoiceOver summary. `nominal` is deliberately silent —
    /// narrating "nominal" after every metric would bury the two bands that
    /// actually matter.
    var spokenSuffix: String? {
        switch self {
        case .nominal: return nil
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }
}

/// Draws one `BarModule` into the current graphics context and reports the
/// width it needs.
///
/// A class, not a struct of static functions, because everything expensive
/// (font construction, hex parsing, text measurement, symbol tinting) is
/// cached on the instance. The instance is cheap to throw away and rebuild —
/// which is exactly what `StatusItemView` does when the theme or the
/// effective appearance changes, so no cache ever goes stale.
final class BarModuleRenderer {
    let theme: Theme
    let palette: MenuBarPalette

    private let font: NSFont
    private let baseAttributes: [NSAttributedString.Key: Any]
    private var textSizeCache: [String: CGSize] = [:]
    private var symbolCache: [SymbolKey: NSImage] = [:]
    private var symbolCacheOrder: [SymbolKey] = []
    private var fallbackImage: NSImage?

    /// The non-color cue drawn beside a critical value (§9.4). A glyph rather
    /// than a shape so it survives every theme, font and bar height.
    private static let criticalCue = "!"

    /// Fractions of the ramp at which a value stops being ordinary. Chosen so
    /// the warning band starts around where the ramp visibly leaves green.
    private static let warningThreshold = 0.6
    private static let criticalThreshold = 0.85

    private static let symbolCacheLimit = 64

    /// Cache key for a tinted glyph.
    ///
    /// The tint is quantized to 1/32 per channel rather than keyed on the
    /// exact color: `.thresholdGradient` interpolates continuously, so an
    /// exact key made every single frame a cache miss. Quantizing also avoids
    /// `NSColor.description`, which allocated a formatted string on every
    /// lookup — on the hot path, for a value used only as a dictionary key.
    private struct SymbolKey: Hashable {
        let name: String
        let r: Int8
        let g: Int8
        let b: Int8
        let a: Int8

        init(name: String, color: NSColor) {
            self.name = name
            let srgb = color.usingColorSpace(.sRGB)
            func quantize(_ component: CGFloat?) -> Int8 {
                guard let component else { return 0 }
                return Int8(clamping: Int((min(max(component, 0), 1) * 31).rounded()))
            }
            r = quantize(srgb?.redComponent)
            g = quantize(srgb?.greenComponent)
            b = quantize(srgb?.blueComponent)
            a = quantize(srgb?.alphaComponent)
        }
    }

    init(theme: Theme, dark: Bool) {
        self.theme = theme
        self.palette = MenuBarPalette(theme: theme, dark: dark)
        self.font = Self.makeFont(theme: theme)
        self.baseAttributes = [.font: self.font]
    }

    // MARK: - Public entry points

    /// Intrinsic width of a module. Kept separate from `draw` so the view can
    /// size the status item without a drawing context.
    func width(for module: BarModule, value: Double?, normalized: Double?, history: [Double]) -> CGFloat {
        cueWidth(for: module, value: value) + contentWidth(for: module, value: value, normalized: normalized, history: history)
    }

    /// Draws into the current `NSGraphicsContext`. `rect` is the module's slot
    /// in the bar item's (unflipped) coordinate space.
    func draw(_ module: BarModule, value: Double?, normalized: Double?, history: [Double], in rect: CGRect) {
        var slot = rect
        let cue = cueWidth(for: module, value: value)
        if cue > 0 {
            // §9.4: never state-by-hue alone. The critical band gets a glyph
            // in the danger color *and* the color itself.
            drawText(Self.criticalCue, in: slot, x: slot.minX, color: palette.danger)
            slot = CGRect(x: slot.minX + cue, y: slot.minY, width: max(slot.width - cue, 0), height: slot.height)
        }

        let tint = color(for: module, value: value)
        switch module.displayMode {
        case .iconOnly:
            drawIconOnly(module, value: value, tint: tint, in: slot)
        case .valueOnly:
            drawValueOnly(module, value: value, tint: tint, in: slot)
        case .iconAndValue:
            drawIconAndValue(module, value: value, tint: tint, in: slot)
        case .sparkline:
            drawSparkline(module, value: value, history: history, tint: tint, in: slot, showsValue: false)
        case .sparklineAndValue:
            drawSparkline(module, value: value, history: history, tint: tint, in: slot, showsValue: true)
        case .bar:
            drawBar(module, normalized: normalized, tint: tint, in: slot)
        case .arc:
            drawArc(module, normalized: normalized, tint: tint, in: slot)
        }
    }

    private func contentWidth(for module: BarModule, value: Double?, normalized: Double?, history: [Double]) -> CGFloat {
        switch module.displayMode {
        case .iconOnly:
            return iconSize
        case .valueOnly:
            return textSize(valueText(module, value)).width
        case .iconAndValue:
            return iconSize + iconTextGap + textSize(valueText(module, value)).width
        case .sparkline:
            return labelWidth(module) + graphWidth(history: history)
        case .sparklineAndValue:
            return labelWidth(module)
                + graphWidth(history: history)
                + iconTextGap
                + textSize(valueText(module, value, includeLabel: false)).width
        case .bar:
            return labelWidth(module) + gaugeWidth(normalized: normalized)
        case .arc:
            return labelWidth(module) + arcWidth(normalized: normalized)
        }
    }

    // MARK: - Severity (§9.4)

    /// The ramp band this value falls in, or nil when the module isn't
    /// threshold-colored (no other rule defines "bad") or has no reading.
    func severity(for module: BarModule, value: Double?) -> BarSeverity? {
        guard case .thresholdGradient(let low, let high) = module.colorRule, let value else { return nil }
        guard let position = rampPosition(value: value, low: low, high: high) else { return nil }
        if position >= Self.criticalThreshold { return .critical }
        if position >= Self.warningThreshold { return .warning }
        return .nominal
    }

    private func cueWidth(for module: BarModule, value: Double?) -> CGFloat {
        severity(for: module, value: value) == .critical
            ? textSize(Self.criticalCue).width + iconTextGap
            : 0
    }

    // MARK: - Text modes

    private func drawValueOnly(_ module: BarModule, value: Double?, tint: NSColor, in rect: CGRect) {
        let text = valueText(module, value)
        drawText(text, in: rect, x: rect.minX, color: value == nil ? palette.textTertiary : tint)
    }

    private func drawIconOnly(_ module: BarModule, value: Double?, tint: NSColor, in rect: CGRect) {
        // An icon-only module has no number to dim, so unavailability is
        // expressed by dimming the glyph itself rather than swapping in a dash
        // that would change the module's width from frame to frame.
        let color = value == nil ? palette.textTertiary : tint
        drawSymbol(for: module.metric, color: color, in: iconRect(at: rect.minX, in: rect))
    }

    private func drawIconAndValue(_ module: BarModule, value: Double?, tint: NSColor, in rect: CGRect) {
        let color = value == nil ? palette.textTertiary : tint
        drawSymbol(for: module.metric, color: color, in: iconRect(at: rect.minX, in: rect))
        drawText(valueText(module, value), in: rect, x: rect.minX + iconSize + iconTextGap, color: color)
    }

    // MARK: - Sparkline

    private func drawSparkline(
        _ module: BarModule,
        value: Double?,
        history: [Double],
        tint: NSColor,
        in rect: CGRect,
        showsValue: Bool
    ) {
        var x = rect.minX
        x += drawLeadingLabel(module, in: rect, x: x)

        let plotWidth = graphWidth(history: history)
        let plotRect = CGRect(
            x: x,
            y: rect.minY + verticalInset,
            width: plotWidth,
            height: max(rect.height - verticalInset * 2, 1)
        )

        if history.count >= 2 {
            drawSeries(history, in: plotRect, tint: tint)
        } else {
            // Not enough samples to plot yet (P5: say so, don't draw a
            // misleading flat zero line).
            drawText(
                MetricFormatter.unavailable,
                in: rect,
                x: plotRect.midX - textSize(MetricFormatter.unavailable).width / 2,
                color: palette.textTertiary
            )
        }
        x += plotWidth

        if showsValue {
            let text = valueText(module, value, includeLabel: false)
            drawText(text, in: rect, x: x + iconTextGap, color: value == nil ? palette.textTertiary : tint)
        }
    }

    private func drawSeries(_ samples: [Double], in rect: CGRect, tint: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext, samples.count >= 2 else { return }

        // Auto-scale to the buffer's own range. A perfectly flat series has a
        // zero range, so it renders as a flat mid-line rather than dividing
        // by zero or slamming to the top of the plot.
        let lowest = samples.min() ?? 0
        let highest = samples.max() ?? 0
        let span = highest - lowest
        let flat = !span.isFinite || span < 0.000_001

        let count = samples.count
        let step = rect.width / CGFloat(count - 1)
        func point(_ index: Int) -> CGPoint {
            let sample = samples[index]
            let fraction = (flat || !sample.isFinite) ? 0.5 : (sample - lowest) / span
            return CGPoint(
                x: rect.minX + CGFloat(index) * step,
                y: rect.minY + CGFloat(min(max(fraction, 0), 1)) * rect.height
            )
        }

        ctx.saveGState()
        ctx.setLineWidth(max(theme.chartLineWidth, 0.5))
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        switch theme.chartStyle {
        case .bars:
            let barWidth = max(step - 1, 0.75)
            ctx.setFillColor(tint.cgColor)
            for index in 0..<count {
                let p = point(index)
                let height = max(p.y - rect.minY, 0.75)
                ctx.fill(CGRect(x: p.x - barWidth / 2, y: rect.minY, width: barWidth, height: height))
            }
        case .line, .stepped, .area:
            let line = CGMutablePath()
            line.move(to: point(0))
            for index in 1..<count {
                let p = point(index)
                if theme.chartStyle == .stepped {
                    line.addLine(to: CGPoint(x: p.x, y: point(index - 1).y))
                }
                line.addLine(to: p)
            }

            if theme.chartStyle == .area {
                // The fill is the same path closed down to the baseline; the
                // open line is stroked on top afterwards so the crest stays
                // crisp instead of being half-swallowed by the gradient.
                let fill = CGMutablePath()
                fill.addPath(line)
                fill.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                fill.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
                fill.closeSubpath()

                ctx.saveGState()
                ctx.addPath(fill)
                ctx.clip()
                drawFillGradient(ctx, in: rect)
                ctx.restoreGState()
            }

            applyGlow(ctx, color: tint)
            ctx.setStrokeColor(tint.cgColor)
            ctx.addPath(line)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func drawFillGradient(_ ctx: CGContext, in rect: CGRect) {
        let colors = palette.chartFill.map { $0.cgColor } as CFArray
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space, colors: colors, locations: nil) else { return }
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.minX, y: rect.minY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    // MARK: - Bar

    private func drawBar(_ module: BarModule, normalized: Double?, tint: NSColor, in rect: CGRect) {
        var x = rect.minX
        x += drawLeadingLabel(module, in: rect, x: x)

        guard let normalized else {
            drawText(MetricFormatter.unavailable, in: rect, x: x, color: palette.textTertiary)
            return
        }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let height: CGFloat = 6
        let track = CGRect(x: x, y: rect.midY - height / 2, width: gaugeWidth(normalized: normalized), height: height)
        let radius = height / 2

        ctx.saveGState()
        ctx.setFillColor(palette.separator.cgColor)
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()

        let fraction = CGFloat(min(max(normalized, 0), 1))
        let fillWidth = track.width * fraction
        if fraction > 0.001 {
            // A minimum nub keeps tiny-but-nonzero values visible, but it has
            // to stay near-hairline: clamping to the pill's own height made 1%
            // and 12% draw identically.
            let fill = CGRect(x: track.minX, y: track.minY, width: max(fillWidth, 1.5), height: height)
            applyGlow(ctx, color: tint)
            ctx.setFillColor(tint.cgColor)
            ctx.addPath(CGPath(roundedRect: fill, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    // MARK: - Arc

    private func drawArc(_ module: BarModule, normalized: Double?, tint: NSColor, in rect: CGRect) {
        var x = rect.minX
        x += drawLeadingLabel(module, in: rect, x: x)

        guard let normalized else {
            drawText(MetricFormatter.unavailable, in: rect, x: x, color: palette.textTertiary)
            return
        }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let lineWidth = max(theme.chartLineWidth + 0.75, 1.5)
        let diameter = arcDiameter(in: rect)
        let center = CGPoint(x: x + diameter / 2, y: rect.midY)
        let radius = max((diameter - lineWidth) / 2, 0.5)

        ctx.saveGState()
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)

        ctx.setStrokeColor(palette.separator.cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        let fraction = min(max(normalized, 0), 1)
        if fraction > 0.001 {
            applyGlow(ctx, color: tint)
            ctx.setStrokeColor(tint.cgColor)
            // Starts at 12 o'clock and sweeps clockwise, matching how every
            // other circular gauge on the platform reads.
            let start = CGFloat.pi / 2
            ctx.addArc(
                center: center,
                radius: radius,
                startAngle: start,
                endAngle: start - .pi * 2 * CGFloat(fraction),
                clockwise: true
            )
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: - Color rules

    func color(for module: BarModule, value: Double?) -> NSColor {
        switch module.colorRule {
        case .fixed(let hex):
            guard let rgba = ThemeColor.rgbaComponents(hex: hex) else { return palette.accent }
            return NSColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
        case .thresholdGradient(let low, let high):
            guard let value else { return palette.textTertiary }
            return rampColor(value: value, low: low, high: high)
        case .matchSystemAccent:
            // Flattened to a concrete sRGB color *here*, at draw time, rather
            // than handing the dynamic color to the glyph cache: a baked-in
            // dynamic color would keep painting the old accent after the user
            // changes theirs, whereas a flattened one changes the cache key
            // and re-renders.
            return NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor.controlAccentColor
        case .themeMetricColor:
            return palette.metricColors[module.metric.rawValue] ?? palette.accent
        }
    }

    /// Where `value` sits between `low` and `high`, clamped to 0...1.
    ///
    /// `low > high` inverts the ramp for free, because the span is negative —
    /// which is exactly what metrics like free disk space want (low is the bad
    /// end).
    private func rampPosition(value: Double, low: Double, high: Double) -> Double? {
        let span = high - low
        guard value.isFinite, span.isFinite, abs(span) > 0.000_001 else { return nil }
        return min(max((value - low) / span, 0), 1)
    }

    /// Green → amber → red.
    private func rampColor(value: Double, low: Double, high: Double) -> NSColor {
        guard let position = rampPosition(value: value, low: low, high: high) else {
            // A degenerate (or non-finite) range still has to answer with
            // *something* legible; the two ends are the only honest options.
            return value >= high ? palette.danger : palette.success
        }
        return position < 0.5
            ? lerp(palette.success, palette.warning, CGFloat(position * 2))
            : lerp(palette.warning, palette.danger, CGFloat((position - 0.5) * 2))
    }

    /// Manual sRGB interpolation rather than `blended(withFraction:of:)`,
    /// which returns nil when the two colors can't be converted into a common
    /// space — a nil we'd have to invent a fallback for anyway.
    private func lerp(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        guard let from = a.usingColorSpace(.sRGB), let to = b.usingColorSpace(.sRGB) else { return a }
        return NSColor(
            srgbRed: from.redComponent + (to.redComponent - from.redComponent) * t,
            green: from.greenComponent + (to.greenComponent - from.greenComponent) * t,
            blue: from.blueComponent + (to.blueComponent - from.blueComponent) * t,
            alpha: from.alphaComponent + (to.alphaComponent - from.alphaComponent) * t
        )
    }

    // MARK: - Text

    /// The full string a text module shows: optional "CPU " label, the
    /// formatted value, and an em dash when the metric is absent.
    ///
    /// `showUnit` is passed *into* the formatter rather than string-stripped
    /// afterwards, because several units are transformed on the way out
    /// (mV→V, MHz→GHz, °C→"58°") and stripping the declared suffix silently
    /// did nothing for those while mangling "1h 20m" into "1h 20".
    func valueText(_ module: BarModule, _ value: Double?, includeLabel: Bool = true) -> String {
        let prefix = (includeLabel && module.showLabel) ? module.metric.shortLabel + " " : ""
        guard let value else { return prefix + MetricFormatter.unavailable }
        return prefix + MetricFormatter.compact(value, unit: module.metric.unit, includeUnit: module.showUnit)
    }

    // MARK: - Chrome the view draws around modules

    /// Width of an arbitrary string in the bar font — the view needs it to
    /// budget for the truncation ellipsis before it decides what fits.
    func measure(_ text: String) -> CGFloat { textSize(text).width }

    func drawTertiaryText(_ text: String, in rect: CGRect, x: CGFloat) {
        drawText(text, in: rect, x: x, color: palette.textTertiary)
    }

    var fallbackGlyphWidth: CGFloat { iconSize }

    /// Drawn when every module is hidden. An empty bar item is an invisible,
    /// unclickable bar item, so something always occupies the slot.
    func drawFallbackGlyph(in rect: CGRect) {
        if fallbackImage == nil {
            let configuration = NSImage.SymbolConfiguration(
                pointSize: theme.barFontSize,
                weight: Self.symbolWeight(theme.barFontWeight)
            )
            guard let base = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "MacStat")?
                .withSymbolConfiguration(configuration) else { return }
            fallbackImage = Self.tinted(base, color: palette.textSecondary)
        }
        fallbackImage?.draw(in: iconRect(at: rect.minX, in: rect), from: .zero, operation: .sourceOver, fraction: 1)
    }

    private func drawText(_ text: String, in rect: CGRect, x: CGFloat, color: NSColor) {
        let size = textSize(text)
        var attributes = baseAttributes
        attributes[.foregroundColor] = color
        NSAttributedString(string: text, attributes: attributes)
            .draw(at: CGPoint(x: x, y: rect.midY - size.height / 2))
    }

    /// Cached because the same handful of strings ("72%", "CPU 14%") recur for
    /// hours, and measuring is the single most-called thing in a layout pass.
    private func textSize(_ text: String) -> CGSize {
        if let cached = textSizeCache[text] { return cached }
        let size = NSAttributedString(string: text, attributes: baseAttributes).size()
        // Unbounded growth is theoretically possible (byte counts churn), so
        // the cache is dropped wholesale rather than LRU-evicted — simpler,
        // and a rebuild costs a few dozen measurements.
        if textSizeCache.count > 256 { textSizeCache.removeAll(keepingCapacity: true) }
        textSizeCache[text] = size
        return size
    }

    private func labelWidth(_ module: BarModule) -> CGFloat {
        guard module.showLabel else { return 0 }
        return textSize(module.metric.shortLabel + " ").width
    }

    @discardableResult
    private func drawLeadingLabel(_ module: BarModule, in rect: CGRect, x: CGFloat) -> CGFloat {
        guard module.showLabel else { return 0 }
        let text = module.metric.shortLabel + " "
        drawText(text, in: rect, x: x, color: palette.textSecondary)
        return textSize(text).width
    }

    // MARK: - Symbols

    private func drawSymbol(for metric: MetricID, color: NSColor, in rect: CGRect) {
        guard let image = tintedSymbol(for: metric, color: color) else { return }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    /// Tinting an `NSImage` means re-rendering it, so tinted glyphs are cached
    /// by (symbol, quantized color) and evicted oldest-first. FIFO rather than
    /// a flush-everything cap: dumping the whole cache every N misses threw
    /// away the stable entries of *other* modules to make room for one
    /// gradient module's churn.
    private func tintedSymbol(for metric: MetricID, color: NSColor) -> NSImage? {
        let name = Self.symbolName(for: metric)
        let key = SymbolKey(name: name, color: color)
        if let cached = symbolCache[key] { return cached }

        let configuration = NSImage.SymbolConfiguration(
            pointSize: theme.barFontSize,
            weight: Self.symbolWeight(theme.barFontWeight)
        )
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: metric.shortLabel)?
            .withSymbolConfiguration(configuration) else { return nil }

        let tinted = Self.tinted(base, color: color)
        if symbolCache.count >= Self.symbolCacheLimit, let oldest = symbolCacheOrder.first {
            symbolCacheOrder.removeFirst()
            symbolCache.removeValue(forKey: oldest)
        }
        symbolCache[key] = tinted
        symbolCacheOrder.append(key)
        return tinted
    }

    private static func tinted(_ base: NSImage, color: NSColor) -> NSImage {
        NSImage(size: base.size, flipped: false) { bounds in
            base.draw(in: bounds)
            color.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
    }

    /// One glyph per module rather than per metric — every battery metric
    /// reads as "battery" in a 16pt slot, and picking per-metric symbols would
    /// mean maintaining a 60-case table that mostly repeats itself.
    private static func symbolName(for metric: MetricID) -> String {
        metric.module.symbolName
    }

    // MARK: - Geometry

    private var iconSize: CGFloat { (theme.barFontSize + 3).rounded() }
    private var iconTextGap: CGFloat { 3 }
    private var verticalInset: CGFloat { 4 }

    private func iconRect(at x: CGFloat, in rect: CGRect) -> CGRect {
        CGRect(x: x, y: rect.midY - iconSize / 2, width: iconSize, height: iconSize)
    }

    private func graphWidth(history: [Double]) -> CGFloat {
        history.count >= 2 ? max(theme.barGraphWidth, 8) : textSize(MetricFormatter.unavailable).width
    }

    private func gaugeWidth(normalized: Double?) -> CGFloat {
        normalized == nil
            ? textSize(MetricFormatter.unavailable).width
            : max(theme.barGraphWidth * 0.55, 18).rounded()
    }

    private func arcWidth(normalized: Double?) -> CGFloat {
        normalized == nil ? textSize(MetricFormatter.unavailable).width : nominalArcDiameter
    }

    private var nominalArcDiameter: CGFloat { min(max(theme.barFontSize + 2, 12), 18).rounded() }

    /// The reserved width always uses the nominal diameter; a short bar only
    /// ever shrinks the glyph, so the gauge can never grow past the slot the
    /// layout pass measured for it.
    private func arcDiameter(in rect: CGRect) -> CGFloat {
        rect.height > 0 ? min(nominalArcDiameter, rect.height - verticalInset) : nominalArcDiameter
    }

    private func applyGlow(_ ctx: CGContext, color: NSColor) {
        let intensity = min(max(theme.glowIntensity, 0), 1)
        guard intensity > 0.01 else { return }
        ctx.setShadow(
            offset: .zero,
            blur: 3 * CGFloat(intensity),
            color: color.withAlphaComponent(0.85 * CGFloat(intensity)).cgColor
        )
    }

    // MARK: - Font

    private static func makeFont(theme: Theme) -> NSFont {
        let size = min(max(theme.barFontSize, 8), 18)
        let weight = nsWeight(theme.barFontWeight)

        var font: NSFont
        switch theme.fontFamily {
        case .system:
            font = .systemFont(ofSize: size, weight: weight)
        case .systemMono:
            font = .monospacedSystemFont(ofSize: size, weight: weight)
        case .rounded:
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
        case .custom(let name):
            // An imported theme can name a font the user doesn't have; falling
            // back to the system font is the right degradation, not a failure.
            font = NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
        }

        if theme.numericStyle == .monospacedDigit {
            // The feature setting (rather than swapping in a mono font) keeps
            // the theme's chosen family while stopping the digits from
            // jittering the bar's width every sample.
            let settings: [[NSFontDescriptor.FeatureKey: Int]] = [[
                .typeIdentifier: kNumberSpacingType,
                .selectorIdentifier: kMonospacedNumbersSelector,
            ]]
            let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: settings])
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        return font
    }

    private static func nsWeight(_ token: FontWeightToken) -> NSFont.Weight {
        switch token {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }

    private static func symbolWeight(_ token: FontWeightToken) -> NSFont.Weight {
        nsWeight(token)
    }
}
