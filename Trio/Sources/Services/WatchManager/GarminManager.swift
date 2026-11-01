import Combine
import ConnectIQ
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

    /// Manages local user settings: Garmin's watch apps and display choices, units, colour scheme.
    @Injected() private var settingsManager: SettingsManager!

    @Injected() private var trioAlertManager: TrioAlertManager!

    /// Persists the user's device list between app launches.
    @Persisted(key: "BaseGarminManager.persistedDevices") private var persistedDevices: [GarminDevice] = []

    /// Router for presenting alerts or navigation flows (injected via Swinject).
    private let router: Router

    /// Garmin ConnectIQ shared instance for watch interactions.
    private let connectIQ = ConnectIQ.sharedInstance()

    /// Keeps references to watch apps (both watchface & data field) for each registered device.
    private var watchApps: [IQApp] = []

    /// A set of Combine cancellables for managing the lifecycle of various subscriptions.
    private var cancellables = Set<AnyCancellable>()

    /// Holds a promise used when the user is selecting devices (via `showDeviceSelection()`).
    private var deviceSelectionPromise: Future<[IQDevice], Never>.Promise?

    /// Subject for debouncing watch state updates
    private let watchStateSubject = PassthroughSubject<Data, Never>()

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

    // MARK: - Device Ready State (SDK 1.8+)

    /// Tracks which devices have completed characteristic discovery and are ready for communication.
    /// In SDK 1.8+, `deviceStatusChanged: connected` does NOT mean the device is ready.
    /// We must wait for `deviceCharacteristicsDiscovered:` before sending messages.
    private var readyDevices: Set<UUID> = []

    // MARK: - Deduplication

    /// Hash of last sent data to prevent duplicate broadcasts
    private var lastSentDataHash: Int?

    /// Hash of last prepared data to skip redundant preparation
    private var lastPreparedDataHash: Int?
    private var lastPreparedWatchState: [GarminWatchState]?

    /// Queue for the settings throttle timer
    private let timerQueue = DispatchQueue(label: "BaseGarminManager.timerQueue", qos: .utility)

    // MARK: - Settings Change Throttle

    /// Track previous Garmin settings to detect what specifically changed
    private var previousGarminSettings = GarminWatchSettings()

    /// Pending settings update task - waits for user to finish making changes
    private var pendingSettingsUpdate: DispatchWorkItem?

    /// Latest settings data to send when throttle timer fires
    private var pendingSettingsData: Data?

    /// How long to wait for additional settings changes before sending (seconds)
    private let settingsThrottleDuration: TimeInterval = 10

    // MARK: - Snapshots

    /// Follows the Garmin plugin's snapshots (`GarminSmartwatchManager.snapshots`),
    /// the only source of the watch state.
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
    /// and following the Garmin plugin's snapshots.
    /// - Parameter resolver: Swinject resolver for injecting dependencies like the Router.
    init(resolver: Resolver) {
        router = resolver.resolve(Router.self)!
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

        // Each snapshot from the Garmin plugin, sent when a reading or the loop's
        // output changes; none while the plugin isn't added.
        GarminSmartwatchManager.snapshots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                if snapshot != nil {
                    self?.triggerWatchStateUpdate(triggeredBy: "Snapshot")
                }
            }
            .store(in: &subscriptions)
    }

    // MARK: - Settings Helpers

    /// Returns the currently configured Garmin watchface from settings
    private var currentWatchface: GarminWatchface {
        settingsManager.settings.garminSettings.watchface
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
        } else {
            return "unknown app (\(uuid.uuidString))"
        }
    }

    // MARK: - Updates

    /// Triggers watch state preparation and sends to debounce subject
    private func triggerWatchStateUpdate(triggeredBy trigger: String) {
        guard !devices.isEmpty else { return }

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
        // Skip if no devices connected, or no snapshot from the Garmin plugin yet
        guard !devices.isEmpty, let snapshot = GarminSmartwatchManager.snapshots.value else {
            return []
        }

        if debugWatchState {
            debug(.watch, "Preparing Garmin watch state, trigger \(triggeredBy)")
        }

        let garminSettings = settingsManager.settings.garminSettings
        let options = GarminWatchState.DisplayOptions(
            primaryAttributeChoice: garminSettings.primaryAttributeChoice.rawValue,
            secondaryAttributeChoice: garminSettings.secondaryAttributeChoice.rawValue,
            // Short form, not the enum raw value: this is the wire format the watchface reads.
            glucoseColorScheme: glucoseColorScheme == .dynamicColor ? "dynamic" : "static",
            sendsHistory: needsHistoricalGlucoseData
        )
        let watchStates = GarminWatchState.states(from: snapshot, options: options)

        // Deduplicate: Check if data is unchanged from last preparation
        if watchStates.hashValue == lastPreparedDataHash {
            if debugWatchState {
                debug(.watch, "Garmin watch state unchanged")
            }
            return lastPreparedWatchState ?? watchStates
        }

        if debugWatchState {
            let first = watchStates.first
            debug(
                .watch,
                "Garmin watch state prepared: \(watchStates.count) entries, BG \(first?.sgv ?? 0), IOB \(String(format: "%.1f", first?.iob ?? 0)) U, COB \(String(format: "%.0f", first?.cob ?? 0)) g, temp basal \(String(format: "%.2f", first?.tbr ?? 0)) U/h, eventual BG \(first?.eventualBG ?? 0), sensitivity ratio \(String(format: "%.2f", first?.sensRatio ?? 0)), color scheme \(first?.glucoseColorScheme ?? "none"), target \(first?.targetGlucose.map { "\($0)" } ?? "none")"
            )
        }

        lastPreparedDataHash = watchStates.hashValue
        lastPreparedWatchState = watchStates
        return watchStates
    }

    // MARK: - Device & App Registration

    /// Registers the given devices for ConnectIQ events (device status changes) and watch app messages.
    /// It also creates and registers watch apps (watchface + data field) for each device.
    /// - Parameter devices: The devices to register.
    private func registerDevices(_ devices: [IQDevice]) {
        watchApps.removeAll()

        // Reset broadcast hash so newly registered apps receive data
        // Without this, hash deduplication could skip sending to new apps if data unchanged
        lastSentDataHash = nil

        // Note: Do NOT clear readyDevices here. The device ready state is based on BLE
        // characteristic discovery, which only happens on new connections. Re-registering
        // for app messages doesn't affect the underlying BLE connection state.

        for device in devices {
            connectIQ?.register(forDeviceEvents: device, delegate: self)

            // Register watchface if enabled
            if isWatchfaceDataEnabled,
               let watchfaceUUID = currentWatchface.watchfaceUUID,
               let watchfaceApp = IQApp(uuid: watchfaceUUID, store: UUID(), device: device)
            {
                debugGarmin("Registered Garmin \(appDetailedName(for: watchfaceUUID))")
                watchApps.append(watchfaceApp)
                connectIQ?.register(forAppMessages: watchfaceApp, delegate: self)
            } else if !isWatchfaceDataEnabled {
                debugGarmin("Garmin watchface data disabled, watchface not registered")
            }

            // Always register datafield (if configured)
            if let datafieldUUID = currentDatafield.datafieldUUID,
               let datafieldApp = IQApp(uuid: datafieldUUID, store: UUID(), device: device)
            {
                debugGarmin("Registered Garmin \(appDetailedName(for: datafieldUUID))")
                watchApps.append(datafieldApp)
                connectIQ?.register(forAppMessages: datafieldApp, delegate: self)
            }
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
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
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

    /// Broadcasts watch state data to all registered apps
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

        if currentHash == lastSentDataHash {
            if debugWatchState {
                debug(.watch, "Garmin broadcast skipped, data unchanged")
            }
            return
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) else {
            warning(.watch, "Garmin watch state is not valid JSON")
            return
        }

        watchApps.forEach { app in
            guard let appUUID = app.uuid else {
                debug(.watch, "Skipped Garmin app without UUID")
                return
            }
            let appName = self.appDisplayName(for: appUUID)

            // Check if device is ready (SDK 1.8+ requirement)
            guard let device = app.device, readyDevices.contains(device.uuid) else {
                debugGarmin("Skipped Garmin \(appName), device not ready")
                return
            }

            connectIQ?.getAppStatus(app) { [weak self] status in
                guard status?.isInstalled == true else {
                    debug(.watch, "Garmin \(appName) not installed")
                    return
                }
                self?.debugGarmin("Sending to Garmin \(appName)")
                self?.sendMessage(jsonObject as Any, to: app, appName: appName)
            }
        }

        // Update last sent hash after initiating send
        lastSentDataHash = currentHash
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

    /// Sends a message to a given IQApp with optional progress and completion callbacks.
    /// Retries once after a short delay if the first attempt fails (SDK may need time after re-registration).
    /// - Parameters:
    ///   - msg: The data to send to the watch app.
    ///   - app: The `IQApp` instance representing the watchface or data field.
    ///   - appName: The display name of the app for logging.
    ///   - isRetry: Whether this is a retry attempt (to prevent infinite retries).
    private func sendMessage(_ msg: Any, to app: IQApp, appName: String, isRetry: Bool = false) {
        connectIQ?.sendMessage(
            msg,
            to: app,
            progress: { _, _ in },
            completion: { [weak self] result in
                switch result {
                case .success:
                    debug(.watch, "Sent to Garmin \(appName)")
                default:
                    if isRetry {
                        error(.watch, "Sending to Garmin \(appName) failed after retry")
                    } else {
                        warning(.watch, "Sending to Garmin \(appName) failed, retrying in 2 s")
                        // Retry after delay - SDK may need time after re-registration
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            self?.debugGarmin("Retrying send to Garmin \(appName)")
                            self?.sendMessage(msg, to: app, appName: appName, isRetry: true)
                        }
                    }
                }
            }
        )
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
    /// Note: In SDK 1.8+, `connected` does NOT mean ready for communication.
    /// Wait for `deviceCharacteristicsDiscovered:` before sending messages.
    /// - Parameters:
    ///   - device: The device whose status has changed.
    ///   - status: The new status for the device.
    func deviceStatusChanged(_ device: IQDevice, status: IQDeviceStatus) {
        // Always log connection state changes - critical for diagnosing SDK issues
        switch status {
        case .invalidDevice:
            warning(.watch, "Garmin device invalid")
            readyDevices.remove(device.uuid)
        case .bluetoothNotReady:
            info(.watch, "Garmin device unavailable, Bluetooth not ready")
            readyDevices.remove(device.uuid)
        case .notFound:
            info(.watch, "Garmin device not found")
            readyDevices.remove(device.uuid)
        case .notConnected:
            info(.watch, "Garmin device disconnected")
            readyDevices.remove(device.uuid)
        case .connected:
            debug(.watch, "Garmin device connected, waiting for characteristics")
        @unknown default:
            debug(.watch, "Garmin device status unknown (\(status.rawValue))")
        }
    }

    /// Called when device characteristics are discovered and the device is ready for communication.
    /// This is required in SDK 1.8+ - sending before this callback may fail.
    /// - Parameter device: The device whose characteristics have been discovered.
    func deviceCharacteristicsDiscovered(_ device: IQDevice) {
        info(.watch, "Garmin device connected and ready")
        readyDevices.insert(device.uuid)

        // Trigger a data send now that device is ready
        // This ensures newly connected devices get data promptly
        triggerWatchStateUpdate(triggeredBy: "DeviceReady")
    }

    // MARK: - IQAppMessageDelegate

    /// Called when a message arrives from a Garmin watch app (watchface or data field).
    /// If the watch requests a "status" update, we call `setupGarminWatchState()` asynchronously
    /// and re-send the watch state data.
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

        // If watch requests status update, send current data via unified path
        guard let statusString = message as? String, statusString == "status" else {
            return
        }

        // Use triggerWatchStateUpdate for consistent deduplication and debouncing
        // This prevents double sends when watchface request coincides with determination
        triggerWatchStateUpdate(triggeredBy: "WatchRequest")
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

        // Update stored values
        units = currentUnits
        glucoseColorScheme = currentColorScheme

        // Re-register devices only if watchface/datafield configuration changed
        if watchfaceChanged || datafieldChanged || watchfaceDataEnabledChanged {
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
        } else if unitsChanged || displayAttributesChanged || colorSchemeChanged {
            // Throttle other settings changes in case user makes multiple changes
            if debugWatchState {
                debug(.watch, "Garmin display settings changed, scheduling update")
            }
            sendSettingsUpdateThrottled()
        }

        // Store current Garmin settings for next comparison
        previousGarminSettings = currentGarminSettings
    }
}
