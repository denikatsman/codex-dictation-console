import SwiftUI

struct AppAccessControls: View {
    @ObservedObject var settings: AppAccessSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App access").font(.title3.weight(.semibold))
            Toggle("Show in menu bar", isOn: Binding(
                get: { settings.preferences.showInMenuBar }, set: { settings.setMenuBar($0) }
            ))
            .disabled(!settings.preferences.showInDock)
            Toggle("Show in Dock", isOn: Binding(
                get: { settings.preferences.showInDock }, set: { settings.setDock($0) }
            ))
            .disabled(!settings.preferences.showInMenuBar)
            Text("Keep at least one way to open the library. Changes apply immediately. The capture helper keeps its separate status menu.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
