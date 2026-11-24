import PDFKit
import os

/// The reader's PDF document. Pages draw normally, or in forced dark mode when `forcedDark` is on.
final class ReaderDocument: PDFDocument, PDFDocumentDelegate {
    let darkRenderer: DarkPageRenderer
    private let darkState = OSAllocatedUnfairLock(initialState: false)

    /// Read from PDFKit's render threads.
    var forcedDark: Bool {
        get { darkState.withLock { $0 } }
        set { darkState.withLock { $0 = newValue } }
    }

    init?(fileURL: URL, forcedDark: Bool) {
        darkRenderer = DarkPageRenderer(url: fileURL)
        super.init(url: fileURL)
        self.forcedDark = forcedDark
        delegate = self
    }

    func classForPage() -> AnyClass {
        ReaderPage.self
    }
}

/// Draws a page. In forced dark mode it paints the dark surface and draws the recolored copy of the page:
/// text becomes light, images and artwork keep their original colors. Pages without PDF text (scans) and
/// pages the renderer can't reproduce are drawn exactly as the original.
final class ReaderPage: PDFPage {
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        guard let document = document as? ReaderDocument, document.forcedDark else {
            super.draw(with: box, to: context)
            return
        }
        let index = document.index(for: self)
        switch document.darkRenderer.rendering(forPage: index) {
        case .original:
            super.draw(with: box, to: context)
        case .derived(let page):
            let bounds = bounds(for: box)
            context.saveGState()
            context.setFillColor(DarkPalette.surfaceColor)
            context.fill(bounds)
            context.clip(to: bounds)
            context.drawPDFPage(page)
            context.restoreGState()
            for annotation in annotations where annotation.shouldDisplay {
                annotation.draw(with: box, in: context)
            }
        }
    }
}
