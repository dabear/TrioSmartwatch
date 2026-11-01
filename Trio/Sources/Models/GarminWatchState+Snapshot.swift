import Foundation
import LoopKit

/// Garmin's watch state built only from the host's `SmartwatchStatusSnapshot`,
/// so the Garmin plugin needs nothing from Trio's stores.
extension GarminWatchState {
    /// What the snapshot doesn't carry: Trio's Garmin display settings.
    struct DisplayOptions: Equatable {
        /// `GarminPrimaryAttributeChoice` raw value.
        var primaryAttributeChoice: String
        /// `GarminSecondaryAttributeChoice` raw value.
        var secondaryAttributeChoice: String
        /// "dynamic" or "static", the wire format the watchface reads.
        var glucoseColorScheme: String
        /// SwissAlpine and the complication app show up to 24 readings; the others one.
        var sendsHistory: Bool
    }

    /// The most readings a watch app gets.
    static let maximumHistoryCount = 24

    /// Newest reading first, like dev's GarminManager: the first entry carries
    /// every value, the others only their time and glucose. Empty without readings.
    static func states(
        from snapshot: SmartwatchStatusSnapshot,
        options: DisplayOptions,
        now: Date = Date()
    ) -> [GarminWatchState] {
        var readings = snapshot.glucoseHistory
        if let latest = snapshot.glucose, !readings.contains(where: { $0.date == latest.date }) {
            readings.append(latest)
        }
        readings.sort { $0.date > $1.date }
        guard let latest = readings.first else { return [] }

        var first = GarminWatchState()
        // When the loop last ran, not when the reading arrived; 31 minutes ago when
        // unknown, so the watch shows the loop as stale rather than as no data yet.
        first.date = milliseconds(snapshot.lastLoopCompleted ?? now.addingTimeInterval(-31 * 60))
        first.glucoseDate = milliseconds(latest.date)
        first.sgv = mgdL(latest.milligramsPerDeciliter)
        first.direction = latest.trend.map(direction) ?? "--"
        first.delta = readings.count > 1
            ? mgdL(latest.milligramsPerDeciliter - readings[1].milligramsPerDeciliter)
            : 0
        first.units_hint = snapshot.displayUnit == .millimolesPerLiter ? "mmol" : "mgdl"
        first.iob = formattedIOB(snapshot.insulinOnBoard ?? 0)
        first.cob = snapshot.carbsOnBoard
        first.tbr = snapshot.therapy.flatMap { $0.tempBasalRate ?? $0.scheduledBasalRate }
        first.isf = snapshot.therapy?.insulinSensitivity.flatMap(mgdL)
        first.eventualBG = snapshot.therapy?.eventualGlucose.flatMap(mgdL)
        first.sensRatio = snapshot.therapy?.sensitivityRatio
        first.targetGlucose = snapshot.therapy?.correctionRange.flatMap { mgdL(($0.lowerBound + $0.upperBound) / 2) }
        first.displayPrimaryAttributeChoice = options.primaryAttributeChoice
        first.displaySecondaryAttributeChoice = options.secondaryAttributeChoice
        first.glucoseColorScheme = options.glucoseColorScheme

        let older = options.sendsHistory ? readings.dropFirst().prefix(maximumHistoryCount - 1) : []
        return [first] + older.map { reading in
            var state = GarminWatchState()
            state.date = milliseconds(reading.date)
            state.sgv = mgdL(reading.milligramsPerDeciliter)
            return state
        }
    }

    /// Nightscout direction names, which Garmin's watch apps read.
    static func direction(_ trend: SmartwatchGlucoseTrend) -> String {
        switch trend {
        case .upUpUp: return "DoubleUp"
        case .upUp: return "SingleUp"
        case .up: return "FortyFiveUp"
        case .flat: return "Flat"
        case .down: return "FortyFiveDown"
        case .downDown: return "SingleDown"
        case .downDownDown: return "DoubleDown"
        }
    }

    /// One decimal, and at least 0.1 in size so a small IOB doesn't show as zero.
    static func formattedIOB(_ value: Double) -> Double {
        if value.magnitude < 0.1, value != 0 {
            return value > 0 ? 0.1 : -0.1
        }
        return (value * 10).rounded() / 10
    }

    private static func milliseconds(_ date: Date) -> UInt64 {
        UInt64(date.timeIntervalSince1970 * 1000)
    }

    private static func mgdL(_ value: Double) -> Int16? {
        guard value.isFinite, abs(value) <= Double(Int16.max) else { return nil }
        return Int16(value.rounded())
    }
}
