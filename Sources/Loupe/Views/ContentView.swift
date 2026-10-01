import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: BrowserModel
    @State private var isTargeted = false

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
        .toolbar { toolbarContent }
        .navigationTitle(model.rootName)
        .navigationSubtitle(model.statusText)
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
            .help("Open selected item in viewer (Return)")
            .keyboardShortcut(.return, modifiers: [])
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
