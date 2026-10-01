import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    /// Folder to open when this window first appears (nil shows the drop zone).
    let initialFolder: URL?

    @State private var model = BrowserModel()
    @State private var isTargeted = false

    init(initialFolder: URL? = nil) {
        self.initialFolder = initialFolder
    }

    var body: some View {
        Group {
            if model.root == nil {
                DropZoneView(model: model)
            } else {
                NavigationSplitView {
                    FolderSidebar(model: model)
                        .frame(minWidth: 220)
                } detail: {
                    detail
                }
            }
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 4)
                    .background(Color.accentColor.opacity(0.08))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .fullScreenViewer(isPresented: $model.isViewerPresented) {
            MediaViewer(model: model)
        }
        .onAppear {
            if let initialFolder, model.root == nil {
                model.open(url: initialFolder)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if model.isScanning {
                ProgressView("Scanning \(model.rootName)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BrowserGridView(model: model)
            }
        }
        // Hide the window chrome's controls while the full viewer is up so the
        // sort/zoom/view controls don't float over the fullscreen image.
        .toolbar(model.isViewerPresented ? .hidden : .automatic, for: .windowToolbar)
        .toolbar { toolbarContent }
        .navigationTitle(model.rootName)
        .navigationSubtitle(model.statusText)
        .background(hotkeys)
    }

    /// Invisible buttons that carry global keyboard shortcuts for the window.
    private var hotkeys: some View {
        ZStack {
            Button("Toggle Viewer") { model.toggleViewer() }
                .keyboardShortcut("g", modifiers: [])
            Button("Open") {
                model.selectFirstIfNeeded()
                if model.selectedItem != nil { model.isViewerPresented = true }
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(model.displayedItems.isEmpty)
            Button("Refresh") { model.refresh() }
                .keyboardShortcut("r", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("View", selection: $model.mode) {
                ForEach(BrowseMode.allCases, id: \.self) { mode in
                    Label(mode.rawValue, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Flattened shows all media; Folders shows one folder at a time.")
        }

        ToolbarItem {
            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.root == nil || model.isScanning)
            .help("Rescan the current folder (⌘R)")
        }

        ToolbarItem {
            Menu {
                Picker("Sort By", selection: $model.sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Ascending", isOn: $model.sortAscending)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }

        ToolbarItem {
            Slider(value: $model.thumbnailSize, in: 90...320)
                .frame(width: 120)
                .help("Thumbnail size")
        }

        ToolbarItem {
            Button {
                model.selectFirstIfNeeded()
                model.isViewerPresented = true
            } label: {
                Label("Open", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(model.displayedItems.isEmpty)
            .help("Open selected item in viewer (G or Return)")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    model.open(url: url)
                } else {
                    // A file was dropped: open its enclosing folder.
                    model.open(url: url.deletingLastPathComponent())
                }
            }
        }
        return true
    }
}
