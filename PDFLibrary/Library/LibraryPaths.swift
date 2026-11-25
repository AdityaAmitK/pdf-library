import Foundation

/// On-disk layout of one library scope:
///
///     Application Support/PDFLibrary/Libraries/<scope>/
///         catalog.json          documents, tombstones (atomic writes)
///         Files/<uuid>.pdf      durable PDF copies, the only source the reader opens
///         sync-state.plist      CKSyncEngine state, including pending changes
///         record-metadata.plist CloudKit system fields per record, for conflict-free saves
///         sync-environment      CloudKit environment the two files above belong to
///
/// Each iCloud account gets its own scope, so libraries never mix when the account changes.
struct LibraryPaths: Sendable {
    static let localScope = "local"

    let scope: String
    let root: URL

    init(scope: String) {
        self.scope = scope
        root = Self.librariesDirectory.appending(path: scope, directoryHint: .isDirectory)
    }

    static var librariesDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "PDFLibrary", directoryHint: .isDirectory)
            .appending(path: "Libraries", directoryHint: .isDirectory)
    }

    var catalogURL: URL { root.appending(path: "catalog.json") }
    var filesDirectory: URL { root.appending(path: "Files", directoryHint: .isDirectory) }
    var syncStateURL: URL { root.appending(path: "sync-state.plist") }
    var recordMetadataURL: URL { root.appending(path: "record-metadata.plist") }
    /// CloudKit environment (Development or Production) that the sync state and metadata belong to.
    var syncEnvironmentURL: URL { root.appending(path: "sync-environment") }
    var stagingDirectory: URL { root.appending(path: "Staging", directoryHint: .isDirectory) }

    func fileURL(for id: UUID) -> URL {
        filesDirectory.appending(path: "\(id.uuidString).pdf")
    }

    func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [filesDirectory, stagingDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
