import SwiftUI

@main
struct LoupeApp: App {
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Each window owns its own BrowserModel (created in ContentView), so
        // multiple windows can browse different folders independently. The
        // window's value is an optional folder URL to open on launch; the
        // presentation type is `URL?` so a `nil` value (an empty window) is
        // itself a valid value that `openWindow(value:)` can accept.
        WindowGroup(for: URL?.self) { $url in
            ContentView(initialFolder: url ?? nil)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    openWindow(value: URL?.none)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Open Folder in New Window…") {
                    if let url = chooseFolder() {
                        openWindow(value: URL?.some(url))
                    }
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }

    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
