import SwiftUI

// The main window's shared page furniture. Dashboard and Insights are two
// tabs of one surface, so the organizing devices — uppercase section labels,
// full-bleed hairlines, the quiet tile — live here once instead of drifting
// apart as per-tab copies (which is exactly what had happened: three kerning
// values and four card chromes for the same visual job).

/// The uppercase wayfinding label above a band of content. Tertiary and
/// tracked out — a whisper, never competing with card titles. Carries its
/// own vertical rhythm (a section's breathing room above, a smaller gap to
/// its content below) so call sites don't re-invent the spacing.
struct SectionHeaderLabel: View {
    @Environment(\.themePalette) private var palette

    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(palette.font(size: 11, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(palette.textTertiary)
            .padding(.top, palette.spacingSection)
            .padding(.bottom, palette.spacingBlock)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The smaller in-card cousin: a label above a block *inside* a section
/// ("What to do", a domain name in the category breakdown). Same voice as
/// `SectionHeaderLabel`, one step down; no baked-in padding because these
/// sit in tight stacks whose gaps the parent already owns.
struct MicroHeaderLabel: View {
    @Environment(\.themePalette) private var palette

    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(palette.font(size: 10, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(palette.textTertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Full-bleed hairline between sections — the same organizing device the
/// dropdown uses. The negative padding must mirror the page gutter
/// (`spacingPage`), which is why pages that use this must pad with the token
/// rather than local arithmetic.
struct SectionRule: View {
    @Environment(\.themePalette) private var palette

    var body: some View {
        Rectangle()
            .fill(palette.separator)
            .frame(height: 1)
            .padding(.horizontal, -palette.spacingPage)
            .accessibilityHidden(true)
    }
}

extension View {
    /// The quiet tile: fill only, no border — the one place boxes survived
    /// the main window's de-carding (a chart wants a plot area, a clickable
    /// row wants an affordance). Anything heavier belongs to the dropdown's
    /// `dashboardCard` glass, not to the main window.
    func quietCard(_ palette: ThemePalette) -> some View {
        self
            .padding(palette.spacingBlock)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous))
    }
}
