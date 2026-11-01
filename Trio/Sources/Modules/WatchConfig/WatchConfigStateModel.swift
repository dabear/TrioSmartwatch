import Combine
import ConnectIQ
import SwiftUI

extension WatchConfig {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var smartwatchHost: SmartwatchHost!

        /// The Garmin watch plugin, if added: it keeps the devices and sends to them.
        private var garmin: GarminSmartwatchManager? { smartwatchHost.smartwatchManager as? GarminSmartwatchManager }

        @Published var units: GlucoseUnits = .mgdL
        @Published var devices: [IQDevice] = []
        @Published var confirmBolusFaster = false
        @Published var showForecastWatch = false

        /// Whether the Garmin watch plugin is added: without it, Garmin gets no data.
        @Published var isGarminPluginAdded = false

        /// Garmin watch settings containing all watch-related configuration
        @Published var garminSettings = GarminWatchSettings()

        private(set) var preferences = Preferences()

        override func subscribe() {
            preferences = provider.preferences
            units = settingsManager.settings.units

            // Subscribe to the entire garminSettings struct from TrioSettings
            subscribeSetting(\.garminSettings, on: $garminSettings) { garminSettings = $0 }
            subscribeSetting(\.confirmBolusFaster, on: $confirmBolusFaster) { confirmBolusFaster = $0 }
            subscribeSetting(\.showForecastWatch, on: $showForecastWatch) { showForecastWatch = $0 }

            updateGarmin()
            smartwatchHost.smartwatchManagerChanged
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.updateGarmin() }
                .store(in: &lifetime)
        }

        private func updateGarmin() {
            isGarminPluginAdded = garmin != nil
            devices = garmin?.devices ?? []
        }

        /// Prompts the user to select Garmin devices and updates the device list
        func selectGarminDevices() {
            guard let garmin else { return }
            garmin.selectDevices()
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.devices, on: self)
                .store(in: &lifetime)
        }

        /// Updates the Garmin manager with the current device list
        func deleteGarminDevice() {
            garmin?.updateDeviceList(devices)
        }

        /// Handles watchface selection changes by automatically disabling data transmission
        /// to allow the user to switch watchfaces on their Garmin device without data conflicts
        func handleWatchfaceChange() {
            garminSettings.isWatchfaceDataEnabled = false
        }

        /// Resumes data transmission after user confirms they have switched watchface on their device
        func resumeDataTransmission() {
            garminSettings.isWatchfaceDataEnabled = true
        }
    }
}

extension WatchConfig.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
