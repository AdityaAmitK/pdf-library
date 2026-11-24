import SwiftUI

/// The reader for one document that has a local file.
struct ReaderView: View {
    let id: UUID
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.forcePDFDarkMode) private var forceDark = false
    @State private var controller: ReaderController?
    @State private var failedToOpen = false

    var body: some View {
        Group {
            if let controller {
                ReaderContent(controller: controller, title: title, forceDark: $forceDark)
            } else if failedToOpen {
                ContentUnavailableView(
                    "Can’t Open This PDF",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The file on this device couldn’t be read. Delete it and import it again.")
                )
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .task {
            guard controller == nil else { return }
            controller = ReaderController(id: id, library: model.library, forcedDark: forceDark)
            failedToOpen = controller == nil
        }
        .onChange(of: forceDark) { _, on in controller?.setForcedDark(on) }
        .onChange(of: model.library.entry(id)?.pageIndex) { _, page in
            if let page { controller?.remotePositionChanged(to: page) }
        }
        .onDisappear { model.library.flushPendingSave() }
    }

    private var title: String { model.library.entry(id)?.title ?? "" }
}

private struct ReaderContent: View {
    @Bindable var controller: ReaderController
    let title: String
    @Binding var forceDark: Bool
    @State private var pageText = ""
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var chromeHidden = false
    #endif

    var body: some View {
        // The overlay sits in a ZStack so it keeps to the safe area while the pages scroll under the bars.
        ZStack(alignment: .bottom) {
            reader
            VStack(spacing: 8) {
                if let note = controller.note {
                    PageNoteView(note: note)
                        .transition(.opacity)
                }
                #if os(iOS)
                PageIndicator(controller: controller)
                #endif
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
            .environment(\.colorScheme, controller.forcedDark ? .dark : colorScheme)
            .animation(.easeOut(duration: 0.2), value: controller.note)
        }
            .toolbar { toolbar }
            .focusedSceneValue(\.reader, controller)
            .alert("Go to Page", isPresented: $controller.isGoToPagePresented) {
                TextField("Page", text: $pageText)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Button("Go") {
                    if let page = Int(pageText.trimmingCharacters(in: .whitespaces)) {
                        controller.goToPage(min(max(page, 1), max(controller.pageCount, 1)) - 1)
                    }
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a page number from 1 to \(controller.pageCount).")
            }
            .onChange(of: controller.isGoToPagePresented) { _, shown in
                if shown { pageText = "" }
            }
            #if os(macOS)
            .navigationSubtitle("Page \(controller.currentPage + 1) of \(controller.pageCount)")
            #else
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(chromeHidden ? .hidden : .automatic, for: .navigationBar)
            .statusBarHidden(chromeHidden)
            .persistentSystemOverlays(chromeHidden ? .hidden : .automatic)
            .animation(.easeInOut(duration: 0.2), value: chromeHidden)
            .onChange(of: sizeClass) { _, size in if size != .compact { chromeHidden = false } }
            #endif
    }

    @ViewBuilder private var reader: some View {
        #if os(macOS)
        PDFKitView(controller: controller)
        #else
        PDFKitView(controller: controller, onTap: sizeClass == .compact ? { chromeHidden.toggle() } : nil)
            .ignoresSafeArea(edges: chromeHidden ? .all : .bottom)
        #endif
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        #if os(macOS)
        ToolbarItemGroup(placement: .navigation) {
            ControlGroup {
                Button("Previous Page", systemImage: "chevron.up", action: controller.previousPage)
                    .disabled(!controller.canGoBack)
                Button("Next Page", systemImage: "chevron.down", action: controller.nextPage)
                    .disabled(!controller.canGoForward)
            }
            .help("Previous or next page")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Go to Page", systemImage: "number") { controller.isGoToPagePresented = true }
                .help("Go to Page (⌥⌘G)")
        }
        #endif
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $forceDark) {
                Label("Force PDF Dark Mode", systemImage: forceDark ? "moon.fill" : "moon")
            }
            .toggleStyle(.button)
            .help("Force PDF Dark Mode (⇧⌘D)")
        }
    }
}

/// "3 / 120" in a capsule that stays visible when the bars are hidden; tap to jump to a page.
private struct PageIndicator: View {
    let controller: ReaderController

    var body: some View {
        Button {
            controller.isGoToPagePresented = true
        } label: {
            Text("\(controller.currentPage + 1) / \(controller.pageCount)")
                .font(.footnote.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thickMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(controller.currentPage + 1) of \(controller.pageCount)")
        .accessibilityHint("Go to a page")
    }
}

/// Tells the reader why a page kept its original colors in forced dark mode.
private struct PageNoteView: View {
    let note: DarkPageRenderer.PageNote

    var body: some View {
        Label(message, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(maxWidth: 460)
            .accessibilityElement(children: .combine)
    }

    private var message: String {
        switch note {
        case .scan: "Scanned page — its text is part of the image and keeps its original colors"
        case .unsupported(let reason): "Shown in original colors: \(reason)"
        case .lightBoxes: "Some text sits on light boxes that keep their original color and may be hard to read"
        }
    }
}
