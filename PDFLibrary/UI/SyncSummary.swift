import SwiftUI

/// What the library footer and Settings say about iCloud.
struct SyncSummary {
    enum Tone { case normal, busy, warning, error }

    let message: String
    let systemImage: String
    let tone: Tone
    let canRetry: Bool

    @MainActor
    init(_ sync: SyncController) {
        if let problem = sync.problem {
            self.init(problem, "exclamationmark.icloud", .error, retry: true)
            return
        }
        switch sync.status {
        case .disabled:
            self.init("iCloud sync unavailable in this build", "icloud.slash", .normal)
        case .checking:
            self.init("Checking iCloud…", "icloud", .busy)
        case .noAccount:
            self.init("iCloud off — local library", "icloud.slash", .normal)
        case .restricted:
            self.init("iCloud restricted — local library", "icloud.slash", .normal)
        case .temporarilyUnavailable:
            self.init("iCloud temporarily unavailable", "exclamationmark.icloud", .warning, retry: true)
        case .waitingForNetwork:
            self.init("Waiting for a connection to reach iCloud", "wifi.slash", .warning)
        case .error(let message):
            self.init(message, "exclamationmark.icloud", .error, retry: true)
        case .available where !sync.isOnline:
            self.init("Offline — changes sync when you’re back online", "wifi.slash", .warning)
        case .available where sync.isSyncing || !sync.downloadsInFlight.isEmpty:
            self.init("Syncing with iCloud…", "arrow.triangle.2.circlepath.icloud", .busy)
        case .available where !sync.library.missingFiles.isEmpty:
            // Nothing is transferring right now, but some PDFs still aren't on this device.
            let count = sync.library.missingFiles.count
            self.init(count == 1 ? "1 PDF waiting to download" : "\(count) PDFs waiting to download",
                      "icloud.and.arrow.down", .warning, retry: true)
        case .available where sync.library.catalog.documents.values.contains(where: { $0.uploadError != nil }):
            self.init("Some PDFs couldn’t upload", "exclamationmark.icloud", .warning, retry: true)
        case .available where sync.library.catalog.documents.values.contains(where: { !$0.pending.isEmpty }):
            self.init("Waiting to upload changes…", "arrow.triangle.2.circlepath.icloud", .busy, retry: true)
        case .available:
            self.init("Synced with iCloud", "checkmark.icloud", .normal)
        }
    }

    private init(_ message: String, _ systemImage: String, _ tone: Tone, retry: Bool = false) {
        self.message = message
        self.systemImage = systemImage
        self.tone = tone
        canRetry = retry
    }

    var iconStyle: AnyShapeStyle {
        switch tone {
        case .normal, .busy: AnyShapeStyle(.secondary)
        case .warning: AnyShapeStyle(.orange)
        case .error: AnyShapeStyle(.red)
        }
    }
}

extension SyncController {
    /// Uploads only happen with a signed-in iCloud account, so "waiting to upload" means nothing otherwise.
    var uploadsExpected: Bool {
        switch status {
        case .disabled, .noAccount, .restricted: false
        default: true
        }
    }
}
