import Sparkle
import SwiftUI

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        "https://raw.githubusercontent.com/wieandteduard/port-menu/main/packaging/appcast.xml"
    }
}

@main
struct PorterApp: App {
    @State private var store = PortStore.shared
    private let updaterController: SPUStandardUpdaterController
    private let updaterDelegate = UpdaterDelegate()

    init() {
        updaterController = SPUStandardUpdaterController(
            // Keep upstream releases from replacing this personal build.
            startingUpdater: false,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )
        moveToApplicationsIfNeeded()
        // Poll even when there is no menu bar item to trigger onAppear.
        PortStore.shared.ensurePolling()
    }

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!store.entries.isEmpty)) {
            PortListView(updater: updaterController.updater)
                .environment(store)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: store.entries.isEmpty
                      ? "square.fill"
                      : "circle.fill")
                    .font(.system(size: 5.5))
                    .foregroundStyle(statusColor)
                Text(store.entries.count, format: .number)
                    .fontDesign(.monospaced)
            }
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }

    private var statusColor: Color {
        if store.lastError != nil && store.entries.isEmpty {
            return .orange
        }
        return store.entries.isEmpty ? .gray : .green
    }
}
