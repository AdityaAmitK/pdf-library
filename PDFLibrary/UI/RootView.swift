import SwiftUI
import UniformTypeIdentifiers

/// The library window: a split view that collapses to a stack on iPhone and narrow iPad windows.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(OpenRequests.self) private var openRequests
    @State private var selection: UUID?
    @State private var isImporterPresented = false
    @State private var importsInFlight = 0
    @State private var renaming: DocumentEntry?
    @State private var renameText = ""
    @State private var deleting: DocumentEntry?
    @State private var isDropTargeted = false
    #if os(iOS)
    @State private var isSettingsPresented = false
    #endif

    var body: some View {
        NavigationSplitView {
            LibraryListView(
                selection: $selection,
                importsInFlight: importsInFlight,
                onImport: { isImporterPresented = true },
                onRename: beginRename,
                onDelete: { deleting = $0 }
            )
            .navigationTitle("Library")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
            #endif
            .toolbar { libraryToolbar }
        } detail: {
            NavigationStack { detail }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.tint, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            importPDFs(files)
            return !files.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importPDFs(urls)
            case .failure(let error): model.library.notice = .error(error.localizedDescription)
            }
        }
        #if os(iOS)
        .onOpenURL { url in
            if url.isFileURL { openRequests.urls.append(url) }
        }
        #endif
        .onChange(of: openRequests.urls, initial: true) { _, urls in
            guard !urls.isEmpty else { return }
            openRequests.urls = []
            importPDFs(urls)
        }
        .onChange(of: model.library.documents.map(\.id)) { _, ids in
            // Deleted here or on another device: close its reader.
            if let id = selection, !ids.contains(id) { selection = nil }
        }
        .alert("Rename PDF", isPresented: isPresented($renaming)) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let renaming { model.library.rename(renaming.id, to: renameText) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(deleting?.title ?? "")”?",
            isPresented: isPresented($deleting),
            titleVisibility: .visible,
            presenting: deleting
        ) { entry in
            Button("Delete", role: .destructive) { delete(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It will be removed from all your devices.")
        }
        #if os(iOS)
        .sheet(isPresented: $isSettingsPresented) {
            NavigationStack { SettingsView() }
        }
        #endif
        .focusedSceneValue(\.libraryActions, libraryActions)
    }

    @ViewBuilder private var detail: some View {
        if let id = selection, let entry = model.library.entry(id) {
            if model.library.hasLocalFile(id) {
                ReaderView(id: id).id(id)
            } else {
                UnavailableDocumentView(entry: entry)
            }
        } else if model.library.documents.isEmpty {
            LibraryEmptyView { isImporterPresented = true }
        } else {
            ContentUnavailableView("No PDF Selected", systemImage: "doc.text", description: Text("Choose a PDF from your library."))
        }
    }

    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) {
            Button("Settings", systemImage: "gearshape") { isSettingsPresented = true }
        }
        #endif
        ToolbarItem(placement: .primaryAction) {
            Button("Import PDFs", systemImage: "plus") { isImporterPresented = true }
                .help("Import PDFs (⌘O)")
        }
    }

    private var libraryActions: LibraryActions {
        let dialogOpen = renaming != nil || deleting != nil || isImporterPresented
        let selected = dialogOpen ? nil : selection.flatMap(model.library.entry)
        return LibraryActions(
            importPDFs: { isImporterPresented = true },
            renameSelection: selected.map { entry in { beginRename(entry) } },
            deleteSelection: selected.map { entry in { deleting = entry } }
        )
    }

    private func beginRename(_ entry: DocumentEntry) {
        renameText = entry.title
        renaming = entry
    }

    private func delete(_ entry: DocumentEntry) {
        if selection == entry.id { selection = nil }
        model.library.delete(entry.id)
    }

    private func importPDFs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let before = Set(model.library.documents.map(\.id))
        importsInFlight += 1
        Task {
            await model.library.importFiles(urls)
            importsInFlight -= 1
            // Opening a single PDF (Open With, Open in, one dropped file) goes straight to it.
            let added = model.library.documents.filter { !before.contains($0.id) }
            if added.count == 1 { selection = added[0].id }
        }
    }

    private func isPresented<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}
