import Foundation
import LoopKit
import Testing

@testable import Trio

@Suite("Smartwatch host: alert and trend mapping") struct SmartwatchHostTests {
    private func identifier(_ alertIdentifier: String, manager: String = BaseTrioAlertManager.managerIdentifier)
        -> Alert.Identifier
    {
        Alert.Identifier(managerIdentifier: manager, alertIdentifier: alertIdentifier)
    }

    @Test("Trio glucose alerts map to the watch's alert types") func glucoseAlertTypes() {
        let uuid = UUID().uuidString
        #expect(BaseSmartwatchHost.glucoseAlertType(of: identifier("glucose.urgentLow.\(uuid)")) == .urgentLow)
        #expect(BaseSmartwatchHost.glucoseAlertType(of: identifier("glucose.low.\(uuid)")) == .low)
        #expect(BaseSmartwatchHost.glucoseAlertType(of: identifier("glucose.high.\(uuid)")) == .high)
        #expect(BaseSmartwatchHost.glucoseAlertType(of: identifier("glucose.forecastedLow.\(uuid)")) == .predictedLow)
    }

    @Test("Other alerts are not glucose alerts") func otherAlerts() {
        let uuid = UUID().uuidString
        #expect(BaseSmartwatchHost.glucoseAlertType(of: identifier("glucose.carbsRequired.\(uuid)")) == nil)
        #expect(BaseSmartwatchHost.glucoseAlertType(of: identifier("glucose.stale")) == nil)
        #expect(BaseSmartwatchHost.glucoseAlertType(of: identifier("notLooping")) == nil)
        #expect(BaseSmartwatchHost.glucoseAlertType(of: identifier("glucose.low.\(uuid)", manager: "SomeCGM")) == nil)
    }

    @Test("Trend arrows match LoopKit's GlucoseTrend") func trends() {
        #expect(BloodGlucose.Direction.tripleUp.smartwatchTrend == .upUpUp)
        #expect(BloodGlucose.Direction.doubleUp.smartwatchTrend == .upUpUp)
        #expect(BloodGlucose.Direction.singleUp.smartwatchTrend == .upUp)
        #expect(BloodGlucose.Direction.fortyFiveUp.smartwatchTrend == .up)
        #expect(BloodGlucose.Direction.flat.smartwatchTrend == .flat)
        #expect(BloodGlucose.Direction.fortyFiveDown.smartwatchTrend == .down)
        #expect(BloodGlucose.Direction.singleDown.smartwatchTrend == .downDown)
        #expect(BloodGlucose.Direction.doubleDown.smartwatchTrend == .downDownDown)
        #expect(BloodGlucose.Direction.tripleDown.smartwatchTrend == .downDownDown)
        #expect(BloodGlucose.Direction.notComputable.smartwatchTrend == nil)
        #expect(BloodGlucose.Direction.rateOutOfRange.smartwatchTrend == nil)
    }
}
