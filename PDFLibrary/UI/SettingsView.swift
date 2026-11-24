import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.forcePDFDarkMode) private var forceDark = false
    @AppStorage(SettingsKey.appAppearance) private var appearance = AppAppearance.system
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        let summary = SyncSummary(model.sync)
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("App")
            } footer: {
                Text("Dark uses dark menus, lists and toolbars everywhere in the app. PDF pages stay as they are unless Force PDF Dark Mode is on.")
            }
            Section {
                Toggle("Force PDF Dark Mode", isOn: $forceDark)
            } header: {
                Text("Reading")
            } footer: {
                Text("Shows PDF pages on a dark background with light text, even when your device uses Light appearance. Photos, artwork and scanned pages keep their original colors. Only the reader changes.")
            }
            Section("iCloud") {
                LabeledContent("Status") {
                    Text(summary.message)
                        .multilineTextAlignment(.trailing)
                }
                if summary.canRetry {
                    Button("Retry Sync") { model.sync.syncNow() }
                }
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        #else
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        #endif
    }
}
