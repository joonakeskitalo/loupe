import SwiftUI
import UniformTypeIdentifiers

/// Shown when no folder is open. Prompts the user to drop or choose a folder.
struct DropZoneView: View {
    @Bindable var model: BrowserModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 72))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)

            Text("Drop a folder to browse")
                .font(.title2.weight(.medium))

            Text("Images, videos, and PDFs will be flattened into one view.\nUse the sidebar to browse folders individually.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Choose Folder…") {
                chooseFolder()
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .padding(24)
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.open(url: url)
        }
    }
}
