import SwiftUI

@main
struct PDFLibraryApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    #else
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase

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
            case .inactive, .background: delegate.model.library.flushPendingSave()
            @unknown default: break
            }
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(delegate.model)
        }
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
            .environment(delegate.model)
            .environment(delegate.openRequests)
    }
}
