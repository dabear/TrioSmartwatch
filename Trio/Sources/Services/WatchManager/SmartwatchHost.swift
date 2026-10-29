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

    /// Trio doesn't take remote actions from watch plugins yet.
    func smartwatchManager(_ manager: SmartwatchManager, requestBolus _: SmartwatchBolusRequest) async throws -> Double {
        log(manager, .error, "Bolus request from the watch refused: Trio doesn't take boluses from watch plugins")
        throw SmartwatchBolusError.notAllowed
    }
}

// MARK: - SmartwatchManagerOnboardingDelegate

extension BaseSmartwatchHost: SmartwatchManagerOnboardingDelegate {
    func smartwatchManagerOnboarding(didCreateSmartwatchManager manager: SmartwatchManagerUI) {
        debug(.watch, "Watch manager \(manager.pluginIdentifier) created")
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
