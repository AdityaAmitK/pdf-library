import Foundation
import Observation

/// Owns the library and its sync for the app's lifetime.
@MainActor
@Observable
final class AppModel {
    let library: LibraryStore
    let sync: SyncController

    init() {
        // Open the last active library immediately (also offline); the account check may switch it.
        let scope = UserDefaults.standard.string(forKey: SyncController.activeScopeKey) ?? LibraryPaths.localScope
        library = LibraryStore(scope: scope)
        sync = SyncController(library: library)
        sync.start()
    }
}
