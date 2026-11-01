import Combine
import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

/// Garmin as a watch plugin in the host's slot. Experimental.
///
/// It only shows data: no remote actions are declared, so nothing goes from the
/// watch to Trio. The plugin passes each snapshot to `BaseGarminManager`, which
/// keeps everything Connect IQ (devices, watch apps, sending) and builds the
/// Garmin watch state from the snapshot alone. Devices and watch apps are still
/// chosen in Trio's Garmin settings.
final class GarminSmartwatchManager: SmartwatchManagerUI {
    static let pluginIdentifier = "GarminSmartwatchManager"
    static let localizedTitle = "Garmin"

    /// The latest snapshot from the host, `nil` while no Garmin plugin is added.
    /// `BaseGarminManager` sends nothing without one.
    static let snapshots = CurrentValueSubject<SmartwatchStatusSnapshot?, Never>(nil)

    /// What Garmin's watch apps show; no alerts, predictions or remote actions.
    static var capabilities: SmartwatchCapabilities { [.glucose, .history, .loopStatus, .therapy] }

    weak var smartwatchManagerDelegate: SmartwatchManagerDelegate?

    init() {}

    init?(rawState _: RawStateValue) {}

    /// Also when the host drops the plugin without deleting it, such as when another
    /// watch takes its slot: Garmin then stops getting data.
    deinit {
        Self.snapshots.send(nil)
    }

    var rawState: RawStateValue { [:] }
    var pluginIdentifier: String { Self.pluginIdentifier }
    var localizedTitle: String { Self.localizedTitle }
    var isOnboarded: Bool { true }

    func watchDataDidUpdate(_ snapshot: SmartwatchStatusSnapshot) {
        Self.snapshots.send(snapshot)
    }

    func delete(completion: @escaping () -> Void) {
        Self.snapshots.send(nil)
        notifyDelegateOfDeletion(completion: completion)
    }

    func initializationComplete(for _: [Pluggable]) {}

    var debugDescription: String {
        "## GarminSmartwatchManager\n* snapshot: \(Self.snapshots.value == nil ? "none" : "received")"
    }

    // MARK: - AlertResponder, AlertSoundVendor

    func acknowledgeAlert(alertIdentifier _: LoopKit.Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    func getSoundBaseURL() -> URL? { nil }
    func getSounds() -> [LoopKit.Alert.Sound] { [] }

    // MARK: - UI

    static var onboardingImage: UIImage? { UIImage(systemName: "applewatch.side.right") }
    var smallImage: UIImage? { Self.onboardingImage }

    /// Nothing to set up here: devices and watch apps are chosen in Trio's Garmin settings.
    @MainActor static func setupViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference _: DisplayGlucosePreference,
        colorPalette _: LoopUIColorPalette,
        allowDebugFeatures _: Bool
    ) -> SetupUIResult<SmartwatchManagerViewController, SmartwatchManagerUI> {
        .createdAndOnboarded(GarminSmartwatchManager())
    }

    @MainActor func settingsViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference _: DisplayGlucosePreference,
        colorPalette _: LoopUIColorPalette,
        allowDebugFeatures _: Bool
    ) -> SmartwatchManagerViewController {
        GarminSettingsNavigationController(manager: self)
    }
}

/// The plugin's settings: what it does, and removing it.
final class GarminSettingsNavigationController: UINavigationController, SmartwatchManagerOnboarding, CompletionNotifying {
    weak var smartwatchManagerOnboardingDelegate: SmartwatchManagerOnboardingDelegate?
    weak var completionDelegate: CompletionDelegate?

    init(manager: GarminSmartwatchManager) {
        super.init(nibName: nil, bundle: nil)
        let view = GarminSmartwatchSettingsView(
            remove: { [weak self] in
                manager.delete {
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.completionDelegate?.completionNotifyingDidComplete(self)
                    }
                }
            },
            done: { [weak self] in
                guard let self else { return }
                self.completionDelegate?.completionNotifyingDidComplete(self)
            }
        )
        setViewControllers([UIHostingController(rootView: view)], animated: false)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct GarminSmartwatchSettingsView: View {
    let remove: () -> Void
    let done: () -> Void
    @State private var confirmingRemoval = false

    var body: some View {
        List {
            Section {
                Text(
                    "Trio sends glucose, loop status and therapy values to the Garmin watch apps chosen in Trio's Garmin settings."
                )
                Text("Experimental. Nothing is sent from the watch to Trio.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Remove Garmin", role: .destructive) { confirmingRemoval = true }
            } footer: {
                Text("Garmin watches get no data from Trio without this.")
            }
        }
        .navigationTitle(GarminSmartwatchManager.localizedTitle)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) } }
        .confirmationDialog("Remove Garmin?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove", role: .destructive, action: remove)
        }
    }
}
