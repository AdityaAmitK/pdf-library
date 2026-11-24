import Observation
import PDFKit
import SwiftUI

/// Drives one open document: restores the saved page, records pages the reader moves to, applies forced
/// dark mode in place, and exposes navigation and zoom for toolbars and menu commands.
@MainActor
@Observable
final class ReaderController {
    let id: UUID
    let document: ReaderDocument
    private(set) var currentPage = 0
    private(set) var note: DarkPageRenderer.PageNote?
    private(set) var forcedDark: Bool
    /// Shows the Go to Page prompt; set by the toolbar, the page indicator and the Go menu.
    var isGoToPagePresented = false

    var pageCount: Int { document.pageCount }

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private weak var pdfView: ReaderPDFView?
    @ObservationIgnored private var defaultBackground: PlatformColor?
    @ObservationIgnored private var pageObserver: NSObjectProtocol?
    @ObservationIgnored private var noteTask: Task<Void, Never>?
    /// The saved page has been applied. Page changes before that are PDFKit settling, not the reader.
    @ObservationIgnored private var restored = false
    /// Nonzero while the app itself moves the view (restore, dark-mode redraw, remote jump).
    @ObservationIgnored private var programmaticMoves = 0
    /// The reader has moved since opening; remote positions no longer move the view.
    @ObservationIgnored private var userNavigated = false

    init?(id: UUID, library: LibraryStore, forcedDark: Bool) {
        guard let document = ReaderDocument(fileURL: library.fileURL(id), forcedDark: forcedDark),
              document.pageCount > 0 else { return nil }
        self.id = id
        self.library = library
        self.document = document
        self.forcedDark = forcedDark
    }

    // MARK: View lifecycle

    func attach(_ view: ReaderPDFView) {
        pdfView = view
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        defaultBackground = view.backgroundColor
        applyBackground()
        view.onLayout = { [weak self] in self?.restoreIfReady() }
        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: view, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pageChanged() }
        }
        view.document = document
    }

    func detach() {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        pageObserver = nil
        noteTask?.cancel()
        pdfView?.onLayout = nil
        library.flushPendingSave()
    }

    /// Restores the saved page once the view has a size; `go(to:)` before layout lands on the wrong page.
    private func restoreIfReady() {
        guard !restored, let view = pdfView, view.bounds.width > 0, view.bounds.height > 0 else { return }
        restored = true
        view.onLayout = nil
        let saved = library.entry(id)?.pageIndex ?? 0
        moveProgrammatically { [self] in
            if let page = document.page(at: clamp(saved)) { view.go(to: page) }
        }
    }

    // MARK: Page tracking

    private func pageChanged() {
        guard let page = visiblePageIndex, page != currentPage else { return }
        currentPage = page
        refreshNote()
        guard restored, programmaticMoves == 0 else { return }
        userNavigated = true
        library.recordPosition(id, page: page)
    }

    private var visiblePageIndex: Int? {
        guard let page = pdfView?.currentPage else { return nil }
        return document.index(for: page)
    }

    /// Runs a move the user didn't make, then re-reads the page once PDFKit has settled so the
    /// notifications it posts meanwhile are not recorded as reading progress.
    private func moveProgrammatically(_ move: () -> Void) {
        programmaticMoves += 1
        move()
        DispatchQueue.main.async { [self] in
            if let page = visiblePageIndex, page != currentPage {
                currentPage = page
                refreshNote()
            }
            programmaticMoves -= 1
        }
    }

    /// A newer position arrived from another device. Follow it only if the reader hasn't moved yet.
    func remotePositionChanged(to page: Int) {
        guard restored, !userNavigated, clamp(page) != currentPage,
              let view = pdfView, let target = document.page(at: clamp(page)) else { return }
        moveProgrammatically { view.go(to: target) }
    }

    private func clamp(_ page: Int) -> Int { min(max(0, page), pageCount - 1) }

    // MARK: Navigation (user actions; the resulting page change is recorded)

    var canGoBack: Bool { currentPage > 0 }
    var canGoForward: Bool { currentPage < pageCount - 1 }

    func goToPage(_ index: Int) {
        guard let page = document.page(at: clamp(index)) else { return }
        pdfView?.go(to: page)
    }

    func nextPage() { pdfView?.goToNextPage(nil) }
    func previousPage() { pdfView?.goToPreviousPage(nil) }
    func firstPage() { pdfView?.goToFirstPage(nil) }
    func lastPage() { pdfView?.goToLastPage(nil) }

    func zoomIn() { pdfView?.zoomIn(nil) }
    func zoomOut() { pdfView?.zoomOut(nil) }
    func zoomToActualSize() {
        pdfView?.autoScales = false
        pdfView?.scaleFactor = 1
    }
    func zoomToFit() { pdfView?.autoScales = true }

    // MARK: Forced dark mode

    /// Applies the setting to the open document and redraws it at the exact same spot and zoom.
    func setForcedDark(_ on: Bool) {
        guard on != forcedDark else { return }
        forcedDark = on
        document.forcedDark = on
        applyBackground()
        refreshNote()
        guard let view = pdfView, view.document != nil else { return }
        let destination = view.currentDestination
        let autoScales = view.autoScales
        let scale = view.scaleFactor
        moveProgrammatically {
            // PDFKit caches drawn page tiles; reattaching the document is the supported way to redraw them.
            view.document = nil
            view.document = document
            if autoScales {
                view.autoScales = true
            } else {
                view.scaleFactor = scale
            }
            view.layoutDocumentView()
            if let destination { view.go(to: destination) }
        }
    }

    private func applyBackground() {
        guard let view = pdfView else { return }
        if forcedDark {
            view.backgroundColor = .readerDarkSurface
        } else if let defaultBackground {
            view.backgroundColor = defaultBackground
        }
    }

    private func refreshNote() {
        noteTask?.cancel()
        guard forcedDark else {
            note = nil
            return
        }
        let renderer = document.darkRenderer
        let page = currentPage
        noteTask = Task { [weak self] in
            let note = await Task.detached(priority: .utility) { renderer.note(forPage: page) }.value
            guard !Task.isCancelled, let self, self.currentPage == page, self.forcedDark else { return }
            self.note = note
        }
    }
}

#if os(macOS)
typealias PlatformColor = NSColor
#else
typealias PlatformColor = UIColor
#endif

extension PlatformColor {
    static var readerDarkSurface: PlatformColor {
        #if os(macOS)
        NSColor(cgColor: DarkPalette.surfaceColor) ?? .black
        #else
        UIColor(cgColor: DarkPalette.surfaceColor)
        #endif
    }
}
