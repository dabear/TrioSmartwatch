import Combine
import CoreData
import Foundation
import LoopKit
import LoopKitUI
import LupedSmartwatchKit
import LupedSmartwatchKitUI
import Swinject

/// A watch plugin Trio can host. Trio links its plugins statically.
struct SmartwatchPlugin {
    let managerType: SmartwatchManagerUI.Type
    let descriptor: SmartwatchManagerDescriptor

    static let all: [SmartwatchPlugin] = [
        SmartwatchPlugin(
            managerType: LupedSmartwatchManager.self,
            descriptor: SmartwatchManagerDescriptor(
                identifier: LupedSmartwatchManager.pluginIdentifier,
                localizedTitle: LupedSmartwatchManager.localizedTitle,
                subtitle: "Pebble Time 2 and Pebble Round 2",
                manufacturer: "Core Devices",
                image: LupedSmartwatchManager.onboardingImage
            )
        )
    ]

    static func managerType(for identifier: String) -> SmartwatchManagerUI.Type? {
        all.first { $0.descriptor.identifier == identifier }?.managerType
    }
}

/// Hosts one `SmartwatchManager` plugin (such as the Pebble plugin) next to the
/// Apple Watch and Garmin integrations: keeps it, feeds it Trio's state and
/// glucose alerts, and routes its log lines to the device log.
protocol SmartwatchHost: AnyObject {
    var smartwatchManager: SmartwatchManagerUI? { get }
    /// Fires when a watch manager is added or removed.
    var smartwatchManagerChanged: AnyPublisher<Void, Never> { get }
    var availableSmartwatchManagers: [SmartwatchManagerDescriptor] { get }

    @MainActor func setupViewController(
        for identifier: String,
        completionDelegate: CompletionDelegate?
    ) -> UIViewController?
    @MainActor func settingsViewController(completionDelegate: CompletionDelegate?) -> UIViewController?

    /// Offers a URL Trio doesn't handle itself, such as a companion app's callback.
    @MainActor func handle(_ url: URL) -> Bool
}

final class BaseSmartwatchHost: SmartwatchHost, Injectable {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var apsManager: APSManager!
    @Injected() private var deviceDataManager: DeviceDataManager!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var iobService: IOBService!
    @Injected() private var trioAlertManager: TrioAlertManager!
    @Injected() private var deviceLogStore: DeviceLogStore!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var adjustmentManager: AdjustmentManager!
    @Injected() private var overrideStorage: OverrideStorage!
    @Injected() private var tempTargetStorage: TempTargetsStorage!

    @PersistedProperty(key: "SmartwatchManagerState") private var rawSmartwatchManager: [String: Any]?

    private let changedSubject = PassthroughSubject<Void, Never>()
    private var subscriptions = Set<AnyCancellable>()
    private let coreDataQueue = DispatchQueue(label: "BaseSmartwatchHost.coreData", qos: .utility)

    /// Main-actor state for sending snapshots.
    @MainActor private var lastSentSnapshot: SmartwatchStatusSnapshot?
    @MainActor private var updateGeneration = 0

    private(set) var smartwatchManager: SmartwatchManagerUI? {
        didSet {
            smartwatchManager?.smartwatchManagerDelegate = self
            rawSmartwatchManager = smartwatchManager.map(Self.rawValue(of:))
            changedSubject.send()
            Task { @MainActor in self.refresh() }
        }
    }

    var smartwatchManagerChanged: AnyPublisher<Void, Never> { changedSubject.eraseToAnyPublisher() }

    var availableSmartwatchManagers: [SmartwatchManagerDescriptor] { SmartwatchPlugin.all.map(\.descriptor) }

    init(resolver: Resolver) {
        injectServices(resolver)
        restoreManager()
        trioAlertManager.addAlertForwarder(self)
        broadcaster.register(SettingsObserver.self, observer: self)
        subscribeToUpdates()
    }

    // MARK: - Persistence

    private static func rawValue(of manager: SmartwatchManager) -> [String: Any] {
        ["managerIdentifier": manager.pluginIdentifier, "state": manager.rawState]
    }

    private func restoreManager() {
        guard let raw = rawSmartwatchManager else { return }
        guard let identifier = raw["managerIdentifier"] as? String,
              let state = raw["state"] as? SmartwatchManager.RawStateValue,
              let managerType = SmartwatchPlugin.managerType(for: identifier),
              let manager = managerType.init(rawState: state)
        else {
            // As for the pump and CGM: keep the saved state for a build that has the plugin.
            warning(.watch, "Saved watch manager unavailable; keeping its state for a later launch")
            return
        }
        manager.smartwatchManagerDelegate = self
        smartwatchManager = manager
    }

    // MARK: - Setup and settings

    @MainActor func setupViewController(
        for identifier: String,
        completionDelegate: CompletionDelegate?
    ) -> UIViewController? {
        guard let managerType = SmartwatchPlugin.managerType(for: identifier) else { return nil }
        let result = managerType.setupViewController(
            bluetoothProvider: deviceDataManager.bluetoothManager,
            displayGlucosePreference: displayGlucosePreference(),
            colorPalette: .default,
            allowDebugFeatures: false
        )
        switch result {
        case var .userInteractionRequired(viewController):
            viewController.smartwatchManagerOnboardingDelegate = self
            viewController.completionDelegate = completionDelegate
            return viewController
        case let .createdAndOnboarded(manager):
            smartwatchManagerOnboarding(didCreateSmartwatchManager: manager)
            smartwatchManagerOnboarding(didOnboardSmartwatchManager: manager)
            return nil
        }
    }

    @MainActor func settingsViewController(completionDelegate: CompletionDelegate?) -> UIViewController? {
        guard let manager = smartwatchManager else { return nil }
        var viewController = manager.settingsViewController(
            bluetoothProvider: deviceDataManager.bluetoothManager,
            displayGlucosePreference: displayGlucosePreference(),
            colorPalette: .default,
            allowDebugFeatures: false
        )
        viewController.completionDelegate = completionDelegate
        return viewController
    }

    private func displayGlucosePreference() -> DisplayGlucosePreference {
        DisplayGlucosePreference(
            displayGlucoseUnit: settingsManager.settings
                .units == .mmolL ? .millimolesPerLiter : .milligramsPerDeciliter
        )
    }

    @MainActor func handle(_ url: URL) -> Bool {
        smartwatchManager?.watchHostDidReceiveURL(url) ?? false
    }

    // MARK: - Snapshots

    private func subscribeToUpdates() {
        glucoseStorage.updatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
            .store(in: &subscriptions)

        CoreDataStack.shared.entityChangePublisher
            .receive(on: coreDataQueue)
            .filteredByEntityName("GlucoseStored")
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
            .store(in: &subscriptions)

        CoreDataStack.shared.entityChangePublisher
            .receive(on: coreDataQueue)
            .filteredByEntityName("OrefDetermination")
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
            .store(in: &subscriptions)

        iobService.iobPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
            .store(in: &subscriptions)

        apsManager.lastLoopDateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
            .store(in: &subscriptions)

        for entity in ["OverrideStored", "TempTargetStored"] {
            CoreDataStack.shared.entityChangePublisher
                .receive(on: coreDataQueue)
                .filteredByEntityName(entity)
                .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
                .store(in: &subscriptions)
        }
    }

    /// Sends the current snapshot even if unchanged, for a new watch manager or
    /// one that reconnected.
    @MainActor private func refresh() {
        lastSentSnapshot = nil
        update()
    }

    @MainActor private func update() {
        guard let manager = smartwatchManager else { return }
        updateGeneration += 1
        let generation = updateGeneration
        let capabilities = manager.effectiveCapabilities
        Task { @MainActor in
            let snapshot: SmartwatchStatusSnapshot
            do {
                snapshot = try await makeSnapshot(capabilities: capabilities)
            } catch {
                warning(.watch, "Unable to build the watch snapshot: \(error)")
                return
            }
            guard generation == updateGeneration,
                  let current = smartwatchManager, current === manager,
                  snapshot != lastSentSnapshot
            else { return }
            lastSentSnapshot = snapshot
            current.watchDataDidUpdate(snapshot)
        }
    }

    private struct DeterminationValues {
        var timestamp: Date?
        var cob: Double?
        var eventualGlucose: Double?
        var insulinSensitivity: Double?
        var sensitivityRatio: Double?
        var target: Double?
        var scheduledBasal: Double?
    }

    @MainActor private func makeSnapshot(capabilities: SmartwatchCapabilities) async throws -> SmartwatchStatusSnapshot {
        let readings = try await fetchReadings(since: Date().addingTimeInterval(-SmartwatchStatusSnapshot.historyInterval))
        var snapshot = SmartwatchStatusSnapshot(
            displayUnit: settingsManager.settings.units == .mmolL ? .millimolesPerLiter : .milligramsPerDeciliter,
            glucose: readings.last,
            glucoseHistory: capabilities.contains(.history) ? readings : []
        )
        if capabilities.contains(.remoteOverride) {
            snapshot.overridePresets = try await overridePresets()
        }
        if capabilities.contains(.remoteTempTarget) {
            snapshot.tempTargetPresets = try await tempTargetPresets()
        }
        guard capabilities.contains(.loopStatus) || capabilities.contains(.therapy) else { return snapshot }

        let determination = try await latestDetermination()
        if capabilities.contains(.loopStatus) {
            snapshot.insulinOnBoard = iobService.currentIOB.map { Double(truncating: $0 as NSDecimalNumber) }
            snapshot.carbsOnBoard = determination?.cob
            let lastLoop = apsManager.lastLoopDate
            snapshot.lastLoopCompleted = lastLoop == .distantPast ? nil : lastLoop
            snapshot.isClosedLoop = settingsManager.settings.dosingMode == .closed
        }
        if capabilities.contains(.therapy) {
            var tempBasalRate: Double?
            if case let .tempBasal(dose) = deviceDataManager.pumpManager?.status.basalDeliveryState {
                tempBasalRate = dose.unitsPerHour
            }
            snapshot.therapy = SmartwatchTherapyContext(
                tempBasalRate: tempBasalRate,
                scheduledBasalRate: determination?.scheduledBasal,
                insulinSensitivity: determination?.insulinSensitivity,
                eventualGlucose: determination?.eventualGlucose,
                sensitivityRatio: determination?.sensitivityRatio,
                // The target the algorithm used, including any override or temp target.
                correctionRange: determination?.target.map { $0 ... $0 }
            )
        }
        return snapshot
    }

    private func fetchReadings(since start: Date) async throws -> [SmartwatchGlucoseReading] {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "smartwatchReadings"
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate(format: "date >= %@", start as NSDate),
            key: "date",
            ascending: true,
            fetchLimit: 0
        )
        return await context.perform {
            (results as? [GlucoseStored] ?? []).compactMap { stored in
                guard let date = stored.date else { return nil }
                return SmartwatchGlucoseReading(
                    date: date,
                    milligramsPerDeciliter: Double(stored.glucose),
                    trend: stored.direction.flatMap { BloodGlucose.Direction(from: $0) }?.smartwatchTrend,
                    wasUserEntered: stored.isManual
                )
            }
        }
    }

    /// Trio's override presets; `enabled` marks the running one. Durations are stored in minutes.
    private func overridePresets() async throws -> [SmartwatchPreset] {
        let ids = try await overrideStorage.fetchForOverridePresets()
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "smartwatchOverridePresets"
        let rows: [OverrideStored] = try await CoreDataStack.shared.getNSManagedObject(with: ids, context: context)
        return await context.perform {
            rows.compactMap { row in
                guard let id = row.id, let name = row.name else { return nil }
                let minutes = row.duration.map { Double(truncating: $0) } ?? 0
                return SmartwatchPreset(
                    id: id,
                    name: name,
                    isActive: row.enabled,
                    duration: row.indefinite || minutes <= 0 ? nil : minutes * 60
                )
            }
        }
    }

    /// Trio's temp target presets; `enabled` marks the running one. Durations are stored in minutes.
    private func tempTargetPresets() async throws -> [SmartwatchPreset] {
        let ids = try await tempTargetStorage.fetchForTempTargetPresets()
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "smartwatchTempTargetPresets"
        let rows: [TempTargetStored] = try await CoreDataStack.shared.getNSManagedObject(with: ids, context: context)
        return await context.perform {
            rows.compactMap { row in
                guard let id = row.id, let name = row.name else { return nil }
                let minutes = row.duration.map { Double(truncating: $0) } ?? 0
                return SmartwatchPreset(
                    id: id.uuidString,
                    name: name,
                    isActive: row.enabled,
                    duration: minutes > 0 ? minutes * 60 : nil
                )
            }
        }
    }

    /// The newest determination from the last 30 minutes, enacted or suggested.
    private func latestDetermination() async throws -> DeterminationValues? {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "smartwatchDetermination"
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: OrefDetermination.self,
            onContext: context,
            predicate: NSPredicate.predicateFor30MinAgoForDetermination,
            key: "deliverAt",
            ascending: false,
            fetchLimit: 1
        )
        return await context.perform {
            guard let determination = (results as? [OrefDetermination])?.first else { return nil }
            let double = { (value: NSDecimalNumber?) in value.map { Double(truncating: $0) } }
            return DeterminationValues(
                timestamp: determination.timestamp,
                cob: Double(determination.cob),
                eventualGlucose: double(determination.eventualBG),
                insulinSensitivity: double(determination.insulinSensitivity),
                sensitivityRatio: double(determination.sensitivityRatio),
                target: double(determination.currentTarget),
                scheduledBasal: double(determination.scheduledBasal)
            )
        }
    }

    // MARK: - Device log

    private func log(_ manager: SmartwatchManager, _ type: DeviceLogEntryType, _ message: String, device: String? = nil) {
        deviceLogStore.log(managerIdentifier: manager.pluginIdentifier, deviceIdentifier: device, type: type, message: message)
    }
}

// MARK: - SettingsObserver

extension BaseSmartwatchHost: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        // Units or dosing mode may have changed; unchanged snapshots aren't resent.
        Task { @MainActor in self.update() }
    }
}

// MARK: - TrioAlertForwarder

extension BaseSmartwatchHost: TrioAlertForwarder {
    /// Which glucose alert this is: Trio's glucose alerts are
    /// `Trio.glucose.<type>.<UUID>`. Carbs-required and every other alert are nil.
    static func glucoseAlertType(of identifier: Alert.Identifier) -> SmartwatchGlucoseAlertType? {
        guard identifier.managerIdentifier == BaseTrioAlertManager.managerIdentifier else { return nil }
        let parts = identifier.alertIdentifier.split(separator: ".")
        guard parts.count >= 2, parts[0] == "glucose" else { return nil }
        switch parts[1] {
        case "urgentLow": return .urgentLow
        case "low": return .low
        case "high": return .high
        case "forecastedLow": return .predictedLow
        default: return nil
        }
    }

    /// Forwards Trio's immediate glucose alerts. Trio's mute drops non-critical
    /// alerts before they get here, so critical ones reach the watch while muted,
    /// as they reach the phone.
    func alertManager(didIssue alert: Alert, muted _: Bool) {
        guard let manager = smartwatchManager, manager.effectiveCapabilities.contains(.alerts) else { return }
        let content = alert.foregroundContent ?? alert.backgroundContent
        guard let glucoseAlertType = Self.glucoseAlertType(of: alert.identifier) else {
            log(manager, .delegate, "\(content.title) not sent to the watch: only glucose alerts are forwarded")
            return
        }
        guard case .immediate = alert.trigger else {
            log(manager, .delegate, "\(content.title) not sent to the watch: only immediate alerts are forwarded")
            return
        }
        let level: SmartwatchAlertLevel = switch alert.interruptionLevel {
        case .active: .informational
        case .timeSensitive: .warning
        case .critical: .critical
        }
        let watchAlert = SmartwatchAlert(
            identifier: SmartwatchAlertIdentifier(alert.identifier.value),
            level: level,
            title: content.title,
            body: content.body,
            issuedAt: Date(),
            glucoseAlertType: glucoseAlertType
        )
        Task { @MainActor in manager.watchAlertDidIssue(watchAlert) }
    }

    func alertManager(didRetract identifier: Alert.Identifier) {
        guard let manager = smartwatchManager,
              type(of: manager).capabilities.contains(.alerts),
              Self.glucoseAlertType(of: identifier) != nil
        else { return }
        Task { @MainActor in manager.watchAlertDidRetract(SmartwatchAlertIdentifier(identifier.value)) }
    }
}

// MARK: - SmartwatchManagerDelegate

extension BaseSmartwatchHost: SmartwatchManagerDelegate {
    func smartwatchManagerDidUpdateState(_ manager: SmartwatchManager) {
        rawSmartwatchManager = Self.rawValue(of: manager)
    }

    func smartwatchManagerWantsDeletion(_ manager: SmartwatchManager) async {
        await MainActor.run {
            debug(.watch, "Watch manager \(manager.pluginIdentifier) wants deletion")
            UserDefaults.standard.resetSmartwatchPermissions()
            smartwatchManager = nil
        }
    }

    func smartwatchManagerRequestsRefresh(_: SmartwatchManager) {
        Task { @MainActor in self.refresh() }
    }

    func smartwatchManager(_ manager: SmartwatchManager, didLogEvent event: SmartwatchDeviceLogEntry) {
        let type: DeviceLogEntryType = switch event.type {
        case .send: .send
        case .receive: .receive
        case .error: .error
        case .delegate: .delegate
        case .delegateResponse: .delegateResponse
        case .connection: .connection
        }
        log(manager, type, event.message, device: event.deviceIdentifier)
    }

    /// Trio doesn't take boluses, carbs or mute from watch plugins yet.
    func smartwatchManager(_ manager: SmartwatchManager, requestBolus _: SmartwatchBolusRequest) async throws -> Double {
        log(manager, .error, "Bolus request from the watch refused: Trio doesn't take boluses from watch plugins")
        throw SmartwatchBolusError.notAllowed
    }

    func smartwatchManager(_ manager: SmartwatchManager, requestOverride request: SmartwatchOverrideRequest) async throws {
        try await handlePresetRequest(
            kind: "Override",
            action: request.action,
            requestedAt: request.requestedAt,
            capability: .remoteOverride,
            isAllowed: UserDefaults.standard.allowSmartwatchOverrides,
            from: manager,
            activate: { try await self.adjustmentManager.activateOverride(.presetID($0), source: .watch) },
            cancel: { try await self.adjustmentManager.cancelOverride(source: .watch) }
        )
    }

    func smartwatchManager(_ manager: SmartwatchManager, requestTempTarget request: SmartwatchTempTargetRequest) async throws {
        try await handlePresetRequest(
            kind: "Temp target",
            action: request.action,
            requestedAt: request.requestedAt,
            capability: .remoteTempTarget,
            isAllowed: UserDefaults.standard.allowSmartwatchTempTargets,
            from: manager,
            activate: { try await self.adjustmentManager.activateTempTarget(.presetID($0), source: .watch) },
            cancel: { try await self.adjustmentManager.cancelTempTarget(source: .watch) }
        )
    }

    /// How long a request from the watch stays valid after the user confirmed it.
    static let maximumRequestAge: TimeInterval = 30
    /// How far ahead of the phone the watch's clock may run.
    static let maximumClockSkew: TimeInterval = 5

    /// Starts or ends a preset through the same path as Trio's Apple Watch app, only
    /// for the current watch, with the capability and the user's permission, and for
    /// requests confirmed in the last 30 seconds.
    private func handlePresetRequest(
        kind: String,
        action: SmartwatchPresetAction,
        requestedAt: Date,
        capability: SmartwatchCapabilities,
        isAllowed: Bool,
        from manager: SmartwatchManager,
        activate: (String) async throws -> AdjustmentOutcome,
        cancel: () async throws -> AdjustmentOutcome
    ) async throws {
        let description = switch action {
        case let .activate(presetID): "start preset \(presetID)"
        case .cancel: "end the running one"
        }
        log(manager, .receive, "\(kind) request: \(description), confirmed at \(requestedAt)")
        let isCurrentWatch = smartwatchManager.map { ($0 as AnyObject) === (manager as AnyObject) } ?? false
        let refusal: String? = if !isCurrentWatch {
            "the request isn't from the current watch"
        } else if !manager.effectiveCapabilities.contains(capability) {
            "this watch doesn't declare \(capability)"
        } else if !isAllowed {
            "it isn't allowed in the Watch settings"
        } else {
            nil
        }
        if let refusal {
            log(manager, .error, "\(kind) request rejected: notAllowed (\(refusal))")
            throw SmartwatchPresetError.notAllowed
        }
        let age = Date().timeIntervalSince(requestedAt)
        guard age <= Self.maximumRequestAge, age >= -Self.maximumClockSkew else {
            log(manager, .error, String(format: "%@ request rejected: expiredRequest (confirmed %.0f s ago)", kind, age))
            throw SmartwatchPresetError.expiredRequest
        }
        do {
            switch action {
            case let .activate(presetID):
                let outcome = try await activate(presetID)
                log(manager, .delegateResponse, "\(kind) \"\(outcome.started?.name ?? presetID)\" started from the watch")
            case .cancel:
                _ = try await cancel()
                log(manager, .delegateResponse, "\(kind) ended from the watch")
            }
        } catch AdjustmentError.presetNotFound {
            log(manager, .error, "\(kind) request rejected: unknownPreset")
            throw SmartwatchPresetError.unknownPreset
        } catch {
            log(manager, .error, "\(kind) request from the watch failed: \(error)")
            throw SmartwatchPresetError.failed(String(describing: error))
        }
        Task { @MainActor in self.refresh() }
    }
}

extension UserDefaults {
    /// Whether a watch plugin with `.remoteOverride` may start and end overrides. Off by default.
    static let allowSmartwatchOverridesKey = "Trio.smartwatch.allowOverrides"
    /// Whether a watch plugin with `.remoteTempTarget` may start and end temp targets. Off by default.
    static let allowSmartwatchTempTargetsKey = "Trio.smartwatch.allowTempTargets"

    var allowSmartwatchOverrides: Bool { bool(forKey: Self.allowSmartwatchOverridesKey) }
    var allowSmartwatchTempTargets: Bool { bool(forKey: Self.allowSmartwatchTempTargetsKey) }

    /// Turns the permissions off, so a new watch plugin never inherits what the
    /// user granted another one.
    func resetSmartwatchPermissions() {
        set(false, forKey: Self.allowSmartwatchOverridesKey)
        set(false, forKey: Self.allowSmartwatchTempTargetsKey)
    }
}

// MARK: - SmartwatchManagerOnboardingDelegate

extension BaseSmartwatchHost: SmartwatchManagerOnboardingDelegate {
    func smartwatchManagerOnboarding(didCreateSmartwatchManager manager: SmartwatchManagerUI) {
        debug(.watch, "Watch manager \(manager.pluginIdentifier) created")
        UserDefaults.standard.resetSmartwatchPermissions()
        smartwatchManager = manager
    }

    func smartwatchManagerOnboarding(didOnboardSmartwatchManager manager: SmartwatchManagerUI) {
        debug(.watch, "Watch manager \(manager.pluginIdentifier) onboarded")
        Task { @MainActor in self.refresh() }
    }
}

extension BloodGlucose.Direction {
    /// The same trend arrow as LoopKit's `GlucoseTrend`.
    var smartwatchTrend: SmartwatchGlucoseTrend? {
        switch self {
        case .doubleUp,
             .tripleUp: .upUpUp
        case .singleUp: .upUp
        case .fortyFiveUp: .up
        case .flat: .flat
        case .fortyFiveDown: .down
        case .singleDown: .downDown
        case .doubleDown,
             .tripleDown: .downDownDown
        case .none,
             .notComputable,
             .rateOutOfRange: nil
        }
    }
}
