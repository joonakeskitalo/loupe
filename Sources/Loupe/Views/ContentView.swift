import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    /// Folders/files to open when this window first appears (empty shows the
    /// drop zone).
    let initialURLs: [URL]
    /// Set when this window was opened as a ⌘T "New Tab": the id of the
    /// `WindowRequest` whose recorded host group this window should join once it
    /// has a backing `NSWindow`. Nil for ⌘N / normal windows (which stay
    /// standalone). See `WindowTabs.claimTabHost`.
    let tabRequestID: UUID?

    @State private var model = BrowserModel()
    @State private var isTargeted = false
    /// The `NSWindow` hosting this view, captured so drop handling can tell an
    /// internal drag that started in *this* window (ignored) from one that
    /// started in another Loupe window (accepted like a Finder drop).
    @State private var hostWindow: NSWindow?
    /// Registration token while this window is empty and available to receive a
    /// dropped/opened batch (see OpenURLBridge).
    @State private var emptyWindowID: UUID?
    /// Whether the toolbar search field currently has keyboard focus. Used to
    /// suspend modifier-less window hotkeys so typing isn't hijacked.
    @FocusState private var searchFocused: Bool

    /// Whether this window is currently the key (frontmost/active) window.
    ///
    /// Every tab of Loupe's `WindowGroup` is the *same* SwiftUI Scene, so every
    /// open tab mounts `ContentView` and runs the `focusedSceneValue` publishers
    /// below. If two tabs published simultaneously, the scene-scoped values
    /// would be ambiguous, which churns SwiftUI's command validation and breaks
    /// menu key-equivalent dispatch for the whole `.commands` set — that's what
    /// made ⌘N / ⌘T stop firing once a second tab was open. Gating the
    /// publishers on "am I the key window" keeps exactly one active publisher
    /// per scene value at a time, so there's never a collision.
    @State private var isKeyWindow = false

    /// Sidebar column visibility, toggled by ⌘S.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    /// Tracks whether this window already performed its ⌘T tab-merge, so a later
    /// `hostWindow` re-resolve (which happens on layout changes) doesn't try to
    /// re-tab an already-tabbed window.
    @State private var didClaimTab = false

    init(initialURLs: [URL] = [], tabRequestID: UUID? = nil) {
        self.initialURLs = initialURLs
        self.tabRequestID = tabRequestID
    }

    var body: some View {
        Group {
            if !model.hasContent {
                DropZoneView(model: model)
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    FolderSidebar(model: model)
                        .frame(minWidth: 220)
                } detail: {
                    detail
                }
            }
        }
        .overlay {
            // Show the drop highlight for external drops and cross-window Loupe
            // drags, but not for this window's own grid dragging out and back.
            if isTargeted && !InternalDrag.startedFrom(hostWindow) {
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
        // Make this window prefer joining Loupe's tab group, so a new window
        // (⌘T / ⌘N) opens as a tab rather than a separate window.
        .background(WindowTabbingConfigurator())
        // Capture the hosting NSWindow so drop handling can distinguish a drag
        // that began in this window from one dragged over from another window.
        // Also drives the ⌘T tab merge once the window exists.
        .background(WindowReader { window in
            hostWindow = window
            claimTabIfNeeded(window)
        })
        .fullScreenViewer(isPresented: $model.isViewerPresented) {
            MediaViewer(model: model)
        }
        // Free-text tag input (opened with `y`). Applied AFTER the
        // fullScreenViewer overlay so it layers above both the grid and the
        // viewer — otherwise the viewer would cover it in fullscreen.
        .overlay {
            if model.showTagInput {
                TagInputOverlay(model: model, isPresented: $model.showTagInput)
                    .zIndex(3)
            }
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
        // Track whether this window is key so the scene-value publishers above
        // only fire for the frontmost tab (see `isKeyWindow`). Seed from the
        // resolved host window, then keep it current via the key notifications.
        .onChange(of: hostWindow) { _, window in
            isKeyWindow = window?.isKeyWindow ?? false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let w = note.object as? NSWindow, w === hostWindow {
                isKeyWindow = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if let w = note.object as? NSWindow, w === hostWindow {
                isKeyWindow = false
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
                // The info sidebar spans the full height from the toolbar down
                // to the PathBar, so it sits alongside — not under — the filter
                // bar. The filter bar and the grid/list share the left column
                // and therefore end at the sidebar's left edge.
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        FilterBar(model: model)
                        switch model.viewLayout {
                        case .grid:
                            BrowserGridView(model: model,
                                            canAutoFocus: !searchFocused,
                                            searchFocused: searchFocused)
                        case .list:
                            BrowserListView(model: model,
                                            canAutoFocus: !searchFocused,
                                            searchFocused: searchFocused)
                        }
                    }
                    if model.showPreviewSidebar {
                        ItemPreviewSidebar(model: model)
                            .transition(.move(edge: .trailing))
                    }
                    if model.showInfoSidebar {
                        ItemInfoSidebar(model: model)
                            .transition(.move(edge: .trailing))
                    }
                }
                PathBar(model: model)
            }
        }
        // Publish this window's model (and the two shortcut-gating flags) so
        // the menu-bar commands — which live at the Scene level — can act on
        // the frontmost window. These use `focusedSceneValue` (not
        // `focusedValue`) so they resolve for the key window regardless of which
        // inner view — grid, list, sidebar, or none — currently holds focus.
        // With plain `focusedValue` the commands read nil (and disable) whenever
        // focus wasn't inside this subtree, e.g. when the sidebar was focused or
        // nothing was.
        //
        // Every tab is the same Scene, so these publishers are gated on
        // `isKeyWindow`: only the frontmost tab publishes, keeping exactly one
        // active publisher per key. Without that gate two tabs publish at once,
        // the scene values go ambiguous, and SwiftUI's command validation churn
        // breaks menu key-equivalent dispatch (⌘N / ⌘T stop working). See
        // `isKeyWindow`.
        .modifier(KeyWindowSceneValues(
            isKeyWindow: isKeyWindow,
            model: model,
            trashEligible: !(searchFocused || model.showTagInput || model.isViewerPresented),
            searchFieldFocused: searchFocused || model.showTagInput
        ))
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
        // Mirror the field's focus onto the model so the grid/list's deferred
        // focus reclaims can read the *current* state (not the render-lagged
        // `searchFocused` parameter). Without this the first click into the
        // field was instantly stolen back by a deferred `gridFocused = true`.
        .onChange(of: searchFocused) { _, focused in
            model.isSearchFieldFocused = focused
        }
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
                .disabled(model.isViewerPresented || searchFocused || model.showTagInput)
            // ⌘S toggles the sidebar. Lives here (not in the menu) because the
            // visibility is view-local state. Suspended while the viewer is up.
            Button("Toggle Sidebar") { toggleSidebar() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.isViewerPresented || searchFocused || model.showTagInput)
            // Space and Return both open the full viewer on the selection.
            Button("Open Viewer") { model.openViewer() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.displayedItems.isEmpty || model.isViewerPresented || searchFocused || model.showTagInput)
            Button("Open") { model.openViewer() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(model.displayedItems.isEmpty || searchFocused || model.showTagInput)
            // The ⌘-modified actions (Refresh ⌘R, Select All ⌘A, Open with
            // Default App ⌘↓, Reveal in Finder ⇧⌘R, Flag ⌘K, Show Flagged Only
            // ⇧⌘F, zoom ⌘=/⌘−, Move to Trash ⌘⌫) now live in the menu bar (see
            // LoupeCommands), which is their single owner. Only the modifier-
            // less / ⌃-digit hotkeys remain here, gated by search/viewer focus.

            // Reveal in Finder also responds to F1 (the menu shows ⇧⌘R). F1
            // isn't a menu equivalent, so this hidden button is its sole owner.
            Button("Reveal in Finder (F1)") { model.revealInFinder() }
                // F1 — NSF1FunctionKey is U+F704.
                .keyboardShortcut(KeyEquivalent("\u{F704}"), modifiers: [])
                .disabled(model.selectedItems.isEmpty || searchFocused || model.showTagInput)

            // J/L step the selection; I flags the selection. Suspended while the
            // viewer is open (it carries its own copies so it can navigate/flag
            // from inside) and while search has focus so the keys type normally.
            // (K is play/pause inside the viewer, handled there.)
            Button("Previous Item") { model.moveSelection(by: -1) }
                .keyboardShortcut("j", modifiers: [])
                .disabled(model.displayedItems.isEmpty || model.isViewerPresented || searchFocused || model.showTagInput)
            Button("Next Item") { model.moveSelection(by: 1) }
                .keyboardShortcut("l", modifiers: [])
                .disabled(model.displayedItems.isEmpty || model.isViewerPresented || searchFocused || model.showTagInput)
            Button("Flag Item") { model.toggleFlag() }
                .keyboardShortcut("i", modifiers: [])
                .disabled(model.selectedItems.isEmpty || model.isViewerPresented || searchFocused || model.showTagInput)
            Button("Flag Item (S)") { model.toggleFlag() }
                .keyboardShortcut("s", modifiers: [])
                .disabled(model.selectedItems.isEmpty || model.isViewerPresented || searchFocused || model.showTagInput)
            // F also flags. The grid normally owns F through its focused
            // `.onKeyPress`, but when a non-grid subview holds first responder —
            // e.g. the preview sidebar's video player (an AVPlayerView) — that
            // handler never fires. This window-level key equivalent gives F a
            // focus-independent owner too; when the grid IS focused it consumes
            // F first (returning .handled), so this never double-toggles.
            Button("Flag Item (F)") { model.toggleFlag() }
                .keyboardShortcut("f", modifiers: [])
                .disabled(model.selectedItems.isEmpty || model.isViewerPresented || searchFocused || model.showTagInput)

            // Y opens the free-text tag input for the selection.
            Button("Tag Item") { model.beginTagging() }
                .keyboardShortcut("y", modifiers: [])
                .disabled(model.selectedItems.isEmpty || model.isViewerPresented || searchFocused || model.showTagInput)

            // ⌫ (backspace) hides/unhides the selection. Kept here (not in the
            // menu bar) as a modifier-less hotkey, gated on search/viewer focus
            // so backspace still edits text in the search field and the viewer
            // owns its own keys. ⌘⌫ remains "Move to Trash" (menu-owned); this
            // is plain backspace only.
            Button("Hide Item") { model.toggleHidden() }
                .keyboardShortcut(.deleteBackspace, modifiers: [])
                .disabled(model.selectedItems.isEmpty || model.isViewerPresented || searchFocused || model.showTagInput)

            // X marks the selection as hidden (triage), always hiding rather
            // than toggling — so repeating it never un-hides — then advances
            // the cursor to the next survivor (via the model's successor
            // logic). Pairs with C below for quick keyboard triage. Gated like
            // the other modifier-less marks so the key types normally while
            // searching and the viewer owns its own keys.
            Button("Hide Item (X)") { model.hideSelection() }
                .keyboardShortcut("x", modifiers: [])
                .disabled(model.selectedItems.isEmpty || model.isViewerPresented || searchFocused || model.showTagInput)

            // C advances the selection to the next item (same as L), so the
            // user can mark with X and step forward with C from the home row.
            Button("Next Item (C)") { model.moveSelection(by: 1) }
                .keyboardShortcut("c", modifiers: [])
                .disabled(model.displayedItems.isEmpty || model.isViewerPresented || searchFocused || model.showTagInput)

            // Quick sort presets. Moved off ⌃1–⌃3 (now color-tag keys) to the
            // function row: F2 Name, F3 Size, F4 File Type. (F1 is Reveal in
            // Finder.) NSFxFunctionKey code points: F2 U+F705, F3 U+F706,
            // F4 U+F707.
            Button("Sort by Name (A→Z)") { model.sortByNameAscending() }
                .keyboardShortcut(KeyEquivalent("\u{F705}"), modifiers: [])
                .disabled(searchFocused || model.showTagInput)
            Button("Sort by Size (Largest First)") { model.sortBySizeDescending() }
                .keyboardShortcut(KeyEquivalent("\u{F706}"), modifiers: [])
                .disabled(searchFocused || model.showTagInput)
            Button("Sort by File Type (A→Z)") { model.sortByTypeAscending() }
                .keyboardShortcut(KeyEquivalent("\u{F707}"), modifiers: [])
                .disabled(searchFocused || model.showTagInput)

            // Color-tag hotkeys: 1 red, 2 blue, 3 green, 4 orange, 5 purple.
            // Both the plain digit and ⌃digit apply the tag; pressing the same
            // tag again clears it. Gated like the flag keys: needs a selection,
            // suspended while searching. The plain-digit variant is only live
            // in the grid — inside the viewer the bare digits drive video
            // seeking, so the viewer registers only the ⌃digit copies.
            ForEach(Array(ColorTag.allInHotkeyOrder.enumerated()), id: \.element) { index, tag in
                Button("Tag \(tag.displayName)") { model.toggleColorTag(tag) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
                    .disabled(model.selectedItems.isEmpty || model.isViewerPresented || searchFocused || model.showTagInput)
                Button("Tag \(tag.displayName) (Ctrl)") { model.toggleColorTag(tag) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
                    .disabled(model.selectedItems.isEmpty || model.isViewerPresented || searchFocused || model.showTagInput)
            }

            // Escape clears the selection; if nothing is selected it clears the
            // active type/extension filters instead.
            Button("Clear Selection or Filters") { model.escape() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!model.canEscape || model.isViewerPresented || searchFocused || model.showTagInput)

            // Grid zoom-in via ⌘+ (the plus-key alias). The menu owns ⌘= and
            // ⌘−; this extra alias stays in-window, gated so the viewer's own
            // image-zoom shortcuts take precedence while it's open.
            Button("Zoom Grid In (plus)") { model.zoomGridIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(model.isViewerPresented || searchFocused || model.showTagInput)

            // ⌘F focuses the toolbar search field — the standard macOS "Find"
            // shortcut. Lives here (not the menu bar) because the field's focus
            // is view-local `@FocusState`. Suspended while the viewer or the
            // tag-input overlay owns the keyboard, and while the field is
            // already focused (a disabled Button releases ⌘F so the focused
            // field gets native behavior). ⇧⌘F / ⌥⌘F stay with their own
            // commands; only plain ⌘F lands here.
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model.isViewerPresented || searchFocused || model.showTagInput)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(id: "mode", placement: .navigation) {
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

        ToolbarItem(id: "refresh") {
            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(!model.hasContent || model.isScanning)
            .help("Rescan all folders (⌘R)")
        }

        // Consolidated on-device AI controls (scene classification + face
        // recognition), kept away from the zoom slider. While a pass runs it
        // shows progress; otherwise it's a menu where the user picks the face
        // engine and sensitivity *before* running, then triggers either pass.
        ToolbarItem(id: "ai") {
            if model.isClassifying {
                HStack(spacing: 6) {
                    ProgressView(value: Double(model.classifyProgress),
                                 total: Double(max(1, model.classifyTotal)))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Text("\(model.classifyActivity) \(model.classifyProgress)/\(model.classifyTotal)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .help("Working on-device…")
            } else if model.hasClassifiableImages {
                AIMenu(model: model)
            }
        }

        // Progress while a multi-image "Copy Image As" render or an "Export
        // Images As" render runs. The two never overlap (export is gated on
        // `!isExportingImages`, and a single-image copy is instant), so one
        // slot serves both.
        ToolbarItem(id: "imageProgress") {
            if model.isCopyingImages {
                progressReadout(
                    label: "Copying",
                    done: model.copyProgress,
                    total: model.copyTotal,
                    help: "Rendering images to copy…"
                )
            } else if model.isExportingImages {
                progressReadout(
                    label: "Exporting",
                    done: model.exportProgress,
                    total: model.exportTotal,
                    help: "Exporting images to the chosen folder…"
                )
            }
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
                        Label("Name (A→Z)  F2", systemImage: model.isSort(.name, ascending: true) ? "checkmark" : "textformat")
                    }

                    Button {
                        model.sortBySizeDescending()
                    } label: {
                        Label("Size (Largest First)  F3", systemImage: model.isSort(.size, ascending: false) ? "checkmark" : "arrow.down")
                    }

                    Button {
                        model.sortByTypeAscending()
                    } label: {
                        Label("File Type (A→Z)  F4", systemImage: model.isSort(.type, ascending: true) ? "checkmark" : "doc")
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

        ToolbarItem(id: "open") {
            Button {
                model.selectFirstIfNeeded()
                model.isViewerPresented = true
            } label: {
                Label("Open", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(model.displayedItems.isEmpty)
            .help("Open selected item in viewer (Space or Return)")
        }

        ToolbarItemGroup {
            Button {
                withAnimation { model.togglePreviewSidebar() }
            } label: {
                Label("Preview", systemImage: "sidebar.squares.right")
            }
            .help("Show a preview of the selected item (⌥⌘P)")

            Button {
                withAnimation { model.toggleInfoSidebar() }
            } label: {
                Label("Info", systemImage: "sidebar.right")
            }
            .help("Show item info and metadata (⌥⌘I)")
        }
    }

    /// A small circular-progress + count readout used by the shared
    /// copy/export toolbar slot.
    private func progressReadout(label: String, done: Int, total: Int, help: String) -> some View {
        HStack(spacing: 6) {
            ProgressView(value: Double(done), total: Double(max(1, total)))
                .progressViewStyle(.circular)
                .controlSize(.small)
            Text("\(label) \(done)/\(total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help(help)
    }

    /// For a window opened as a ⌘T "New Tab", merge it into the recorded host's
    /// tab group once its backing `NSWindow` exists. Runs at most once per
    /// window (guarded by `didClaimTab`), since `WindowReader` re-resolves the
    /// window on later layout passes.
    private func claimTabIfNeeded(_ window: NSWindow?) {
        guard let window, let tabRequestID, !didClaimTab else { return }
        didClaimTab = true
        WindowTabs.claimTabHost(for: tabRequestID, newWindow: window)
    }

    /// Toggles the sidebar between hidden and shown (⌘S).
    private func toggleSidebar() {
        withAnimation {
            columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // Ignore only a drag that started in THIS window (dragging a file out
        // and back shouldn't re-open it). A drag from another Loupe window — or
        // from Finder/another app — is a genuine drop and is handled below, so
        // items can be dragged from one window into another.
        guard !InternalDrag.startedFrom(hostWindow) else { return false }
        guard !providers.isEmpty else { return false }

        // Resolve every dropped provider to a URL, then open the whole batch at
        // once. Loading providers one-by-one and opening each independently
        // raced the per-file folder scans and left only the last file selected,
        // so sibling files dropped together couldn't land in one folder with a
        // shared selection. Gather first, dispatch once.
        let group = DispatchGroup()
        let box = URLBox()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { box.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            Task { @MainActor in openURLs(box.urls) }
        }
        return true
    }

    /// Opens a batch of folders/files into the current window, appending to any
    /// folders already present. Preserves the drop order.
    private func openURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        var folders: [URL] = []
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
               isDir.boolValue {
                folders.append(url)
            } else {
                files.append(url)
            }
        }

        // Open all dropped folders under one scan task. Looping `open(url:)`
        // per folder cancelled every scan but the last (see `open(urls:)`), so
        // dropping several folders only showed the last one until ⌘R.
        if !folders.isEmpty { model.open(urls: folders) }
        // Files dropped together — especially siblings from one Finder folder —
        // are opened as a group so same-directory files share a folder and end
        // up selected together.
        if !files.isEmpty { model.openFiles(files) }
    }

    /// Opens a single folder or file into the current window.
    private func openURL(_ url: URL) {
        openURLs([url])
    }
}

/// Gives every Loupe window the same `tabbingIdentifier` so they *can* be
/// tabbed together, and leaves everything else to AppKit.
///
/// Explicitly does NOT force windows into a shared tab group. Tabs are created
/// deliberately by ⌘T, whose new window merges itself into the frontmost
/// window's group via `WindowTabs.claimTabHost`; a plain ⌘N / `openWindow` stays
/// a standalone window. An earlier version set `tabbingMode = .preferred` and manually
/// `addTabbedWindow`'d every new window into the group. That fought AppKit and
/// SwiftUI's `openWindow`: it merged ⌘N windows that should be standalone, and
/// once a group already existed the manual re-tabbing failed so no third tab
/// (and no new window) ever appeared. Setting only the identifier — and letting
/// AppKit own tab creation/placement — is what makes both ⌘T and ⌘N behave.
///
/// SwiftUI's `WindowGroup` doesn't expose the backing `NSWindow`, so we attach a
/// zero-size AppKit view and reach `view.window` once it's in the hierarchy.
private struct WindowTabbingConfigurator: NSViewRepresentable {
    static let tabbingIdentifier = "com.loupe.browser.window"

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            // Shared identifier lets these windows merge into one tab group
            // (via ⌘T and the Window ▸ Merge All Windows menu). `.automatic`
            // tabbing mode respects the user's system "prefer tabs" setting and,
            // crucially, does not force a standalone ⌘N window into the group.
            window.tabbingIdentifier = Self.tabbingIdentifier
            window.tabbingMode = .automatic
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Publishes a window's scene-scoped focused values, but ONLY while that window
/// is the key window. Every tab of Loupe's `WindowGroup` is the same SwiftUI
/// Scene, so if more than one tab published these at once the values would be
/// ambiguous and SwiftUI's command validation would thrash — breaking menu
/// key-equivalent dispatch (⌘N / ⌘T stopped firing with two tabs open). Gating
/// on `isKeyWindow` guarantees a single active publisher per key at any moment.
///
/// When not key, the modifier publishes nothing (it applies no
/// `focusedSceneValue`), so this window simply isn't a candidate and the key
/// window's values win unambiguously.
private struct KeyWindowSceneValues: ViewModifier {
    let isKeyWindow: Bool
    let model: BrowserModel
    let trashEligible: Bool
    let searchFieldFocused: Bool

    func body(content: Content) -> some View {
        // Always apply the same modifier chain, flipping the *values* (not the
        // view structure) on key/non-key. Branching the modifier set with an
        // if/else gives the two branches different structural identities, so
        // every key-window change would tear down and rebuild `content` (the
        // whole detail subtree). That rebuild is what reset image/video zoom,
        // re-centered the scroll on the selection, and restarted the sidebar
        // preview video from the beginning whenever the window was defocused.
        // Feeding nil when not key keeps the subtree's identity stable across
        // focus changes; the menu commands already treat a nil focused value as
        // "not the key window" (?? fallbacks in LoupeCommands).
        content
            .focusedSceneValue(\.activeBrowserModel, isKeyWindow ? model : nil)
            .focusedSceneValue(\.trashShortcutEligible, isKeyWindow ? trashEligible : nil)
            .focusedSceneValue(\.searchFieldFocused, isKeyWindow ? searchFieldFocused : nil)
    }
}

/// Reports the `NSWindow` that ends up hosting this SwiftUI view. SwiftUI
/// doesn't expose the backing window directly, so we attach a zero-size AppKit
/// view and read `view.window` once it's in the hierarchy. Used so the drop
/// handler can compare against the window an internal drag started from.
private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowResolvingView {
        let view = WindowResolvingView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: WindowResolvingView, context: Context) {
        nsView.onResolve = onResolve
        // The window can attach after the first layout pass (and change when a
        // tab is torn out into its own window), so keep the binding current.
        DispatchQueue.main.async { [weak nsView] in
            nsView?.onResolve?(nsView?.window)
        }
    }
}

/// Zero-size helper view that reports its hosting `NSWindow` the *instant* it
/// enters the window hierarchy (`viewDidMoveToWindow`), not a run-loop turn
/// later. That early, synchronous callback is what lets a ⌘T window hide itself
/// (alpha 0) and merge into its tab group before the window server composites a
/// first standalone frame — eliminating the tab-creation flicker. The async
/// safety net in `WindowReader.updateNSView` still covers later window changes.
private final class WindowResolvingView: NSView {
    var onResolve: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onResolve?(window)
    }
}

/// A tiny thread-safe collector for drop URLs. `NSItemProvider.loadObject`
/// completions fire on arbitrary background queues, so appends from several
/// providers can overlap; this serializes them behind a lock while preserving
/// the order in which each provider resolved.
private final class URLBox {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
