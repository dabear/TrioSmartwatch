import ConnectIQ
import CoreData
import Foundation
import LoopKit
import Swinject
import Testing

@testable import Trio

/// Records what the Garmin plugin asks the host, and answers as told.
final class FakeSmartwatchHost: SmartwatchManagerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _carbRequests: [SmartwatchCarbEntryRequest] = []
    private var _bolusRequests: [SmartwatchBolusRequest] = []
    private var _overrideRequests: [SmartwatchOverrideRequest] = []
    private var _tempTargetRequests: [SmartwatchTempTargetRequest] = []
    var bolusError: Error?
    var carbError: Error?
    var onRefresh: () -> Void = {}

    var carbRequests: [SmartwatchCarbEntryRequest] { lock.withLock { _carbRequests } }
    var bolusRequests: [SmartwatchBolusRequest] { lock.withLock { _bolusRequests } }
    var overrideRequests: [SmartwatchOverrideRequest] { lock.withLock { _overrideRequests } }
    var tempTargetRequests: [SmartwatchTempTargetRequest] { lock.withLock { _tempTargetRequests } }

    func smartwatchManagerDidUpdateState(_: SmartwatchManager) {}
    func smartwatchManagerWantsDeletion(_: SmartwatchManager) async {}
    func smartwatchManagerRequestsRefresh(_: SmartwatchManager) { onRefresh() }
    func smartwatchManager(_: SmartwatchManager, didLogEvent _: SmartwatchDeviceLogEntry) {}

    func smartwatchManager(_: SmartwatchManager, requestBolus request: SmartwatchBolusRequest) async throws -> Double {
        lock.withLock { _bolusRequests.append(request) }
        if let bolusError { throw bolusError }
        return request.units
    }

    func smartwatchManager(_: SmartwatchManager, requestCarbEntry request: SmartwatchCarbEntryRequest) async throws -> Double {
        lock.withLock { _carbRequests.append(request) }
        if let carbError { throw carbError }
        return request.grams
    }

    func smartwatchManager(_: SmartwatchManager, requestOverride request: SmartwatchOverrideRequest) async throws {
        lock.withLock { _overrideRequests.append(request) }
    }

    func smartwatchManager(_: SmartwatchManager, requestTempTarget request: SmartwatchTempTargetRequest) async throws {
        lock.withLock { _tempTargetRequests.append(request) }
    }
}

private func snapshot(
    glucose: [Double] = [100, 110, 120],
    permitted: SmartwatchCapabilities = [.remoteBolus, .remoteCarbs, .remoteOverride, .remoteTempTarget],
    overrides: [SmartwatchPreset] = [],
    tempTargets: [SmartwatchPreset] = []
) -> SmartwatchStatusSnapshot {
    let now = Date()
    let readings = glucose.enumerated().map { index, value in
        SmartwatchGlucoseReading(
            date: now.addingTimeInterval(TimeInterval(index - glucose.count + 1) * 300),
            milligramsPerDeciliter: value,
            trend: .up
        )
    }
    var snapshot = SmartwatchStatusSnapshot(
        displayUnit: .milligramsPerDeciliter,
        glucose: readings.last,
        glucoseHistory: readings,
        insulinOnBoard: 1.234,
        carbsOnBoard: 20,
        lastLoopCompleted: now.addingTimeInterval(-60),
        isClosedLoop: true,
        bolusContext: SmartwatchBolusContext(
            token: UUID(),
            issuedAt: now,
            recommendedBolus: 1,
            maximumBolus: 5,
            supportedBolusVolumes: [0.05, 0.1]
        ),
        therapy: SmartwatchTherapyContext(
            tempBasalRate: 0.8,
            scheduledBasalRate: 1,
            insulinSensitivity: 50,
            eventualGlucose: 130,
            sensitivityRatio: 1.1,
            correctionRange: 100 ... 110
        ),
        overridePresets: overrides,
        tempTargetPresets: tempTargets
    )
    snapshot.permittedActions = permitted
    snapshot.maximumCarbEntry = 120
    snapshot.bolusIncrement = 0.05
    return snapshot
}

@Suite("Garmin SmartwatchManager plugin", .serialized) final class GarminSmartwatchManagerTests {
    let resolver: Resolver
    let bridge: GarminSmartwatchBridge
    let host = FakeSmartwatchHost()
    let plugin: GarminSmartwatchManager
    let processor: SmartwatchWatchCommandProcessor
    let commandApp: UUID

    init() async throws {
        let stack = try await CoreDataStack.createForTests()
        resolver = makeGarminResolver(stack: stack, overrides: [])
        let settings = try #require(resolver.resolve(SettingsManager.self))
        settings.settings.garminSettings.watchface = .complication
        commandApp = try #require(GarminCommandApp(settings.settings.garminSettings).appUUID)
        bridge = try #require(resolver.resolve(GarminSmartwatchBridge.self))
        plugin = GarminSmartwatchManager(bridge: bridge)
        plugin.smartwatchManagerDelegate = host
        processor = SmartwatchWatchCommandProcessor(resolver: resolver)
    }

    private func request(_ command: WatchCommand, id: UUID = UUID(), app: UUID? = nil) -> WatchCommandRequest {
        WatchCommandRequest(requestID: id, appUUID: app ?? commandApp, date: Date().addingTimeInterval(-3), command: command)
    }

    // MARK: - Limits

    @Test("Garmin's limits match its watch apps; the defaults stay for every other plugin") func testLimits() {
        let limits = plugin.remoteActionLimits
        #expect(limits.requestWindow.maximumAge == 120)
        #expect(limits.requestWindow.maximumClockSkew == 60)
        #expect(limits.bolus.minimumInterval == 360)
        #expect(!limits.bolus.requiresContextToken)
        #expect(!limits.bolus.capsAtRecommendation)
        #expect(limits.carbEntry.minimumInterval == 0)
        #expect(limits.bolus.maximumGlucoseAge == SmartwatchBolusPolicy.Limits.standard.maximumGlucoseAge)
        #expect(SmartwatchRemoteActionLimits.standard.bolus.requiresContextToken)
    }

    @Test("Under Garmin's limits the policy allows any amount up to max bolus, without the token") func testPolicyWithGarminLimits() {
        let context = SmartwatchBolusContext(
            token: UUID(),
            issuedAt: Date(),
            recommendedBolus: 1,
            maximumBolus: 5,
            supportedBolusVolumes: []
        )
        let policy = SmartwatchBolusPolicy(
            limits: plugin.remoteActionLimits.bolusPolicyLimits,
            isAllowed: true,
            currentContext: context,
            latestGlucoseDate: Date(),
            recentDeliveries: [],
            roundToSupportedVolume: { $0 }
        )
        let late = SmartwatchBolusRequest(units: 3, contextToken: UUID(), requestedAt: Date().addingTimeInterval(-90))
        #expect(policy.evaluate(late, now: Date()) == .success(3))
        let tooMuch = SmartwatchBolusRequest(units: 6, contextToken: UUID(), requestedAt: Date())
        #expect(policy.evaluate(tooMuch, now: Date()) == .failure(.exceedsMaximumBolus))
    }

    // MARK: - Commands

    @Test("Carbs go to the host dated when the user confirmed them") func testCarbs() async {
        bridge.publish(snapshot())
        let request = request(.carbs(25))
        let result = await processor.process(request)
        #expect(result.acknowledged && result.ackCode == .carbsLogged)
        #expect(host.carbRequests.map(\.grams) == [25])
        #expect(host.carbRequests.first?.requestedAt == request.date)
    }

    @Test("A bolus goes to the host with the snapshot's context, not forced") func testBolus() async {
        let current = snapshot()
        bridge.publish(current)
        let result = await processor.process(request(.bolus(2.5)))
        #expect(result.acknowledged)
        #expect(host.bolusRequests.first?.units == 2.5)
        #expect(host.bolusRequests.first?.contextToken == current.bolusContext?.token)
        #expect(host.bolusRequests.first?.isForced == false)
    }

    @Test("A host refusal reaches the watch as a failure; in progress is not a failure") func testRefusals() async {
        bridge.publish(snapshot())
        host.bolusError = SmartwatchBolusError.noRecentGlucose
        let refused = await processor.process(request(.bolus(1)))
        #expect(!refused.acknowledged && refused.ackCode == .genericFailure)
        host.bolusError = SmartwatchBolusError.inProgress
        let inProgress = await processor.process(request(.bolus(1)))
        #expect(inProgress.ackCode == .inProgress)
    }

    @Test("A resent request runs once and gets the same result") func testResend() async {
        bridge.publish(snapshot())
        let id = UUID()
        let first = await processor.process(request(.carbs(10), id: id))
        let second = await processor.process(request(.carbs(10), id: id))
        #expect(first == second)
        #expect(host.carbRequests.count == 1)
    }

    @Test("Only the command app's commands reach the host") func testOtherApp() async {
        bridge.publish(snapshot())
        let result = await processor.process(request(.carbs(10), app: UUID()))
        #expect(!result.acknowledged)
        #expect(host.carbRequests.isEmpty)
    }

    @Test("Without the plugin in Trio's watch slot nothing reaches a host") func testNoPlugin() async {
        bridge.publish(snapshot())
        bridge.detach(plugin)
        let result = await processor.process(request(.carbs(10)))
        #expect(!result.acknowledged)
        #expect(host.carbRequests.isEmpty)
    }

    @Test("A meal adds the carbs, then boluses against the next snapshot") func testMeal() async {
        bridge.publish(snapshot())
        let next = snapshot()
        host.onRefresh = { [bridge] in bridge.publish(next) }
        let result = await processor.process(request(.mealBolus(carbs: 30, bolus: 2)))
        #expect(result.acknowledged)
        #expect(host.carbRequests.map(\.grams) == [30])
        #expect(host.bolusRequests.first?.contextToken == next.bolusContext?.token)
    }

    @Test("A meal whose bolus is refused keeps its carbs and says so") func testMealPartial() async {
        bridge.publish(snapshot())
        host.onRefresh = { [bridge] in bridge.publish(snapshot()) }
        host.bolusError = SmartwatchBolusError.notAllowed
        let result = await processor.process(request(.mealBolus(carbs: 30, bolus: 2)))
        #expect(result.ackCode == .partialFailure)
        #expect(host.carbRequests.count == 1)
    }

    @Test("Presets are started by their unique, exact name") func testPresets() async {
        let presets = [
            SmartwatchPreset(id: "a", name: "Exercise", isActive: false, duration: nil),
            SmartwatchPreset(id: "b", name: "Twin", isActive: false, duration: nil),
            SmartwatchPreset(id: "c", name: "Twin", isActive: false, duration: nil)
        ]
        bridge.publish(snapshot(overrides: presets, tempTargets: presets))
        let started = await processor.process(request(.activateOverride(name: "Exercise")))
        #expect(started.ackCode == .overrideStarted)
        #expect(host.overrideRequests.first?.action == .activate(presetID: "a"))
        let ambiguous = await processor.process(request(.activateTempTarget(name: "Twin")))
        #expect(!ambiguous.acknowledged)
        let missing = await processor.process(request(.activateOverride(name: "exercise")))
        #expect(!missing.acknowledged)
        let cancelled = await processor.process(request(.cancelTempTarget))
        #expect(cancelled.ackCode == .tempTargetStopped)
        #expect(host.tempTargetRequests.map(\.action) == [.cancel])
    }

    @Test("The command app's menu follows the user's permissions and the host's limits") func testCapabilities() {
        bridge.publish(snapshot(permitted: [.remoteCarbs]))
        let carbsOnly = processor.capabilities()
        #expect(carbsOnly.isCommandControlEnabled)
        #expect(!carbsOnly.isBolusCommandEnabled)
        #expect(carbsOnly.maxCarbs == 120)
        #expect(carbsOnly.maxBolus == 5)
        #expect(carbsOnly.bolusIncrement == Decimal(0.05))
        bridge.publish(snapshot(permitted: []))
        #expect(!processor.capabilities().isCommandControlEnabled)
    }

    @Test("Presets for the command app come from the snapshot") func testPresetsProvider() async throws {
        bridge.publish(snapshot(overrides: [SmartwatchPreset(id: "x", name: "Sick", isActive: true, duration: nil)]))
        let provider = SmartwatchWatchPresetsProvider(resolver: resolver)
        let entries = try await provider.overridePresets()
        #expect(entries.map(\.name) == ["Sick"])
        #expect(entries.first?.isActive == true)
        #expect(entries.first?.ref == .presetID("x"))
    }

    // MARK: - Watch state

    @Test("The watch state is built from the snapshot alone") func testWatchState() async throws {
        let device = try #require(IQDevice(id: UUID(), modelName: "fenix 8", friendlyName: "A"))
        let manager = BaseGarminManager(resolver: resolver, connectIQClient: SpyConnectIQClient())
        defer { manager.updateDeviceList([]) }
        manager.updateDeviceList([device])
        #expect(try await manager.setupGarminWatchState().isEmpty, "Nothing before the first snapshot")

        bridge.publish(snapshot(glucose: [100, 110, 125]))
        let state = try #require(try await manager.setupGarminWatchState().first)
        #expect(state.sgv == 125)
        #expect(state.delta == 15)
        #expect(state.direction == "FortyFiveUp")
        #expect(state.units_hint == "mgdl")
        #expect(state.iob == 1.2)
        #expect(state.cob == 20)
        #expect(state.tbr == 0.8)
        #expect(state.isf == 50)
        #expect(state.eventualBG == 130)
        #expect(state.sensRatio == 1.1)
        #expect(state.targetGlucose == 100)
    }
}
