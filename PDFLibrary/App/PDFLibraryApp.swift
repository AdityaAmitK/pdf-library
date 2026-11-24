import SwiftUI

@main
struct PDFLibraryApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    #else
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.appAppearance) private var appearance = AppAppearance.system

    var body: some Scene {
        mainWindow
        .commands {
            AppCommands()
            #if os(macOS)
            SidebarCommands()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: delegate.model.sync.retryDownloads()
            case .inactive: delegate.model.library.flushPendingSave()
            case .background: sendBeforeSuspension()
            @unknown default: break
            }
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(delegate.model)
                .preferredColorScheme(appearance.colorScheme)
        }
        #endif
    }

    /// Writes the reading checkpoint and sends it to iCloud before the system suspends the app, so another
    /// device picks up the latest page without this one being opened again.
    private func sendBeforeSuspension() {
        let model = delegate.model
        model.library.flushPendingSave()
        #if os(iOS)
        let task = BackgroundTask(name: "Send reading position")
        Task { @MainActor in
            await model.sync.sendPendingChanges()
            task.end()
        }
        #else
        Task { await model.sync.sendPendingChanges() }
        #endif
    }

    private var mainWindow: some Scene {
        #if os(macOS)
        // One library, one window. Files opened from Finder arrive through the app delegate.
        Window("PDF Library", id: "library") { root }
        #else
        WindowGroup { root }
        #endif
    }

    private var root: some View {
        RootView()
            .preferredColorScheme(appearance.colorScheme)
            .environment(delegate.model)
            .environment(delegate.openRequests)
    }
}

#if os(iOS)
/// A UIKit background task that is ended exactly once, by the work or by expiry.
@MainActor
private final class BackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif
