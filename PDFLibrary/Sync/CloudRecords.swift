import CloudKit
import Foundation

/// CloudKit schema (private database, custom zone "Library"). See docs/CLOUDKIT.md.
///
/// - `Document`  (recordName = document UUID): title, titleModifiedAt, createdAt, byteSize, sha256, pageCount,
///   deleted. Deletion is a tombstone (`deleted = 1`) that is never removed, so it beats stale offline edits.
/// - `PDFFile`   (recordName = "file-<UUID>"): asset, sha256. Written once at import; never re-uploaded.
/// - `Position`  (recordName = "pos-<UUID>"): pageIndex, pageModifiedAt. Changes often, kept tiny.
enum CloudRecords {
    static let containerIdentifier = "iCloud.com.aditya.pdflibrary"
    static let zoneID = CKRecordZone.ID(zoneName: "Library", ownerName: CKCurrentUserDefaultName)

    enum Kind: String {
        case document = "Document"
        case file = "PDFFile"
        case position = "Position"
    }

    static func recordID(_ kind: Kind, _ id: UUID) -> CKRecord.ID {
        switch kind {
        case .document: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        case .file: CKRecord.ID(recordName: "file-\(id.uuidString)", zoneID: zoneID)
        case .position: CKRecord.ID(recordName: "pos-\(id.uuidString)", zoneID: zoneID)
        }
    }

    static func parse(_ recordID: CKRecord.ID) -> (Kind, UUID)? {
        let name = recordID.recordName
        if name.hasPrefix("file-"), let id = UUID(uuidString: String(name.dropFirst(5))) { return (.file, id) }
        if name.hasPrefix("pos-"), let id = UUID(uuidString: String(name.dropFirst(4))) { return (.position, id) }
        if let id = UUID(uuidString: name) { return (.document, id) }
        return nil
    }

    static func metadata(from record: CKRecord, id: UUID) -> RemoteMetadata? {
        let deleted = (record["deleted"] as? Int64 ?? 0) != 0
        guard deleted || (record["title"] as? String) != nil else { return nil }
        return RemoteMetadata(
            id: id,
            title: record["title"] as? String ?? "",
            titleModifiedAt: record["titleModifiedAt"] as? Date ?? .distantPast,
            createdAt: record["createdAt"] as? Date ?? record.creationDate ?? Date(),
            byteSize: record["byteSize"] as? Int64 ?? 0,
            sha256: record["sha256"] as? String ?? "",
            pageCount: Int(record["pageCount"] as? Int64 ?? 0),
            deleted: deleted)
    }

    static func position(from record: CKRecord) -> RemotePosition? {
        guard let page = record["pageIndex"] as? Int64, let date = record["pageModifiedAt"] as? Date else { return nil }
        return RemotePosition(pageIndex: Int(page), modifiedAt: date)
    }

    static func fill(_ record: CKRecord, with entry: DocumentEntry) {
        record["title"] = entry.title
        record["titleModifiedAt"] = entry.titleModifiedAt
        record["createdAt"] = entry.createdAt
        record["byteSize"] = entry.byteSize
        record["sha256"] = entry.sha256
        record["pageCount"] = Int64(entry.pageCount)
        record["deleted"] = Int64(0)
    }

    static func fillTombstone(_ record: CKRecord, deletedAt: Date) {
        record["deleted"] = Int64(1)
        // Only fields the Production schema already has: CloudKit Production rejects new fields.
        record["titleModifiedAt"] = deletedAt
        record["title"] = nil
    }
}

/// CloudKit system fields (change tags) per record name, so saves update the existing server record instead
/// of failing with "record already exists". Persisted next to the sync state.
struct RecordMetadataCache {
    private(set) var fields: [String: Data] = [:]
    let url: URL

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? PropertyListDecoder().decode([String: Data].self, from: data) {
            fields = decoded
        }
    }

    func record(for recordID: CKRecord.ID, type: CloudRecords.Kind) -> CKRecord {
        if let data = fields[recordID.recordName],
           let coder = try? NSKeyedUnarchiver(forReadingFrom: data) {
            coder.requiresSecureCoding = true
            defer { coder.finishDecoding() }
            if let record = CKRecord(coder: coder), record.recordID == recordID { return record }
        }
        return CKRecord(recordType: type.rawValue, recordID: recordID)
    }

    mutating func store(_ record: CKRecord) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        fields[record.recordID.recordName] = coder.encodedData
    }

    mutating func remove(_ recordID: CKRecord.ID) {
        fields[recordID.recordName] = nil
    }

    mutating func removeAll() { fields = [:] }

    func persist() {
        guard let data = try? PropertyListEncoder().encode(fields) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
