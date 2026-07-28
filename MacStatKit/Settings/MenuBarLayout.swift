import Foundation

/// The user's composed menu bar: which metrics appear, in what order, drawn
/// how (plan §8.2). This is the flagship customization surface — the whole
/// bar is data, so the settings composer edits a value type and the renderer
/// just draws whatever it's handed.
public struct MenuBarLayout: Codable, Equatable, Sendable {
    public var modules: [BarModule]
    public var spacing: Double
    public var separatorStyle: SeparatorStyle
    /// Truncate rather than push other status items off a crowded (notch) bar.
    public var maxWidth: Double?
    public var collapseWhenInactive: Bool

    public init(
        modules: [BarModule] = [],
        spacing: Double = 6,
        separatorStyle: SeparatorStyle = .space,
        maxWidth: Double? = 320,
        collapseWhenInactive: Bool = false
    ) {
        self.modules = modules
        self.spacing = spacing
        self.separatorStyle = separatorStyle
        self.maxWidth = maxWidth
        self.collapseWhenInactive = collapseWhenInactive
    }
}

public struct BarModule: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var metric: MetricID
    public var displayMode: DisplayMode
    public var showLabel: Bool
    public var showUnit: Bool
    public var colorRule: ColorRule
    public var visibilityRule: VisibilityRule

    public init(
        id: UUID = UUID(),
        metric: MetricID,
        displayMode: DisplayMode = .valueOnly,
        showLabel: Bool = false,
        showUnit: Bool = true,
        colorRule: ColorRule = .matchSystemAccent,
        visibilityRule: VisibilityRule = .always
    ) {
        self.id = id
        self.metric = metric
        self.displayMode = displayMode
        self.showLabel = showLabel
        self.showUnit = showUnit
        self.colorRule = colorRule
        self.visibilityRule = visibilityRule
    }
}

public enum DisplayMode: String, Codable, CaseIterable, Sendable {
    case iconOnly
    case valueOnly
    case iconAndValue
    case sparkline
    case bar
    case arc
    case sparklineAndValue

    public var displayName: String {
        switch self {
        case .iconOnly: return "Icon only"
        case .valueOnly: return "Value only"
        case .iconAndValue: return "Icon + value"
        case .sparkline: return "Sparkline"
        case .bar: return "Bar"
        case .arc: return "Arc"
        case .sparklineAndValue: return "Sparkline + value"
        }
    }

    /// Modes that plot history need a sample buffer; the others only ever
    /// read the newest value.
    public var needsHistory: Bool {
        self == .sparkline || self == .sparklineAndValue
    }
}

public enum ColorRule: Codable, Equatable, Sendable {
    case fixed(hex: String)
    /// Green→amber→red ramp between `low` and `high`. `low > high` inverts it,
    /// which is what metrics like free disk space want (low is bad).
    case thresholdGradient(low: Double, high: Double)
    case matchSystemAccent
    /// Use the per-metric color from the active theme's `metricColors`.
    case themeMetricColor
}

public enum VisibilityRule: Codable, Equatable, Sendable {
    case always
    case whenAboveThreshold(Double)
    case whenOnBattery
    case whenCharging
    case whenAssertionActive
}

public enum SeparatorStyle: String, Codable, CaseIterable, Sendable {
    case none, dot, line, space

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .dot: return "Dot"
        case .line: return "Line"
        case .space: return "Space"
        }
    }
}

// MARK: - Presets (plan §8.2)

public extension MenuBarLayout {
    static let minimal = MenuBarLayout(
        modules: [
            BarModule(metric: .batteryChargePercent, displayMode: .iconAndValue)
        ],
        separatorStyle: .space
    )

    static let batteryFocus = MenuBarLayout(
        modules: [
            BarModule(metric: .batteryChargePercent, displayMode: .iconAndValue),
            BarModule(metric: .batteryChargingWatts, displayMode: .valueOnly,
                      visibilityRule: .whenCharging),
            BarModule(metric: .batteryHealthPercent, displayMode: .valueOnly, showLabel: true),
            BarModule(metric: .batteryTemperatureC, displayMode: .valueOnly)
        ],
        separatorStyle: .dot
    )

    static let powerUser = MenuBarLayout(
        modules: [
            BarModule(metric: .batteryChargingWatts, displayMode: .iconAndValue),
            BarModule(metric: .cpuTotalPercent, displayMode: .sparklineAndValue,
                      colorRule: .thresholdGradient(low: 20, high: 90)),
            BarModule(metric: .memoryUsedBytes, displayMode: .sparkline,
                      colorRule: .themeMetricColor)
        ],
        separatorStyle: .dot
    )

    static let performance = MenuBarLayout(
        modules: [
            BarModule(metric: .cpuTotalPercent, displayMode: .sparklineAndValue,
                      showLabel: true, colorRule: .thresholdGradient(low: 20, high: 90)),
            BarModule(metric: .gpuUtilizationPercent, displayMode: .sparklineAndValue,
                      showLabel: true, colorRule: .themeMetricColor),
            BarModule(metric: .anePowerWatts, displayMode: .valueOnly, showLabel: true),
            BarModule(metric: .memoryUsedBytes, displayMode: .bar, showLabel: true)
        ],
        separatorStyle: .dot
    )

    static let everything = MenuBarLayout(
        modules: [
            BarModule(metric: .batteryChargePercent, displayMode: .iconAndValue),
            BarModule(metric: .cpuTotalPercent, displayMode: .sparklineAndValue, showLabel: true),
            BarModule(metric: .gpuUtilizationPercent, displayMode: .sparkline, showLabel: true),
            BarModule(metric: .memoryUsedBytes, displayMode: .bar, showLabel: true),
            BarModule(metric: .networkRxBytesPerSec, displayMode: .valueOnly, showLabel: true),
            BarModule(metric: .thermalSocTempC, displayMode: .valueOnly)
        ],
        spacing: 4,
        separatorStyle: .dot,
        maxWidth: 460
    )

    static let presets: [(name: String, layout: MenuBarLayout)] = [
        ("Minimal", .minimal),
        ("Battery Focus", .batteryFocus),
        ("Power User", .powerUser),
        ("Performance", .performance),
        ("Everything", .everything)
    ]
}
