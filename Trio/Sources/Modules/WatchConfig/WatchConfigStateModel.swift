import Combine
import SwiftUI

extension WatchConfig {
    final class StateModel: BaseStateModel<Provider> {
        @Published var units: GlucoseUnits = .mgdL
        @Published var confirmBolusFaster = false
        @Published var showForecastWatch = false

        private(set) var preferences = Preferences()

        override func subscribe() {
            preferences = provider.preferences
            units = settingsManager.settings.units

            subscribeSetting(\.confirmBolusFaster, on: $confirmBolusFaster) { confirmBolusFaster = $0 }
            subscribeSetting(\.showForecastWatch, on: $showForecastWatch) { showForecastWatch = $0 }
        }
    }
}

extension WatchConfig.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
