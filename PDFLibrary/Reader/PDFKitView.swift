import PDFKit
import SwiftUI

/// A PDFView that reports layout passes, so the saved page is restored only once the view has a size.
final class ReaderPDFView: PDFView {
    var onLayout: (() -> Void)?

    #if os(macOS)
    override func layout() {
        super.layout()
        notifyLayout()
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        notifyLayout()
    }
    #endif

    private func notifyLayout() {
        guard onLayout != nil else { return }
        // Restoring moves the view, so wait until the current layout pass has finished.
        DispatchQueue.main.async { [weak self] in self?.onLayout?() }
    }
}

#if os(macOS)
struct PDFKitView: NSViewRepresentable {
    let controller: ReaderController

    func makeCoordinator() -> ReaderController { controller }

    func makeNSView(context: Context) -> ReaderPDFView {
        let view = ReaderPDFView()
        controller.attach(view)
        return view
    }

    func updateNSView(_ view: ReaderPDFView, context: Context) {}

    static func dismantleNSView(_ view: ReaderPDFView, coordinator: ReaderController) {
        coordinator.detach()
    }
}
#else
struct PDFKitView: UIViewRepresentable {
    let controller: ReaderController
    /// Called for single taps that PDFKit doesn't use (links and selection keep working).
    var onTap: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> ReaderPDFView {
        let view = ReaderPDFView()
        controller.attach(view)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: ReaderPDFView, context: Context) {
        context.coordinator.onTap = onTap
    }

    static func dismantleUIView(_ view: ReaderPDFView, coordinator: Coordinator) {
        coordinator.controller.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let controller: ReaderController
        var onTap: (() -> Void)?

        init(controller: ReaderController) {
            self.controller = controller
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            onTap?()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Taps on links go to PDFKit only.
            guard let view = gestureRecognizer.view as? PDFView,
                  let page = view.page(for: touch.location(in: view), nearest: false) else { return true }
            let point = view.convert(touch.location(in: view), to: page)
            return page.annotation(at: point)?.url == nil && page.annotation(at: point)?.action == nil
        }
    }
}
#endif
