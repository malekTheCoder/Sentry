import AppKit
import MacStatKit

/// The custom-drawn bar item (plan §8.1). Owns the layout, the theme, the
/// newest snapshot and the per-metric history buffers, and paints the whole
/// strip with Core Graphics.
///
/// Everything here runs on the main thread and redraws every few seconds for
/// the lifetime of the app, so the hot path is deliberately allocation-light
/// (plan §3.2 P6): the renderer and its resolved palette are rebuilt only on
/// theme/appearance changes, and the layout pass is recomputed only when a
/// snapshot actually arrives.
final class StatusItemView: NSView {

    /// One module that survived visibility filtering and truncation, with the
    /// values already read out of the snapshot so `draw(_:)` never touches the
    /// model again.
    private struct RenderItem {
        let module: BarModule
        let value: Double?
        let normalized: Double?
        let width: CGFloat
    }

    /// Plan §8.2 calls the sparkline a "60-sample mini line chart"; that's also
    /// what the dropdown's charts show, so the two agree on window length.
    private static let historyLength = 60

    private(set) var layout: MenuBarLayout
    private(set) var theme: Theme

    private var snapshot: SystemSnapshot?
    private var history: [MetricID: [Double]] = [:]
    private var historyMetrics: Set<MetricID> = []
    private var renderer: BarModuleRenderer
    private var items: [RenderItem] = []
    private var isTruncated = false
    private var cachedWidth: CGFloat = 0

    /// A readable summary for VoiceOver (plan §9.4) — without it the custom
    /// view reads as an unlabeled blank.
    private(set) var accessibilitySummary: String = "Sentry"

    /// Semantic color token of the currently-displayed alert highlight, or
    /// nil when none is active. Set via `highlight(token:for:)`.
    private var highlightToken: String?
    private var highlightExpiryTimer: Timer?

    init(layout: MenuBarLayout, theme: Theme) {
        self.layout = layout
        self.theme = theme
        self.renderer = BarModuleRenderer(theme: theme, dark: true)
        super.init(frame: CGRect(x: 0, y: 0, width: 24, height: NSStatusBar.system.thickness))
        setAccessibilityRole(.image)
        setAccessibilityLabel(accessibilitySummary)
        rebuildRenderer()
        pruneHistory()
        rebuildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StatusItemView is created in code only")
    }

    // MARK: - Input

    func update(_ snapshot: SystemSnapshot) {
        self.snapshot = snapshot
        appendHistory(from: snapshot)
        rebuildLayout()
    }

    func apply(layout: MenuBarLayout) {
        guard layout != self.layout else { return }
        self.layout = layout
        pruneHistory()
        rebuildLayout()
    }

    /// Shows the alert highlight for `duration`, then clears it.
    ///
    /// Time-limited rather than sticky because nothing would ever clear it
    /// otherwise: `AlertEngine` fires an action, it has no matching
    /// "condition ended" event, and a highlight that never goes away stops
    /// carrying information within a day. The timer is replaced (not
    /// stacked) so a rule firing repeatedly extends the window instead of
    /// queueing several expiries that each fight over the same state.
    func highlight(token: String, for duration: TimeInterval = 30) {
        highlightExpiryTimer?.invalidate()
        highlightToken = token
        needsDisplay = true
        highlightExpiryTimer = Timer.scheduledTimer(
            withTimeInterval: duration,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.highlightToken = nil
                self?.highlightExpiryTimer = nil
                self?.needsDisplay = true
            }
        }
    }

    func apply(theme: Theme) {
        guard theme != self.theme else { return }
        self.theme = theme
        rebuildRenderer()
        rebuildLayout()
    }

    // MARK: - History

    private func appendHistory(from snapshot: SystemSnapshot) {
        // Iterating the metric set rather than the modules keeps two modules
        // charting the same metric from double-appending each sample.
        for metric in historyMetrics {
            // A nil sample is genuinely "no reading", not a zero — appending
            // one would draw a cliff in the sparkline that never happened
            // (P5).
            guard let value = snapshot.value(for: metric) else { continue }
            // Subscript-with-default mutates the stored array in place; a
            // `history[m] = buffer` round-trip would copy the whole buffer on
            // every sample.
            history[metric, default: []].append(value)
            if let count = history[metric]?.count, count > Self.historyLength {
                history[metric]?.removeFirst(count - Self.historyLength)
            }
        }
    }

    /// Drops buffers for metrics the current layout no longer charts, so a
    /// user cycling through presets doesn't accumulate dead arrays.
    private func pruneHistory() {
        historyMetrics = Set(layout.modules.filter { $0.displayMode.needsHistory }.map(\.metric))
        history = history.filter { historyMetrics.contains($0.key) }
    }

    // MARK: - Layout

    private func rebuildRenderer() {
        renderer = BarModuleRenderer(theme: theme, dark: effectiveAppearance.macStatIsDark)
    }

    private func rebuildLayout() {
        let gap = separatorGap
        let ellipsisWidth = renderer.measure(Self.ellipsis)
        // The user's maxWidth is the width of the whole item, so the padding
        // the item always adds comes out of the budget before modules do.
        let budget = layout.maxWidth.map { max(CGFloat($0) - horizontalPadding * 2, 0) }

        var built: [RenderItem] = []
        built.reserveCapacity(layout.modules.count)
        var used: CGFloat = 0
        var truncated = false

        for module in layout.modules {
            let value = snapshot?.value(for: module.metric)
            guard isVisible(module, value: value) else { continue }

            let normalized = snapshot?.normalizedValue(for: module.metric)
            let width = renderer.width(
                for: module,
                value: value,
                normalized: normalized,
                history: history[module.metric] ?? []
            )
            let advance = built.isEmpty ? width : gap + width

            if let budget {
                // R8: on a crowded (notch) bar, drop *trailing* modules rather
                // than overflowing or letting the item collapse to nothing —
                // the first module is always kept even if it alone busts the
                // budget, because a vanished bar item reads as a crashed app.
                let projected = used + advance + (built.isEmpty ? 0 : ellipsisWidth + gap)
                if !built.isEmpty, projected > budget {
                    truncated = true
                    break
                }
            }

            used += advance
            built.append(RenderItem(module: module, value: value, normalized: normalized, width: width))
        }

        items = built
        isTruncated = truncated

        var total = used
        if truncated { total += gap + ellipsisWidth }
        if built.isEmpty { total = renderer.fallbackGlyphWidth }
        total += horizontalPadding * 2

        if abs(total - cachedWidth) > 0.5 {
            cachedWidth = total
            invalidateIntrinsicContentSize()
        }
        rebuildAccessibilitySummary()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(cachedWidth, renderer.fallbackGlyphWidth), height: NSStatusBar.system.thickness)
    }

    private var horizontalPadding: CGFloat { 4 }

    /// Gap between modules. `.dot`/`.line` need room for the glyph itself on
    /// top of the user's spacing; `.space` is simply a wider gap.
    private var separatorGap: CGFloat {
        let spacing = CGFloat(max(layout.spacing, 0))
        switch layout.separatorStyle {
        case .none: return spacing
        case .space: return spacing * 2
        case .dot: return spacing + 4
        case .line: return spacing + 5
        }
    }

    // MARK: - Visibility

    private func isVisible(_ module: BarModule, value: Double?) -> Bool {
        switch module.visibilityRule {
        case .always:
            break
        case .whenAboveThreshold(let threshold):
            guard let value, value > threshold else { return false }
        case .whenOnBattery:
            guard let battery = snapshot?.battery, !battery.isPluggedIn else { return false }
        case .whenCharging:
            guard let battery = snapshot?.battery, battery.isCharging else { return false }
        case .whenAssertionActive:
            // No snapshot / no assertion state means "not asserting" — an
            // unknown is not an active hold.
            guard let assertion = snapshot?.sleepAssertion, case .active = assertion else { return false }
        }
        if layout.collapseWhenInactive, isIdle(module, value: value) { return false }
        return true
    }

    /// "Idle" is only meaningful for activity metrics — a battery sitting at
    /// 0% is a crisis, not an idle module, and memory is never idle. An
    /// *unavailable* metric is also not idle: P5 wants a visible em dash, and
    /// collapsing is about noise, not about hiding bad news.
    private func isIdle(_ module: BarModule, value: Double?) -> Bool {
        guard let value else { return false }
        switch module.metric.module {
        case .cpu, .gpu, .ane, .disk, .network:
            break
        case .battery, .memory, .thermal, .system:
            return false
        }
        switch module.metric.unit {
        case .percent: return value < 1
        case .watts: return value < 0.05
        case .bytesPerSecond: return value < 1024      // sub-1 KB/s is line noise
        case .operationsPerSecond: return value < 1
        case .megabitsPerSecond: return value < 1
        case .boolean: return value <= 0
        default: return false
        }
    }

    // MARK: - Drawing

    private static let ellipsis = "…"

    override func draw(_ dirtyRect: NSRect) {
        let slot = bounds
        guard slot.width > 0 else { return }

        drawHighlightIfNeeded(in: slot)

        guard !items.isEmpty else {
            renderer.drawFallbackGlyph(in: slot.insetBy(dx: horizontalPadding, dy: 0))
            return
        }

        let gap = separatorGap
        var x = slot.minX + horizontalPadding

        for (index, item) in items.enumerated() {
            if index > 0 {
                drawSeparator(centeredAt: x + gap / 2, in: slot)
                x += gap
            }
            renderer.draw(
                item.module,
                value: item.value,
                normalized: item.normalized,
                history: history[item.module.metric] ?? [],
                in: CGRect(x: x, y: slot.minY, width: item.width, height: slot.height)
            )
            x += item.width
        }

        if isTruncated {
            // Signals "there's more you're not seeing" instead of silently
            // pretending the dropped modules were never configured.
            renderer.drawTertiaryText(Self.ellipsis, in: slot, x: x + gap)
        }
    }

    // MARK: - Alert highlight (plan §11.1 `AlertAction.menuBarHighlight`)

    /// Draws the alert highlight behind the modules, if one is active.
    ///
    /// Deliberately a rounded, translucent wash rather than an opaque fill:
    /// the point is to draw the eye to a bar item the user isn't looking at,
    /// not to make its numbers unreadable — and the menu bar sits on the
    /// user's wallpaper, so an opaque block would read as a rendering glitch.
    private func drawHighlightIfNeeded(in slot: CGRect) {
        guard let token = highlightToken,
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        let color = renderer.palette.alertHighlightColor(for: token)
        let inset = slot.insetBy(dx: 1, dy: 2)
        let path = CGPath(
            roundedRect: inset,
            cornerWidth: 4,
            cornerHeight: 4,
            transform: nil
        )
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(color.withAlphaComponent(0.28).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private func drawSeparator(centeredAt x: CGFloat, in rect: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        switch layout.separatorStyle {
        case .none, .space:
            return
        case .dot:
            let size: CGFloat = 2
            ctx.setFillColor(renderer.palette.separator.cgColor)
            ctx.fillEllipse(in: CGRect(x: x - size / 2, y: rect.midY - size / 2, width: size, height: size))
        case .line:
            let inset: CGFloat = 4
            ctx.setFillColor(renderer.palette.separator.cgColor)
            ctx.fill(CGRect(x: x - 0.5, y: rect.minY + inset, width: 1, height: max(rect.height - inset * 2, 1)))
        }
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The bar item's appearance is not the app's — the menu bar flips
        // independently (wallpaper, dark-mode switch), so the palette is
        // re-resolved here rather than once at init.
        rebuildRenderer()
        rebuildLayout()
    }

    // MARK: - Accessibility

    private func rebuildAccessibilitySummary() {
        guard !items.isEmpty else {
            accessibilitySummary = "Sentry"
            setAccessibilityLabel(accessibilitySummary)
            return
        }
        let parts = items.map { item -> String in
            let label = item.module.metric.shortLabel
            guard let value = item.value else { return "\(label) unavailable" }
            var spoken = "\(label) \(Self.spoken(value, unit: item.module.metric.unit))"
            // §9.4: the threshold ramp's state must reach a VoiceOver user
            // too, who gets none of the red the sighted cue relies on.
            if let severity = renderer.severity(for: item.module, value: value)?.spokenSuffix {
                spoken += ", \(severity)"
            }
            return spoken
        }
        accessibilitySummary = "Sentry: " + parts.joined(separator: ", ")
        setAccessibilityLabel(accessibilitySummary)
    }

    /// VoiceOver reads "72%" as "seventy-two percent" reliably, but "45.8W"
    /// and "58°" it does not — the symbols get spelled or skipped, so the
    /// compact string is expanded into words here.
    private static func spoken(_ value: Double, unit: MetricUnit) -> String {
        let text = MetricFormatter.compact(value, unit: unit)
        switch unit {
        case .percent: return text.replacingOccurrences(of: "%", with: " percent")
        case .watts: return text.replacingOccurrences(of: "W", with: " watts")
        case .celsius: return text.replacingOccurrences(of: "°", with: " degrees")
        default: return text
        }
    }

    // MARK: - Hit testing

    /// The view lives inside the `NSStatusBarButton`, which owns click
    /// handling and the highlight state; swallowing mouse events here would
    /// make the item unclickable.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
