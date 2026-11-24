import CoreGraphics
import CryptoKit
import Foundation
import Observation

/// Receives local edits that iCloud needs to hear about. Implemented by `SyncController`.
@MainActor
protocol LibraryChangeSink: AnyObject {
    func libraryNeedsSave(_ id: UUID, records: PendingRecords)
    func libraryNeedsTombstone(_ id: UUID)
}

/// The local library: the durable source of truth for the reader. Works with or without iCloud.
@MainActor
@Observable
final class LibraryStore {
    private(set) var paths: LibraryPaths
    private(set) var catalog = Catalog()
    /// Documents whose PDF bytes are present in `Files/`.
    private(set) var localFiles: Set<UUID> = []
    /// Shown in the library until dismissed: import failures, storage errors.
    var notice: LibraryNotice?

    @ObservationIgnored weak var changeSink: (any LibraryChangeSink)?
    /// The last catalog write failed. While true, iCloud's change token isn't saved, so fetched changes
    /// that didn't reach disk are fetched again on the next launch.
    @ObservationIgnored private(set) var hasUnsavedChanges = false
    @ObservationIgnored private var catalogWritable = true
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var positionsAwaitingSave: Set<UUID> = []

    init(scope: String) {
        paths = LibraryPaths(scope: scope)
        load()
    }

    // MARK: Reading

    var documents: [DocumentEntry] {
        catalog.documents.values.sorted {
            switch $0.title.localizedStandardCompare($1.title) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: $0.createdAt < $1.createdAt
            }
        }
    }

    func entry(_ id: UUID) -> DocumentEntry? { catalog.documents[id] }
    func hasLocalFile(_ id: UUID) -> Bool { localFiles.contains(id) }
    func fileURL(_ id: UUID) -> URL { paths.fileURL(for: id) }
    func isTombstoned(_ id: UUID) -> Bool { catalog.tombstones[id] != nil }

    var missingFiles: [DocumentEntry] {
        catalog.documents.values.filter { !localFiles.contains($0.id) }
    }

    // MARK: Scope

    /// Switches to another library scope (account change). Pending writes for the old scope are flushed first.
    func switchScope(to scope: String) {
        guard scope != paths.scope else { return }
        flushPendingSave()
        paths = LibraryPaths(scope: scope)
        load()
    }

    private func load() {
        do {
            try paths.ensureDirectories()
        } catch {
            notice = .error("Couldn't prepare library storage: \(error.localizedDescription)")
        }
        catalogWritable = true
        do {
            let data = try Data(contentsOf: paths.catalogURL)
            do {
                catalog = try JSONDecoder().decode(Catalog.self, from: data)
            } catch {
                // Keep the unreadable catalog aside; the PDFs stay and are recovered below.
                let aside = paths.root.appending(path: "catalog-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: paths.catalogURL, to: aside)
                // Everything must be fetched again, even with no local files to recover.
                try? FileManager.default.removeItem(at: paths.syncStateURL)
                try? FileManager.default.removeItem(at: paths.recordMetadataURL)
                catalog = Catalog()
                notice = .error("The library catalog was unreadable and was set aside. Your PDFs were kept; titles and pages may need restoring from iCloud.")
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            catalog = Catalog()  // a new library
        } catch {
            // Can't read it right now (e.g. before first unlock): never write over it this session.
            catalog = Catalog()
            catalogWritable = false
            notice = .error("The library couldn't be opened: \(error.localizedDescription). Relaunch the app.")
            return
        }
        reconcileFiles()
        // Unread documents have no position to send.
        for (id, entry) in catalog.documents where entry.pageModifiedAt == nil && entry.pending.contains(.position) {
            catalog.documents[id]?.pending.remove(.position)
        }
        refreshLocalFiles()
        cleanStaging()
    }

    private func refreshLocalFiles() {
        let fm = FileManager.default
        localFiles = Set(catalog.documents.keys.filter { fm.fileExists(atPath: paths.fileURL(for: $0).path) })
    }

    /// PDFs in Files/ without a catalog entry. Deleted documents (tombstoned) are removed. Anything else (an
    /// import whose catalog write was interrupted, or a library whose catalog was unreadable) is never
    /// deleted: it is added back as a document so no PDF is lost.
    private func reconcileFiles() {
        let fm = FileManager.default
        var recovered = false
        for url in (try? fm.contentsOfDirectory(at: paths.filesDirectory, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  catalog.documents[id] == nil else { continue }
            if catalog.tombstones[id] != nil {
                try? fm.removeItem(at: url)
                continue
            }
            guard let pageCount = try? PDFImporter.validate(url), let sha = try? PDFImporter.sha256(of: url) else { continue }
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            catalog.documents[id] = DocumentEntry(
                id: id, title: "Recovered PDF", titleModifiedAt: .distantPast, createdAt: created,
                byteSize: size, sha256: sha, pageCount: pageCount, pageIndex: 0, pageModifiedAt: nil,
                fileInCloud: false, pending: [])
            // Nothing is sent for it until a full fetch has applied the server's titles, positions and
            // tombstones; then whatever the server lacks is uploaded (see `releaseRecovered`).
            catalog.recoveredAwaitingFetch.insert(id)
            recovered = true
        }
        if recovered {
            // Fetch everything again: drop the change token and cached change tags of the lost catalog.
            try? fm.removeItem(at: paths.syncStateURL)
            try? fm.removeItem(at: paths.recordMetadataURL)
            save()
        }
    }

    private func cleanStaging() {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: paths.stagingDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: Persistence

    /// Writes the catalog atomically. Returns false (and shows the error) if it couldn't be written; callers
    /// must not delete files or publish changes to iCloud for state that isn't on disk.
    @discardableResult
    func save() -> Bool {
        guard catalogWritable else {
            hasUnsavedChanges = true
            return false
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(catalog)
            try data.write(to: paths.catalogURL, options: [.atomic])
            hasUnsavedChanges = false
            return true
        } catch {
            hasUnsavedChanges = true
            notice = .error("Couldn't save the library: \(error.localizedDescription)")
            return false
        }
    }

    /// Position changes are frequent; write them at most once a second.
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flushPendingSave()
        }
    }

    /// Writes any pending position checkpoint now (app backgrounding, reader closing, scope switch).
    func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        let ids = positionsAwaitingSave
        guard !ids.isEmpty else { return }
        guard save() else {
            scheduleSave()  // retry the checkpoint; positions stay queued
            return
        }
        positionsAwaitingSave = []
        for id in ids where catalog.documents[id] != nil {
            changeSink?.libraryNeedsSave(id, records: .position)
        }
    }

    // MARK: Local edits

    func rename(_ id: UUID, to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, var entry = catalog.documents[id], entry.title != title else { return }
        entry.title = title
        entry.titleModifiedAt = Date()
        entry.pending.insert(.metadata)
        catalog.documents[id] = entry
        save()
        changeSink?.libraryNeedsSave(id, records: .metadata)
    }

    /// Records a reading checkpoint. Only call for pages the reader actually moved to, never for the page
    /// restored on open, so merely opening a document can't overwrite newer progress from another device.
    func recordPosition(_ id: UUID, page: Int) {
        guard var entry = catalog.documents[id], entry.pageIndex != page || entry.pageModifiedAt == nil else { return }
        entry.pageIndex = page
        entry.pageModifiedAt = Date()
        entry.pending.insert(.position)
        catalog.documents[id] = entry
        positionsAwaitingSave.insert(id)
        scheduleSave()
    }

    func delete(_ id: UUID) {
        guard catalog.documents[id] != nil else { return }
        let before = catalog
        catalog.documents[id] = nil
        catalog.orphanPositions[id] = nil
        catalog.tombstones[id] = Date()
        catalog.pendingTombstones.insert(id)
        guard save() else {
            catalog = before  // the tombstone isn't durable: keep the document and its file
            return
        }
        positionsAwaitingSave.remove(id)
        try? FileManager.default.removeItem(at: paths.fileURL(for: id))
        localFiles.remove(id)
        changeSink?.libraryNeedsTombstone(id)
    }

    // MARK: Import

    /// Imports PDFs as app-owned copies. Bad files are reported; good ones in the same batch still import.
    func importFiles(_ urls: [URL]) async {
        var failures: [String] = []
        var duplicates: [String] = []
        let staging = paths.stagingDirectory
        let scope = paths.scope
        for (index, url) in urls.enumerated() {
            guard paths.scope == scope else {
                // The iCloud account changed during this import: none of the rest joins the other library.
                let rest = urls[index...].map(\.lastPathComponent).joined(separator: ", ")
                failures.append("\(rest): the iCloud account changed during import. Import again.")
                break
            }
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try PDFImporter.prepare(url, stagingDirectory: staging)
                }.value
                guard paths.scope == scope else {
                    // The iCloud account changed while the file was being read; don't add it to another library.
                    try? FileManager.default.removeItem(at: prepared.stagedURL)
                    failures.append("\(url.lastPathComponent): the iCloud account changed during import. Import it again.")
                    continue
                }
                if let existing = catalog.documents.values.first(where: { $0.sha256 == prepared.sha256 }) {
                    if !localFiles.contains(existing.id) {
                        // Known document whose bytes haven't downloaded yet: use these (same checksum).
                        do {
                            let target = paths.fileURL(for: existing.id)
                            if FileManager.default.fileExists(atPath: target.path) {
                                _ = try FileManager.default.replaceItemAt(target, withItemAt: prepared.stagedURL)
                            } else {
                                try FileManager.default.moveItem(at: prepared.stagedURL, to: target)
                            }
                            localFiles.insert(existing.id)
                            setDownloadError(existing.id, nil)
                        } catch {
                            try? FileManager.default.removeItem(at: prepared.stagedURL)
                            failures.append("\(url.lastPathComponent): \(LibraryError.storage(error).localizedDescription)")
                        }
                        continue
                    }
                    try? FileManager.default.removeItem(at: prepared.stagedURL)
                    duplicates.append(existing.title)
                    continue
                }
                try commit(prepared)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            notice = .error("Couldn't import \(failures.joined(separator: "; "))")
        } else if !duplicates.isEmpty {
            notice = .info("Already in your library: \(duplicates.joined(separator: ", "))")
        }
    }

    private func commit(_ prepared: PreparedImport) throws {
        let id = UUID()
        do {
            try FileManager.default.moveItem(at: prepared.stagedURL, to: paths.fileURL(for: id))
        } catch {
            try? FileManager.default.removeItem(at: prepared.stagedURL)
            throw LibraryError.storage(error)
        }
        let now = Date()
        catalog.documents[id] = DocumentEntry(
            id: id, title: prepared.title, titleModifiedAt: now, createdAt: now,
            byteSize: prepared.byteSize, sha256: prepared.sha256, pageCount: prepared.pageCount,
            pageIndex: 0, pageModifiedAt: nil, fileInCloud: false, pending: [.metadata, .file])
        guard save() else {
            catalog.documents[id] = nil
            try? FileManager.default.removeItem(at: paths.fileURL(for: id))
            throw LibraryError.catalogNotSaved
        }
        localFiles.insert(id)
        changeSink?.libraryNeedsSave(id, records: [.metadata, .file])
    }

    /// Moves every document of `other` (the signed-out local library) into this library.
    /// Used when iCloud becomes available, so PDFs imported while signed out join the account library.
    /// Files are copied first and removed from the local library only after this catalog is safely written,
    /// so a failure at any point leaves every PDF reachable from at least one library.
    /// Returns true once the signed-out library holds nothing left to transfer (so the pending adoption
    /// target can be cleared); false if anything must be retried on a later activation.
    @discardableResult
    func adopt(from other: LibraryPaths) -> Bool {
        guard let data = try? Data(contentsOf: other.catalogURL) else { return true }  // nothing signed out
        guard let source = try? JSONDecoder().decode(Catalog.self, from: data) else { return false }
        guard !source.documents.isEmpty else { return true }
        let fm = FileManager.default
        defer { mergedIDs = [] }
        var adopted: [UUID] = []
        var redundant: [UUID] = []   // already in this library (same bytes): the local copy can go
        for (id, var entry) in source.documents {
            let match = catalog.documents[id] ?? catalog.documents.values.first { $0.sha256 == entry.sha256 }
            if let match {
                // Same bytes already known here. Keep the local copy unless this library has its file; if it
                // doesn't yet (still downloading), give it these bytes first.
                if !localFiles.contains(match.id) {
                    let target = paths.fileURL(for: match.id)
                    guard (try? fm.copyItem(at: other.fileURL(for: id), to: target)) != nil,
                          (try? PDFImporter.sha256(of: target)) == match.sha256 else {
                        try? fm.removeItem(at: target)
                        continue
                    }
                    localFiles.insert(match.id)
                    catalog.documents[match.id]?.downloadError = nil
                }
                mergeNewerProgress(from: entry, into: match.id)
                redundant.append(id)
                continue
            }
            guard catalog.tombstones[id] == nil else {
                redundant.append(id)  // deleted in this account: deletion wins over the signed-out copy
                continue
            }
            let destination = paths.fileURL(for: id)
            do {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: other.fileURL(for: id), to: destination)
            } catch {
                continue  // stays in the local library; adoption is retried next time
            }
            entry.fileInCloud = false
            entry.pending = entry.pageModifiedAt == nil ? [.metadata, .file] : .all
            catalog.documents[id] = entry
            localFiles.insert(id)
            adopted.append(id)
        }
        guard !adopted.isEmpty || !redundant.isEmpty else { return false }
        guard save() else {
            for id in adopted {
                catalog.documents[id] = nil
                localFiles.remove(id)
                try? fm.removeItem(at: paths.fileURL(for: id))
            }
            return false
        }
        var remaining = source
        for id in adopted + redundant {
            remaining.documents[id] = nil
            // Marks the bytes as transferred, so an interrupted cleanup deletes them at next launch instead
            // of recovering them into the signed-out library (and adopting them into another account).
            remaining.tombstones[id] = Date()
        }
        var sourceCleaned = false
        if let data = try? JSONEncoder().encode(remaining), (try? data.write(to: other.catalogURL, options: [.atomic])) != nil {
            for id in adopted + redundant { try? fm.removeItem(at: other.fileURL(for: id)) }
            sourceCleaned = true
        }
        for id in adopted + mergedIDs {
            if let pending = catalog.documents[id]?.pending { changeSink?.libraryNeedsSave(id, records: pending) }
        }
        return sourceCleaned && remaining.documents.isEmpty
    }

    @ObservationIgnored private var mergedIDs: [UUID] = []

    /// Reading done (or a rename made) while signed out wins over the account's older values.
    private func mergeNewerProgress(from local: DocumentEntry, into id: UUID) {
        guard var entry = catalog.documents[id] else { return }
        var changed = false
        if let localPage = local.pageModifiedAt, localPage > (entry.pageModifiedAt ?? .distantPast) {
            entry.pageIndex = local.pageIndex
            entry.pageModifiedAt = localPage
            entry.pending.insert(.position)
            changed = true
        }
        if local.titleModifiedAt > entry.titleModifiedAt {
            entry.title = local.title
            entry.titleModifiedAt = local.titleModifiedAt
            entry.pending.insert(.metadata)
            changed = true
        }
        if changed {
            catalog.documents[id] = entry
            mergedIDs.append(id)
        }
    }

    // MARK: Sync bookkeeping (called by SyncController)

    func markSynced(_ id: UUID, records: PendingRecords, titleModifiedAt: Date? = nil, pageModifiedAt: Date? = nil) {
        guard var entry = catalog.documents[id] else { return }
        var cleared = records
        // A newer local edit made while the save was in flight still needs its own save.
        if let sent = titleModifiedAt, sent < entry.titleModifiedAt { cleared.remove(.metadata) }
        if let sent = pageModifiedAt, let local = entry.pageModifiedAt, sent < local { cleared.remove(.position) }
        entry.pending.subtract(cleared)
        if records.contains(.file) {
            entry.fileInCloud = true
        }
        if records.contains(.file) || entry.pending.isEmpty {
            entry.uploadError = nil
        }
        catalog.documents[id] = entry
        save()
    }

    /// After a full fetch: recovered documents the server didn't delete are uploaded if it lacks them.
    func releaseRecovered() -> [UUID] {
        let ids = catalog.recoveredAwaitingFetch
        guard !ids.isEmpty else { return [] }
        catalog.recoveredAwaitingFetch = []
        var released: [UUID] = []
        for id in ids {
            guard var entry = catalog.documents[id] else { continue }
            if entry.titleModifiedAt == .distantPast { entry.pending.insert(.metadata) }
            if !entry.fileInCloud, localFiles.contains(id) { entry.pending.insert(.file) }
            catalog.documents[id] = entry
            if !entry.pending.isEmpty { released.append(id) }
        }
        save()
        return released
    }

    func markPending(_ id: UUID, records: PendingRecords) {
        guard var entry = catalog.documents[id] else { return }
        entry.pending.formUnion(records)
        if records.contains(.file) { entry.fileInCloud = false }
        catalog.documents[id] = entry
        save()
    }

    func markTombstonePending(_ id: UUID) {
        guard catalog.pendingTombstones.insert(id).inserted else { return }
        save()
    }

    func markTombstoneSynced(_ id: UUID) {
        guard catalog.pendingTombstones.remove(id) != nil else { return }
        save()
    }

    func setUploadError(_ id: UUID, _ message: String?) {
        guard catalog.documents[id]?.uploadError != message else { return }
        catalog.documents[id]?.uploadError = message
        save()
    }

    func setDownloadError(_ id: UUID, _ message: String?) {
        guard catalog.documents[id]?.downloadError != message else { return }
        catalog.documents[id]?.downloadError = message
        save()
    }

    /// Marks every record as needing a save, e.g. after iCloud data was reset.
    func markAllPending() {
        for (id, entry) in catalog.documents {
            var pending: PendingRecords = .metadata
            if entry.pageModifiedAt != nil { pending.insert(.position) }
            if localFiles.contains(id) { pending.insert(.file) }
            catalog.documents[id]?.pending = pending
            catalog.documents[id]?.fileInCloud = false
        }
        catalog.pendingTombstones.formUnion(catalog.tombstones.keys)
        save()
    }

    /// Removes every document locally (the user deleted this app's data from iCloud settings).
    func removeAllDocuments() {
        let ids = Array(catalog.documents.keys)
        catalog = Catalog()
        // Tombstones so a file whose removal fails is deleted at next launch rather than recovered. They
        // aren't queued for upload, but if another device later re-sends one of these records, delete wins
        // and the tombstone is sent then.
        for id in ids { catalog.tombstones[id] = Date() }
        localFiles = []
        guard save() else { return }
        for id in ids {
            try? FileManager.default.removeItem(at: paths.fileURL(for: id))
        }
    }

    // MARK: Remote changes (called by SyncController)

    enum RemoteOutcome { case applied, ignored, rejectedByTombstone }

    func applyRemoteMetadata(_ remote: RemoteMetadata) -> RemoteOutcome {
        if remote.deleted {
            applyRemoteDeletion(remote.id)
            return .applied
        }
        if catalog.tombstones[remote.id] != nil { return .rejectedByTombstone }
        if var entry = catalog.documents[remote.id] {
            guard remote.titleModifiedAt > entry.titleModifiedAt else { return .ignored }
            entry.title = remote.title
            entry.titleModifiedAt = remote.titleModifiedAt
            entry.pending.remove(.metadata)
            catalog.documents[remote.id] = entry
        } else {
            let orphan = catalog.orphanPositions.removeValue(forKey: remote.id)
            catalog.documents[remote.id] = DocumentEntry(
                id: remote.id, title: remote.title, titleModifiedAt: remote.titleModifiedAt,
                createdAt: remote.createdAt, byteSize: remote.byteSize, sha256: remote.sha256,
                pageCount: remote.pageCount, pageIndex: orphan?.pageIndex ?? 0, pageModifiedAt: orphan?.modifiedAt,
                fileInCloud: true)
            if FileManager.default.fileExists(atPath: paths.fileURL(for: remote.id).path) {
                localFiles.insert(remote.id)
            }
        }
        save()
        return .applied
    }

    func applyRemotePosition(_ id: UUID, _ position: RemotePosition) -> RemoteOutcome {
        if catalog.tombstones[id] != nil { return .rejectedByTombstone }
        guard var entry = catalog.documents[id] else {
            if position.modifiedAt > (catalog.orphanPositions[id]?.modifiedAt ?? .distantPast) {
                catalog.orphanPositions[id] = position
                save()
            }
            return .applied
        }
        guard position.modifiedAt > (entry.pageModifiedAt ?? .distantPast) else { return .ignored }
        entry.pageIndex = min(max(0, position.pageIndex), max(0, entry.pageCount - 1))
        entry.pageModifiedAt = position.modifiedAt
        entry.pending.remove(.position)
        catalog.documents[id] = entry
        positionsAwaitingSave.remove(id)
        save()
        return .applied
    }

    func applyRemoteDeletion(_ id: UUID) {
        catalog.documents[id] = nil
        catalog.orphanPositions[id] = nil
        if catalog.tombstones[id] == nil { catalog.tombstones[id] = Date() }
        positionsAwaitingSave.remove(id)
        localFiles.remove(id)
        // Remove the bytes only once the tombstone is on disk. If the write fails, the in-memory tombstone
        // reaches disk with the next successful save and the file is removed at the next launch.
        guard save() else { return }
        try? FileManager.default.removeItem(at: paths.fileURL(for: id))
    }

    /// Copies a downloaded asset (CloudKit's staging file, which may vanish) into durable storage.
    func installRemoteFile(_ id: UUID, from stagedURL: URL, sha256: String?) async -> Bool {
        // Only for documents in the catalog: a file that arrives before its Document record is fetched
        // again by the download pass once the document exists, so no unreferenced file is ever kept.
        guard catalog.tombstones[id] == nil, catalog.documents[id] != nil else { return false }
        if localFiles.contains(id) { return true }
        let destination = paths.fileURL(for: id)
        let staging = paths.stagingDirectory
        let expected = sha256 ?? catalog.documents[id]?.sha256
        let scope = paths.scope
        let result = await Task.detached(priority: .utility) {
            try PDFImporter.installDownloaded(stagedURL, to: destination, stagingDirectory: staging, expectedSHA256: expected)
        }.result
        // The file went into the library it was requested for; if the account changed meanwhile, the
        // current library must not record it.
        guard paths.scope == scope else { return false }
        switch result {
        case .success:
            // The document may have been deleted while the copy ran.
            if catalog.tombstones[id] != nil || catalog.documents[id] == nil {
                try? FileManager.default.removeItem(at: destination)
                return false
            }
            localFiles.insert(id)
            if catalog.documents[id]?.downloadError != nil { catalog.documents[id]?.downloadError = nil; save() }
            return true
        case .failure(let error):
            setDownloadError(id, error.localizedDescription)
            return false
        }
    }
}

struct RemoteMetadata: Sendable {
    var id: UUID
    var title: String
    var titleModifiedAt: Date
    var createdAt: Date
    var byteSize: Int64
    var sha256: String
    var pageCount: Int
    var deleted: Bool
}

enum LibraryNotice: Equatable, Identifiable {
    case info(String)
    case error(String)

    var id: String { message }
    var message: String {
        switch self {
        case .info(let m), .error(let m): m
        }
    }
    var isError: Bool { if case .error = self { true } else { false } }
}

enum LibraryError: LocalizedError {
    case notPDF
    case passwordProtected
    case empty
    case checksumMismatch
    case catalogNotSaved
    case storage(Error)

    var errorDescription: String? {
        switch self {
        case .notPDF: "This file isn't a readable PDF."
        case .passwordProtected: "Password-protected PDFs aren't supported."
        case .empty: "This PDF has no pages."
        case .checksumMismatch: "The downloaded file was incomplete. It will be downloaded again."
        case .catalogNotSaved: "The library couldn't be saved."
        case .storage(let error):
            if Self.isOutOfSpace(error) { "Not enough storage on this device." } else { error.localizedDescription }
        }
    }

    static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        return (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
            || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC))
    }
}

struct PreparedImport: Sendable {
    var stagedURL: URL
    var title: String
    var byteSize: Int64
    var sha256: String
    var pageCount: Int
}

/// File work that runs off the main actor.
enum PDFImporter {
    static func prepare(_ source: URL, stagingDirectory: URL) throws -> PreparedImport {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let staged = stagingDirectory.appending(path: "\(UUID().uuidString).pdf")
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [.withoutChanges], error: &coordinationError) { url in
            do { try FileManager.default.copyItem(at: url, to: staged) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw LibraryError.storage(error) }

        do {
            let pageCount = try validate(staged)
            let size = try FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? NSNumber
            return PreparedImport(
                stagedURL: staged,
                title: source.deletingPathExtension().lastPathComponent,
                byteSize: size?.int64Value ?? 0,
                sha256: try sha256(of: staged),
                pageCount: pageCount)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    static func validate(_ url: URL) throws -> Int {
        guard let document = CGPDFDocument(url as CFURL) else { throw LibraryError.notPDF }
        if document.isEncrypted, !document.isUnlocked, !document.unlockWithPassword("") {
            throw LibraryError.passwordProtected
        }
        guard document.numberOfPages > 0 else { throw LibraryError.empty }
        return document.numberOfPages
    }

    static func installDownloaded(_ staged: URL, to destination: URL, stagingDirectory: URL, expectedSHA256: String?) throws {
        let temp = stagingDirectory.appending(path: "\(UUID().uuidString).download")
        do {
            try FileManager.default.copyItem(at: staged, to: temp)
            if let expectedSHA256, try sha256(of: temp) != expectedSHA256 { throw LibraryError.checksumMismatch }
            _ = try validate(temp)
            // Same volume, so this rename is atomic: the reader never sees a partial file.
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: destination)
            }
        } catch let error as LibraryError {
            try? FileManager.default.removeItem(at: temp)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw LibraryError.storage(error)
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
