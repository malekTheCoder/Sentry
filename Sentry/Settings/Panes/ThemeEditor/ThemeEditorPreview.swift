import SwiftUI
import SentryKit

/// §9.3's "live preview panel rendering a fake bar item + dropdown as they
/// edit."
///
/// **It renders the theme being edited, never the active one.** Every color,
/// font and radius below resolves through a `ThemePalette` built from the
/// `theme` passed in, and the whole subtree gets that palette pushed into the
/// environment — so the surrounding editor chrome stays on the *app's* theme
/// while this column shows the draft. That split is the entire point of the
/// plan's implementation note ("you want the live preview to render a
/// different theme than the active one simultaneously"), and it is why
/// nothing here reads `\.themePalette` from the environment it inherits.
///
/// **Why an approximation and not the real dropdown**, the same caveat
/// `MenuBarPreviewStrip` carries and for the same reason: `DropdownView` is
/// driven by a live `DropdownViewModel` fed by a `SystemSnapshot`, and there
/// is no snapshot stream in the settings window. So this draws the same
/// *token decisions* — which color paints which surface, how density changes
/// the rhythm, what a metric row and a chart and a state chip look like —
/// against fixed sample values. It is honest about tokens, not about your
/// numbers, and it says so on screen rather than letting "43%" read as a
/// reading.
///
/// **Deliberately not shown:** the dropdown's keep-awake controls, agent
/// activity line, and per-card disclosure. None of them introduce a token
/// this panel doesn't already exercise, so including them would make the
/// preview longer without making it more informative — and every one of them
/// would need invented state to render at all.
struct ThemeEditorPreview: View {

    /// The draft. Not `@Binding` — the preview never writes.
    let theme: Theme
    /// Which half of every light/dark pair to render. Follows the editor's
    /// appearance switch rather than the settings window's own appearance, so
    /// a user editing the dark half sees the dark half.
    let appearance: ThemeAppearance
    /// The real menu-bar layout, so the strip previews the modules the user
    /// actually has rather than an invented set.
    let layout: MenuBarLayout

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var scheme: ColorScheme { appearance == .dark ? .dark : .light }
    private var palette: ThemePalette { ThemePalette(theme: theme, scheme: scheme) }

    /// §9.4: Increase Contrast disables glow and scanlines. Applied to the
    /// *preview* as well as the real UI so the preview keeps telling the
    /// truth about what this user will actually see — a glow rendered here
    /// but suppressed everywhere else would be the preview lying, which is
    /// the one thing a preview must not do.
    private var suppressesEffects: Bool { contrast == .increased }

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacingBlock) {
            caption

            MenuBarPreviewStrip(layout: layout, theme: theme)

            dropdownMock
                .frame(maxWidth: 300)

            if suppressesEffects && (theme.glowIntensity > 0 || theme.scanlineOverlay) {
                effectsSuppressedNote
            }
        }
        // The draft palette, pushed down for anything below that reads it.
        // The editor chrome outside this view keeps the active theme's.
        .environment(\.themePalette, palette)
    }

    private var caption: some View {
        // Deliberately *not* themed with the draft palette: this line is the
        // editor talking about the preview, not part of the preview. Drawing
        // it in the draft's text color would make it the first casualty of an
        // unreadable draft, right when the user most needs to read it.
        VStack(alignment: .leading, spacing: 2) {
            Text("Live preview")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Renders the theme you're editing, in \(appearance.displayName.lowercased()) appearance. Sample values, not live readings.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var effectsSuppressedNote: some View {
        Label(
            "Increase Contrast is on in System Settings, so glow and scanlines are suppressed here and in the app.",
            systemImage: "circle.lefthalf.filled"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Dropdown mock

    private var dropdownMock: some View {
        VStack(alignment: .leading, spacing: palette.spacingRow) {
            header
            divider
            ForEach(previewRows, id: \.metric) { row in
                metricRow(row)
            }
            divider
            chart
            stateChips
        }
        .padding(palette.spacingBlock)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backdrop)
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                .strokeBorder(palette.separator, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dropdown preview")
    }

    /// Material themes get a real `NSVisualEffectView` behind the background
    /// wash, exactly as `themedBackdrop` does for the app's own surfaces — a
    /// flat fill here would make every glass theme look identical to its
    /// opaque sibling in the one place a user is deciding between them.
    @ViewBuilder
    private var backdrop: some View {
        if theme.useMaterialBackground {
            ZStack {
                VisualEffect(material: theme.materialStyle.nsMaterial)
                palette.background
            }
        } else {
            palette.background
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: palette.spacingTight) {
            Text("Battery")
                .font(palette.font(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text("72%")
                .font(palette.numericFont(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .themeGlow(palette, enabled: !suppressesEffects)
            Spacer(minLength: 0)
            Text("3h 12m left")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textSecondary)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(palette.separator)
            .frame(height: 1)
    }

    /// The six modules `ThemePalette.moduleColor` maps, which is also the set
    /// the per-metric grid edits — so a color changed in that grid moves
    /// something visible here.
    private var previewRows: [(metric: MetricID, label: String, value: String)] {
        [
            (.cpuTotalPercent, String(localized: "CPU"), "14%"),
            (.gpuUtilizationPercent, String(localized: "GPU"), "37%"),
            (.memoryUsedBytes, String(localized: "Memory"), "12 GB"),
            (.thermalSocTempC, String(localized: "Thermal"), "49°"),
        ]
    }

    private func metricRow(_ row: (metric: MetricID, label: String, value: String)) -> some View {
        HStack(spacing: palette.spacingTight) {
            Circle()
                .fill(palette.metricColor(row.metric))
                .frame(width: 6, height: 6)
            Text(row.label)
                .font(palette.font(size: 12))
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: palette.spacingTight)
            Text(row.value)
                .font(palette.numericFont(size: 12, weight: .medium))
                .foregroundStyle(palette.textPrimary)
        }
    }

    /// Exercises `chartStyle`, `chartLineWidth`, `chartFill`, `chartGrid` and
    /// `showChartGrid` — every chart token the editor exposes, so none of
    /// those controls is one the user has to change and then go hunting for.
    private var chart: some View {
        let samples: [Double] = [0.28, 0.41, 0.33, 0.52, 0.46, 0.68, 0.58, 0.79, 0.63, 0.71, 0.55, 0.66]
        return ZStack {
            if theme.showChartGrid {
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { _ in
                        Rectangle().fill(palette.chartGrid).frame(height: 1)
                        Spacer(minLength: 0)
                    }
                }
            }
            ThemeChartPreviewShape(samples: samples, style: theme.chartStyle, closed: true)
                .fill(
                    LinearGradient(
                        colors: palette.chartFill,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            ThemeChartPreviewShape(samples: samples, style: theme.chartStyle, closed: false)
                .stroke(
                    palette.metricColor(.cpuTotalPercent),
                    style: StrokeStyle(lineWidth: theme.chartLineWidth, lineCap: .round, lineJoin: .round)
                )
                .themeGlow(palette, enabled: !suppressesEffects)
        }
        .frame(height: 44)
        .overlay(alignment: .topLeading) {
            if theme.scanlineOverlay && !suppressesEffects {
                scanlines
            }
        }
        .accessibilityHidden(true)
    }

    /// One-pixel horizontal rules at 2pt pitch — the same CRT treatment the
    /// `scanlineOverlay` token names. Drawn only over the chart rather than
    /// the whole card because that is the only place the real UI applies it.
    private var scanlines: some View {
        GeometryReader { geo in
            Path { path in
                var y: CGFloat = 0
                while y < geo.size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    y += 2
                }
            }
            .stroke(palette.background.opacity(0.35), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    /// §9.4: "Never encode meaning in color alone — pair every color state
    /// with an icon or text label." These three chips are the preview's
    /// demonstration of that rule *and* the place a user sees what their
    /// success/warning/danger colors look like on a real chip rather than as
    /// a bare swatch in the editor list.
    private var stateChips: some View {
        HStack(spacing: palette.spacingTight) {
            chip(String(localized: "Charging"), symbol: "bolt.fill", color: palette.success)
            chip(String(localized: "Warm"), symbol: "thermometer.medium", color: palette.warning)
            chip(String(localized: "Low"), symbol: "exclamationmark.triangle.fill", color: palette.danger)
            Spacer(minLength: 0)
        }
    }

    private func chip(_ title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
            Text(title)
                .font(palette.font(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(palette.surfaceElevated)
        )
    }
}

// MARK: - Chart shape

/// The four `ChartStyle` cases as one `Shape`, so the preview's chart control
/// actually changes the chart.
///
/// Separate from the Dashboard's real chart rendering (Swift Charts) rather
/// than reusing it: Swift Charts needs a data series with real dates and axes
/// this panel has neither of, and a 44pt-tall preview strip is not the surface
/// to negotiate that on. What matters here is that the four styles are
/// visually distinguishable and that line width and fill land where the tokens
/// say — which a `Path` does exactly.
struct ThemeChartPreviewShape: Shape {

    let samples: [Double]
    let style: ChartStyle
    /// `true` closes the path down to the baseline for the gradient fill.
    /// The stroke pass uses `false`, so the fill's bottom edge is never
    /// stroked as if it were data.
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard samples.count > 1, rect.width > 0, rect.height > 0 else { return path }

        // `.bars` is genuinely a different shape rather than a variation on
        // the polyline, so it short-circuits.
        if style == .bars {
            let slot = rect.width / CGFloat(samples.count)
            let barWidth = max(slot * 0.62, 1)
            for (index, sample) in samples.enumerated() {
                let height = rect.height * CGFloat(min(max(sample, 0), 1))
                let x = rect.minX + CGFloat(index) * slot + (slot - barWidth) / 2
                path.addRect(CGRect(x: x, y: rect.maxY - height, width: barWidth, height: height))
            }
            return path
        }

        let stepX = rect.width / CGFloat(samples.count - 1)
        func point(_ index: Int) -> CGPoint {
            CGPoint(
                x: rect.minX + CGFloat(index) * stepX,
                y: rect.maxY - rect.height * CGFloat(min(max(samples[index], 0), 1))
            )
        }

        path.move(to: point(0))
        for index in 1..<samples.count {
            let next = point(index)
            if style == .stepped {
                path.addLine(to: CGPoint(x: next.x, y: path.currentPoint?.y ?? next.y))
            }
            path.addLine(to: next)
        }

        // `.line` draws no fill at all — closing it would give a line chart a
        // filled body, which is what `.area` is for. The gradient pass simply
        // produces an empty path.
        if closed && style != .line {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Glow

extension View {
    /// The `glowIntensity` token, as the soft shadow the "hacker aesthetic"
    /// presets ask for.
    ///
    /// `enabled` exists so §9.4's Increase Contrast suppression is a caller's
    /// decision rather than this modifier reaching for the environment behind
    /// its caller's back — the preview and the real UI disable it under
    /// different conditions, and a modifier that decided for both would be
    /// wrong for one.
    @ViewBuilder
    func themeGlow(_ palette: ThemePalette, enabled: Bool) -> some View {
        if enabled && palette.glow > 0 {
            shadow(color: palette.accent.opacity(palette.glow * 0.8), radius: palette.glow * 5)
        } else {
            self
        }
    }
}
