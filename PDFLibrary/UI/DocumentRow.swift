import SwiftUI

/// Where a document stands on this device and in iCloud.
enum DocumentStatus: Equatable {
    case downloading
    case waitingForDownload
    case downloadFailed(String)
    case uploadFailed(String)
    case waitingToUpload
    case inICloud
    case onDeviceOnly

    @MainActor
    init(_ entry: DocumentEntry, library: LibraryStore, sync: SyncController) {
        if !library.hasLocalFile(entry.id) {
            if sync.downloadsInFlight.contains(entry.id) {
                self = .downloading
            } else if let error = entry.downloadError {
                self = .downloadFailed(error)
            } else {
                self = .waitingForDownload
            }
        } else if let error = entry.uploadError {
            self = .uploadFailed(error)
        } else if !entry.pending.isEmpty, sync.uploadsExpected {
            self = .waitingToUpload
        } else if entry.fileInCloud {
            self = .inICloud
        } else {
            self = .onDeviceOnly
        }
    }

    var isAvailable: Bool {
        switch self {
        case .downloading, .waitingForDownload, .downloadFailed: false
        default: true
        }
    }
}

struct DocumentRow: View {
    let entry: DocumentEntry
    let status: DocumentStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ReadingProgressRing(progress: progress)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                .opacity(status.isAvailable ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .lineLimit(2)
                    .foregroundStyle(status.isAvailable ? .primary : .secondary)
                HStack(spacing: 6) {
                    Text(positionText)
                    statusLabel
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var progress: Double? {
        guard entry.pageModifiedAt != nil, entry.pageCount > 0 else { return nil }
        return Double(entry.pageIndex + 1) / Double(entry.pageCount)
    }

    private var positionText: String {
        entry.pageModifiedAt == nil ? "Not started" : "Page \(entry.pageIndex + 1) of \(entry.pageCount)"
    }

    @ViewBuilder private var statusLabel: some View {
        switch status {
        case .downloading:
            StatusTag(text: "Downloading", showsText: true) { ProgressView().controlSize(.mini) }
        case .waitingForDownload:
            StatusTag(text: "Waiting to download", symbol: "icloud.and.arrow.down", showsText: true)
        case .downloadFailed:
            StatusTag(text: "Download failed", symbol: "exclamationmark.triangle.fill", showsText: true)
                .foregroundStyle(.red)
        case .uploadFailed:
            StatusTag(text: "Upload failed", symbol: "exclamationmark.icloud.fill", showsText: true)
                .foregroundStyle(.red)
        case .waitingToUpload:
            StatusTag(text: "Waiting to upload", symbol: "arrow.up.icloud", showsText: false)
        case .inICloud:
            StatusTag(text: "In iCloud", symbol: "checkmark.icloud", showsText: false)
                .foregroundStyle(.tertiary)
        case .onDeviceOnly:
            EmptyView()
        }
    }

    private var errorMessage: String? {
        switch status {
        case .downloadFailed(let message), .uploadFailed(let message): message
        default: nil
        }
    }
}

/// A compact "· icon text" status. Quiet states show only the icon; VoiceOver still reads the text.
private struct StatusTag<Icon: View>: View {
    let text: String
    let showsText: Bool
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "·").accessibilityHidden(true)
            icon.imageScale(.small)
            if showsText { Text(text) }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

extension StatusTag where Icon == Image {
    init(text: String, symbol: String, showsText: Bool) {
        self.init(text: text, showsText: showsText) { Image(systemName: symbol) }
    }
}

/// How far through the document the reader is; an empty track means not started.
struct ReadingProgressRing: View {
    let progress: Double?
    @ScaledMetric(relativeTo: .body) private var size = 20
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.04, progress))
                    .stroke(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
