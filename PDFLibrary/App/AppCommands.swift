import SwiftUI

enum SettingsKey {
    static let forcePDFDarkMode = "forcePDFDarkMode"
}

/// Library actions the focused window offers to the menu bar.
struct LibraryActions {
    var importPDFs: () -> Void
    var renameSelection: (() -> Void)?
    var deleteSelection: (() -> Void)?
}

extension FocusedValues {
    @Entry var reader: ReaderController?
    @Entry var libraryActions: LibraryActions?
}

struct AppCommands: Commands {
    @FocusedValue(\.reader) private var reader
    @FocusedValue(\.libraryActions) private var library
    @AppStorage(SettingsKey.forcePDFDarkMode) private var forceDark = false

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import…") { library?.importPDFs() }
                .keyboardShortcut("o")
                .disabled(library == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Rename…") { library?.renameSelection?() }
                .disabled(library?.renameSelection == nil)
            Button("Delete…") { library?.deleteSelection?() }
                .keyboardShortcut(.delete)
                .disabled(library?.deleteSelection == nil)
        }
        CommandGroup(after: .toolbar) {
            Toggle("Force PDF Dark Mode", isOn: $forceDark)
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Zoom In") { reader?.zoomIn() }
                .keyboardShortcut("+")
                .disabled(reader == nil)
            Button("Zoom Out") { reader?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(reader == nil)
            Button("Actual Size") { reader?.zoomToActualSize() }
                .keyboardShortcut("0")
                .disabled(reader == nil)
            Button("Zoom to Fit") { reader?.zoomToFit() }
                .keyboardShortcut("9")
                .disabled(reader == nil)
            Divider()
        }
        CommandMenu("Go") {
            Button("Next Page") { reader?.nextPage() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(reader?.canGoForward != true)
            Button("Previous Page") { reader?.previousPage() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(reader?.canGoBack != true)
            Divider()
            Button("First Page") { reader?.firstPage() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(reader?.canGoBack != true)
            Button("Last Page") { reader?.lastPage() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(reader?.canGoForward != true)
            Divider()
            Button("Go to Page…") { reader?.isGoToPagePresented = true }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(reader == nil)
        }
    }
}
