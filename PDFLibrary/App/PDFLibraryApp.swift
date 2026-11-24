import SwiftUI

@main
struct PDFLibraryApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            Text("\(model.library.documents.count) documents")
        }
    }
}
