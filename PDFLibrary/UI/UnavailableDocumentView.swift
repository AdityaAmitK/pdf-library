import SwiftUI

/// Shown instead of the reader while a document's PDF hasn't reached this device.
struct UnavailableDocumentView: View {
    let entry: DocumentEntry
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = DocumentStatus(entry, library: model.library, sync: model.sync)
        ContentUnavailableView {
            switch status {
            case .downloading:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Downloading")
                }
            case .downloadFailed:
                Label("Download Failed", systemImage: "exclamationmark.triangle")
            default:
                Label("Waiting to Download", systemImage: "icloud.and.arrow.down")
            }
        } description: {
            Text(description(status))
        } actions: {
            if status != .downloading {
                Button("Retry") { model.sync.retryDownloads() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canDownload)
            }
        }
        .navigationTitle(entry.title)
    }

    private var canDownload: Bool {
        model.sync.status == .available && model.sync.isOnline
    }

    private func description(_ status: DocumentStatus) -> String {
        if case .downloadFailed(let message) = status {
            return "“\(entry.title)” couldn’t be downloaded: \(message)"
        }
        if status == .downloading {
            return "“\(entry.title)” opens as soon as it’s on this device."
        }
        switch model.sync.status {
        case .noAccount, .restricted:
            return "“\(entry.title)” is in iCloud. Sign in to iCloud to download it."
        case .disabled:
            return "This build can’t download from iCloud."
        default:
            return model.sync.isOnline
                ? "“\(entry.title)” hasn’t reached this device yet. It downloads automatically."
                : "“\(entry.title)” will download when you’re back online."
        }
    }
}
