import Combine
import ConnectIQ
import CoreData
import Foundation
import LoopKit
import Swinject

// MARK: - GarminManager Protocol

/// Manages Garmin devices, allowing the app to select devices, update a known device list,
/// and send watch-state data to connected Garmin watch apps.
protocol GarminManager {
    /// Prompts the user to select Garmin devices, returning the chosen devices in a publisher.
    /// - Returns: A publisher that eventually outputs an array of selected `IQDevice` objects.
    func selectDevices() -> AnyPublisher<[IQDevice], Never>

    /// Updates the currently tracked device list. This typically persists the device list and
    /// triggers re-registration for any relevant ConnectIQ events.
    /// - Parameter devices: The new array of `IQDevice` objects to track.
    func updateDeviceList(_ devices: [IQDevice])

    /// Takes raw JSON-encoded watch-state data and dispatches it to any connected watch apps.
    /// - Parameter data: The JSON-encoded data representing the watch state.
    func sendWatchStateData(_ data: Data)

    /// The devices currently known to the app. May be loaded from disk or user selection.
    var devices: [IQDevice] { get }
}

// MARK: - Connect IQ Client

/// The Connect IQ calls that register and reach watch apps, behind a protocol so delivery can be tested
/// without a watch. There is deliberately no app-status call: each one is a BLE round trip to the watch.
protocol GarminConnectIQClient: AnyObject {
    func registerDevice(_ device: IQDevice, delegate: IQDeviceEventDelegate)
    func registerApp(_ app: IQApp, delegate: IQAppMessageDelegate)
    func send(_ message: Any, to app: IQApp, completion: @escaping (IQSendMessageResult) -> Void)
}

extension ConnectIQ: GarminConnectIQClient {
    func registerDevice(_ device: IQDevice, delegate: IQDeviceEventDelegate) {
        register(forDeviceEvents: device, delegate: delegate)
    }

    func registerApp(_ app: IQApp, delegate: IQAppMessageDelegate) {
        register(forAppMessages: app, delegate: delegate)
    }

    func send(_ message: Any, to app: IQApp, completion: @escaping (IQSendMessageResult) -> Void) {
        sendMessage(message, to: app, progress: { _, _ in }, completion: completion)
    }
}

// MARK: - BaseGarminManager

/// Concrete implementation of `GarminManager` that handles:
///  - Device registration/unregistration with Garmin ConnectIQ
///  - Data persistence for selected devices
///  - Generating & sending watch-state updates (glucose, IOB, COB, etc.) to Garmin watch apps.
final class BaseGarminManager: NSObject, GarminManager, Injectable {
    // MARK: - Dependencies & Properties

    /// Observes system-wide notifications, including `.openFromGarminConnect`.
    @Injected() private var notificationCenter: NotificationCenter!

    /// Broadcaster used for publishing or subscribing to global events (e.g., unit changes).
    @Injected() private var broadcaster: Broadcaster!

    /// APSManager containing insulin pump logic, e.g., for making bolus requests, reading basal info, etc.

    /// Manages local user settings, such as glucose units (mg/dL or mmol/L).
    @Injected() private var settingsManager: SettingsManager!

    /// Stores, retrieves, and updates glucose data in CoreData.

    /// Stores, retrieves, and updates insulin dose determinations in CoreData.

    /// JSON settings store, used here to read the glucose target profile.

    @Injected() private var trioAlertManager: TrioAlertManager!
    @Injected() private var presetsProvider: WatchPresetsProvider!
    @Injected() private var watchCommandProcessor: WatchCommandProcessor!

    /// The plugin side: the latest snapshot from SmartwatchHost, and the delegate for commands.
    @Injected() private var smartwatchBridge: GarminSmartwatchBridge!

    /// The permissions and presets of the last snapshot, so a change reaches the command app.
    private var lastCommandInfo: CommandInfo?

    /// Persists the user's device list between app launches.
    @Persisted(key: "BaseGarminManager.persistedDevices") private var persistedDevices: [GarminDevice] = []

    /// Router for presenting alerts or navigation flows (injected via Swinject).
    private let router: Router

    /// Garmin ConnectIQ shared instance for watch interactions.
    private let connectIQ = ConnectIQ.sharedInstance()

    /// Registers and messages watch apps; the shared `connectIQ` unless a test injects a spy.
    private let connectIQClient: GarminConnectIQClient?

    /// Wait before the single resend of a failed message.
    private let sendRetryDelay: TimeInterval

    private let broadcastDebounce: DispatchQueue.SchedulerTimeType.Stride

    /// Keeps references to watch apps (both watchface & data field) for each registered device.
    private var watchApps: [IQApp] = []

    /// A set of Combine cancellables for managing the lifecycle of various subscriptions.
    private var cancellables = Set<AnyCancellable>()

    /// Holds a promise used when the user is selecting devices (via `showDeviceSelection()`).
    private var deviceSelectionPromise: Future<[IQDevice], Never>.Promise?

    /// Subject for debouncing watch state updates
    private let watchStateSubject = PassthroughSubject<Data, Never>()

    /// Publishes the trigger name of every watch state refresh that is started.
    let stateRefreshTriggers = PassthroughSubject<String, Never>()

    /// Current glucose units, either mg/dL or mmol/L, read from user settings.
    private var units: GlucoseUnits = .mgdL

    /// Glucose color scheme, read from user settings and forwarded to watch apps
    /// that can color glucose themselves.
    private var glucoseColorScheme: GlucoseColorScheme = .staticColor

    // MARK: - Debug Logging

    /// Enable/disable watch state preparation and throttling logs:
    /// - Glucose/IOB received, waiting for determination
    /// - Determination arrived, cancelled timer
    /// - Preparing/Prepared watch state, Skipping - data unchanged
    /// - Settings throttle timer started/running/fired
    private let debugWatchState = true

    /// Enable/disable watch status and communication logs:
    /// - Device status changes (connected, notConnected, etc.)
    /// - Registered watchface/datafield
    /// - Sending to / Successfully sent
    /// - Watchface/datafield config changed
    private let debugGarminEnabled = true

    /// Helper method for conditional watch status/comms logging.
    /// Logs messages only if debugGarminEnabled is true.
    /// - Parameter message: The debug message to log.
    private func debugGarmin(_ message: String) {
        guard debugGarminEnabled else { return }
        debug(.watch, message)
    }

    // MARK: - Delivery

    /// What an app is still owed after its send failed for good; latest state wins. Main queue only.
    private struct OwedDelivery {
        var stateHash: Int?
        var pushesPresets = false
        var announcesCommandApp = false
    }

    /// The send result is the readiness signal: readiness never gates a send, because a missed
    /// characteristics callback would otherwise block delivery until the next reconnect.
    private var owedDeliveries: [String: OwedDelivery] = [:]

    /// Apps that answered `AppNotFound`, skipped until re-registration or a message from them.
    private var absentApps: Set<String> = []

    /// The only send gate, owned by the SDK's device status callbacks.
    private var disconnectedDevices: Set<UUID> = []

    /// Latest broadcast payload, redelivered to apps that are owed state.
    private var lastBroadcast: (payload: Any, hash: Int)?

    // MARK: - Deduplication

    /// Hash of the last state each app confirmed receiving, keyed by `deliveryKey(for:)`.
    private var lastSentDataHashes: [String: Int] = [:]

    /// Hash of last prepared data to skip redundant preparation
    private var lastPreparedDataHash: Int?
    private var lastPreparedWatchState: [GarminWatchState]?

    // MARK: - Settings Change Throttle

    /// Queue for the settings throttle timer
    private let timerQueue = DispatchQueue(label: "BaseGarminManager.timerQueue", qos: .utility)

    /// Track previous Garmin settings to detect what specifically changed
    private var previousGarminSettings = GarminWatchSettings()

    /// Pending settings update task - waits for user to finish making changes
    private var pendingSettingsUpdate: DispatchWorkItem?

    /// Latest settings data to send when throttle timer fires
    private var pendingSettingsData: Data?

    /// How long to wait for additional settings changes before sending (seconds)
    private let settingsThrottleDuration: TimeInterval = 10

    // MARK: - Subscriptions

    /// Snapshot and preset subscriptions (separate from `cancellables`).
    private var subscriptions = Set<AnyCancellable>()

    /// Array of Garmin `IQDevice` objects currently tracked.
    /// Changing this property triggers re-registration and updates persisted devices.
    private(set) var devices: [IQDevice] = [] {
        didSet {
            // Persist newly updated device list
            persistedDevices = devices.map(GarminDevice.init)
            // Re-register for events, app messages, etc.
            registerDevices(devices)
        }
    }

    // MARK: - Initialization

    /// Creates a new `BaseGarminManager`, injecting required services, restoring any persisted devices,
    /// and setting up watchers for data changes (e.g., glucose updates).
    /// - Parameters:
    ///   - resolver: Swinject resolver for injecting dependencies like the Router.
    ///   - connectIQClient: Replaces the Connect IQ SDK for registration and sending.
    ///   - presetChanges: Replaces the Core Data preset change signal.
    ///   - sendRetryDelay: Wait before resending a failed message.
    ///   - broadcastDebounce: Quiet time before a state broadcast goes out.
    init(
        resolver: Resolver,
        connectIQClient: GarminConnectIQClient? = nil,
        presetChanges: AnyPublisher<Void, Never>? = nil,
        sendRetryDelay: TimeInterval = 2,
        broadcastDebounce: DispatchQueue.SchedulerTimeType.Stride = .seconds(2)
    ) {
        router = resolver.resolve(Router.self)!
        self.connectIQClient = connectIQClient ?? ConnectIQ.sharedInstance()
        self.sendRetryDelay = sendRetryDelay
        self.broadcastDebounce = broadcastDebounce
        super.init()
        injectServices(resolver)

        connectIQ?.initialize(withUrlScheme: "Trio", uiOverrideDelegate: self)

        restoreDevices()

        subscribeToOpenFromGarminConnect()
        subscribeToWatchState()

        units = settingsManager.settings.units
        glucoseColorScheme = settingsManager.settings.glucoseColorScheme
        previousGarminSettings = settingsManager.settings.garminSettings

        broadcaster.register(SettingsObserver.self, observer: self)

        // Trio's state arrives only as the plugin's snapshots: SmartwatchHost sends one on
        // every new reading and loop result, so there is nothing to coordinate here.
        smartwatchBridge.snapshotUpdates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.snapshotDidUpdate(snapshot)
            }
            .store(in: &subscriptions)

        presetChanges?
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.pushPresetsToCommandApp(triggeredBy: "PresetStorage")
            }
            .store(in: &subscriptions)
    }

    /// What the command app is built from; a change is pushed to it.
    private struct CommandInfo: Equatable {
        let permittedActions: SmartwatchCapabilities
        let overridePresets: [SmartwatchPreset]?
        let tempTargetPresets: [SmartwatchPreset]?
        let maximumCarbEntry: Double?
        let maximumBolus: Double?
        let bolusIncrement: Double?
    }

    private func snapshotDidUpdate(_ snapshot: SmartwatchStatusSnapshot?) {
        triggerWatchStateUpdate(triggeredBy: snapshot == nil ? "PluginRemoved" : "Snapshot")
        let info = snapshot.map {
            CommandInfo(
                permittedActions: $0.permittedActions,
                overridePresets: $0.overridePresets,
                tempTargetPresets: $0.tempTargetPresets,
                maximumCarbEntry: $0.maximumCarbEntry,
                maximumBolus: $0.bolusContext?.maximumBolus,
                bolusIncrement: $0.bolusIncrement
            )
        }
        if info != lastCommandInfo {
            lastCommandInfo = info
            pushPresetsToCommandApp(triggeredBy: "Snapshot")
        }
    }

    // MARK: - Settings Helpers

    /// Returns the currently configured Garmin watchface from settings
    private var currentWatchface: GarminWatchface {
        settingsManager.settings.garminSettings.watchface
    }

    /// The only watch app whose commands run, and the only one that gets the preset list.
    private var currentCommandApp: GarminCommandApp {
        GarminCommandApp(settingsManager.settings.garminSettings)
    }

    /// Returns the currently configured Garmin datafield from settings
    private var currentDatafield: GarminDatafield {
        settingsManager.settings.garminSettings.datafield
    }

    /// Returns whether watchface data transmission is enabled in settings
    private var isWatchfaceDataEnabled: Bool {
        settingsManager.settings.garminSettings.isWatchfaceDataEnabled
    }

    /// SwissAlpine watchface and the complication app use historical glucose data (24 entries).
    /// Trio watchface only uses current reading.
    ///
    /// The complication app needs it for the 2 h graph in its own view; the complications
    /// it publishes read only element 0 and work without history.
    private var needsHistoricalGlucoseData: Bool {
        currentWatchface == .swissalpine
            || currentWatchface == .complication
    }

    /// Returns the display name for an app UUID (watchface or datafield).
    /// Use this for routine log messages where UUID adds noise.
    private func appDisplayName(for uuid: UUID) -> String {
        if uuid == currentWatchface.watchfaceUUID {
            return "watchface:\(currentWatchface.displayName)"
        } else if uuid == currentDatafield.datafieldUUID {
            return "datafield:\(currentDatafield.displayName)"
        } else if uuid == GarminWatchControls.appUUID {
            return "watch app:\(GarminWatchControls.displayName)"
        } else {
            return "unknown app"
        }
    }

    /// Returns the detailed display name including UUID for an app.
    /// Use this for registration/connection messages and error scenarios where UUID identification is valuable.
    /// This helps with debugging when multiple versions/distributions exist (local, test, live builds).
    private func appDetailedName(for uuid: UUID) -> String {
        if uuid == currentWatchface.watchfaceUUID {
            return "watchface:\(currentWatchface.displayName) (\(uuid.uuidString))"
        } else if uuid == currentDatafield.datafieldUUID {
            return "datafield:\(currentDatafield.displayName) (\(uuid.uuidString))"
        } else if uuid == GarminWatchControls.appUUID {
            return "watch app:\(GarminWatchControls.displayName) (\(uuid.uuidString))"
        } else {
            return "unknown app (\(uuid.uuidString))"
        }
    }

    // MARK: - Internal Setup / Handlers

    /// Triggers watch state preparation and sends to debounce subject
    /// If triggered by Determination, cancels pending glucose fallback timer
    private func triggerWatchStateUpdate(triggeredBy trigger: String) {
        guard !devices.isEmpty else { return }
        stateRefreshTriggers.send(trigger)

        Task {
            do {
                let watchState = try await setupGarminWatchState(triggeredBy: trigger)
                let watchStateData = try JSONEncoder().encode(watchState)
                watchStateSubject.send(watchStateData)
            } catch {
                warning(.watch, "Preparing Garmin watch state failed, trigger \(trigger)", error: error)
            }
        }
    }

    /// Sends settings update with throttle - waits for user to finish making changes
    /// If timer already running, just updates data without rescheduling
    /// When timer fires, sends the latest collected data
    private func sendSettingsUpdateThrottled() {
        guard !devices.isEmpty else { return }

        // If timer already scheduled, just log and return - data will be fresh when timer fires
        if pendingSettingsUpdate != nil {
            if debugWatchState {
                debug(.watch, "Garmin settings update already scheduled")
            }
            return
        }

        // Create new throttled task
        let throttledTask = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            if self.debugWatchState {
                debug(.watch, "Sending throttled Garmin settings update")
            }

            Task {
                do {
                    let watchState = try await self.setupGarminWatchState(triggeredBy: "Settings")
                    let watchStateData = try JSONEncoder().encode(watchState)
                    self.watchStateSubject.send(watchStateData)
                } catch {
                    warning(.watch, "Preparing Garmin settings update failed", error: error)
                }
            }

            // Clean up
            self.pendingSettingsUpdate = nil
            self.pendingSettingsData = nil
        }

        pendingSettingsUpdate = throttledTask
        timerQueue.asyncAfter(deadline: .now() + settingsThrottleDuration, execute: throttledTask)

        if debugWatchState {
            debug(.watch, "Garmin settings update scheduled in \(Int(settingsThrottleDuration)) s")
        }
    }

    // MARK: - Watch State Setup

    /// Builds an array of GarminWatchState objects containing current glucose, trend, loop data, and historical readings.
    /// Historical data is included for watchfaces that support it (e.g., SwissAlpine).
    /// - Parameter triggeredBy: A string describing what triggered this update (for debugging/logging).
    /// - Returns: An array of `GarminWatchState` objects with the latest watch data.
    func setupGarminWatchState(triggeredBy: String = #function) async throws -> [GarminWatchState] {
        // Skip if no devices connected, or before the plugin's first snapshot
        guard !devices.isEmpty, let snapshot = smartwatchBridge.snapshot else {
            return []
        }

        if debugWatchState {
            debug(.watch, "Preparing Garmin watch state, trigger \(triggeredBy)")
        }

        // Newest first: SwissAlpine needs 24, Trio needs 2 (for delta calculation)
        let history = snapshot.glucoseHistory.isEmpty ? [snapshot.glucose].compactMap { $0 } : snapshot.glucoseHistory
        let readings = Array(history.reversed().prefix(needsHistoricalGlucoseData ? 24 : 2))
        let therapy = snapshot.therapy
        let mgdl = { (value: Double) in Int16(clamping: Int(value.rounded())) }

        // The loop's last run; 31 minutes ago when unknown, so the watchface tells "no data
        // yet" (nil) from "loop is stale"
        let loopDate = snapshot.lastLoopCompleted ?? Date().addingTimeInterval(-31 * 60)
        let unitsHint = snapshot.displayUnit == .milligramsPerDeciliter ? "mgdl" : "mmol"
        // Short form, not the enum raw value: this is the wire format the watchface reads.
        let colorSchemeValue = glucoseColorScheme == .dynamicColor ? "dynamic" : "static"
        let entriesToSend = needsHistoricalGlucoseData ? readings.count : 1

        var watchStates: [GarminWatchState] = []
        for (index, reading) in readings.enumerated() {
            guard index < entriesToSend else { break }
            var watchState = GarminWatchState()
            watchState.sgv = mgdl(reading.milligramsPerDeciliter)
            if index == 0 {
                watchState.date = UInt64(loopDate.timeIntervalSince1970 * 1000)
                watchState.direction = reading.trend.map(Self.direction) ?? "--"
                watchState.delta = readings
                    .count > 1 ? mgdl(reading.milligramsPerDeciliter - readings[1].milligramsPerDeciliter) : 0
                // Glucose timestamp: Used by watchface to determine if glucose is fresh
                watchState.glucoseDate = UInt64(reading.date.timeIntervalSince1970 * 1000)
                watchState.units_hint = unitsHint
                watchState.iob = formatIOB(Decimal(snapshot.insulinOnBoard ?? 0))
                watchState.cob = snapshot.carbsOnBoard
                watchState.tbr = therapy?.tempBasalRate ?? therapy?.scheduledBasalRate
                watchState.isf = therapy?.insulinSensitivity.map(mgdl)
                watchState.eventualBG = therapy?.eventualGlucose.map(mgdl)
                watchState.sensRatio = therapy?.sensitivityRatio
                watchState.displayPrimaryAttributeChoice = settingsManager.settings.garminSettings.primaryAttributeChoice.rawValue
                watchState.displaySecondaryAttributeChoice = settingsManager.settings.garminSettings.secondaryAttributeChoice
                    .rawValue
                watchState.glucoseColorScheme = colorSchemeValue
                // The target the algorithm used, including any override or temp target
                watchState.targetGlucose = therapy?.correctionRange.map { mgdl($0.lowerBound) }
            } else {
                watchState.date = UInt64(reading.date.timeIntervalSince1970 * 1000)
            }
            watchStates.append(watchState)
        }

        // Deduplicate: Check if data is unchanged from last preparation
        let currentHash = watchStates.hashValue
        if currentHash == lastPreparedDataHash, let lastPreparedWatchState {
            if debugWatchState {
                debug(.watch, "Garmin watch state unchanged")
            }
            return lastPreparedWatchState
        }
        lastPreparedDataHash = currentHash
        lastPreparedWatchState = watchStates
        return watchStates
    }

    /// The direction names the Garmin apps read. The snapshot's trend merges triple and
    /// double arrows.
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

    /// Formats IOB (Insulin On Board) value with 1 decimal precision for display.
    /// Prevents small values from rounding to zero by enforcing a minimum magnitude of 0.1.
    /// - Parameter value: The IOB value to format.
    /// - Returns: The formatted IOB value as a Double with 1 decimal place.
    private func formatIOB(_ value: Decimal) -> Double {
        let doubleValue = NSDecimalNumber(decimal: value).doubleValue
        if doubleValue.magnitude < 0.1, doubleValue != 0 {
            return doubleValue > 0 ? 0.1 : -0.1
        }
        return (doubleValue * 10).rounded() / 10
    }

    // MARK: - Device & App Registration

    /// Registers the given devices for ConnectIQ events (device status changes) and watch app messages.
    /// It also creates and registers watch apps (watchface, data field and Trio-WatchControls) for each device.
    /// - Parameter devices: The devices to register.
    private func registerDevices(_ devices: [IQDevice]) {
        let previousApps = watchApps
        watchApps.removeAll()

        // Reset broadcast hashes so newly registered apps receive data
        // Without this, hash deduplication could skip sending to new apps if data unchanged
        lastSentDataHashes.removeAll()
        // re-registration is the retry permission for apps that answered AppNotFound
        absentApps.removeAll()

        for device in devices {
            connectIQClient?.registerDevice(device, delegate: self)

            // Register watchface if enabled
            if isWatchfaceDataEnabled,
               let watchfaceUUID = currentWatchface.watchfaceUUID,
               let watchfaceApp = IQApp(uuid: watchfaceUUID, store: UUID(), device: device)
            {
                debugGarmin("Registered Garmin \(appDetailedName(for: watchfaceUUID))")
                watchApps.append(watchfaceApp)
                connectIQClient?.registerApp(watchfaceApp, delegate: self)
            } else if !isWatchfaceDataEnabled {
                debugGarmin("Garmin watchface data disabled, watchface not registered")
            }

            // Always register datafield (if configured)
            if let datafieldUUID = currentDatafield.datafieldUUID,
               let datafieldApp = IQApp(uuid: datafieldUUID, store: UUID(), device: device)
            {
                debugGarmin("Registered Garmin \(appDetailedName(for: datafieldUUID))")
                watchApps.append(datafieldApp)
                connectIQClient?.registerApp(datafieldApp, delegate: self)
            }

            if currentCommandApp == .watchControls,
               let watchControlsUUID = GarminWatchControls.appUUID,
               let watchControlsApp = IQApp(uuid: watchControlsUUID, store: UUID(), device: device)
            {
                debugGarmin("Registered Garmin \(appDetailedName(for: watchControlsUUID))")
                watchApps.append(watchControlsApp)
                connectIQClient?.registerApp(watchControlsApp, delegate: self)
            }
        }

        let registeredKeys = Set(watchApps.compactMap(deliveryKey(for:)))
        owedDeliveries = owedDeliveries.filter { registeredKeys.contains($0.key) }

        for app in watchApps where app.uuid.map(GarminCommandApp.appUUIDs.contains) == true {
            sendCommandAppNotice(to: app, isActive: true)
        }
        for app in previousApps where app.uuid.map(GarminCommandApp.appUUIDs.contains) == true {
            guard let key = deliveryKey(for: app), !registeredKeys.contains(key) else { continue }
            sendCommandAppNotice(to: app, isActive: false)
        }
    }

    /// Restores previously persisted devices from local storage into `devices`.
    private func restoreDevices() {
        devices = persistedDevices.map(\.iqDevice)
    }

    // MARK: - Simulator Support

    #if targetEnvironment(simulator)
        /// Mock IQDevice class for simulator testing
        /// Minimal implementation just for testing - no actual Garmin functionality
        class MockIQDevice: IQDevice {
            private let _uuid: UUID
            private let _friendlyName: String
            private let _modelName: String

            override var uuid: UUID { _uuid }
            override var friendlyName: String { _friendlyName }
            override var modelName: String { _modelName }
            var status: IQDeviceStatus { .connected }

            init(uuid: UUID, friendlyName: String, modelName: String) {
                _uuid = uuid
                _friendlyName = friendlyName
                _modelName = modelName
                super.init()
            }

            @available(*, unavailable) required init?(coder _: NSCoder) {
                fatalError("init(coder:) not implemented for mock device")
            }

            /// Shared simulated device UUID for consistency across the app
            static let simulatedUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
                ?? UUID()

            /// Creates the standard simulated Enduro 3 device
            static func createSimulated() -> MockIQDevice {
                MockIQDevice(
                    uuid: simulatedUUID,
                    friendlyName: "Enduro 3 Sim",
                    modelName: "Enduro 3"
                )
            }
        }
    #endif

    // MARK: - Combine Subscriptions

    /// Subscribes to the `.openFromGarminConnect` notification, parsing devices from the given URL
    /// and updating the device list accordingly.
    private func subscribeToOpenFromGarminConnect() {
        notificationCenter
            .publisher(for: .openFromGarminConnect)
            .sink { [weak self] notification in
                guard let self = self, let url = notification.object as? URL else { return }
                self.parseDevices(for: url)
            }
            .store(in: &cancellables)
    }

    /// Subscribes to watch state updates with debouncing
    private func subscribeToWatchState() {
        watchStateSubject
            .debounce(for: broadcastDebounce, scheduler: DispatchQueue.main)
            .sink { [weak self] data in
                self?.broadcastWatchStateData(data)
            }
            .store(in: &cancellables)
    }

    // MARK: - Parsing & Broadcasting

    /// Parses devices from a Garmin Connect URL and updates our `devices` property.
    /// - Parameter url: The URL provided by Garmin Connect containing device selection info.
    private func parseDevices(for url: URL) {
        let parsed = connectIQ?.parseDeviceSelectionResponse(from: url) as? [IQDevice]
        devices = parsed ?? []
        deviceSelectionPromise?(.success(devices))
        deviceSelectionPromise = nil
    }

    /// Sends the state once to every registered app that has not confirmed this exact state yet.
    private func broadcastWatchStateData(_ data: Data) {
        // Deduplicate: Use stable content-based hash (sorted JSON bytes)
        let currentHash: Int
        if let sortedData = try? JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: data, options: []),
            options: [.sortedKeys]
        ) {
            currentHash = sortedData.base64EncodedString().hashValue
        } else {
            currentHash = data.count // Fallback
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) else {
            warning(.watch, "Garmin watch state is not valid JSON")
            return
        }
        lastBroadcast = (jsonObject, currentHash)

        for app in watchApps {
            guard let key = deliveryKey(for: app), let device = app.device else { continue }
            let appName = appDisplayName(for: app.uuid)

            if lastSentDataHashes[key] == currentHash, owedDeliveries[key]?.stateHash == nil {
                if debugWatchState {
                    debug(.watch, "Garmin \(appName) skipped, data unchanged")
                }
                continue
            }
            guard isReachable(key: key, device: device, appName: appName) else {
                recordOwed(for: key, stateHash: currentHash)
                continue
            }
            debugGarmin("Sending state to Garmin \(appName)")
            sendMessage(jsonObject, to: app, appName: appName, stateHash: currentHash)
        }
    }

    // MARK: - Delivery

    private func deliveryKey(for app: IQApp) -> String? {
        guard let appUUID = app.uuid, let deviceUUID = app.device?.uuid else { return nil }
        return "\(appUUID.uuidString)-\(deviceUUID.uuidString)"
    }

    /// SDK completions are not documented to arrive on main; delivery state lives there.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// Skipping keeps whatever the app is owed for the next trigger.
    private func isReachable(key: String, device: IQDevice, appName: String) -> Bool {
        if absentApps.contains(key) {
            debugGarmin("Garmin \(appName) skipped, app not installed")
            return false
        }
        if disconnectedDevices.contains(device.uuid) {
            debugGarmin("Garmin \(appName) skipped, device disconnected")
            return false
        }
        return true
    }

    /// Acks and other replies are never owed; the watch expires an unanswered command itself.
    private func recordOwed(for key: String, stateHash: Int? = nil, presets: Bool = false, commandApp: Bool = false) {
        guard stateHash != nil || presets || commandApp else { return }
        var owed = owedDeliveries[key] ?? OwedDelivery()
        if let stateHash {
            owed.stateHash = stateHash
        }
        owed.pushesPresets = owed.pushesPresets || presets
        owed.announcesCommandApp = owed.announcesCommandApp || commandApp
        owedDeliveries[key] = owed
    }

    /// Any delivered message proves the channel, so what the app is still owed goes out now.
    private func flushOwed(to app: IQApp, key: String, appName: String) {
        guard let owed = owedDeliveries.removeValue(forKey: key) else { return }
        if owed.stateHash != nil, let broadcast = lastBroadcast, lastSentDataHashes[key] != broadcast.hash {
            debugGarmin("Sending owed state to Garmin \(appName)")
            sendMessage(broadcast.payload, to: app, appName: appName, stateHash: broadcast.hash)
        }
        if owed.pushesPresets {
            pushPresets(to: [app], triggeredBy: "OwedDelivery")
        }
        if owed.announcesCommandApp {
            sendCommandAppNotice(to: app, isActive: true)
        }
    }

    /// Redelivers on the triggers that occur anyway (broadcast, reconnect, inbound message) instead of timers.
    private func flushOwed(on device: IQDevice) {
        for app in watchApps where app.device?.uuid == device.uuid {
            guard let key = deliveryKey(for: app), !absentApps.contains(key) else { continue }
            flushOwed(to: app, key: key, appName: appDisplayName(for: app.uuid))
        }
    }

    /// Main queue only.
    private func pushPresetsToCommandApp(triggeredBy trigger: String) {
        guard let commandAppUUID = currentCommandApp.appUUID else { return }
        pushPresets(to: watchApps.filter { $0.uuid == commandAppUUID }, triggeredBy: trigger)
    }

    /// Read by both command apps, Trio-WatchControls and Complication. Only the active notice is owed:
    /// an app told to stand down that missed it is told again as soon as it sends anything.
    private func sendCommandAppNotice(to app: IQApp, isActive: Bool) {
        guard let key = deliveryKey(for: app), let device = app.device else { return }
        let appName = appDisplayName(for: app.uuid)
        let notice = GarminMessageEnvelope.commandAppNotice(isActive: isActive, commandApp: currentCommandApp)
        guard !isActive || isReachable(key: key, device: device, appName: appName) else {
            recordOwed(for: key, commandApp: true)
            return
        }
        debug(.watch, "Sending command app notice to Garmin \(appName), \(isActive ? "active" : "inactive")")
        sendMessage(notice, to: app, appName: appName, announcesCommandApp: isActive)
    }

    /// Targeted like a reply, so it never touches the state broadcast or its content hash.
    private func pushPresets(to targets: [IQApp], triggeredBy trigger: String) {
        guard !targets.isEmpty else { return }

        Task {
            do {
                let response = try await GarminMessageEnvelope.presetsResponse(
                    loadPresets(),
                    capabilities: self.watchCommandProcessor.capabilities()
                )
                onMain { [weak self] in
                    guard let self else { return }
                    for app in targets {
                        guard let key = self.deliveryKey(for: app), let device = app.device else { continue }
                        let appName = self.appDisplayName(for: app.uuid)
                        guard self.isReachable(key: key, device: device, appName: appName) else {
                            self.recordOwed(for: key, presets: true)
                            continue
                        }
                        self.sendTargetedResponse(response, to: app, appName: appName, isPresets: true)
                    }
                }
            } catch {
                warning(
                    .watch,
                    "Loading presets for the Garmin push after \(trigger) failed (\(WatchCommandErrorCategory.name(for: error)))"
                )
            }
        }
    }

    private func loadPresets() async throws -> WatchPresets {
        try await presetsProvider.presets()
    }

    /// Answers one app directly, never through `broadcastWatchStateData`, whose content hash would
    /// otherwise suppress the next state update.
    private func sendTargetedResponse(_ response: [String: Any], to app: IQApp, appName: String, isPresets: Bool = false) {
        let kind = response[WatchMessageKeys.request] as? String ?? "response"
        debug(.watch, "Sending \(kind) to Garmin \(appName)")
        sendMessage(response, to: app, appName: appName, isPresets: isPresets)
    }

    // MARK: - GarminManager Conformance

    /// Prompts the user to select one or more Garmin devices, returning a publisher that emits
    /// the final array of selected devices once the user finishes selection.
    /// - Returns: An `AnyPublisher` emitting `[IQDevice]` on success, or empty array on error/timeout.
    func selectDevices() -> AnyPublisher<[IQDevice], Never> {
        Future { [weak self] promise in
            guard let self = self else {
                promise(.success([]))
                return
            }
            self.deviceSelectionPromise = promise
            self.connectIQ?.showDeviceSelection()
        }
        .timeout(.seconds(120), scheduler: DispatchQueue.main)
        .replaceEmpty(with: [])
        .eraseToAnyPublisher()
    }

    /// Updates the manager's list of devices, typically after user selection or manual changes.
    /// - Parameter devices: The new array of `IQDevice` objects to track.
    func updateDeviceList(_ devices: [IQDevice]) {
        self.devices = devices
    }

    /// Sends the given watch state data to the debounce subject for eventual broadcast.
    /// - Parameter data: JSON-encoded data representing the latest watch state.
    func sendWatchStateData(_ data: Data) {
        watchStateSubject.send(data)
    }

    // MARK: - Helper: Sending Messages

    /// Sends with one resend after `sendRetryDelay` for transient failures; a final failure leaves the
    /// state or preset list owed. `AppNotFound` is never resent: the app is provably not installed.
    private func sendMessage(
        _ msg: Any,
        to app: IQApp,
        appName: String,
        stateHash: Int? = nil,
        isPresets: Bool = false,
        announcesCommandApp: Bool = false,
        isRetry: Bool = false
    ) {
        connectIQClient?.send(msg, to: app) { [weak self] result in
            self?.onMain {
                guard let self, let key = self.deliveryKey(for: app) else { return }
                switch result {
                case .success:
                    debug(.watch, "Sent to Garmin \(appName)")
                    self.absentApps.remove(key)
                    if let stateHash {
                        self.lastSentDataHashes[key] = stateHash
                    }
                    self.flushOwed(to: app, key: key, appName: appName)
                case .failure_AppNotFound:
                    debug(.watch, "Garmin \(appName) not installed, skipped until re-registered or heard from")
                    self.absentApps.insert(key)
                    self.recordOwed(for: key, stateHash: stateHash, presets: isPresets, commandApp: announcesCommandApp)
                default:
                    let reason = NSStringFromSendMessageResult(result) ?? "\(result.rawValue)"
                    if isRetry {
                        error(.watch, "Sending to Garmin \(appName) failed after retry (\(reason))")
                        self.recordOwed(for: key, stateHash: stateHash, presets: isPresets, commandApp: announcesCommandApp)
                    } else {
                        warning(.watch, "Sending to Garmin \(appName) failed, retrying (\(reason))")
                        DispatchQueue.main.asyncAfter(deadline: .now() + self.sendRetryDelay) { [weak self] in
                            self?.debugGarmin("Retrying send to Garmin \(appName)")
                            self?.sendMessage(
                                msg,
                                to: app,
                                appName: appName,
                                stateHash: stateHash,
                                isPresets: isPresets,
                                announcesCommandApp: announcesCommandApp,
                                isRetry: true
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Extensions

extension BaseGarminManager: IQUIOverrideDelegate, IQDeviceEventDelegate, IQAppMessageDelegate {
    // MARK: - IQUIOverrideDelegate

    /// Called if the Garmin Connect Mobile app is not installed or otherwise not available.
    /// Typically, you would show an alert or prompt the user to install the app from the store.
    func needsToInstallConnectMobile() {
        warning(.watch, "Garmin Connect app not available")
        let content = Alert.Content(
            title: String(localized: "Garmin is not available"),
            body: String(
                localized:
                "The app Garmin Connect must be installed to use Trio.\nGo to the App Store to download it."
            ),
            acknowledgeActionButtonLabel: String(localized: "OK")
        )
        let alert = Alert(
            identifier: Alert.Identifier(
                managerIdentifier: "trio.garmin",
                alertIdentifier: "connect.mobile.missing"
            ),
            foregroundContent: content,
            backgroundContent: content,
            trigger: .immediate,
            interruptionLevel: .active,
            sound: nil
        )
        trioAlertManager?.issueAlert(alert)
    }

    // MARK: - IQDeviceEventDelegate

    /// Called whenever the status of a registered Garmin device changes (e.g., connected, not found, etc.).
    /// Only a lost connection gates sends; nothing here costs a round trip to the watch.
    /// - Parameters:
    ///   - device: The device whose status has changed.
    ///   - status: The new status for the device.
    func deviceStatusChanged(_ device: IQDevice, status: IQDeviceStatus) {
        // Always log connection state changes - critical for diagnosing SDK issues
        switch status {
        case .invalidDevice:
            warning(.watch, "Garmin device invalid")
            disconnectedDevices.insert(device.uuid)
        case .bluetoothNotReady:
            info(.watch, "Garmin device unavailable, Bluetooth not ready")
            disconnectedDevices.insert(device.uuid)
        case .notFound:
            info(.watch, "Garmin device not found")
            disconnectedDevices.insert(device.uuid)
        case .notConnected:
            info(.watch, "Garmin device disconnected")
            disconnectedDevices.insert(device.uuid)
        case .connected:
            debug(.watch, "Garmin device connected, waiting for characteristics")
            disconnectedDevices.remove(device.uuid)
        @unknown default:
            debug(.watch, "Garmin device status unknown (\(status.rawValue))")
        }
    }

    /// Called when device characteristics are discovered and the device is ready for communication.
    /// This is required in SDK 1.8+ - sending before this callback may fail.
    /// - Parameter device: The device whose characteristics have been discovered.
    func deviceCharacteristicsDiscovered(_ device: IQDevice) {
        info(.watch, "Garmin device connected and ready")
        disconnectedDevices.remove(device.uuid)
        flushOwed(on: device)

        // Trigger a data send now that device is ready
        // This ensures newly connected devices get data promptly
        triggerWatchStateUpdate(triggeredBy: "DeviceReady")
    }

    // MARK: - IQAppMessageDelegate

    /// Called when a message arrives from a Garmin watch app (watchface, datafield or command app).
    /// Status requests refresh the broadcast state; preset requests and commands are answered only to
    /// the requesting app.
    /// - Parameters:
    ///   - message: The message content from the watch app.
    ///   - app: The watch app sending the message.
    func receivedMessage(_ message: Any, from app: IQApp) {
        guard let appUUID = app.uuid else {
            debug(.watch, "Ignored message from Garmin app without UUID")
            return
        }
        let appName = appDisplayName(for: appUUID)
        debugGarmin("Message received from Garmin \(appName)")
        let registered = watchApps.first { $0.uuid == appUUID && $0.device?.uuid == app.device?.uuid }

        // a message from the app proves the channel, so it gets what it is owed right away
        if let registered, let key = deliveryKey(for: registered) {
            onMain { [weak self] in
                self?.absentApps.remove(key)
                self?.flushOwed(to: registered, key: key, appName: appName)
            }
        } else if GarminCommandApp.appUUIDs.contains(appUUID), devices.contains(where: { $0.uuid == app.device?.uuid }) {
            // it still acts as the command app, so it missed the notice to stand down
            onMain { [weak self] in
                self?.sendCommandAppNotice(to: app, isActive: false)
            }
        }

        let router = GarminMessageRouter(processor: watchCommandProcessor, loadPresets: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.loadPresets()
        })

        Task {
            let outcome = await router.route(
                message,
                from: appUUID,
                isRegistered: registered != nil,
                // only on a selected device: any other watch must not reach the processor
                isCommandApp: GarminCommandApp.appUUIDs.contains(appUUID) && devices.contains { $0.uuid == app.device?.uuid },
                appName: appName
            )

            if let reply = outcome.reply {
                onMain { [weak self] in
                    self?.sendTargetedResponse(reply, to: app, appName: appName)
                }
            }
            // debounced path, so a request coinciding with a determination still sends once
            if let trigger = outcome.refreshTrigger {
                triggerWatchStateUpdate(triggeredBy: trigger)
            }
            if outcome.pushesPresets {
                onMain { [weak self] in
                    self?.pushPresetsToCommandApp(triggeredBy: "WatchCommand")
                }
            }
        }
    }
}

extension BaseGarminManager: SettingsObserver {
    /// Called whenever TrioSettings changes (e.g., user toggles mg/dL vs. mmol/L, watchface selection, etc.).
    /// Compares previous vs current settings to determine what changed and responds appropriately.
    /// - Parameter _: The updated TrioSettings instance.
    func settingsDidChange(_: TrioSettings) {
        let currentGarminSettings = settingsManager.settings.garminSettings
        let currentUnits = settingsManager.settings.units
        let currentColorScheme = settingsManager.settings.glucoseColorScheme

        // Detect what specifically changed
        let unitsChanged = currentUnits != units
        let colorSchemeChanged = currentColorScheme != glucoseColorScheme
        let watchfaceChanged = currentGarminSettings.watchface != previousGarminSettings.watchface
        let datafieldChanged = currentGarminSettings.datafield != previousGarminSettings.datafield
        let watchfaceDataEnabledChanged = currentGarminSettings.isWatchfaceDataEnabled != previousGarminSettings
            .isWatchfaceDataEnabled
        let displayAttributesChanged = currentGarminSettings.primaryAttributeChoice != previousGarminSettings
            .primaryAttributeChoice ||
            currentGarminSettings.secondaryAttributeChoice != previousGarminSettings.secondaryAttributeChoice
        // Permissions and max carbs reach the command app with the plugin's snapshots.
        let commandAppChanged = GarminCommandApp(currentGarminSettings) != GarminCommandApp(previousGarminSettings)

        // Update stored values
        units = currentUnits
        glucoseColorScheme = currentColorScheme

        // Re-register devices only if the set of watch apps changed
        if watchfaceChanged || datafieldChanged || watchfaceDataEnabledChanged || commandAppChanged {
            debugGarmin("Garmin watchface or data field changed, re-registering devices")
            if !devices.isEmpty {
                registerDevices(devices)
            }
        }

        // Send update for settings that affect displayed data
        // Watchface/datafield changes only need re-registration, not data update
        // Disabling watchface data doesn't need an update (nothing to send to)
        let watchfaceDataJustEnabled = watchfaceDataEnabledChanged && currentGarminSettings.isWatchfaceDataEnabled

        if watchfaceDataJustEnabled {
            // Send immediately when watchface data is enabled - user wants to see data now
            if debugWatchState {
                debug(.watch, "Garmin watchface data enabled, sending update")
            }
            triggerWatchStateUpdate(triggeredBy: "Settings")
        } else if commandAppChanged {
            // a newly selected command app shows nothing until its first state
            triggerWatchStateUpdate(triggeredBy: "CommandSettings")
        } else if unitsChanged || displayAttributesChanged || colorSchemeChanged {
            // Throttle other settings changes in case user makes multiple changes
            if debugWatchState {
                debug(.watch, "Garmin display settings changed, scheduling update")
            }
            sendSettingsUpdateThrottled()
        }

        // the complication builds its menu and pickers from these
        if commandAppChanged {
            pushPresetsToCommandApp(triggeredBy: "CommandSettings")
        }

        // Store current Garmin settings for next comparison
        previousGarminSettings = currentGarminSettings
    }
}
