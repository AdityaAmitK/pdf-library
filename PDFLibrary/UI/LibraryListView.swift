import SwiftUI

/// The sidebar (Mac, iPad) or first screen (iPhone): every PDF with its reading position and sync state.
struct LibraryListView: View {
    @Binding var selection: UUID?
    let importsInFlight: Int
    let onImport: () -> Void
    let onRename: (DocumentEntry) -> Void
    let onDelete: (DocumentEntry) -> Void
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        let library = model.library
        List(selection: $selection) {
            ForEach(library.documents) { entry in
                DocumentRow(entry: entry, status: DocumentStatus(entry, library: library, sync: model.sync))
                    .tag(entry.id)
                    .contextMenu { menu(for: entry) }
                    #if os(iOS)
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash") { onDelete(entry) }
                            .tint(.red)
                    }
                    .swipeActions(edge: .leading) {
                        Button("Rename", systemImage: "pencil") { onRename(entry) }
                            .tint(.accentColor)
                    }
                    #endif
            }
        }
        .overlay {
            if library.documents.isEmpty { emptyState }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let notice = library.notice {
                NoticeBanner(notice: notice) { library.notice = nil }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SyncStatusBar(importsInFlight: importsInFlight)
        }
        .animation(.easeOut(duration: 0.2), value: library.notice)
        #if os(macOS)
        .onDeleteCommand {
            if let id = selection, let entry = library.entry(id) { onDelete(entry) }
        }
        #endif
    }

    @ViewBuilder private func menu(for entry: DocumentEntry) -> some View {
        Button("Rename…", systemImage: "pencil") { onRename(entry) }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { onDelete(entry) }
    }

    @ViewBuilder private var emptyState: some View {
        #if os(iOS)
        if sizeClass == .compact {
            LibraryEmptyView(onImport: onImport)
        } else {
            Text("No PDFs").foregroundStyle(.secondary)
        }
        #else
        Text("No PDFs").foregroundStyle(.secondary)
        #endif
    }
}

/// The first-run invitation to import.
struct LibraryEmptyView: View {
    let onImport: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("No PDFs Yet", systemImage: "books.vertical")
        } description: {
            Text(description)
        } actions: {
            Button("Import PDFs…", action: onImport)
                .buttonStyle(.borderedProminent)
        }
    }

    private var description: String {
        switch model.sync.status {
        case .noAccount, .restricted:
            "iCloud is off, so PDFs you import stay on this device."
        case .disabled:
            "PDFs you import are kept on this device."
        default:
            "Import a PDF to start reading. It’s kept on this device and in iCloud, so every device opens it at the same page."
        }
    }
}

/// A dismissible message from the library, such as an import that was skipped.
struct NoticeBanner: View {
    let notice: LibraryNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(notice.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                .accessibilityHidden(true)
            Text(notice.message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .task(id: notice) {
            // Information fades on its own; errors stay until dismissed.
            guard !notice.isError else { return }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { dismiss() }
        }
    }
}

/// The library footer: iCloud state, import progress and Retry.
struct SyncStatusBar: View {
    let importsInFlight: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = SyncSummary(model.sync)
        HStack(spacing: 8) {
            if importsInFlight > 0 {
                ProgressView().controlSize(.small)
                Text("Importing…")
            } else {
                Group {
                    if summary.tone == .busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: summary.systemImage)
                            .foregroundStyle(summary.iconStyle)
                    }
                }
                .accessibilityHidden(true)
                Text(summary.message)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if summary.canRetry && importsInFlight == 0 {
                Button("Retry") { model.sync.syncNow() }
                    .buttonStyle(.borderless)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}
