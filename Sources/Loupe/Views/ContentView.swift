import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    /// Folders/files to open when this window first appears (empty shows the
    /// drop zone).
    let initialURLs: [URL]

    @State private var model = BrowserModel()
    @State private var isTargeted = false
    /// Registration token while this window is empty and available to receive a
    /// dropped/opened batch (see OpenURLBridge).
    @State private var emptyWindowID: UUID?
    /// Whether the toolbar search field currently has keyboard focus. Used to
    /// suspend modifier-less window hotkeys so typing isn't hijacked.
    @FocusState private var searchFocused: Bool

    init(initialURLs: [URL] = []) {
        self.initialURLs = initialURLs
    }

    var body: some View {
        Group {
            if !model.hasContent {
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
            // Don't show the drop highlight for our own grid's drags.
            if isTargeted && !InternalDrag.inProgress {
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
            if !initialURLs.isEmpty {
                // Window was opened with an explicit batch (e.g. a drop while
                // already running).
                for url in initialURLs { openURL(url) }
            } else if !model.hasContent {
                // An empty window: offer it to the bridge so a Dock/"open with"
                // drop reuses it instead of spawning a duplicate window.
                emptyWindowID = OpenURLBridge.shared.registerEmptyWindow { batch in
                    for url in batch { openURL(url) }
                }
            }
        }
        .onDisappear {
            if let id = emptyWindowID {
                OpenURLBridge.shared.unregisterEmptyWindow(id)
                emptyWindowID = nil
            }
        }
        .onChange(of: model.hasContent) { _, hasContent in
            // Once this window has content it's no longer a reuse target.
            if hasContent, let id = emptyWindowID {
                OpenURLBridge.shared.unregisterEmptyWindow(id)
                emptyWindowID = nil
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
                FilterBar(model: model)
                switch model.viewLayout {
                case .grid:
                    BrowserGridView(model: model, canAutoFocus: !searchFocused)
                case .list:
                    BrowserListView(model: model, canAutoFocus: !searchFocused)
                }
                PathBar(model: model)
            }
        }
        // Hide the window chrome's controls while the full viewer is up so the
        // sort/zoom/view controls don't float over the fullscreen image.
        .toolbar(model.isViewerPresented ? .hidden : .automatic, for: .windowToolbar)
        .toolbar { toolbarContent }
        .searchable(
            text: $model.searchText,
            placement: .toolbar,
            prompt: "Search in \(model.searchScopeName)"
        )
        .searchFocused($searchFocused)
        .navigationTitle(model.isViewerPresented ? "" : model.rootName)
        .navigationSubtitle(model.isViewerPresented ? "" : model.statusText)
        .background(hotkeys)
    }

    /// Invisible buttons that carry global keyboard shortcuts for the window.
    ///
    /// All of these are suspended while the search field has focus: a disabled
    /// `Button` releases its keyboard shortcut, so plain keys (and ⌘A etc.) go
    /// to the text field for normal typing/editing instead of being hijacked.
    private var hotkeys: some View {
        ZStack {
            // G toggles between the grid and list layouts. Suspended while the
            // viewer is open so it doesn't swap layouts behind the viewer.
            Button("Toggle Grid/List") { model.toggleLayout() }
                .keyboardShortcut("g", modifiers: [])
                .disabled(model.isViewerPresented || searchFocused)
            // Space and Return both open the full viewer on the selection.
            Button("Open Viewer") { model.openViewer() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.displayedItems.isEmpty || model.isViewerPresented || searchFocused)
            Button("Open") { model.openViewer() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(model.displayedItems.isEmpty || searchFocused)
            Button("Refresh") { model.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(searchFocused)
            Button("Select All") { model.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(model.displayedItems.isEmpty || searchFocused)
            Button("Open with Default App") { model.openInDefaultApp() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(model.selectedItems.isEmpty || searchFocused)
            Button("Reveal in Finder") { model.revealInFinder() }
                // F1 — NSF1FunctionKey is U+F704.
                .keyboardShortcut(KeyEquivalent("\u{F704}"), modifiers: [])
                .disabled(model.selectedItems.isEmpty || searchFocused)
            Button("Move to Trash") { model.moveToTrash() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.canTrashSelection || searchFocused)
            Button("Flag for Later") { model.toggleFlag() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(model.selectedItems.isEmpty || searchFocused)
            Button("Show Flagged Only") { model.showFlaggedOnly.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled((model.flaggedCount == 0 && !model.showFlaggedOnly) || searchFocused)

            // Quick sort presets.
            Button("Sort by Name (A→Z)") { model.sortByNameAscending() }
                .keyboardShortcut("1", modifiers: .control)
                .disabled(searchFocused)
            Button("Sort by Size (Largest First)") { model.sortBySizeDescending() }
                .keyboardShortcut("2", modifiers: .control)
                .disabled(searchFocused)

            // Escape clears the selection; if nothing is selected it clears the
            // active type/extension filters instead.
            Button("Clear Selection or Filters") { model.escape() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!model.canEscape || model.isViewerPresented || searchFocused)

            // Grid zoom. Suspended while the viewer is open so its image-zoom
            // shortcuts (⌘+/⌘−/⌘0) take precedence there instead.
            Button("Zoom Grid In") { model.zoomGridIn() }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(model.isViewerPresented || searchFocused)
            Button("Zoom Grid In (plus)") { model.zoomGridIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(model.isViewerPresented || searchFocused)
            Button("Zoom Grid Out") { model.zoomGridOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(model.isViewerPresented || searchFocused)
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

        ToolbarItem(id: "subfolders") {
            Toggle(isOn: $model.includeSubfolders) {
                Label("Include Subfolders", systemImage: "arrow.turn.down.right")
            }
            .toggleStyle(.button)
            .disabled(model.mode != .folders)
            .help("When on, a selected folder also shows media from its subfolders.")
        }

        ToolbarItem {
            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(!model.hasContent || model.isScanning)
            .help("Rescan all folders (⌘R)")
        }


        ToolbarItem(id: "layout") {
            Picker("Layout", selection: $model.viewLayout) {
                ForEach(ViewLayout.allCases, id: \.self) { layout in
                    Label(layout.rawValue, systemImage: layout.symbol).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .help("Switch between the thumbnail grid and a detailed list (G).")
        }

        ToolbarItem(id: "sort") {
            Menu {
                Section("Quick Sort") {
                    Button {
                        model.sortByNameAscending()
                    } label: {
                        Label("Name (A→Z)  ⌃1", systemImage: model.isSort(.name, ascending: true) ? "checkmark" : "textformat")
                    }

                    Button {
                        model.sortBySizeDescending()
                    } label: {
                        Label("Size (Largest First)  ⌃2", systemImage: model.isSort(.size, ascending: false) ? "checkmark" : "arrow.down")
                    }
                }

                Picker("Sort By", selection: $model.sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Ascending", isOn: $model.sortAscending)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }

        ToolbarItem(id: "size") {
            Slider(value: $model.thumbnailSize,
                   in: BrowserModel.minThumbnailSize...BrowserModel.maxThumbnailSize)
                .frame(width: 120)
                .help(model.viewLayout == .grid ? "Thumbnail size" : "Row size")
        }

        ToolbarItem {
            Button {
                model.selectFirstIfNeeded()
                model.isViewerPresented = true
            } label: {
                Label("Open", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(model.displayedItems.isEmpty)
            .help("Open selected item in viewer (Space or Return)")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // Ignore files dragged out of our own grid and dropped back in.
        guard !InternalDrag.inProgress else { return false }
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in openURL(url) }
            }
        }
        return true
    }

    /// Opens a folder or file into the current window, appending to any folders
    /// already present.
    private func openURL(_ url: URL) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            model.open(url: url)
        } else {
            // A file: show it (and browse its folder when the sandbox allows).
            model.openFile(url)
        }
    }
}
