import CoreGraphics
import Foundation

/// Produces and caches forced-dark versions of a document's pages. Safe to call from PDFKit's render threads.
final class DarkPageRenderer: @unchecked Sendable {
    enum Rendering {
        /// The document is returned with its page so a cache eviction can't free it mid-draw.
        case derived(CGPDFDocument, CGPDFPage)
        case original
    }

    /// What the reader should tell the user about a page in forced dark mode.
    enum PageNote: Equatable, Sendable {
        /// An image with no PDF text (a scan): any text on it is part of the image and keeps its colors.
        case scan
        /// Drawn in original colors because the page uses something the recolorer can't reproduce.
        case unsupported(String)
    }

    private let source: CGPDFDocument?
    private let lock = NSLock()
    private var derived: [Int: CGPDFDocument] = [:]
    private var recency: [Int] = []
    private var notes: [Int: PageNote] = [:]
    private var unsupported: Set<Int> = []
    private static let cacheLimit = 8

    /// Opens its own Core Graphics document so it never contends with PDFKit's.
    init(url: URL) {
        source = CGPDFDocument(url as CFURL)
    }

    func rendering(forPage index: Int) -> Rendering {
        lock.lock()
        defer { lock.unlock() }
        if unsupported.contains(index) { return .original }
        if let document = derived[index], let page = document.page(at: 1) {
            touch(index)
            return .derived(document, page)
        }
        guard let source, let page = source.page(at: index + 1) else {
            return markUnsupported(index, "The page couldn't be read.")
        }
        switch DarkPageBuilder.build(page: page) {
        case .derived(let data):
            guard let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider),
                  let derivedPage = document.page(at: 1) else {
                return markUnsupported(index, "The recolored page couldn't be assembled.")
            }
            derived[index] = document
            touch(index)
            return .derived(document, derivedPage)
        case .scan:
            // No PDF text to recolor: draw the original (and keep no decoded copy in memory).
            notes[index] = .scan
            unsupported.insert(index)
            return .original
        case .unsupported(let message):
            return markUnsupported(index, message)
        }
    }

    private func markUnsupported(_ index: Int, _ message: String) -> Rendering {
        unsupported.insert(index)
        notes[index] = .unsupported(message)
        return .original
    }

    /// The note for a page, analysing it if needed. Call off the main thread.
    func note(forPage index: Int) -> PageNote? {
        _ = rendering(forPage: index)
        lock.lock()
        defer { lock.unlock() }
        return notes[index]
    }

    private func touch(_ index: Int) {
        recency.removeAll { $0 == index }
        recency.append(index)
        while recency.count > Self.cacheLimit {
            derived[recency.removeFirst()] = nil
        }
    }
}
