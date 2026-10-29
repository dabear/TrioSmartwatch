import LoopKitUI
import SwiftUI
import Swinject
import UIKit

/// Rows on the Watch screen for watch plugins (such as Pebble): one per
/// available plugin until a watch is added, then the added watch, which opens
/// the plugin's own settings.
struct WatchConfigSmartwatchRows: View {
    let resolver: Resolver

    @State private var sheet: Sheet?
    @State private var revision = 0
    @AppStorage(UserDefaults.allowSmartwatchOverridesKey) private var allowOverrides = false
    @AppStorage(UserDefaults.allowSmartwatchTempTargetsKey) private var allowTempTargets = false

    private var host: SmartwatchHost { resolver.resolve(SmartwatchHost.self)! }

    private enum Sheet: Identifiable {
        case setup(identifier: String)
        case settings

        var id: String {
            switch self {
            case let .setup(identifier): "setup-\(identifier)"
            case .settings: "settings"
            }
        }
    }

    var body: some View {
        Group {
            if let manager = host.smartwatchManager {
                Button { sheet = .settings } label: {
                    row(title: manager.localizedTitle, image: manager.smallImage)
                }
                // Only for a watch that can start presets; off by default and
                // turned off when the watch is removed or replaced.
                if manager.effectiveCapabilities.contains(.remoteOverride) {
                    Toggle(String(localized: "Allow Overrides from Watch"), isOn: $allowOverrides)
                }
                if manager.effectiveCapabilities.contains(.remoteTempTarget) {
                    Toggle(String(localized: "Allow Temp Targets from Watch"), isOn: $allowTempTargets)
                }
            } else {
                ForEach(host.availableSmartwatchManagers, id: \.identifier) { descriptor in
                    Button { sheet = .setup(identifier: descriptor.identifier) } label: {
                        row(title: descriptor.localizedTitle, image: descriptor.image, subtitle: descriptor.subtitle)
                    }
                }
            }
        }
        // Re-render when a watch is added or removed.
        .id(revision)
        .sheet(item: $sheet) { sheet in
            SmartwatchViewControllerView { completionDelegate in
                switch sheet {
                case let .setup(identifier):
                    host.setupViewController(for: identifier, completionDelegate: completionDelegate)
                case .settings:
                    host.settingsViewController(completionDelegate: completionDelegate)
                }
            } onComplete: {
                self.sheet = nil
            }
            .ignoresSafeArea()
            .interactiveDismissDisabled()
        }
        .onReceive(host.smartwatchManagerChanged.receive(on: DispatchQueue.main)) { _ in
            revision += 1
        }
    }

    private func row(title: String, image: UIImage?, subtitle: String? = nil) -> some View {
        HStack(spacing: 12) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundColor(.primary)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
        }
    }
}

/// Hosts a plugin's setup or settings view controller and closes the sheet when
/// the plugin reports it is done.
private struct SmartwatchViewControllerView: UIViewControllerRepresentable {
    let makeViewController: @MainActor(CompletionDelegate) -> UIViewController?
    let onComplete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        guard let viewController = makeViewController(context.coordinator) else {
            // Set up without user interaction, or nothing to show.
            DispatchQueue.main.async(execute: onComplete)
            return UIViewController()
        }
        return viewController
    }

    func updateUIViewController(_: UIViewController, context _: Context) {}

    final class Coordinator: CompletionDelegate {
        let onComplete: () -> Void

        init(onComplete: @escaping () -> Void) {
            self.onComplete = onComplete
        }

        func completionNotifyingDidComplete(_: CompletionNotifying) {
            DispatchQueue.main.async(execute: onComplete)
        }
    }
}
