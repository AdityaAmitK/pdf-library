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
        if let data = try? Data(contentsOf: paths.catalogURL) {
            do {
                catalog = try JSONDecoder().decode(Catalog.self, from: data)
            } catch {
                // Never overwrite an unreadable catalog; keep it aside for recovery.
                let aside = paths.root.appending(path: "catalog-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: paths.catalogURL, to: aside)
                catalog = Catalog()
                notice = .error("The library catalog was unreadable and was set aside. iCloud will restore synced documents.")
            }
        } else {
            catalog = Catalog()
        }
        refreshLocalFiles()
        cleanStaging()
    }

    private func refreshLocalFiles() {
        let fm = FileManager.default
        localFiles = Set(catalog.documents.keys.filter { fm.fileExists(atPath: paths.fileURL(for: $0).path) })
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
        saveTask?.cancel()
        saveTask = nil
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(catalog)
            try data.write(to: paths.catalogURL, options: [.atomic])
            return true
        } catch {
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
        let ids = positionsAwaitingSave
        positionsAwaitingSave = []
        save()
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
        for url in urls {
            let staging = paths.stagingDirectory
            let scope = paths.scope
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
            pageIndex: 0, pageModifiedAt: nil, fileInCloud: false, pending: .all)
        guard save() else {
            catalog.documents[id] = nil
            try? FileManager.default.removeItem(at: paths.fileURL(for: id))
            throw LibraryError.catalogNotSaved
        }
        localFiles.insert(id)
        changeSink?.libraryNeedsSave(id, records: .all)
    }

    /// Moves every document of `other` (the signed-out local library) into this library.
    /// Used when iCloud becomes available, so PDFs imported while signed out join the account library.
    /// Files are copied first and removed from the local library only after this catalog is safely written,
    /// so a failure at any point leaves every PDF reachable from at least one library.
    func adopt(from other: LibraryPaths) {
        guard let data = try? Data(contentsOf: other.catalogURL),
              let source = try? JSONDecoder().decode(Catalog.self, from: data),
              !source.documents.isEmpty else { return }
        let fm = FileManager.default
        var adopted: [UUID] = []
        var redundant: [UUID] = []   // already in this library (same bytes): the local copy can go
        for (id, var entry) in source.documents {
            if catalog.documents[id] != nil || catalog.documents.values.contains(where: { $0.sha256 == entry.sha256 }) {
                redundant.append(id)
                continue
            }
            guard catalog.tombstones[id] == nil else { continue }
            let destination = paths.fileURL(for: id)
            do {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: other.fileURL(for: id), to: destination)
            } catch {
                continue  // stays in the local library; adoption is retried next time
            }
            entry.fileInCloud = false
            entry.pending = .all
            catalog.documents[id] = entry
            localFiles.insert(id)
            adopted.append(id)
        }
        guard !adopted.isEmpty || !redundant.isEmpty else { return }
        guard save() else {
            for id in adopted {
                catalog.documents[id] = nil
                localFiles.remove(id)
                try? fm.removeItem(at: paths.fileURL(for: id))
            }
            return
        }
        var remaining = source
        for id in adopted + redundant { remaining.documents[id] = nil }
        if let data = try? JSONEncoder().encode(remaining), (try? data.write(to: other.catalogURL, options: [.atomic])) != nil {
            for id in adopted + redundant { try? fm.removeItem(at: other.fileURL(for: id)) }
        }
        for id in adopted {
            changeSink?.libraryNeedsSave(id, records: .all)
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
            entry.uploadError = nil
        }
        catalog.documents[id] = entry
        save()
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
        for id in catalog.documents.keys {
            catalog.documents[id]?.pending = .all
            catalog.documents[id]?.fileInCloud = false
        }
        catalog.pendingTombstones.formUnion(catalog.tombstones.keys)
        save()
    }

    /// Removes every document locally (the user deleted this app's data from iCloud settings).
    func removeAllDocuments() {
        for id in catalog.documents.keys {
            try? FileManager.default.removeItem(at: paths.fileURL(for: id))
        }
        catalog = Catalog()
        localFiles = []
        save()
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
        try? FileManager.default.removeItem(at: paths.fileURL(for: id))
        localFiles.remove(id)
        save()
    }

    /// Copies a downloaded asset (CloudKit's staging file, which may vanish) into durable storage.
    func installRemoteFile(_ id: UUID, from stagedURL: URL, sha256: String?) async -> Bool {
        guard catalog.tombstones[id] == nil else { return false }
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
            if catalog.tombstones[id] != nil {
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
