import Foundation

/// One PDF in the library. The PDF bytes live in `LibraryPaths.fileURL(for:)` and never change after import.
/// Title and reading position carry their own timestamps so they merge independently across devices.
struct DocumentEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var titleModifiedAt: Date
    let createdAt: Date
    let byteSize: Int64
    let sha256: String
    var pageCount: Int

    /// Zero-based page the reader last settled on. `pageModifiedAt == nil` means it was never read.
    var pageIndex: Int
    var pageModifiedAt: Date?

    /// True once the PDF file record has reached iCloud (or arrived from it).
    var fileInCloud: Bool
    /// Last download failure for this document, shown in the library until a retry succeeds.
    var downloadError: String?
    /// Last upload failure (quota, storage), shown until a retry succeeds.
    var uploadError: String?
    /// Records that changed locally and still need an iCloud save. Persisted with the catalog, so pending
    /// work survives a crash even if the sync engine's own state was not written yet.
    var pending: PendingRecords = []
}

struct PendingRecords: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int
    static let metadata = PendingRecords(rawValue: 1 << 0)
    static let position = PendingRecords(rawValue: 1 << 1)
    static let file = PendingRecords(rawValue: 1 << 2)
    static let all: PendingRecords = [.metadata, .position, .file]
}

/// The persisted catalog of one library scope (one iCloud account, or the signed-out local library).
struct Catalog: Codable, Sendable {
    var version = 1
    var documents: [UUID: DocumentEntry] = [:]
    /// Deleted document IDs. Kept forever (they are tiny) so a stale device can never resurrect a deletion.
    var tombstones: [UUID: Date] = [:]
    /// Reading positions that arrived before their document record did.
    var orphanPositions: [UUID: RemotePosition] = [:]
    /// Tombstones that iCloud has not confirmed yet.
    var pendingTombstones: Set<UUID> = []
}

struct RemotePosition: Codable, Hashable, Sendable {
    var pageIndex: Int
    var modifiedAt: Date
}
