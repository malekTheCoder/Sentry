import SwiftUI
import SentryKit

/// Per-category subscores, grouped by domain.
///
/// **Categories with no data render as "—", never as 100.** A Mac whose
/// thermal sensors aren't readable has nothing for the thermal rules to
/// judge, and showing a full bar there would be a fabricated pass — the same
/// class of mistake as the "0.0 W" reading this codebase removed on
/// principle. `ProtectionScore.CategoryScore.hasData` carries that
/// distinction and this view honours it.
/// Flat on the page — the section header above it ("By Category") is the
/// title, so this view is just the two domain columns side by side (the
/// hardware/security split *is* the natural column split) with one quiet
/// caption underneath explaining the arithmetic.
struct CategoryBreakdownCard: View {
    @Environment(\.themePalette) private var palette

    let score: ProtectionScore

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacingRow) {
            HStack(alignment: .top, spacing: palette.spacingPage) {
                ForEach(InsightDomain.allCases, id: \.self) { domain in
                    domainSection(domain)
                }
            }
            Text("Each category starts at 100 and loses the weight of its own findings.")
                .font(palette.font(size: 10))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func domainSection(_ domain: InsightDomain) -> some View {
        let rows = score.categories.filter { $0.category.domain == domain }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: palette.spacingTight) {
                MicroHeaderLabel(title: domain.displayName)
                ForEach(rows) { row in
                    categoryRow(row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func categoryRow(_ row: ProtectionScore.CategoryScore) -> some View {
        HStack(spacing: palette.spacingTight) {
            Image(systemName: row.category.symbolName)
                .font(.system(size: 10))
                .foregroundStyle(palette.textTertiary)
                .frame(width: 16)
            Text(row.category.displayName)
                .font(palette.font(size: 12))
                .foregroundStyle(palette.textPrimary)
                .frame(width: 130, alignment: .leading)

            meter(for: row)

            Text(valueText(for: row))
                .font(palette.font(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(row.hasData ? palette.textPrimary : palette.textTertiary)
                .frame(width: 34, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.category.displayName)
        .accessibilityValue(accessibilityValue(for: row))
    }

    @ViewBuilder
    private func meter(for row: ProtectionScore.CategoryScore) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(palette.separator)
                if let value = row.score {
                    Capsule()
                        .fill(tint(for: value))
                        .frame(width: max(2, width * min(max(Double(value) / 100, 0), 1)))
                }
            }
        }
        .frame(height: 5)
        .frame(maxWidth: .infinity)
    }

    /// Point boundaries come from `ProtectionScore`, not from literals here:
    /// two views with their own copies of 85/60 is precisely how the score
    /// and the words beside it drifted apart before.
    private func tint(for value: Int) -> Color {
        palette.tint(for: ProtectionScore.pointsBand(for: value))
    }

    private func valueText(for row: ProtectionScore.CategoryScore) -> String {
        guard let value = row.score else { return MetricFormatter.unavailable }
        return "\(value)"
    }

    private func accessibilityValue(for row: ProtectionScore.CategoryScore) -> String {
        guard let value = row.score else {
            return String(localized: "not scored — no data for this category on this Mac")
        }
        // Numerics are formatted to `String` before interpolation, matching
        // the house rule documented on `InsightPhrasing.duration`.
        let valueText = "\(value)"
        guard row.findingCount > 0 else {
            return String(localized: "\(valueText) out of 100, no findings")
        }
        let findingsText = "\(row.findingCount)"
        return String(localized: "\(valueText) out of 100, \(findingsText) findings")
    }
}
