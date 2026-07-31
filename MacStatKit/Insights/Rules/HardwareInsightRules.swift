import Foundation

// MARK: - Battery longevity

/// High-state-of-charge residency — the best-documented driver of
/// lithium-ion calendar ageing, and the one habit a laptop user can change
/// without changing what they do all day.
public struct HighChargeResidencyRule: ProtectionInsightRule {
    public let id = "battery.high-soc-residency"
    public let category: InsightCategory = .batteryLongevity
    public init() {}

    /// Half the time above 90% is enough to be worth mentioning; three
    /// quarters is enough to be the dominant wear factor on this machine.
    public static let advisoryFraction = 0.5
    public static let warningFraction = 0.75

    /// Below this many charge readings the fraction is too coarse to quote
    /// as a percentage — 3 samples out of 4 is not "75% of the time".
    public static let minimumSamples = 100

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.hasEnoughHistory,
              let battery = context.battery,
              battery.chargeSampleCount >= Self.minimumSamples,
              let fraction = battery.fractionAtOrAbove90,
              fraction >= Self.advisoryFraction
        else { return nil }

        let severity: InsightSeverity = fraction >= Self.warningFraction ? .warning : .advice
        let fractionText = InsightPhrasing.percent(fraction: fraction)
        let dayText = InsightPhrasing.days(battery.daysWithData)

        var evidence = [
            String(localized: "Charge sat at or above 90% in \(fractionText) of the readings Sentry took over \(dayText).")
        ]
        if let above95 = battery.fractionAtOrAbove95 {
            let above95Text = InsightPhrasing.percent(fraction: above95)
            evidence.append(String(localized: "It was at 95% or higher \(above95Text) of the time."))
        }
        if let delta = battery.healthDelta,
           let earliest = battery.earliestHealthPercent,
           let latest = battery.latestHealthPercent,
           delta < 0 {
            let earliestText = InsightPhrasing.percentValue(earliest)
            let latestText = InsightPhrasing.percentValue(latest)
            let lostText = InsightPhrasing.percentValue(abs(delta))
            evidence.append(String(localized: "Measured capacity moved from \(earliestText) to \(latestText) of design over the same window — \(lostText) lost."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "This battery lives near full"),
            summary: String(localized: "\(fractionText) of the last \(dayText) were spent at 90% charge or above."),
            detail: String(localized: "Lithium-ion cells age fastest when they are held at a high state of charge, and they do it whether or not the Mac is being used — it is calendar ageing, not cycle wear. On the readings Sentry has from this machine, a high charge is the state it spends most of its life in, which makes it the single biggest lever available on how much capacity this battery still has in two years."),
            recommendation: String(localized: "Turn on Optimized Battery Charging, or the 80% charge limit if this Mac supports it, in System Settings ▸ Battery. If it lives on a desk permanently, the 80% limit is the bigger win of the two."),
            category: category,
            severity: severity,
            evidence: evidence,
            action: InsightAction(
                label: String(localized: "Open Battery settings"),
                target: .systemSettings(urlString: SystemSettingsLink.battery),
                fallbackDescription: String(localized: "System Settings ▸ Battery ▸ Battery Health")
            ),
            confidence: context.confidenceForCoverage,
            scoreImpact: severity == .warning ? InsightWeight.moderateHardware : InsightWeight.minorHardware
        )
    }
}

/// A battery that never moves at all. Distinct from
/// `HighChargeResidencyRule`: that one is about *where* the charge sits,
/// this one is about it not moving, which is its own (milder) problem and
/// has a different fix.
public struct BatteryNeverExercisedRule: ProtectionInsightRule {
    public let id = "battery.never-exercised"
    public let category: InsightCategory = .batteryLongevity
    public init() {}

    public static let minimumStaticDays = 7
    public static let maximumMeanDepthPercent = 5.0

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        // Only meaningful on a machine that has a battery it *could* be
        // running off. A Mac mini's "battery" never moving is not a finding.
        guard context.device.isPortable != false,
              context.hasEnoughHistory,
              let battery = context.battery,
              battery.daysEssentiallyStatic >= Self.minimumStaticDays,
              let meanDepth = battery.meanDailyDepthPercent,
              meanDepth < Self.maximumMeanDepthPercent
        else { return nil }

        let staticDayText = InsightPhrasing.days(battery.daysEssentiallyStatic)
        let totalDayText = InsightPhrasing.days(battery.daysWithData)
        let depthText = InsightPhrasing.percentValue(meanDepth)

        return ProtectionInsight(
            id: id,
            title: String(localized: "The battery is never being used"),
            summary: String(localized: "On \(staticDayText) out of \(totalDayText), the charge barely moved."),
            detail: String(localized: "Sentry's readings show this Mac running from the adapter essentially all the time — the daily swing between the day's highest and lowest charge averages \(depthText). A cell that is never cycled still ages, and letting it sit at one level indefinitely also makes the charge estimate drift, because the gas gauge recalibrates from full-to-low transitions it isn't getting."),
            recommendation: String(localized: "Run this Mac off the battery down to roughly 30–40% once a month, then charge it back up in one go. That is enough to keep the charge estimate honest without adding meaningful cycle wear."),
            category: category,
            severity: .advice,
            evidence: [
                String(localized: "Daily charge swing averaged \(depthText) across \(totalDayText)."),
                String(localized: "\(staticDayText) had a total swing under 3 percentage points.")
            ],
            action: nil,
            confidence: context.confidenceForCoverage,
            scoreImpact: InsightWeight.minorHardware
        )
    }
}

/// Repeated deep discharges. The mirror image of high-charge residency and
/// the other end of the same curve.
public struct DeepDischargeRule: ProtectionInsightRule {
    public let id = "battery.deep-discharge-frequency"
    public let category: InsightCategory = .batteryLongevity
    public init() {}

    public static let advisoryDays = 3
    public static let warningDays = 6

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.hasEnoughHistory,
              let battery = context.battery,
              battery.daysWithDeepDischarge >= Self.advisoryDays
        else { return nil }

        let severity: InsightSeverity = battery.daysWithDeepDischarge >= Self.warningDays ? .warning : .advice
        let deepDayText = InsightPhrasing.days(battery.daysWithDeepDischarge)
        let totalDayText = InsightPhrasing.days(battery.daysWithData)

        var evidence = [
            String(localized: "Charge fell below 10% on \(deepDayText) of the \(totalDayText) Sentry has readings for.")
        ]
        if let below20 = battery.fractionBelow20 {
            let below20Text = InsightPhrasing.percent(fraction: below20)
            evidence.append(String(localized: "\(below20Text) of all readings were under 20%."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "Running the battery down to empty, repeatedly"),
            summary: String(localized: "The charge dropped under 10% on \(deepDayText)."),
            detail: String(localized: "Deep discharges put the cell at its lowest voltage, which is the most stressful state it experiences short of being hot. One occasionally is fine and even useful for calibration; a habit of it measurably shortens usable life, and it is happening often enough on this Mac to be a habit rather than an accident."),
            recommendation: String(localized: "Plug in around 20–30% rather than running to the low-battery warning. If the pattern is caused by long stretches away from an outlet, a small USB-C battery pack is a cheaper fix than a battery replacement."),
            category: category,
            severity: severity,
            evidence: evidence,
            action: nil,
            confidence: context.confidenceForCoverage,
            scoreImpact: severity == .warning ? InsightWeight.moderateHardware : InsightWeight.minorHardware
        )
    }
}

/// Measured capacity loss over the observed window, normalised to a
/// per-30-day rate so a 6-day window and a 60-day window are comparable.
public struct CapacityLossRateRule: ProtectionInsightRule {
    public let id = "battery.capacity-loss-rate"
    public let category: InsightCategory = .batteryLongevity
    public init() {}

    /// Points of design capacity lost per 30 days.
    public static let advisoryRate = 0.75
    public static let warningRate = 1.5

    /// A capacity reading is noisy sample-to-sample; a shorter window than
    /// this turns that noise into an alarming "rate".
    public static let minimumDays = 10

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard let battery = context.battery,
              battery.daysWithData >= Self.minimumDays,
              let delta = battery.healthDelta,
              let earliest = battery.earliestHealthPercent,
              let latest = battery.latestHealthPercent,
              delta < 0
        else { return nil }

        let ratePer30Days = abs(delta) / Double(battery.daysWithData) * 30
        guard ratePer30Days >= Self.advisoryRate else { return nil }

        let severity: InsightSeverity = ratePer30Days >= Self.warningRate ? .warning : .advice
        let rateText = InsightPhrasing.percentValue(ratePer30Days)
        let earliestText = InsightPhrasing.percentValue(earliest)
        let latestText = InsightPhrasing.percentValue(latest)
        let dayText = InsightPhrasing.days(battery.daysWithData)

        var evidence = [
            String(localized: "Measured capacity went from \(earliestText) to \(latestText) of design across \(dayText) — about \(rateText) per month at that rate.")
        ]
        if let cycleDelta = battery.cycleDelta, cycleDelta > 0 {
            let cycleText = "\(cycleDelta)"
            evidence.append(String(localized: "\(cycleText) charge cycles were logged in the same window."))
        }
        if let residency = battery.fractionAtOrAbove90 {
            let residencyText = InsightPhrasing.percent(fraction: residency)
            evidence.append(String(localized: "\(residencyText) of that time was spent at 90% charge or above."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "Capacity is falling faster than it should"),
            summary: String(localized: "About \(rateText) of design capacity lost per month at the current rate."),
            detail: String(localized: "This is measured, not modelled: Sentry recorded this Mac's own reported full-charge capacity at the start and end of the window and compared them. A healthy battery under normal use loses well under half a percent a month. A rate this high usually means one of three things — sustained high charge, sustained heat, or a cell that is genuinely near the end of its service life."),
            recommendation: String(localized: "Check the thermal and charge-residency findings in this list first; both feed this number. If neither applies and the rate holds, this battery is a service candidate rather than a habit problem."),
            category: category,
            severity: severity,
            evidence: evidence,
            action: nil,
            confidence: context.confidenceForCoverage,
            scoreImpact: severity == .warning ? InsightWeight.majorHardware : InsightWeight.moderateHardware
        )
    }
}

/// Cycle accumulation rate, projected against Apple's own 1,000-cycle
/// rating for current Mac batteries.
public struct CycleBurnRateRule: ProtectionInsightRule {
    public let id = "battery.cycle-burn-rate"
    public let category: InsightCategory = .batteryLongevity
    public init() {}

    /// Apple rates current Mac notebook batteries to retain 80% of original
    /// capacity at this many cycles. Used as a reference point, not as a
    /// cliff — a battery does not stop working at 1,000.
    public static let ratedCycles = 1000
    public static let advisoryCyclesPerYear = 300.0

    public static let minimumDays = 7
    public static let minimumCycleDelta = 3

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard let battery = context.battery,
              battery.daysWithData >= Self.minimumDays,
              let cycleDelta = battery.cycleDelta,
              cycleDelta >= Self.minimumCycleDelta,
              let latestCycles = battery.latestCycleCount
        else { return nil }

        let cyclesPerYear = Double(cycleDelta) / Double(battery.daysWithData) * 365
        guard cyclesPerYear >= Self.advisoryCyclesPerYear else { return nil }

        let remaining = Double(Self.ratedCycles - latestCycles)
        guard remaining > 0 else { return nil }
        let yearsToRating = remaining / cyclesPerYear
        guard yearsToRating.isFinite, yearsToRating > 0 else { return nil }

        let perYearText = "\(Int(cyclesPerYear.rounded()))"
        let cycleDeltaText = "\(cycleDelta)"
        let dayText = InsightPhrasing.days(battery.daysWithData)
        let currentText = "\(latestCycles)"
        let yearsText = String(format: "%.1f", yearsToRating)
        let ratedText = "\(Self.ratedCycles)"

        return ProtectionInsight(
            id: id,
            title: String(localized: "Charge cycles are accumulating quickly"),
            summary: String(localized: "About \(perYearText) cycles a year at the current rate — currently at \(currentText)."),
            detail: String(localized: "Sentry watched this Mac's own cycle counter climb by \(cycleDeltaText) over \(dayText). Extrapolated, that is roughly \(perYearText) cycles a year, which would reach Apple's \(ratedText)-cycle rating in about \(yearsText) years. That rating is where the battery is expected to hold 80% of its original capacity — not a failure point, but a useful horizon for planning a replacement."),
            recommendation: String(localized: "Nothing here is wrong, but if this Mac needs to last several more years, reducing full charge-discharge cycles — mains power for stationary work, the 80% limit when it is desk-bound — is what moves this number."),
            category: category,
            severity: .advice,
            evidence: [
                String(localized: "Cycle count rose by \(cycleDeltaText) over \(dayText)."),
                String(localized: "Current cycle count: \(currentText) of the \(ratedText)-cycle rating.")
            ],
            action: nil,
            confidence: context.confidenceForCoverage,
            scoreImpact: InsightWeight.none
        )
    }
}

/// Charging while the SoC is already thermally saturated — the one habit
/// that stacks both major wear mechanisms at once.
public struct ChargingWhileHotRule: ProtectionInsightRule {
    public let id = "battery.charging-while-hot"
    public let category: InsightCategory = .batteryLongevity
    public init() {}

    public static let advisoryFraction = 0.2
    public static let warningFraction = 0.4
    /// Below this many comparable pairs the fraction is noise.
    public static let minimumComparableSamples = 30

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.hasEnoughHistory,
              let battery = context.battery,
              let hot = battery.chargingWhileHotSamples,
              let comparable = battery.chargingComparableSamples,
              comparable >= Self.minimumComparableSamples
        else { return nil }

        let fraction = Double(hot) / Double(comparable)
        guard fraction >= Self.advisoryFraction else { return nil }

        let severity: InsightSeverity = fraction >= Self.warningFraction ? .warning : .advice
        let fractionText = InsightPhrasing.percent(fraction: fraction)
        let hotText = "\(hot)"
        let comparableText = "\(comparable)"
        let thresholdText = InsightPhrasing.celsius(BatteryHistorySummary.hotChargingSoCThreshold)

        var evidence = [
            String(localized: "\(hotText) of \(comparableText) charging readings (\(fractionText)) were taken while the SoC was at or above \(thresholdText).")
        ]
        if let peak = context.thermal?.peakSoCTemperatureCelsius {
            let peakText = InsightPhrasing.celsius(peak)
            evidence.append(String(localized: "Peak SoC temperature over the same window: \(peakText)."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "Charging while the chip is already hot"),
            summary: String(localized: "\(fractionText) of charging happened above \(thresholdText)."),
            detail: String(localized: "Heat and charge current are the two things that damage a lithium-ion cell, and this Mac is regularly experiencing both at once. Charging pushes current through a cell that is already sitting in a warm chassis, which ages it considerably faster than either condition alone. The usual cause is plugging in during heavy work — a build, an export, a game — rather than before or after it."),
            recommendation: String(localized: "Where the work allows it, let the machine come down to idle temperature before plugging in, and keep it off soft surfaces that block the vents while it charges under load."),
            category: category,
            severity: severity,
            evidence: evidence,
            action: nil,
            confidence: context.confidenceForCoverage,
            scoreImpact: severity == .warning ? InsightWeight.moderateHardware : InsightWeight.minorHardware
        )
    }
}

/// Sustained elevated *battery pack* temperature, as opposed to SoC
/// temperature — a separate sensor and a separate finding.
public struct BatteryTemperatureExposureRule: ProtectionInsightRule {
    public let id = "battery.temperature-exposure"
    public let category: InsightCategory = .batteryLongevity
    public init() {}

    public static let advisoryFraction = 0.25
    public static let warningFraction = 0.5
    /// Above this, lithium-ion calendar ageing accelerates noticeably.
    public static let thresholdCelsius = 35.0

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.hasEnoughHistory,
              let battery = context.battery,
              let fraction = battery.fractionTemperatureAtOrAbove35,
              fraction >= Self.advisoryFraction,
              let mean = battery.meanTemperatureCelsius
        else { return nil }

        let severity: InsightSeverity = fraction >= Self.warningFraction ? .warning : .advice
        let fractionText = InsightPhrasing.percent(fraction: fraction)
        let meanText = InsightPhrasing.celsius(mean)
        let thresholdText = InsightPhrasing.celsius(Self.thresholdCelsius)
        let dayText = InsightPhrasing.days(battery.daysWithData)

        var evidence = [
            String(localized: "The battery pack was at or above \(thresholdText) in \(fractionText) of readings over \(dayText)."),
            String(localized: "Its average temperature across that window was \(meanText).")
        ]
        if let peak = battery.peakTemperatureCelsius {
            let peakText = InsightPhrasing.celsius(peak)
            evidence.append(String(localized: "Peak pack temperature: \(peakText)."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "The battery is running warm"),
            summary: String(localized: "Pack temperature averaged \(meanText), above \(thresholdText) for \(fractionText) of the window."),
            detail: String(localized: "This is the battery's own temperature sensor, not the chip's. Sustained warmth is the fastest way to lose capacity that has nothing to do with how much the battery is used — a cell held warm loses capacity while doing nothing at all. On a laptop the usual causes are working on a bed or sofa, a closed-lid setup with poor airflow, or a case that traps heat."),
            recommendation: String(localized: "Give the underside of the chassis clear airflow, especially while charging or under sustained load. If this Mac is used closed-lid on a dock, a stand that lifts it off the desk is the single most effective change."),
            category: category,
            severity: severity,
            evidence: evidence,
            action: nil,
            confidence: context.confidenceForCoverage,
            scoreImpact: severity == .warning ? InsightWeight.moderateHardware : InsightWeight.minorHardware
        )
    }
}

/// The positive counterpart to the battery rules above.
public struct BatteryInGoodShapeRule: ProtectionInsightRule {
    public let id = "battery.in-good-shape"
    public let category: InsightCategory = .batteryLongevity
    public init() {}

    public static let healthyThreshold = 90.0

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.hasEnoughHistory,
              let battery = context.battery,
              let health = battery.latestHealthPercent,
              health >= Self.healthyThreshold,
              // Only claim "good" if capacity is also not visibly sliding.
              (battery.healthDelta ?? 0) > -0.75
        else { return nil }

        let healthText = InsightPhrasing.percentValue(health)
        var evidence = [
            String(localized: "Measured full-charge capacity is \(healthText) of this battery's design capacity.")
        ]
        if let cycles = battery.latestCycleCount {
            let cycleText = "\(cycles)"
            evidence.append(String(localized: "It has completed \(cycleText) charge cycles."))
        }
        if let residency = battery.fractionAtOrAbove90 {
            let residencyText = InsightPhrasing.percent(fraction: residency)
            evidence.append(String(localized: "Time spent at 90% charge or above: \(residencyText)."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "Battery health is holding up"),
            summary: String(localized: "Capacity is \(healthText) of design and not measurably declining."),
            detail: String(localized: "Over the history Sentry has for this Mac, reported capacity has held steady rather than trending down. Nothing needs changing here — this is the finding that tells you the other battery advice in this list, if any, is not urgent."),
            recommendation: String(localized: "Keep doing what you're doing."),
            category: category,
            severity: .good,
            evidence: evidence,
            action: nil,
            confidence: context.confidenceForCoverage,
            scoreImpact: InsightWeight.none
        )
    }
}

// MARK: - Thermal

/// Sustained thermal saturation across many days.
public struct SustainedHeatRule: ProtectionInsightRule {
    public let id = "thermal.sustained-heat"
    public let category: InsightCategory = .thermal
    public init() {}

    public static let advisoryDays = 3
    public static let warningDays = 8

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.hasEnoughHistory,
              let thermal = context.thermal,
              thermal.daysWithSustainedHeat >= Self.advisoryDays
        else { return nil }

        let severity: InsightSeverity = thermal.daysWithSustainedHeat >= Self.warningDays ? .warning : .advice
        let heatDayText = InsightPhrasing.days(thermal.daysWithSustainedHeat)
        let totalDayText = InsightPhrasing.days(thermal.daysWithData)
        let thresholdText = InsightPhrasing.celsius(ThermalHistorySummary.sustainedHeatThreshold)

        var evidence = [
            String(localized: "The SoC held at or above \(thresholdText) for 30 minutes or more on \(heatDayText) of \(totalDayText).")
        ]
        if let peak = thermal.peakSoCTemperatureCelsius {
            let peakText = InsightPhrasing.celsius(peak)
            evidence.append(String(localized: "Peak reading over the window: \(peakText)."))
        }
        if thermal.hoursAtOrAbove95 >= 0.5 {
            let hoursText = InsightPhrasing.duration(hours: thermal.hoursAtOrAbove95)
            evidence.append(String(localized: "Roughly \(hoursText) were spent at or above 95°C."))
        }
        if let meanCPU = context.load?.meanCPUPercent {
            let cpuText = InsightPhrasing.percentValue(meanCPU, decimals: 0)
            evidence.append(String(localized: "Average CPU load over the same window was \(cpuText)."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "This Mac spends a lot of time hot"),
            summary: String(localized: "Sustained heat on \(heatDayText) out of \(totalDayText)."),
            detail: String(localized: "Sustained high die temperature is what ages a Mac's non-replaceable parts — the battery next to the board, the thermal interface material, and over years the solder joints themselves. Brief peaks under load are entirely normal and designed for; what this finding is about is the *duration*, measured across days on this specific machine."),
            recommendation: String(localized: "Check airflow first: clear vents, a hard surface, and no case or sleeve while under load. If the Mac is already well ventilated, the cause is the workload — look at which processes are driving it in the Dashboard's Top Processes card."),
            category: category,
            severity: severity,
            evidence: evidence,
            action: nil,
            confidence: context.confidenceForCoverage,
            scoreImpact: severity == .warning ? InsightWeight.majorHardware : InsightWeight.moderateHardware
        )
    }
}

/// How much of this Mac's life is spent actively throttled.
public struct ThermalThrottlingRule: ProtectionInsightRule {
    public let id = "thermal.throttling-frequency"
    public let category: InsightCategory = .thermal
    public init() {}

    public static let advisoryFraction = 0.05
    public static let warningFraction = 0.15

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.hasEnoughHistory,
              let thermal = context.thermal,
              let fraction = thermal.throttlingFraction,
              fraction >= Self.advisoryFraction
        else { return nil }

        let severity: InsightSeverity = fraction >= Self.warningFraction ? .warning : .advice
        let fractionText = InsightPhrasing.percent(fraction: fraction)
        let hoursText = InsightPhrasing.duration(hours: thermal.hoursThrottling)
        let dayText = InsightPhrasing.days(thermal.daysWithData)

        return ProtectionInsight(
            id: id,
            title: String(localized: "Thermal throttling is a regular occurrence"),
            summary: String(localized: "Throttling was active in \(fractionText) of readings — about \(hoursText) in total."),
            detail: String(localized: "Throttling means macOS is deliberately reducing performance because the chip cannot shed heat fast enough. It is a protection mechanism working correctly, so nothing is being damaged in the moment — but a machine that reaches it this often is running at the edge of its cooling envelope for a large part of its life, and that is what accumulates into long-term wear. It is also work being paid for and not received."),
            recommendation: String(localized: "Improve airflow before changing the workload — throttling on a Mac that is otherwise healthy is very often a blocked-vent or soft-surface problem. If the machine is several years old and well ventilated, dust in the fan path is the next thing to check."),
            category: category,
            severity: severity,
            evidence: [
                String(localized: "Throttling flagged in \(fractionText) of thermal readings across \(dayText)."),
                String(localized: "Cumulative throttled time: \(hoursText).")
            ],
            action: nil,
            confidence: context.confidenceForCoverage,
            scoreImpact: severity == .warning ? InsightWeight.majorHardware : InsightWeight.moderateHardware
        )
    }
}

/// A thermal baseline that is drifting upward against this Mac's own past —
/// the dust / degraded-paste / failing-fan signature.
public struct RisingThermalBaselineRule: ProtectionInsightRule {
    public let id = "thermal.rising-baseline"
    public let category: InsightCategory = .maintenance
    public init() {}

    public static let advisoryDeltaCelsius = 4.0
    public static let warningDeltaCelsius = 8.0
    /// Comparing halves needs a window long enough for each half to mean
    /// something.
    public static let minimumDays = 12

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard let thermal = context.thermal,
              thermal.daysWithData >= Self.minimumDays,
              let older = thermal.meanFirstHalfCelsius,
              let newer = thermal.meanSecondHalfCelsius
        else { return nil }

        let delta = newer - older
        guard delta >= Self.advisoryDeltaCelsius else { return nil }

        let severity: InsightSeverity = delta >= Self.warningDeltaCelsius ? .warning : .advice
        let olderText = InsightPhrasing.celsius(older)
        let newerText = InsightPhrasing.celsius(newer)
        let deltaText = String(format: "%.1f", delta)
        let dayText = InsightPhrasing.days(thermal.daysWithData)

        var evidence = [
            String(localized: "Mean SoC temperature rose from \(olderText) in the first half of the last \(dayText) to \(newerText) in the second half — up \(deltaText)°C.")
        ]
        if let meanCPU = context.load?.meanCPUPercent {
            let cpuText = InsightPhrasing.percentValue(meanCPU, decimals: 0)
            evidence.append(String(localized: "Average CPU load over the whole window: \(cpuText) — compare this against whether your workload actually changed."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "Running hotter than it was two weeks ago"),
            summary: String(localized: "Average temperature is up \(deltaText)°C against this Mac's own recent baseline."),
            detail: String(localized: "This compares this Mac against itself, not against any other machine — the only baseline that means anything. A cooling system quietly losing effectiveness (dust in the fan path, thermal paste past its useful life, a fan that has started spinning down) shows up exactly like this: the same work, a few degrees warmer, week over week.\n\nThe honest caveat: a genuinely heavier workload produces the identical pattern. Sentry cannot tell the two apart from temperature alone, which is why the average CPU load for the same window is listed alongside it."),
            recommendation: String(localized: "If your workload hasn't changed, this is a cooling problem worth looking at — vents and fan intake first, professional cleaning if the Mac is more than about three years old."),
            category: category,
            severity: severity,
            evidence: evidence,
            action: nil,
            confidence: context.confidenceForCoverage,
            scoreImpact: severity == .warning ? InsightWeight.moderateHardware : InsightWeight.minorHardware
        )
    }
}

/// The positive thermal finding.
public struct ThermalsWellBehavedRule: ProtectionInsightRule {
    public let id = "thermal.well-behaved"
    public let category: InsightCategory = .thermal
    public init() {}

    public static let comfortableCeilingCelsius = 90.0

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.hasEnoughHistory,
              let thermal = context.thermal,
              thermal.sampleCount >= 100,
              let peak = thermal.peakSoCTemperatureCelsius,
              peak < Self.comfortableCeilingCelsius,
              (thermal.throttlingFraction ?? 0) < 0.01,
              thermal.daysWithSustainedHeat == 0
        else { return nil }

        let peakText = InsightPhrasing.celsius(peak)
        let dayText = InsightPhrasing.days(thermal.daysWithData)
        var evidence = [
            String(localized: "Highest SoC temperature across \(dayText): \(peakText)."),
            String(localized: "No sustained periods above 90°C, and effectively no thermal throttling.")
        ]
        if let mean = thermal.meanSoCTemperatureCelsius {
            let meanText = InsightPhrasing.celsius(mean)
            evidence.append(String(localized: "Average temperature: \(meanText)."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "Thermals are comfortable"),
            summary: String(localized: "Peak \(peakText) over \(dayText), with no sustained saturation."),
            detail: String(localized: "This Mac's cooling is comfortably ahead of what is being asked of it. That matters beyond performance: the battery, the board, and the thermal interface material all last longer on a machine that runs cool, so this is a finding worth protecting rather than a box to tick."),
            recommendation: String(localized: "No action needed. If you change how the Mac is used — a docked closed-lid setup, or a heavier sustained workload — this is the number to watch."),
            category: category,
            severity: .good,
            evidence: evidence,
            action: nil,
            confidence: context.confidenceForCoverage,
            scoreImpact: InsightWeight.none
        )
    }
}

/// Sustained pinned CPU across many days — the load that produces the heat.
public struct SustainedCPULoadRule: ProtectionInsightRule {
    public let id = "load.sustained-cpu"
    public let category: InsightCategory = .thermal
    public init() {}

    public static let advisoryDays = 3
    public static let warningDays = 7

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.hasEnoughHistory,
              let load = context.load,
              load.daysWithSustainedCPU >= Self.advisoryDays
        else { return nil }

        let severity: InsightSeverity = load.daysWithSustainedCPU >= Self.warningDays ? .warning : .advice
        let loadDayText = InsightPhrasing.days(load.daysWithSustainedCPU)
        let totalDayText = InsightPhrasing.days(load.daysWithData)
        let runText = InsightPhrasing.duration(hours: load.longestCPURunHours)

        var evidence = [
            String(localized: "CPU stayed at or above 90% for three hours or more on \(loadDayText) of \(totalDayText)."),
            String(localized: "The longest single unbroken stretch was \(runText).")
        ]
        if let mean = load.meanCPUPercent {
            let meanText = InsightPhrasing.percentValue(mean, decimals: 0)
            evidence.append(String(localized: "Average CPU across the whole window: \(meanText)."))
        }
        if let thermalMean = context.thermal?.meanSoCTemperatureCelsius {
            let thermalText = InsightPhrasing.celsius(thermalMean)
            evidence.append(String(localized: "Average SoC temperature over the same window: \(thermalText)."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "Long stretches of pinned CPU"),
            summary: String(localized: "Three-hour-plus runs at 90%+ CPU on \(loadDayText)."),
            detail: String(localized: "Multi-hour full-load runs are what turn normal use into accelerated wear: they hold the chip at its thermal ceiling, keep the fans at their highest duty cycle, and — on battery — deliver deep discharges on top. This is not automatically a problem; if this Mac exists to render, compile, or train, this is it doing its job. It is a problem if the load is something you didn't ask for."),
            recommendation: String(localized: "Check the Dashboard's Top Processes card during one of these stretches to confirm the load is work you intended. If it is, running it plugged in and on a hard, ventilated surface is what limits the cost."),
            category: category,
            severity: severity,
            evidence: evidence,
            action: nil,
            confidence: context.confidenceForCoverage,
            scoreImpact: severity == .warning ? InsightWeight.moderateHardware : InsightWeight.minorHardware
        )
    }
}

/// The GPU counterpart of `SustainedCPULoadRule`.
public struct SustainedGPULoadRule: ProtectionInsightRule {
    public let id = "load.sustained-gpu"
    public let category: InsightCategory = .thermal
    public init() {}

    public static let advisoryDays = 3

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.hasEnoughHistory,
              let load = context.load,
              load.daysWithSustainedGPU >= Self.advisoryDays,
              let meanGPU = load.meanGPUPercent
        else { return nil }

        let gpuDayText = InsightPhrasing.days(load.daysWithSustainedGPU)
        let totalDayText = InsightPhrasing.days(load.daysWithData)
        let meanText = InsightPhrasing.percentValue(meanGPU, decimals: 0)

        var evidence = [
            String(localized: "GPU stayed at or above 80% for three hours or more on \(gpuDayText) of \(totalDayText)."),
            String(localized: "Average GPU utilisation across the window: \(meanText).")
        ]
        if let peak = context.thermal?.peakSoCTemperatureCelsius {
            let peakText = InsightPhrasing.celsius(peak)
            evidence.append(String(localized: "Peak SoC temperature over the same window: \(peakText)."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "Long stretches of sustained GPU load"),
            summary: String(localized: "Three-hour-plus runs at 80%+ GPU on \(gpuDayText)."),
            detail: String(localized: "On Apple silicon the GPU shares a die and a cooling budget with the CPU, so sustained graphics load heats the same package the battery sits next to. Long GPU-bound sessions — gaming, video export, ML inference — are the workloads most likely to hold a Mac at its thermal ceiling for hours at a time."),
            recommendation: String(localized: "Where the work allows it, run these sessions plugged in and elevated. Capping a game's frame rate to the display's refresh rate is usually free performance you were not seeing anyway, and it drops sustained GPU load noticeably."),
            category: category,
            severity: .advice,
            evidence: evidence,
            action: nil,
            confidence: context.confidenceForCoverage,
            scoreImpact: InsightWeight.minorHardware
        )
    }
}

// MARK: - Memory

/// Chronic high memory utilisation.
public struct HighMemoryUtilizationRule: ProtectionInsightRule {
    public let id = "memory.high-utilization"
    public let category: InsightCategory = .memory
    public init() {}

    public static let advisoryFraction = 0.3
    public static let warningFraction = 0.6

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.hasEnoughHistory,
              let memory = context.memory,
              let fraction = memory.fractionUsedAtOrAbove85,
              fraction >= Self.advisoryFraction,
              let installed = context.device.physicalMemoryBytes
        else { return nil }

        let severity: InsightSeverity = fraction >= Self.warningFraction ? .warning : .advice
        let fractionText = InsightPhrasing.percent(fraction: fraction)
        let installedText = InsightPhrasing.bytes(Double(installed))
        let dayText = InsightPhrasing.days(memory.daysWithData)

        var evidence = [
            String(localized: "Memory in use was at or above 85% of this Mac's \(installedText) in \(fractionText) of readings over \(dayText).")
        ]
        if let peak = memory.peakUsedPercent {
            let peakText = InsightPhrasing.percentValue(peak, decimals: 0)
            evidence.append(String(localized: "Peak utilisation: \(peakText)."))
        }
        if memory.swapGrowthBytes > 0 {
            let swapText = InsightPhrasing.bytes(memory.swapGrowthBytes)
            evidence.append(String(localized: "Swap grew by at least \(swapText) across the same window."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "Memory is chronically close to full"),
            summary: String(localized: "At or above 85% of \(installedText) in \(fractionText) of readings."),
            detail: String(localized: "macOS is designed to use available memory rather than leave it idle, so a high figure is not automatically bad. What makes it matter here is persistence: when the working set stays this close to installed memory, the compressor and then swap take over, and swap is written to an SSD that on this generation of Mac is soldered to the board and cannot be replaced independently."),
            recommendation: String(localized: "Find the resident memory hogs in the Dashboard's Top Processes card — browser tabs, virtual machines, and container runtimes are the usual three. If they are all things you genuinely need at once, this Mac is under-specified for the work rather than misconfigured."),
            category: category,
            severity: severity,
            evidence: evidence,
            action: nil,
            confidence: context.confidenceForCoverage,
            scoreImpact: severity == .warning ? InsightWeight.moderateHardware : InsightWeight.minorHardware
        )
    }
}

/// Swap volume — the finding that translates memory pressure into real,
/// irreversible SSD wear.
public struct SwapThrashRule: ProtectionInsightRule {
    public let id = "memory.swap-thrash"
    public let category: InsightCategory = .memory
    public init() {}

    /// 8 GB of swap growth over the window is where this stops being
    /// incidental; 40 GB is where it is a daily pattern with real write
    /// amplification behind it.
    public static let advisoryBytes = 8.0 * 1_073_741_824
    public static let warningBytes = 40.0 * 1_073_741_824

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.hasEnoughHistory,
              let memory = context.memory,
              memory.swapGrowthBytes >= Self.advisoryBytes,
              memory.daysWithData > 0
        else { return nil }

        let severity: InsightSeverity = memory.swapGrowthBytes >= Self.warningBytes ? .warning : .advice
        let totalText = InsightPhrasing.bytes(memory.swapGrowthBytes)
        let dayText = InsightPhrasing.days(memory.daysWithData)
        let perDayText = InsightPhrasing.bytes(memory.swapGrowthBytes / Double(memory.daysWithData))

        var evidence = [
            String(localized: "Swap usage grew by a cumulative \(totalText) over \(dayText) — roughly \(perDayText) a day."),
            String(localized: "That figure is a lower bound: it sums every observed rise in swap use, so writes that happened entirely between two samples are not counted.")
        ]
        if let peak = memory.peakSwapUsedBytes {
            let peakText = InsightPhrasing.bytes(peak)
            evidence.append(String(localized: "Most swap in use at once: \(peakText)."))
        }
        if let installed = context.device.physicalMemoryBytes {
            let installedText = InsightPhrasing.bytes(Double(installed))
            evidence.append(String(localized: "Installed memory: \(installedText)."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "Swap is being written heavily"),
            summary: String(localized: "At least \(totalText) of swap growth over \(dayText)."),
            detail: String(localized: "Every byte of swap is a byte written to the internal SSD, and on this generation of Mac that SSD is soldered to the logic board — its write endurance is the machine's write endurance. A sustained swap habit is one of the few things a user does that consumes a finite, unrecoverable hardware resource rather than merely wearing something out gradually."),
            recommendation: String(localized: "Reduce what is resident rather than trying to tune swap itself, which macOS does not expose. Closing the largest memory consumer during heavy sessions usually removes most of this; the Dashboard's Top Processes card will name it."),
            category: category,
            severity: severity,
            evidence: evidence,
            action: nil,
            confidence: context.confidenceForCoverage,
            scoreImpact: severity == .warning ? InsightWeight.moderateHardware : InsightWeight.minorHardware
        )
    }
}

/// Heavy memory compression — the stage before swap, and an early warning
/// that costs CPU rather than SSD.
public struct MemoryCompressionRule: ProtectionInsightRule {
    public let id = "memory.compression-pressure"
    public let category: InsightCategory = .memory
    public init() {}

    /// Compressed memory averaging more than this share of installed RAM.
    public static let advisoryShare = 0.15

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.hasEnoughHistory,
              let memory = context.memory,
              let meanCompressed = memory.meanCompressedBytes,
              let installed = context.device.physicalMemoryBytes,
              installed > 0
        else { return nil }

        let share = meanCompressed / Double(installed)
        guard share >= Self.advisoryShare else { return nil }

        let shareText = InsightPhrasing.percent(fraction: share)
        let meanText = InsightPhrasing.bytes(meanCompressed)
        let installedText = InsightPhrasing.bytes(Double(installed))
        let dayText = InsightPhrasing.days(memory.daysWithData)

        var evidence = [
            String(localized: "Compressed memory averaged \(meanText) — \(shareText) of this Mac's \(installedText) — across \(dayText).")
        ]
        if let peak = memory.peakCompressedBytes {
            let peakText = InsightPhrasing.bytes(peak)
            evidence.append(String(localized: "Peak compressed memory: \(peakText)."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "macOS is compressing memory heavily"),
            summary: String(localized: "\(shareText) of installed memory is held compressed on average."),
            detail: String(localized: "Memory compression is the step macOS takes before it starts swapping to disk. It costs CPU time — and therefore heat and battery — rather than SSD writes, so it is the cheaper failure mode of the two. A consistently high compressed figure is the earliest honest signal that this Mac's working set has outgrown its installed memory."),
            recommendation: String(localized: "No urgent action. Treat it as the leading indicator: if it keeps climbing, the swap and utilisation findings in this list will follow, and those are the ones that cost hardware."),
            category: category,
            severity: .advice,
            evidence: evidence,
            action: nil,
            confidence: context.confidenceForCoverage,
            scoreImpact: InsightWeight.minorHardware
        )
    }
}

// MARK: - Storage

/// Sustained lack of headroom on the startup volume.
public struct LowStorageHeadroomRule: ProtectionInsightRule {
    public let id = "storage.low-headroom"
    public let category: InsightCategory = .storage
    public init() {}

    public static let warningStreakDays = 3
    public static let criticalStreakDays = 10

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard let storage = context.storage,
              storage.consecutiveDaysBelowTenPercentFree >= Self.warningStreakDays
        else { return nil }

        let severity: InsightSeverity = storage.consecutiveDaysBelowTenPercentFree >= Self.criticalStreakDays
            ? .critical
            : .warning
        let streakText = InsightPhrasing.days(storage.consecutiveDaysBelowTenPercentFree)

        var evidence = [
            String(localized: "The startup volume's best moment of the day stayed under 10% free for \(streakText) running.")
        ]
        if let latest = storage.latestFreePercent {
            let latestText = InsightPhrasing.percentValue(latest)
            evidence.append(String(localized: "Free right now: \(latestText)."))
        }
        if let minimum = storage.minimumFreePercent {
            let minimumText = InsightPhrasing.percentValue(minimum)
            evidence.append(String(localized: "Lowest reading over the window: \(minimumText)."))
        }
        if let total = context.device.startupVolumeTotalBytes, let latest = storage.latestFreePercent {
            let freeBytesText = InsightPhrasing.bytes(Double(total) * latest / 100)
            let totalText = InsightPhrasing.bytes(Double(total))
            evidence.append(String(localized: "That is about \(freeBytesText) free of \(totalText)."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "The startup disk has no headroom"),
            summary: String(localized: "Under 10% free for \(streakText) straight."),
            detail: String(localized: "APFS needs free space to work in. Snapshots — including the ones Time Machine leaves behind locally — cannot be created, swap cannot expand, and macOS updates cannot stage themselves when the volume is this tight. Long stretches at this level are also where filesystem corruption becomes a realistic risk rather than a theoretical one, because a write that runs out of room mid-transaction is the hardest case for any filesystem to handle."),
            recommendation: String(localized: "Get back above 15% free and keep it there. System Settings ▸ General ▸ Storage lists the largest consumers; local Time Machine snapshots and iOS device backups are frequently the two biggest and least-expected entries."),
            category: category,
            severity: severity,
            evidence: evidence,
            action: InsightAction(
                label: String(localized: "Open Storage settings"),
                target: .systemSettings(urlString: SystemSettingsLink.storage),
                fallbackDescription: String(localized: "System Settings ▸ General ▸ Storage")
            ),
            confidence: context.confidenceForCoverage,
            scoreImpact: severity == .critical ? InsightWeight.majorHardware + InsightWeight.minorHardware : InsightWeight.majorHardware
        )
    }
}

/// Free space trending toward zero.
public struct StorageFillingTrendRule: ProtectionInsightRule {
    public let id = "storage.filling-trend"
    public let category: InsightCategory = .storage
    public init() {}

    public static let advisoryHorizonDays = 90.0
    public static let warningHorizonDays = 30.0

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.hasEnoughHistory,
              let storage = context.storage,
              let days = storage.projectedDaysUntilFull,
              days <= Self.advisoryHorizonDays,
              let slope = storage.freePercentSlopePerDay,
              slope < 0
        else { return nil }

        let severity: InsightSeverity = days <= Self.warningHorizonDays ? .warning : .advice
        let daysText = InsightPhrasing.days(days)
        let slopeText = String(format: "%.2f", abs(slope))
        let observedText = InsightPhrasing.days(storage.daysWithData)

        var evidence = [
            String(localized: "Free space has been falling about \(slopeText) percentage points a day over \(observedText).")
        ]
        if let latest = storage.latestFreePercent {
            let latestText = InsightPhrasing.percentValue(latest)
            evidence.append(String(localized: "Currently \(latestText) free."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "This disk is filling up on a schedule"),
            summary: String(localized: "At the current rate it reaches zero in about \(daysText)."),
            detail: String(localized: "This is a straight-line fit to this Mac's own free-space history, not a guess — and like any straight-line fit, it assumes the last few weeks keep repeating. It will be wrong if the cause was a one-off (a big import, a batch of downloads) and roughly right if it is a steady process like growing photo libraries, container images, or Xcode simulator runtimes."),
            recommendation: String(localized: "Worth finding out what is growing before it becomes urgent. If the answer is caches or build artefacts, clearing them now is much less disruptive than clearing them at 2% free."),
            category: category,
            severity: severity,
            evidence: evidence,
            action: InsightAction(
                label: String(localized: "Open Storage settings"),
                target: .systemSettings(urlString: SystemSettingsLink.storage),
                fallbackDescription: String(localized: "System Settings ▸ General ▸ Storage")
            ),
            confidence: context.confidenceForCoverage,
            scoreImpact: severity == .warning ? InsightWeight.moderateHardware : InsightWeight.minorHardware
        )
    }
}

/// Estimated SSD write volume — finite, unrecoverable, and soldered down.
public struct StorageWriteVolumeRule: ProtectionInsightRule {
    public let id = "storage.write-volume"
    public let category: InsightCategory = .storage
    public init() {}

    /// 500 GB across the window is where the annualised figure starts to be
    /// a meaningful share of a consumer SSD's rated endurance.
    public static let advisoryBytes = 500.0 * 1_073_741_824
    public static let minimumWindowDays = 3.0

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.hasEnoughHistory,
              let storage = context.storage,
              let windowDays = storage.writeWindowDays,
              windowDays >= Self.minimumWindowDays,
              storage.estimatedBytesWritten >= Self.advisoryBytes
        else { return nil }

        let totalText = InsightPhrasing.bytes(storage.estimatedBytesWritten)
        let windowText = InsightPhrasing.days(windowDays)
        let perDay = storage.estimatedBytesWritten / windowDays
        let perDayText = InsightPhrasing.bytes(perDay)
        let annualText = InsightPhrasing.bytes(perDay * 365)

        var evidence = [
            String(localized: "Sentry's sampled throughput adds up to roughly \(totalText) written over \(windowText) — about \(perDayText) a day."),
            String(localized: "Extrapolated, that is on the order of \(annualText) a year."),
            String(localized: "This is an estimate from periodic throughput sampling, not a counter read from the drive — treat it as an order of magnitude, not a precise total.")
        ]
        if let swapGrowth = context.memory?.swapGrowthBytes, swapGrowth > 0 {
            let swapText = InsightPhrasing.bytes(swapGrowth)
            evidence.append(String(localized: "At least \(swapText) of that is swap."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "Heavy write volume to the internal SSD"),
            summary: String(localized: "Roughly \(perDayText) a day is being written."),
            detail: String(localized: "Flash memory wears out by being written to, and the internal SSD on this generation of Mac is soldered to the logic board — when it is exhausted, the machine is, in practical terms, exhausted with it. Consumer drives are rated for enough writes that most people never approach the limit; this rate is high enough to be worth knowing about rather than high enough to panic over."),
            recommendation: String(localized: "If a large share of this is swap, fixing the memory findings in this list fixes this too. If it is builds, caches, or video scratch files, moving those to an external drive removes the wear entirely."),
            category: category,
            severity: .advice,
            evidence: evidence,
            action: nil,
            confidence: context.confidenceForCoverage,
            scoreImpact: InsightWeight.minorHardware
        )
    }
}

/// The positive storage finding.
public struct StorageHeadroomHealthyRule: ProtectionInsightRule {
    public let id = "storage.healthy-headroom"
    public let category: InsightCategory = .storage
    public init() {}

    public static let comfortableFreePercent = 25.0

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.hasEnoughHistory,
              let storage = context.storage,
              storage.sampleCount >= 50,
              let minimum = storage.minimumFreePercent,
              minimum >= Self.comfortableFreePercent,
              let latest = storage.latestFreePercent
        else { return nil }

        let latestText = InsightPhrasing.percentValue(latest)
        let minimumText = InsightPhrasing.percentValue(minimum)
        let dayText = InsightPhrasing.days(storage.daysWithData)

        return ProtectionInsight(
            id: id,
            title: String(localized: "Plenty of disk headroom"),
            summary: String(localized: "\(latestText) free now, and never below \(minimumText) across \(dayText)."),
            detail: String(localized: "APFS, swap, snapshots, and macOS updates all need room to work in, and this Mac has consistently had it. This is the state the low-headroom finding exists to protect."),
            recommendation: String(localized: "No action needed. Staying above roughly 15% free is what keeps it this way."),
            category: category,
            severity: .good,
            evidence: [
                String(localized: "Lowest free-space reading over \(dayText): \(minimumText)."),
                String(localized: "Current free space: \(latestText).")
            ],
            action: nil,
            confidence: context.confidenceForCoverage,
            scoreImpact: InsightWeight.none
        )
    }
}

// MARK: - Power habits & maintenance

/// Uptime without a restart.
public struct LongUptimeRule: ProtectionInsightRule {
    public let id = "maintenance.long-uptime"
    public let category: InsightCategory = .maintenance
    public init() {}

    public static let advisoryDays = 14.0
    public static let warningDays = 45.0

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard let uptimeDays = context.powerHabits?.uptimeDays,
              uptimeDays >= Self.advisoryDays
        else { return nil }

        let severity: InsightSeverity = uptimeDays >= Self.warningDays ? .warning : .advice
        let uptimeText = InsightPhrasing.days(uptimeDays)

        var evidence = [
            String(localized: "This Mac has not been restarted in \(uptimeText).")
        ]
        if let version = context.device.macOSVersion {
            evidence.append(String(localized: "Running macOS \(version)."))
        }
        if context.posture.automaticSecurityResponses.isDefinitelyOn {
            evidence.append(String(localized: "Automatic security responses are enabled — some of them only take effect after a restart."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "It has been a long time since a restart"),
            summary: String(localized: "Uptime is \(uptimeText)."),
            detail: String(localized: "macOS is perfectly capable of running for months, so this is not a stability warning. It is a security one: kernel-level and system-library updates — including Apple's Rapid Security Responses — do not take effect until the machine reboots, so a Mac with very long uptime can be fully patched on paper and still running the old code.\n\nNote that macOS uptime keeps counting across sleep, so this number is time since the last restart, not time spent awake."),
            recommendation: String(localized: "Restart when it is convenient. There is no need to make a habit of it — once a month is comfortably enough to keep security updates actually applied."),
            category: category,
            severity: severity,
            evidence: evidence,
            action: nil,
            confidence: 1.0,
            scoreImpact: severity == .warning ? InsightWeight.minorHardware : InsightWeight.none
        )
    }
}

/// A keep-awake assertion currently held — Sentry's own feature, reported
/// honestly rather than hidden because it is ours.
public struct KeepAwakeHeldRule: ProtectionInsightRule {
    public let id = "power.keep-awake-active"
    public let category: InsightCategory = .powerHabits
    public init() {}

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard let assertion = context.snapshot?.sleepAssertion,
              case .active(let mode, let expiresAt, let reason) = assertion
        else { return nil }

        // `AwakeMode` is a raw-value enum with no display name of its own
        // (see its doc comment — it's a shared model type, deliberately
        // free of UI vocabulary), so the readable phrasing is built here.
        let modeText: String
        switch mode {
        case .displayAndSystem: modeText = String(localized: "display and system stay awake")
        case .systemOnly: modeText = String(localized: "system stays awake, display may sleep")
        case .systemWhileOnAC: modeText = String(localized: "system stays awake while on AC power")
        }

        var evidence: [String] = []
        evidence.append(String(localized: "A keep-awake hold is active — \(modeText)."))
        if !reason.isEmpty {
            evidence.append(String(localized: "Reason recorded: \(reason)"))
        }
        if let expiresAt {
            let expiryText = expiresAt.formatted(date: .abbreviated, time: .shortened)
            evidence.append(String(localized: "It expires at \(expiryText)."))
        } else {
            evidence.append(String(localized: "It has no expiry — it will hold until it is released."))
        }
        if let charge = context.snapshot?.battery?.chargePercent {
            let chargeText = InsightPhrasing.percentValue(charge, decimals: 0)
            evidence.append(String(localized: "Current charge: \(chargeText)."))
        }

        // An indefinite hold is the one worth flagging; a timed one is
        // working exactly as designed.
        let severity: InsightSeverity = expiresAt == nil ? .advice : .good

        return ProtectionInsight(
            id: id,
            title: expiresAt == nil
                ? String(localized: "Sleep is being prevented indefinitely")
                : String(localized: "A timed keep-awake hold is running"),
            summary: expiresAt == nil
                ? String(localized: "Sentry is holding this Mac awake with no expiry set.")
                : String(localized: "Sentry is holding this Mac awake until a set time."),
            detail: String(localized: "A Mac that never sleeps never gets the thermal and battery rest that sleep provides, and on a laptop an indefinite hold can quietly run a full charge down in a bag. This is Sentry's own keep-awake feature, reported here for the same reason as everything else in this list — a finding is not less true because we caused it."),
            recommendation: String(localized: "End or time-limit the hold from Sentry's menu bar dropdown when the task it was for is finished."),
            category: category,
            severity: severity,
            evidence: evidence,
            action: InsightAction(
                label: String(localized: "Use the menu bar dropdown"),
                target: .manual,
                fallbackDescription: String(localized: "Click Sentry in the menu bar — the keep-awake card has an End button.")
            ),
            confidence: 1.0,
            scoreImpact: expiresAt == nil ? InsightWeight.minorHardware : InsightWeight.none
        )
    }
}

/// A power adapter that cannot keep up with what this Mac actually draws.
public struct UnderpoweredAdapterRule: ProtectionInsightRule {
    public let id = "power.adapter-undersized"
    public let category: InsightCategory = .powerHabits
    public init() {}

    public static let advisoryFraction = 0.1
    public static let warningFraction = 0.3

    public func evaluate(_ context: InsightContext) -> ProtectionInsight? {
        guard context.hasEnoughHistory,
              let habits = context.powerHabits,
              let rating = habits.adapterRatedWatts,
              rating > 0,
              let fraction = habits.fractionDrawAboveAdapterRating,
              fraction >= Self.advisoryFraction,
              let peak = habits.peakSystemPowerWatts
        else { return nil }

        let severity: InsightSeverity = fraction >= Self.warningFraction ? .warning : .advice
        let fractionText = InsightPhrasing.percent(fraction: fraction)
        let ratingText = "\(rating)"
        let peakText = InsightPhrasing.watts(peak)

        var evidence = [
            String(localized: "System draw exceeded the connected \(ratingText) W adapter's rating in \(fractionText) of readings."),
            String(localized: "Peak measured system power: \(peakText).")
        ]
        if let mean = habits.meanSystemPowerWatts {
            let meanText = InsightPhrasing.watts(mean)
            evidence.append(String(localized: "Average system power over the window: \(meanText)."))
        }

        return ProtectionInsight(
            id: id,
            title: String(localized: "The adapter can't keep up under load"),
            summary: String(localized: "Draw exceeded the \(ratingText) W adapter in \(fractionText) of readings."),
            detail: String(localized: "When a Mac draws more than its adapter supplies, the difference comes out of the battery — so it discharges while plugged in, then recharges once load drops. That cycling is invisible in day-to-day use but it accumulates real charge cycles, and it happens at exactly the moments the machine is hottest, which is the worst time for the cell."),
            recommendation: String(localized: "Use the adapter this Mac shipped with, or a higher-wattage USB-C adapter, for sustained heavy work. A lower-wattage travel adapter is fine for light use and charging overnight."),
            category: category,
            severity: severity,
            evidence: evidence,
            action: nil,
            confidence: context.confidenceForCoverage,
            scoreImpact: severity == .warning ? InsightWeight.moderateHardware : InsightWeight.minorHardware
        )
    }
}
