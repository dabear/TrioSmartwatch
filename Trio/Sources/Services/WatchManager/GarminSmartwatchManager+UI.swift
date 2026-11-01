import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

extension GarminSmartwatchManager: SmartwatchManagerUI {
    static var onboardingImage: UIImage? { UIImage(systemName: "applewatch.side.right") }
    var smallImage: UIImage? { Self.onboardingImage }

    /// Nothing to set up here: devices and watch apps are chosen in Trio's Garmin settings.
    @MainActor static func setupViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference _: DisplayGlucosePreference,
        colorPalette _: LoopUIColorPalette,
        allowDebugFeatures _: Bool
    ) -> SetupUIResult<SmartwatchManagerViewController, SmartwatchManagerUI> {
        guard let manager = GarminSmartwatchManager(rawState: [:]) else {
            // Only without the host's resolver, which the host sets before setup.
            return .userInteractionRequired(GarminSettingsNavigationController(manager: nil))
        }
        return .createdAndOnboarded(manager)
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

    init(manager: GarminSmartwatchManager?) {
        super.init(nibName: nil, bundle: nil)
        let done = { [weak self] in
            guard let self else { return }
            self.completionDelegate?.completionNotifyingDidComplete(self)
        }
        let view = GarminSmartwatchSettingsView(
            remove: manager.map { manager in
                { manager.delete { DispatchQueue.main.async(execute: done) } }
            },
            done: done
        )
        setViewControllers([UIHostingController(rootView: view)], animated: false)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct GarminSmartwatchSettingsView: View {
    /// `nil` when Garmin couldn't be created.
    let remove: (() -> Void)?
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
            if let remove {
                Section {
                    Button("Remove Garmin", role: .destructive) { confirmingRemoval = true }
                } footer: {
                    Text("Garmin watches get no data from Trio without this.")
                }
                .confirmationDialog("Remove Garmin?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                    Button("Remove", role: .destructive, action: remove)
                }
            } else {
                Text("Garmin couldn't be added. Restart Trio and try again.")
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle(GarminSmartwatchManager.localizedTitle)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) } }
    }
}
