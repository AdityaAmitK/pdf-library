import CloudKit
import CryptoKit
import Foundation
import Network
import Observation
import os

/// Keeps the local library in step with the private iCloud database through `CKSyncEngine`.
///
/// The local library stays the source the reader opens; iCloud is the transfer layer. Each iCloud account
/// gets its own library scope, so signing out or switching accounts never mixes libraries.
@MainActor
@Observable
final class SyncController {
    enum Status: Equatable {
        case disabled          // build without iCloud entitlements
        case checking
        case available
        case noAccount
        case restricted
        case temporarilyUnavailable
        case waitingForNetwork // account present, identity not known yet (first launch offline)
        case error(String)
    }

    private(set) var status: Status = .checking
    private(set) var isOnline = true
    private(set) var isSyncing = false
    private(set) var downloadsInFlight: Set<UUID> = []
    /// Most recent sync problem that needs attention (quota, server errors). Cleared by a successful send.
    private(set) var problem: String?

    let library: LibraryStore

    @ObservationIgnored private var container: CKContainer?
    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var engineScope: String?
    @ObservationIgnored private var metadata: RecordMetadataCache?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var accountObserver: NSObjectProtocol?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.aditya.pdflibrary", category: "sync")

    private static let lastAccountKey = "lastICloudAccount"
    static let activeScopeKey = "activeLibraryScope"

    init(library: LibraryStore) {
        self.library = library
        library.changeSink = self
    }

    static var cloudSyncEnabled: Bool {
        let value = Bundle.main.object(forInfoDictionaryKey: "PDFLCloudSync")
        return (value as? Bool) ?? ((value as? String)?.uppercased() == "YES")
    }

    // MARK: Lifecycle

    func start() {
        guard Self.cloudSyncEnabled else {
            status = .disabled
            return
        }
        container = CKContainer(identifier: CloudRecords.containerIdentifier)
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshAccount() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: online) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "pdflibrary.network"))
        Task { await refreshAccount() }
    }

    private func networkChanged(online: Bool) {
        let cameOnline = online && !isOnline
        isOnline = online
        guard cameOnline else { return }
        if status == .waitingForNetwork {
            Task { await refreshAccount() }
        } else {
            syncNow()
        }
    }

    /// Fetches and sends now, then retries missing downloads. Also used by the Retry button.
    func syncNow() {
        guard let engine else {
            Task { await refreshAccount() }
            return
        }
        problem = nil
        requeueAllPending()
        Task {
            do {
                try await engine.fetchChanges()
                try await engine.sendChanges()
            } catch {
                log.error("Manual sync failed: \(error.localizedDescription, privacy: .public)")
                if !isTransient(error) { problem = error.localizedDescription }
            }
            retryDownloads()
        }
    }

    func refreshAccount() async {
        guard let container else { return }
        let accountStatus: CKAccountStatus
        do {
            accountStatus = try await container.accountStatus()
        } catch {
            log.error("Account status failed: \(error.localizedDescription, privacy: .public)")
            // Keep the current library; this is usually transient.
            if engine == nil { status = .error(error.localizedDescription) }
            return
        }
        switch accountStatus {
        case .available:
            let recordName: String?
            do {
                recordName = try await container.userRecordID().recordName
                UserDefaults.standard.set(recordName, forKey: Self.lastAccountKey)
            } catch {
                // Offline launch: the account is unchanged unless iCloud said otherwise (the engine reports
                // switches), so reuse the last known identity.
                recordName = UserDefaults.standard.string(forKey: Self.lastAccountKey)
            }
            if let recordName {
                activate(scope: Self.scope(forAccount: recordName))
                status = .available
            } else {
                status = .waitingForNetwork
            }
        case .noAccount:
            deactivate()
            status = .noAccount
        case .restricted:
            deactivate()
            status = .restricted
        case .temporarilyUnavailable:
            // Keep showing the current library; iCloud usually returns on its own.
            status = .temporarilyUnavailable
        case .couldNotDetermine:
            status = .error("iCloud status couldn't be determined.")
        @unknown default:
            status = .error("Unknown iCloud status.")
        }
    }

    static func scope(forAccount recordName: String) -> String {
        let digest = SHA256.hash(data: Data(recordName.utf8))
        return "icloud-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func activate(scope: String) {
        guard engineScope != scope || engine == nil, let container else { return }
        tearDownEngine()
        let previousScope = library.paths.scope
        library.switchScope(to: scope)
        UserDefaults.standard.set(scope, forKey: Self.activeScopeKey)
        if previousScope == LibraryPaths.localScope {
            // PDFs imported while signed out join the first iCloud library that becomes available.
            library.adopt(from: LibraryPaths(scope: LibraryPaths.localScope))
        }

        let paths = library.paths
        metadata = RecordMetadataCache(url: paths.recordMetadataURL)
        var stateSerialization: CKSyncEngine.State.Serialization?
        if let data = try? Data(contentsOf: paths.syncStateURL) {
            stateSerialization = try? PropertyListDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: stateSerialization,
            delegate: self)
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        engineScope = scope
        if stateSerialization == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudRecords.zoneID))])
        }
        requeueAllPending()
        Task {
            try? await engine.fetchChanges()
            retryDownloads()
        }
    }

    /// Signed out or restricted: stop syncing and show the signed-out local library. The account's library
    /// stays on disk, isolated, and returns when the same account signs back in.
    private func deactivate() {
        tearDownEngine()
        UserDefaults.standard.removeObject(forKey: Self.lastAccountKey)
        UserDefaults.standard.set(LibraryPaths.localScope, forKey: Self.activeScopeKey)
        library.switchScope(to: LibraryPaths.localScope)
    }

    private func tearDownEngine() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadsInFlight = []
        if let engine {
            Task { await engine.cancelOperations() }
        }
        engine = nil
        engineScope = nil
        metadata = nil
    }

    /// Re-adds every save the catalog still marks as pending. The engine ignores duplicates.
    private func requeueAllPending() {
        guard let engine else { return }
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for entry in library.catalog.documents.values where !entry.pending.isEmpty {
            changes += Self.saves(for: entry.id, records: entry.pending)
        }
        for id in library.catalog.pendingTombstones {
            changes += Self.tombstoneChanges(id)
        }
        if !changes.isEmpty { engine.state.add(pendingRecordZoneChanges: changes) }
    }

    private static func saves(for id: UUID, records: PendingRecords) -> [CKSyncEngine.PendingRecordZoneChange] {
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        if records.contains(.metadata) { changes.append(.saveRecord(CloudRecords.recordID(.document, id))) }
        if records.contains(.file) { changes.append(.saveRecord(CloudRecords.recordID(.file, id))) }
        if records.contains(.position) { changes.append(.saveRecord(CloudRecords.recordID(.position, id))) }
        return changes
    }

    private static func tombstoneChanges(_ id: UUID) -> [CKSyncEngine.PendingRecordZoneChange] {
        [
            .saveRecord(CloudRecords.recordID(.document, id)),
            .deleteRecord(CloudRecords.recordID(.file, id)),
            .deleteRecord(CloudRecords.recordID(.position, id)),
        ]
    }

    // MARK: Downloads

    /// Requests every PDF whose bytes aren't on this device yet. Runs after each fetch, on reconnect, on
    /// launch and on Retry; failures stay visible per document until a later attempt succeeds.
    func retryDownloads() {
        guard downloadTask == nil, let container, engine != nil, isOnline else { return }
        let database = container.privateCloudDatabase
        downloadTask = Task { [weak self] in
            defer { self?.downloadTask = nil }
            // One attempt per missing document per pass, oldest first; failures wait for the next trigger.
            var attempted: Set<UUID> = []
            while let self, !Task.isCancelled {
                let candidates = self.library.missingFiles
                    .filter { !attempted.contains($0.id) && !self.downloadsInFlight.contains($0.id) }
                    .sorted { $0.createdAt < $1.createdAt }
                guard let entry = candidates.first else { break }
                attempted.insert(entry.id)
                await self.download(entry.id, database: database)
            }
        }
    }

    private func download(_ id: UUID, database: CKDatabase) async {
        downloadsInFlight.insert(id)
        defer { downloadsInFlight.remove(id) }
        do {
            let record = try await database.record(for: CloudRecords.recordID(.file, id))
            guard let asset = record["asset"] as? CKAsset, let url = asset.fileURL else {
                library.setDownloadError(id, "The PDF in iCloud is missing its file.")
                return
            }
            if await library.installRemoteFile(id, from: url, sha256: record["sha256"] as? String) {
                library.markSynced(id, records: .file)
            }
        } catch let error as CKError where error.code == .unknownItem {
            // The other device hasn't finished uploading yet; the next fetch will bring it.
            library.setDownloadError(id, nil)
        } catch {
            if isTransient(error) {
                library.setDownloadError(id, nil)
            } else {
                library.setDownloadError(id, error.localizedDescription)
            }
        }
    }

    private func isTransient(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        return [.networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy,
                .operationCancelled, .notAuthenticated].contains(ck.code)
    }

    private func persistMetadata() { metadata?.persist() }
}

// MARK: - Local changes

extension SyncController: LibraryChangeSink {
    func libraryNeedsSave(_ id: UUID, records: PendingRecords) {
        engine?.state.add(pendingRecordZoneChanges: Self.saves(for: id, records: records))
    }

    func libraryNeedsTombstone(_ id: UUID) {
        engine?.state.add(pendingRecordZoneChanges: Self.tombstoneChanges(id))
    }
}

// MARK: - CKSyncEngineDelegate

extension SyncController: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === engine else { return }  // an engine from a previous account
        switch event {
        case .stateUpdate(let update):
            if let data = try? PropertyListEncoder().encode(update.stateSerialization) {
                try? data.write(to: library.paths.syncStateURL, options: [.atomic])
            }

        case .accountChange(let change):
            switch change.changeType {
            case .signIn:
                await refreshAccount()
            case .signOut:
                deactivate()
                status = .noAccount
            case .switchAccounts:
                // Never fall back to the previous account's identity after a switch.
                UserDefaults.standard.removeObject(forKey: Self.lastAccountKey)
                deactivate()
                await refreshAccount()
            @unknown default:
                await refreshAccount()
            }

        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == CloudRecords.zoneID {
                metadata?.removeAll()
                persistMetadata()
                switch deletion.reason {
                case .purged:
                    // The user deleted this app's data in iCloud settings.
                    library.removeAllDocuments()
                default:
                    // Zone deleted or encryption reset: upload this device's library again.
                    library.markAllPending()
                    requeueAllPending()
                }
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudRecords.zoneID))])
            }

        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                await applyFetched(modification.record, syncEngine: syncEngine)
            }
            for deletion in changes.deletions {
                applyFetchedDeletion(deletion.recordID, syncEngine: syncEngine)
            }
            persistMetadata()

        case .sentRecordZoneChanges(let sent):
            handleSent(sent, syncEngine: syncEngine)
            persistMetadata()

        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves {
                log.error("Zone save failed: \(failure.error.localizedDescription, privacy: .public)")
                if !isTransient(failure.error) { problem = failure.error.localizedDescription }
            }

        case .willFetchChanges, .willSendChanges:
            isSyncing = true

        case .didFetchChanges:
            isSyncing = false
            retryDownloads()

        case .didSendChanges:
            isSyncing = false

        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard syncEngine === engine else { return nil }
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        var dropped: [CKSyncEngine.PendingRecordZoneChange] = []
        var records: [CKRecord.ID: CKRecord] = [:]
        for change in changes {
            guard case .saveRecord(let recordID) = change else { continue }
            if let record = buildRecord(recordID) {
                records[recordID] = record
            } else {
                dropped.append(change)
            }
        }
        if !dropped.isEmpty { syncEngine.state.remove(pendingRecordZoneChanges: dropped) }
        let sendable = changes.filter { change in
            if case .saveRecord(let id) = change { return records[id] != nil }
            return true
        }
        let provided = records
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: sendable) { provided[$0] }
    }

    /// Builds the record for a pending save from current local state, or nil if there's nothing to send.
    private func buildRecord(_ recordID: CKRecord.ID) -> CKRecord? {
        guard let (kind, id) = CloudRecords.parse(recordID), let metadata else { return nil }
        let record = metadata.record(for: recordID, type: kind)
        switch kind {
        case .document:
            if let deletedAt = library.catalog.tombstones[id] {
                CloudRecords.fillTombstone(record, deletedAt: deletedAt)
                return record
            }
            guard let entry = library.entry(id) else { return nil }
            CloudRecords.fill(record, with: entry)
            return record
        case .file:
            guard let entry = library.entry(id), library.hasLocalFile(id) else { return nil }
            record["asset"] = CKAsset(fileURL: library.fileURL(id))
            record["sha256"] = entry.sha256
            return record
        case .position:
            guard let entry = library.entry(id), let modified = entry.pageModifiedAt else { return nil }
            record["pageIndex"] = Int64(entry.pageIndex)
            record["pageModifiedAt"] = modified
            return record
        }
    }

    private func applyFetched(_ record: CKRecord, syncEngine: CKSyncEngine) async {
        guard let (kind, id) = CloudRecords.parse(record.recordID) else { return }
        metadata?.store(record)
        switch kind {
        case .document:
            guard let remote = CloudRecords.metadata(from: record, id: id) else { return }
            if library.applyRemoteMetadata(remote) == .rejectedByTombstone {
                // A stale device re-created a deleted document: re-assert the tombstone.
                library.markTombstonePending(id)
                syncEngine.state.add(pendingRecordZoneChanges: Self.tombstoneChanges(id))
            }
        case .position:
            guard let position = CloudRecords.position(from: record) else { return }
            if library.applyRemotePosition(id, position) == .rejectedByTombstone {
                syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(record.recordID)])
            }
        case .file:
            if library.isTombstoned(id) {
                syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(record.recordID)])
                return
            }
            guard let asset = record["asset"] as? CKAsset, let url = asset.fileURL else { return }
            // Copy now: CloudKit may remove its staging file once this event returns.
            if await library.installRemoteFile(id, from: url, sha256: record["sha256"] as? String) {
                library.markSynced(id, records: .file)
            }
        }
    }

    private func applyFetchedDeletion(_ recordID: CKRecord.ID, syncEngine: CKSyncEngine) {
        metadata?.remove(recordID)
        guard let (kind, id) = CloudRecords.parse(recordID) else { return }
        switch kind {
        case .document:
            library.applyRemoteDeletion(id)
        case .file:
            // The file vanished from iCloud while the document is still alive: upload it again.
            if library.entry(id) != nil, library.hasLocalFile(id) {
                library.markPending(id, records: .file)
                syncEngine.state.add(pendingRecordZoneChanges: Self.saves(for: id, records: .file))
            }
        case .position:
            break
        }
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, syncEngine: CKSyncEngine) {
        var requeue: [CKSyncEngine.PendingRecordZoneChange] = []
        var sawSuccess = false

        for record in sent.savedRecords {
            metadata?.store(record)
            sawSuccess = true
            guard let (kind, id) = CloudRecords.parse(record.recordID) else { continue }
            switch kind {
            case .document:
                if (record["deleted"] as? Int64 ?? 0) != 0 {
                    library.markTombstoneSynced(id)
                } else {
                    library.markSynced(id, records: .metadata, titleModifiedAt: record["titleModifiedAt"] as? Date)
                }
            case .position:
                library.markSynced(id, records: .position, pageModifiedAt: record["pageModifiedAt"] as? Date)
            case .file:
                library.markSynced(id, records: .file)
            }
        }
        for recordID in sent.deletedRecordIDs {
            metadata?.remove(recordID)
        }

        for failure in sent.failedRecordSaves {
            let recordID = failure.record.recordID
            guard let (kind, id) = CloudRecords.parse(recordID) else { continue }
            switch failure.error.code {
            case .serverRecordChanged:
                guard let server = failure.error.serverRecord else { continue }
                metadata?.store(server)
                if resolveConflict(kind: kind, id: id, server: server) {
                    requeue.append(.saveRecord(recordID))
                }
            case .zoneNotFound:
                metadata?.remove(recordID)
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudRecords.zoneID))])
                requeue.append(.saveRecord(recordID))
            case .unknownItem:
                // The server record is gone; save it fresh.
                metadata?.remove(recordID)
                requeue.append(.saveRecord(recordID))
            case .quotaExceeded:
                // Stays pending in the catalog; retried on next launch or Retry.
                let message = "iCloud storage is full. Free up iCloud space, then tap Retry."
                library.setUploadError(id, message)
                problem = message
            case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy,
                 .notAuthenticated, .operationCancelled, .limitExceeded, .batchRequestFailed:
                // Transient: the engine retries these itself.
                requeue.append(.saveRecord(recordID))
            default:
                log.error("Save of \(recordID.recordName, privacy: .public) failed: \(failure.error.localizedDescription, privacy: .public)")
                if kind == .file { library.setUploadError(id, failure.error.localizedDescription) }
                problem = failure.error.localizedDescription
            }
        }
        if sawSuccess, sent.failedRecordSaves.isEmpty { problem = nil }
        if !requeue.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: requeue) }
    }

    /// Merges a conflicting server record. Returns true when the local version must be saved again.
    private func resolveConflict(kind: CloudRecords.Kind, id: UUID, server: CKRecord) -> Bool {
        switch kind {
        case .document:
            let serverDeleted = (server["deleted"] as? Int64 ?? 0) != 0
            if library.isTombstoned(id) {
                // Deletion wins over any concurrent edit.
                if serverDeleted { library.markTombstoneSynced(id); return false }
                return true
            }
            guard let remote = CloudRecords.metadata(from: server, id: id) else { return true }
            switch library.applyRemoteMetadata(remote) {
            case .applied: return false        // server is newer (or a deletion): adopted locally
            case .ignored: return true         // local title is newer: write it over the server's
            case .rejectedByTombstone: return true
            }
        case .position:
            guard let remote = CloudRecords.position(from: server) else { return true }
            switch library.applyRemotePosition(id, remote) {
            case .applied: return false
            case .ignored: return library.entry(id)?.pageModifiedAt != remote.modifiedAt
            case .rejectedByTombstone: return false
            }
        case .file:
            // PDF bytes are immutable; the server copy is the same file.
            library.markSynced(id, records: .file)
            return false
        }
    }
}
