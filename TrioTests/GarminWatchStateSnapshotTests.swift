import Foundation
import LoopKit
import Testing

@testable import Trio

@Suite("Garmin watch state from the host's snapshot") struct GarminWatchStateSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let options = GarminWatchState.DisplayOptions(
        primaryAttributeChoice: "cob",
        secondaryAttributeChoice: "tbr",
        glucoseColorScheme: "static",
        sendsHistory: false
    )

    private func reading(minutesAgo: Double, _ mgdL: Double, _ trend: SmartwatchGlucoseTrend? = .flat)
        -> SmartwatchGlucoseReading
    {
        SmartwatchGlucoseReading(date: now.addingTimeInterval(-minutesAgo * 60), milligramsPerDeciliter: mgdL, trend: trend)
    }

    private func milliseconds(minutesAgo: Double) -> UInt64 {
        UInt64(now.addingTimeInterval(-minutesAgo * 60).timeIntervalSince1970 * 1000)
    }

    private func snapshot(
        history: [SmartwatchGlucoseReading],
        unit: SmartwatchGlucoseUnit = .millimolesPerLiter,
        therapy: SmartwatchTherapyContext? = nil
    ) -> SmartwatchStatusSnapshot {
        SmartwatchStatusSnapshot(
            displayUnit: unit,
            glucose: history.last,
            glucoseHistory: history,
            insulinOnBoard: 1.234,
            carbsOnBoard: 22,
            lastLoopCompleted: now.addingTimeInterval(-120),
            therapy: therapy
        )
    }

    @Test("The first entry carries every value") func firstEntry() {
        let therapy = SmartwatchTherapyContext(
            tempBasalRate: 0.35,
            scheduledBasalRate: 0.8,
            insulinSensitivity: 54.4,
            eventualGlucose: 120.6,
            sensitivityRatio: 1.1,
            correctionRange: 100 ... 110
        )
        let history = [reading(minutesAgo: 10, 100), reading(minutesAgo: 5, 104), reading(minutesAgo: 0, 110, .up)]
        let states = GarminWatchState.states(from: snapshot(history: history, therapy: therapy), options: options, now: now)

        #expect(states.count == 1, "no history for the Trio watchface")
        let first = try! #require(states.first)
        #expect(first.sgv == 110)
        #expect(first.delta == 6)
        #expect(first.direction == "FortyFiveUp")
        #expect(first.glucoseDate == milliseconds(minutesAgo: 0))
        #expect(first.date == milliseconds(minutesAgo: 2), "when the loop last ran")
        #expect(first.units_hint == "mmol")
        #expect(first.iob == 1.2)
        #expect(first.cob == 22)
        #expect(first.tbr == 0.35)
        #expect(first.isf == 54)
        #expect(first.eventualBG == 121)
        #expect(first.sensRatio == 1.1)
        #expect(first.targetGlucose == 105)
        #expect(first.displayPrimaryAttributeChoice == "cob")
        #expect(first.displaySecondaryAttributeChoice == "tbr")
        #expect(first.glucoseColorScheme == "static")
    }

    @Test("Without a temp basal, the scheduled basal") func scheduledBasal() {
        let therapy = SmartwatchTherapyContext(scheduledBasalRate: 0.8)
        let states = GarminWatchState.states(
            from: snapshot(history: [reading(minutesAgo: 0, 100)], unit: .milligramsPerDeciliter, therapy: therapy),
            options: options,
            now: now
        )
        #expect(states.first?.tbr == 0.8)
        #expect(states.first?.units_hint == "mgdl")
        #expect(states.first?.delta == 0, "one reading: no delta")
    }

    @Test("SwissAlpine and the complication app get up to 24 readings, newest first") func history() {
        var withHistory = options
        withHistory.sendsHistory = true
        let history = (0 ..< 36).reversed().map { reading(minutesAgo: Double($0) * 5, 100 + Double($0)) }
        let states = GarminWatchState.states(from: snapshot(history: history), options: withHistory, now: now)

        #expect(states.count == 24)
        #expect(states[0].sgv == 100)
        #expect(states[1].sgv == 101)
        #expect(states[1].date == milliseconds(minutesAgo: 5), "older entries carry the reading's time")
        #expect(states[1].iob == nil, "older entries carry only time and glucose")
        #expect(states[23].sgv == 123)
    }

    @Test("No loop yet: 31 minutes ago, so the watch shows it as stale") func noLoop() {
        var snapshot = snapshot(history: [reading(minutesAgo: 0, 100)])
        snapshot.lastLoopCompleted = nil
        let states = GarminWatchState.states(from: snapshot, options: options, now: now)
        #expect(states.first?.date == milliseconds(minutesAgo: 31))
    }

    @Test("No readings: nothing to send") func noReadings() {
        let empty = SmartwatchStatusSnapshot(displayUnit: .milligramsPerDeciliter, glucose: nil)
        #expect(GarminWatchState.states(from: empty, options: options, now: now).isEmpty)
    }

    @Test("The latest reading counts even without history") func latestOnly() {
        let latest = reading(minutesAgo: 0, 98, nil)
        let snapshot = SmartwatchStatusSnapshot(displayUnit: .milligramsPerDeciliter, glucose: latest)
        let states = GarminWatchState.states(from: snapshot, options: options, now: now)
        #expect(states.first?.sgv == 98)
        #expect(states.first?.direction == "--")
    }

    @Test("Trends map to Nightscout directions; small IOB stays visible") func directionsAndIOB() {
        #expect(SmartwatchGlucoseTrend.allCases.map(GarminWatchState.direction) == [
            "DoubleUp", "SingleUp", "FortyFiveUp", "Flat", "FortyFiveDown", "SingleDown", "DoubleDown"
        ])
        #expect(GarminWatchState.formattedIOB(0.04) == 0.1)
        #expect(GarminWatchState.formattedIOB(-0.04) == -0.1)
        #expect(GarminWatchState.formattedIOB(0) == 0)
        #expect(GarminWatchState.formattedIOB(2.46) == 2.5)
    }
}
