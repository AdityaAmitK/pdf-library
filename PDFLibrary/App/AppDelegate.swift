import SwiftUI

/// Files the system asked the app to open (Open With, Open in, Share → PDF Library), waiting to be imported.
@MainActor
@Observable
final class OpenRequests {
    var urls: [URL] = []
}

#if os(macOS)
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let openRequests = OpenRequests()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // CKSyncEngine relies on pushes to learn about changes from other devices.
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openRequests.urls += urls.filter(\.isFileURL)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        model.library.flushPendingSave()
    }
}
#else
import UIKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    let model = AppModel()
    let openRequests = OpenRequests()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // CKSyncEngine relies on pushes to learn about changes from other devices.
        application.registerForRemoteNotifications()
        return true
    }
}
#endif
