import Combine
import Foundation
import LoopKit
import LoopKitUI
import SwiftUI
import Swinject
import UIKit

// Experimental: Garmin as a SmartwatchManager plugin. The Connect IQ transport stays in
// BaseGarminManager; it gets Trio's state only from the plugin's snapshots and sends
// commands only through the plugin's delegate (SmartwatchHost), like any other plugin.

/// Carries the latest snapshot and the plugin between the plugin, which SmartwatchHost
/// creates, and the Connect IQ singleton, which the app creates.
final class GarminSmartwatchBridge {
    private let lock = NSLock()
    private var _snapshot: SmartwatchStatusSnapshot?
    private var _snapshotCount = 0
    private weak var _manager: GarminSmartwatchManager?

    /// Every new snapshot, and `nil` when the plugin is removed.
    let snapshotUpdates = PassthroughSubject<SmartwatchStatusSnapshot?, Never>()

    var snapshot: SmartwatchStatusSnapshot? { lock.withLock { _snapshot } }
    var manager: GarminSmartwatchManager? { lock.withLock { _manager } }
    var snapshotCount: Int { lock.withLock { _snapshotCount } }

    func attach(_ manager: GarminSmartwatchManager) {
        lock.withLock { _manager = manager }
    }

    func detach(_ manager: GarminSmartwatchManager) {
        lock.withLock {
            guard _manager === manager else { return }
            _manager = nil
            _snapshot = nil
        }
        snapshotUpdates.send(nil)
    }

    func publish(_ snapshot: SmartwatchStatusSnapshot) {
        lock.withLock {
            _snapshot = snapshot
            _snapshotCount += 1
        }
        snapshotUpdates.send(snapshot)
    }

    /// Asks the host for a snapshot and waits for it; `nil` after `timeout`.
    func nextSnapshot(timeout: TimeInterval) async -> SmartwatchStatusSnapshot? {
        let start = snapshotCount
        if let manager {
            manager.smartwatchManagerDelegate?.smartwatchManagerRequestsRefresh(manager)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if snapshotCount != start { return snapshot }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }
}

/// Garmin watchfaces, data fields and command apps, as a SmartwatchManager plugin.
final class GarminSmartwatchManager: SmartwatchManagerUI {
    static let pluginIdentifier = "GarminSmartwatchManager"
    static let localizedTitle = String(localized: "Garmin", comment: "Title of the Garmin watch plugin")

    var pluginIdentifier: String { Self.pluginIdentifier }
    var localizedTitle: String { Self.localizedTitle }

    weak var smartwatchManagerDelegate: SmartwatchManagerDelegate?

    static var capabilities: SmartwatchCapabilities {
        [.glucose, .history, .loopStatus, .therapy, .remoteBolus, .remoteCarbs, .remoteOverride, .remoteTempTarget]
    }

    /// Garmin's own command rules: a 2 minute window with 60 s for a watch clock running
    /// ahead, any amount up to the maximum bolus (the Garmin apps neither show the
    /// recommendation nor send a context token back), 6 minutes between watch boluses and
    /// no carb interval. The host's own checks still apply: Trio's max bolus, max IOB and
    /// recent-bolus check, and a glucose reading in the last 15 minutes.
    var remoteActionLimits: SmartwatchRemoteActionLimits {
        SmartwatchRemoteActionLimits(
            requestWindow: SmartwatchRequestWindow(maximumAge: 2 * 60, maximumClockSkew: 60),
            bolus: SmartwatchBolusPolicy.Limits(
                minimumInterval: 6 * 60,
                dailyLimitInMaximumBoluses: .infinity,
                requiresContextToken: false,
                capsAtRecommendation: false
            ),
            carbEntry: SmartwatchCarbEntryPolicy.Limits(minimumInterval: 0)
        )
    }

    private let bridge: GarminSmartwatchBridge

    convenience init?(rawState _: RawStateValue) {
        guard let bridge = TrioApp.resolver.resolve(GarminSmartwatchBridge.self) else { return nil }
        self.init(bridge: bridge)
    }

    init(bridge: GarminSmartwatchBridge) {
        self.bridge = bridge
        bridge.attach(self)
    }

    /// Devices and app choices are still kept by BaseGarminManager and TrioSettings.
    var rawState: RawStateValue { [:] }

    var isOnboarded: Bool { true }

    @MainActor func watchDataDidUpdate(_ snapshot: SmartwatchStatusSnapshot) {
        bridge.publish(snapshot)
    }

    func delete(completion: @escaping () -> Void) {
        bridge.detach(self)
        notifyDelegateOfDeletion(completion: completion)
    }

    var debugDescription: String {
        "## GarminSmartwatchManager\n* attached: \(bridge.manager === self)"
    }

    // MARK: - DeviceManager

    func acknowledgeAlert(alertIdentifier _: LoopKit.Alert.AlertIdentifier) async throws {}
    func acknowledgeAlert(alertIdentifier _: LoopKit.Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    func getSoundBaseURL() -> URL? { nil }
    func getSounds() -> [LoopKit.Alert.Sound] { [] }

    // MARK: - UI

    static var onboardingImage: UIImage? { UIImage(systemName: "applewatch.side.right") }
    var smallImage: UIImage? { Self.onboardingImage }

    /// Devices and apps are picked in Trio's Garmin settings, so setup only adds the plugin.
    @MainActor static func setupViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference _: DisplayGlucosePreference,
        colorPalette _: LoopUIColorPalette,
        allowDebugFeatures _: Bool
    ) -> SetupUIResult<SmartwatchManagerViewController, SmartwatchManagerUI> {
        guard let manager = GarminSmartwatchManager(rawState: [:]) else {
            return .userInteractionRequired(GarminSmartwatchSettingsController(manager: nil))
        }
        return .createdAndOnboarded(manager)
    }

    @MainActor func settingsViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference _: DisplayGlucosePreference,
        colorPalette _: LoopUIColorPalette,
        allowDebugFeatures _: Bool
    ) -> SmartwatchManagerViewController {
        GarminSmartwatchSettingsController(manager: self)
    }
}

/// Points to Trio's Garmin settings and removes the plugin.
final class GarminSmartwatchSettingsController: UINavigationController, SmartwatchManagerOnboarding, CompletionNotifying {
    weak var smartwatchManagerOnboardingDelegate: SmartwatchManagerOnboardingDelegate?
    weak var completionDelegate: CompletionDelegate?

    init(manager: GarminSmartwatchManager?) {
        super.init(nibName: nil, bundle: nil)
        let view = GarminSmartwatchSettingsView(manager: manager) { [weak self] in
            guard let self else { return }
            self.completionDelegate?.completionNotifyingDidComplete(self)
        }
        setViewControllers([UIHostingController(rootView: view)], animated: false)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct GarminSmartwatchSettingsView: View {
    let manager: GarminSmartwatchManager?
    let done: () -> Void

    var body: some View {
        List {
            Section(
                footer: Text(
                    "Garmin devices, the watchface, the data field and the command app are picked in Trio's Watch settings, under Garmin. What the watch may do is set by the Allow switches for this watch."
                )
            ) {
                Text(GarminSmartwatchManager.localizedTitle)
            }
            if let manager {
                Section {
                    Button(role: .destructive) {
                        manager.delete(completion: done)
                    } label: {
                        Text("Remove Garmin")
                    }
                }
            }
        }
        .navigationTitle(GarminSmartwatchManager.localizedTitle)
        .toolbar { Button("Done", action: done) }
    }
}

// MARK: - Commands and presets through the plugin

/// Runs Garmin commands through the plugin's delegate. The host applies its permissions,
/// the plugin's limits and its own safety checks; this keeps Garmin's own concerns: one run
/// per request ID, the command-owner app, and the acks the Garmin apps expect.
final class SmartwatchWatchCommandProcessor: WatchCommandProcessor, Injectable {
    @Injected() private var bridge: GarminSmartwatchBridge!
    @Injected() private var settingsManager: SettingsManager!

    private let cache = WatchCommandRequestCache()
    private let log: WatchCommandLogger
    /// How long a meal's bolus waits for the snapshot that counts its carbs.
    static let mealSnapshotTimeout: TimeInterval = 15

    init(resolver: Resolver, log: WatchCommandLogger = .app) {
        self.log = log
        injectServices(resolver)
    }

    func process(_ request: WatchCommandRequest) async -> WatchCommandResult {
        let key = WatchCommandRequestCache.Key(appUUID: request.appUUID, requestID: request.requestID)
        switch await cache.admit(key, command: request.command, now: Date()) {
        case let .completed(result):
            log.debug("Watch \(request.command.name) command repeated, sending the earlier result again")
            return result
        case .inProgress:
            return WatchCommandResult(
                acknowledged: false,
                ackCode: .inProgress,
                message: String(localized: "Request is already in progress.", comment: "Watch command ack")
            )
        case .conflict:
            log.warning("Watch \(request.command.name) command refused, its request ID was already used for another command")
            return .failure(String(localized: "Request ID was already used.", comment: "Watch command ack"))
        case .full:
            return .failure(String(localized: "Too many requests in progress. Please try again.", comment: "Watch command ack"))
        case let .accepted(ticket):
            let result = await execute(request)
            await cache.complete(ticket, result: result)
            return result
        }
    }

    func capabilities() -> WatchCommandCapabilities {
        let snapshot = bridge.snapshot
        let permitted = snapshot?.permittedActions ?? []
        return WatchCommandCapabilities(
            isCommandControlEnabled: !permitted
                .isDisjoint(with: [.remoteCarbs, .remoteBolus, .remoteOverride, .remoteTempTarget]),
            isBolusCommandEnabled: permitted.contains(.remoteBolus),
            maxBolus: Decimal(snapshot?.bolusContext?.maximumBolus ?? 0),
            maxCarbs: Decimal(snapshot?.maximumCarbEntry ?? 0),
            bolusIncrement: Decimal(snapshot?.bolusIncrement ?? 0)
        )
    }

    private func execute(_ request: WatchCommandRequest) async -> WatchCommandResult {
        guard GarminCommandApp(settingsManager.settings.garminSettings).appUUID == request.appUUID else {
            log.info("Garmin \(request.command.name) command refused, sent by an app that is not the command app")
            return .failure(String(localized: "Commands are handled by another watch app.", comment: "Watch command ack"))
        }
        guard let manager = bridge.manager, let delegate = manager.smartwatchManagerDelegate else {
            return .failure(String(localized: "Add Garmin as the watch in Trio first.", comment: "Watch command ack"))
        }
        let date = request.date
        switch request.command {
        case let .carbs(grams):
            return await carbs(grams, date: date, manager: manager, delegate: delegate)
        case let .bolus(units):
            return await bolus(units, date: date, snapshot: bridge.snapshot, manager: manager, delegate: delegate)
        case let .mealBolus(grams, units):
            let carbsResult = await carbs(grams, date: date, manager: manager, delegate: delegate)
            guard carbsResult.acknowledged else {
                return .failure(String(localized: "Could not log carbs. No bolus was delivered.", comment: "Watch command ack"))
            }
            // The bolus is checked against the snapshot that counts the new carbs.
            let snapshot = await bridge.nextSnapshot(timeout: Self.mealSnapshotTimeout) ?? bridge.snapshot
            let bolusResult = await bolus(units, date: date, snapshot: snapshot, manager: manager, delegate: delegate)
            guard bolusResult.acknowledged else {
                return WatchCommandResult(
                    acknowledged: false,
                    ackCode: .partialFailure,
                    message: String(localized: "Carbs logged. No bolus was delivered.", comment: "Watch command ack")
                )
            }
            return .success(.genericSuccess, String(localized: "Carbs logged and bolus started.", comment: "Watch command ack"))
        case let .activateOverride(name):
            guard let match = Self.uniquePreset(named: name, in: bridge.snapshot?.overridePresets) else {
                return .failure(String(localized: "Preset not found.", comment: "Watch command ack"))
            }
            return await preset(.override, .activate(presetID: match.id), date: date, manager: manager, delegate: delegate)
        case .cancelOverride:
            return await preset(.override, .cancel, date: date, manager: manager, delegate: delegate)
        case let .activateTempTarget(name):
            guard let match = Self.uniquePreset(named: name, in: bridge.snapshot?.tempTargetPresets) else {
                return .failure(String(localized: "Preset not found.", comment: "Watch command ack"))
            }
            return await preset(.tempTarget, .activate(presetID: match.id), date: date, manager: manager, delegate: delegate)
        case .cancelTempTarget:
            return await preset(.tempTarget, .cancel, date: date, manager: manager, delegate: delegate)
        }
    }

    private func carbs(
        _ grams: Int,
        date: Date,
        manager: GarminSmartwatchManager,
        delegate: SmartwatchManagerDelegate
    ) async -> WatchCommandResult {
        do {
            _ = try await delegate.smartwatchManager(
                manager,
                requestCarbEntry: SmartwatchCarbEntryRequest(grams: Double(grams), requestedAt: date)
            )
            return .success(.carbsLogged, String(localized: "Carbs logged.", comment: "Watch command ack"))
        } catch {
            log.info("Garmin carbs command refused by the host (\(error))")
            return .failure(Self.message(for: error))
        }
    }

    private func bolus(
        _ units: Decimal,
        date: Date,
        snapshot: SmartwatchStatusSnapshot?,
        manager: GarminSmartwatchManager,
        delegate: SmartwatchManagerDelegate
    ) async -> WatchCommandResult {
        // The Garmin apps send no context token; the plugin's limits say so, and the host
        // checks against its current context.
        guard let context = snapshot?.bolusContext else {
            return .failure(String(localized: "Bolus from watch is not available yet.", comment: "Watch command ack"))
        }
        let request = SmartwatchBolusRequest(
            units: NSDecimalNumber(decimal: units).doubleValue,
            contextToken: context.token,
            requestedAt: date
        )
        do {
            _ = try await delegate.smartwatchManager(manager, requestBolus: request)
            return .success(.genericSuccess, String(localized: "Bolus started.", comment: "Watch command ack"))
        } catch SmartwatchBolusError.inProgress {
            return WatchCommandResult(
                acknowledged: false,
                ackCode: .inProgress,
                message: String(localized: "Request is already in progress.", comment: "Watch command ack")
            )
        } catch SmartwatchBolusError.deliveryFailed {
            return .failure(String(localized: "Bolus failed. Check pump history before repeating.", comment: "Watch command ack"))
        } catch {
            log.info("Garmin bolus command refused by the host (\(error))")
            return .failure(Self.message(for: error))
        }
    }

    private enum PresetKind { case override, tempTarget }

    private func preset(
        _ kind: PresetKind,
        _ action: SmartwatchPresetAction,
        date: Date,
        manager: GarminSmartwatchManager,
        delegate: SmartwatchManagerDelegate
    ) async -> WatchCommandResult {
        do {
            switch kind {
            case .override:
                try await delegate.smartwatchManager(
                    manager,
                    requestOverride: SmartwatchOverrideRequest(action: action, requestedAt: date)
                )
            case .tempTarget:
                try await delegate.smartwatchManager(
                    manager,
                    requestTempTarget: SmartwatchTempTargetRequest(action: action, requestedAt: date)
                )
            }
        } catch {
            log.info("Garmin preset command refused by the host (\(error))")
            return .failure(Self.message(for: error))
        }
        switch (kind, action) {
        case (.override, .activate):
            return .success(.overrideStarted, String(localized: "Override started.", comment: "Watch command ack"))
        case (.override, .cancel):
            return .success(.overrideStopped, String(localized: "Override stopped.", comment: "Watch command ack"))
        case (.tempTarget, .activate):
            return .success(.tempTargetStarted, String(localized: "Temp target started.", comment: "Watch command ack"))
        case (.tempTarget, .cancel):
            return .success(.tempTargetStopped, String(localized: "Temp target stopped.", comment: "Watch command ack"))
        }
    }

    /// Exact, case-sensitive and unique, as the Garmin series matches names.
    static func uniquePreset(named name: String, in presets: [SmartwatchPreset]?) -> SmartwatchPreset? {
        let matches = (presets ?? []).filter { $0.name == name }
        return matches.count == 1 ? matches.first : nil
    }

    /// Short text for the watch; never amounts or internal details.
    static func message(for error: Error) -> String {
        switch error {
        case SmartwatchBolusError.notAllowed,
             SmartwatchCarbEntryError.notAllowed,
             SmartwatchPresetError.notAllowed:
            return String(localized: "Not allowed from this watch in Trio.", comment: "Watch command ack")
        case SmartwatchBolusError.expiredRequest,
             SmartwatchCarbEntryError.expiredRequest,
             SmartwatchPresetError.expiredRequest:
            return String(localized: "Command expired. Please try again.", comment: "Watch command ack")
        case SmartwatchBolusError.noRecentGlucose:
            return String(localized: "No recent glucose. Bolus not delivered.", comment: "Watch command ack")
        case SmartwatchBolusError.exceedsMaximumBolus:
            return String(localized: "Bolus exceeds max bolus.", comment: "Watch command ack")
        case SmartwatchBolusError.rateLimited,
             SmartwatchCarbEntryError.rateLimited:
            return String(localized: "Too soon after the last watch command.", comment: "Watch command ack")
        case SmartwatchBolusError.dailyLimitReached:
            return String(localized: "Daily watch bolus limit reached.", comment: "Watch command ack")
        case SmartwatchBolusError.refusedByHost:
            return String(localized: "Refused by Trio's bolus safety checks.", comment: "Watch command ack")
        case SmartwatchCarbEntryError.exceedsMaximum:
            return String(localized: "Carbs exceed the maximum allowed.", comment: "Watch command ack")
        case SmartwatchBolusError.invalidAmount,
             SmartwatchCarbEntryError.invalidAmount:
            return String(localized: "Invalid amount.", comment: "Watch command ack")
        case SmartwatchPresetError.unknownPreset:
            return String(localized: "Preset not found.", comment: "Watch command ack")
        default:
            return String(localized: "Command failed.", comment: "Watch command ack")
        }
    }
}

/// The presets a Garmin command app shows, from the plugin's snapshot.
final class SmartwatchWatchPresetsProvider: WatchPresetsProvider, Injectable {
    @Injected() private var bridge: GarminSmartwatchBridge!

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    func overridePresets() async throws -> [WatchPresetEntry] {
        (bridge.snapshot?.overridePresets ?? [])
            .map { WatchPresetEntry(name: $0.name, isActive: $0.isActive, ref: .presetID($0.id)) }
    }

    func tempTargetPresets() async throws -> [WatchPresetEntry] {
        (bridge.snapshot?.tempTargetPresets ?? [])
            .map { WatchPresetEntry(name: $0.name, isActive: $0.isActive, ref: .presetID($0.id)) }
    }
}
