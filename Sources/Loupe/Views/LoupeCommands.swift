import SwiftUI

/// All of Loupe's menu-bar commands, grouped into standard menus. Each command
/// acts on the frontmost window's `BrowserModel`, read via `@FocusedValue`
/// (published by `ContentView`). When no window is key, the focused value is
/// nil and the commands disable themselves.
///
/// Keeping these in the menu bar (rather than only as in-window hotkeys) means
/// the shortcuts are discoverable, show their key equivalents, and are
/// dispatched by AppKit through the responder chain to the key window.
struct LoupeCommands: Commands {
    @FocusedValue(\.activeBrowserModel) private var model
    @FocusedValue(\.trashShortcutEligible) private var trashEligible
    @FocusedValue(\.searchFieldFocused) private var searchFieldFocused

    var body: some Commands {
        // MARK: Copy — REPLACES the Edit menu's standard pasteboard group.
        //
        // SwiftUI's `.pasteboard` group ships a built-in "Copy" already bound to
        // ⌘C. Adding our own Copy *after* that group left two ⌘C owners in the
        // Edit menu; the system's (no-op for our views) could win, so the
        // shortcut appeared dead. Replacing the group makes our Copy the single
        // ⌘C owner. Loupe is a read-only browser, so the system Cut/Paste/Delete
        // the group also provided aren't meaningful and are intentionally gone.
        CommandGroup(replacing: .pasteboard) {
            // Copy the selected file(s) to the clipboard as file references, so
            // ⌘C here then ⌘V in Finder copies the actual files. Gated on a
            // selection; the disabled state releases ⌘C so a focused search
            // field still copies text normally. Also released while the viewer
            // is open, where the viewer owns ⌘C via its own hidden button —
            // keeping exactly one owner of the key live (same pattern as ⌘⌫).
            Button(copyTitle) { model?.copyToClipboard() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!hasSelection || viewerOpen)

            // Paste — forwarded to the first responder. Loupe itself is a
            // read-only browser with nothing to paste into, but replacing the
            // whole `.pasteboard` group (above) also dropped the standard Paste
            // item, which is what wires ⌘V to the focused search field. Without
            // a Paste command in the menu, AppKit has no owner for ⌘V and the
            // keystroke never reaches the search field. Re-adding Paste as a
            // relay to the standard `paste:` action restores pasting into the
            // search field (and any other text field) without re-introducing
            // the system Cut/Delete items we intentionally removed.
            Button("Paste") {
                NSApp.sendAction(
                    #selector(NSText.paste(_:)),
                    to: nil,
                    from: nil
                )
            }
            .keyboardShortcut("v", modifiers: .command)

            // Copy the actual picture (pixels), not the file reference, at a
            // chosen size, in a chosen format, and optionally without EXIF. The
            // format + metadata pickers apply to every scale below.
            Menu("Copy Image As") {
                Picker("Format", selection: formatBinding) {
                    ForEach(ImageCopyFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.inline)

                // PNG has no EXIF container, so stripping is moot for it.
                Toggle("Remove EXIF / Metadata", isOn: stripMetadataBinding)
                    .disabled(!(model?.imageCopyFormat.canCarryMetadata ?? true))

                Divider()

                ForEach(ImageCopyScale.allCases, id: \.self) { scale in
                    Button(scale.displayName) {
                        model?.copyImageToClipboard(
                            scale: scale,
                            format: model?.imageCopyFormat,
                            stripMetadata: model?.imageCopyStripsMetadata
                        )
                    }
                }
            }
            .disabled(!canCopyImage)

            // Export the selected image(s) to a chosen folder, re-encoded at a
            // picked resolution and format (optionally without EXIF). Mirrors
            // "Copy Image As" but writes files to disk instead of the clipboard.
            // Format/resolution/metadata pickers set the defaults; the final
            // button prompts for a destination directory and runs the export.
            Menu("Export Images As") {
                Picker("Format", selection: exportFormatBinding) {
                    ForEach(ImageCopyFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.inline)

                Picker("Resolution", selection: exportScaleBinding) {
                    ForEach(ImageCopyScale.allCases, id: \.self) { scale in
                        Text(scale.displayName).tag(scale)
                    }
                }
                .pickerStyle(.inline)

                // PNG has no EXIF container, so stripping is moot for it.
                Toggle("Remove EXIF / Metadata", isOn: exportStripMetadataBinding)
                    .disabled(!(model?.exportFormat.canCarryMetadata ?? true))

                Divider()

                Button("Export to Folder…") { exportToChosenFolder() }
            }
            .disabled(!canExportImage || (model?.isExportingImages ?? false))
        }

        // MARK: Item actions — placed after the Edit menu's pasteboard group.
        CommandGroup(after: .pasteboard) {
            Divider()

            // No key equivalent here: Return/Space already open the viewer as
            // modifier-less in-window hotkeys (gated by search focus), which
            // would clash with an always-on menu equivalent.
            Button("Open in Viewer") { model?.openViewer() }
                .disabled(!canOpen)

            Button("Open with Default App") { model?.openInDefaultApp() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!hasSelection)

            Button("Reveal in Finder") { model?.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!hasSelection)

            Divider()

            Button(flagTitle) { model?.toggleFlag() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!hasSelection)

            // Hide / unhide the selection. The ⌫ (backspace) shortcut is owned
            // by ContentView's hidden hotkey (its single owner, gated on search/
            // viewer focus so it doesn't hijack text editing); this menu item
            // carries no key equivalent, only the label.
            Button(hideTitle) { model?.toggleHidden() }
                .disabled(!hasSelection)

            // Color tags. The ⌃1–⌃5 shortcuts are owned by ContentView's hidden
            // hotkeys (their single owner); the labels only show the key as a
            // hint so there's no competing menu equivalent. Applying the tag an
            // item already has clears it (handled by `toggleColorTag`).
            Menu("Color Tag") {
                ForEach(Array(ColorTag.allInHotkeyOrder.enumerated()), id: \.element) { index, tag in
                    Button("\(tag.displayName)  ⌃\(index + 1)") {
                        model?.toggleColorTag(tag)
                    }
                    .disabled(!hasSelection)
                }
                Divider()
                Button("Remove Tag") { model?.clearColorTag() }
                    .disabled(!hasSelection)
            }
            .disabled(!hasSelection)

            Divider()

            // On-device AI classification (Apple's Vision classifier, refined
            // by the Foundation Models LLM when Apple Intelligence is on). Runs
            // over the current selection's images, or the whole scope when
            // nothing is selected.
            Button(classifyTitle) {
                if hasSelection {
                    model?.classifySelection()
                } else {
                    model?.classifyAllImages()
                }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(!canClassify)

            Button("Clear AI Categories") { model?.clearAICategories() }
                .disabled((model?.classifiedCount ?? 0) == 0)

            // Identity-free face recognition: cluster same-person photos into
            // "Person N" groups, on-device. Acts on the selection's images, or
            // the whole scope when nothing is selected.
            Button(faceTitle) {
                if hasSelection {
                    model?.recognizeFacesInSelection()
                } else {
                    model?.recognizeAllFaces()
                }
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(!canClassify)

            Button("Clear People") { model?.clearFaces() }
                .disabled((model?.withFacesCount ?? 0) == 0)

            Button("Move to Trash") { model?.moveToTrash() }
                .keyboardShortcut(.deleteBackspace, modifiers: .command)
                // A disabled Button releases its shortcut, so gating on
                // eligibility means the menu owns ⌘⌫ only when it should (not
                // while searching or over the viewer, which carries its own
                // ⌘⌫). That keeps exactly one owner of the key live.
                .disabled(!canTrash || trashEligible != true)
        }

        // MARK: Select All — standard text-editing group.
        //
        // Gated on search focus too: a disabled Button releases its ⌘A
        // shortcut, so while the search field is focused ⌘A falls through to the
        // field and selects its text (instead of selecting all grid items).
        CommandGroup(after: .textEditing) {
            Button("Select All Items") { model?.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!hasItems || viewerOpen || searchFocused)
        }

        // MARK: View menu — merged into SwiftUI's built-in "View" menu (via
        // the `.sidebar` placement) rather than a second `CommandMenu("View")`,
        // which would create a duplicate menu with the same name.
        CommandGroup(after: .sidebar) {
            Divider()

            // Right-hand info sidebar (file info + metadata for the selection).
            Button(infoSidebarToggleTitle) { model?.toggleInfoSidebar() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model == nil)

            Divider()

            // Layout: Grid / List.
            Picker("Layout", selection: layoutBinding) {
                ForEach(ViewLayout.allCases, id: \.self) { layout in
                    Text(layout.rawValue).tag(layout)
                }
            }
            .pickerStyle(.inline)

            // "G" toggles layout as a modifier-less in-window hotkey; no menu
            // key equivalent to avoid an always-on global "G".
            Button("Toggle Grid/List") { model?.toggleLayout() }
                .disabled(model == nil)

            Divider()

            // Browse mode: Flattened / Folders.
            Picker("Browse Mode", selection: modeBinding) {
                ForEach(BrowseMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.inline)

            Toggle("Include Subfolders", isOn: includeSubfoldersBinding)
                .disabled(model == nil || model?.mode != .folders)

            Divider()

            // Grid display options.
            Toggle("Hide Filenames", isOn: hideFilenamesBinding)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model == nil)

            Toggle("Show Flagged Only", isOn: showFlaggedOnlyBinding)
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model == nil)

            Toggle("Show Hidden Only", isOn: showHiddenOnlyBinding)
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(model == nil || ((model?.hiddenCount ?? 0) == 0 && model?.showHiddenOnly != true))

            // How thumbnails are generated. `Native macOS` (Quick Look) is the
            // escape hatch for black .mp4 thumbnails the AVFoundation seek can
            // produce under the default Hybrid routing.
            Menu("Thumbnail Method") {
                Picker("Thumbnail Method", selection: thumbnailMethodBinding) {
                    ForEach(ThumbnailMethod.allCases, id: \.self) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .pickerStyle(.inline)
            }
            .disabled(model == nil)

            // Where in a video its thumbnail frame is taken. Moving off the
            // start is another way to escape a black lead-in frame. Honored by
            // the custom decode paths (AVFoundation / FFmpeg); Native macOS
            // picks its own poster frame, so it's disabled there.
            Menu("Video Thumbnail Frame") {
                Picker("Video Thumbnail Frame", selection: videoThumbnailPositionBinding) {
                    ForEach(VideoThumbnailPosition.allCases, id: \.self) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                .pickerStyle(.inline)
            }
            .disabled(model == nil || model?.thumbnailMethod == .nativeMacOS)

            // Section the grid/list by an AI dimension: none, scene category,
            // or recognized person. Each option disables itself until the
            // matching pass has produced something to group by.
            Menu("Group By") {
                Picker("Group By", selection: groupingBinding) {
                    Text("None").tag(GroupingDimension.none)
                    Text("Folder").tag(GroupingDimension.folder)
                    Text("Category").tag(GroupingDimension.category)
                    Text("Person").tag(GroupingDimension.person)
                }
                .pickerStyle(.inline)
            }
            // Folder grouping needs no AI pass, so the menu is live whenever a
            // window has content; the AI dimensions still only group once their
            // respective passes have produced something.
            .disabled(model == nil || !(model?.hasContent ?? false))

            // Quick toggle for folder grouping (⌘G flips between grouping by
            // folder and a flat list). Needs no AI pass, so it's live whenever
            // the window has content.
            Button(groupByFolderToggleTitle) {
                model?.grouping = model?.grouping == .folder ? .none : .folder
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(model == nil || !(model?.hasContent ?? false))

            // Quick toggle for the most common case (⇧⌘G flips category
            // grouping on/off), kept for muscle memory.
            Button(groupByCategoryToggleTitle) {
                model?.groupByCategory.toggle()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(model == nil || (model?.classifiedCount ?? 0) == 0)

            Divider()

            // Sort submenu.
            Menu("Sort By") {
                Picker("Sort By", selection: sortOrderBinding) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                Picker("Direction", selection: sortAscendingBinding) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                .pickerStyle(.inline)
            }
            .disabled(model == nil)

            Divider()

            // Zoom. Disabled while the viewer is open so its own image-zoom
            // shortcuts take precedence.
            Button("Zoom In") { model?.zoomGridIn() }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(model == nil || viewerOpen)
            Button("Zoom Out") { model?.zoomGridOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(model == nil || viewerOpen)

            Divider()

            Button("Refresh") { model?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!(model?.hasContent ?? false) || (model?.isScanning ?? false))
        }
    }

    // MARK: - Derived enablement
    //
    // `viewerOpen` gates the commands whose shortcuts the viewer wants for
    // itself (zoom, select-all, etc.) so the viewer's own handlers win while
    // it's open, matching the in-window hotkey behavior.

    private var viewerOpen: Bool { model?.isViewerPresented ?? false }
    private var searchFocused: Bool { searchFieldFocused ?? false }
    private var hasItems: Bool { !(model?.displayedItems.isEmpty ?? true) }
    private var hasSelection: Bool { !(model?.selectedItems.isEmpty ?? true) }
    private var canTrash: Bool { model?.canTrashSelection ?? false }
    private var canOpen: Bool { hasItems && !viewerOpen }
    /// Enabled when the selection has at least one image. Unlike the plain
    /// Copy command this stays available while the viewer is open: its submenu
    /// items carry no key equivalents, so there's no ⌘C ownership conflict with
    /// the viewer's own copy handler.
    private var canCopyImage: Bool { model?.canCopyImageSelection ?? false }

    /// Enabled when the selection has at least one image to export. Export only
    /// operates on images, exactly like "Copy Image".
    private var canExportImage: Bool { model?.canExportSelection ?? false }

    private var flagTitle: String {
        let count = model?.selectedItems.count ?? 0
        return count > 1 ? "Flag / Unflag Selection" : "Flag / Unflag"
    }

    private var hideTitle: String {
        let count = model?.selectedItems.count ?? 0
        return count > 1 ? "Hide / Unhide Selection" : "Hide / Unhide"
    }

    private var copyTitle: String {
        let count = model?.selectedItems.count ?? 0
        return count > 1 ? "Copy \(count) Files" : "Copy"
    }

    /// Whether a classify action has any image to act on right now: images in
    /// the selection, or any image in the scope when nothing is selected.
    private var canClassify: Bool {
        guard let model, !model.isClassifying else { return false }
        if hasSelection {
            return model.selectedMediaItems.contains { $0.kind == .image }
        }
        return model.hasClassifiableImages
    }

    private var classifyTitle: String {
        if model?.isClassifying == true { return "Working…" }
        let selectedImages = model?.selectedMediaItems.filter { $0.kind == .image }.count ?? 0
        if selectedImages > 1 { return "Classify \(selectedImages) Images with AI" }
        if hasSelection && selectedImages == 1 { return "Classify Image with AI" }
        return "Classify All Images with AI"
    }

    private var faceTitle: String {
        if model?.isClassifying == true { return "Working…" }
        let selectedImages = model?.selectedMediaItems.filter { $0.kind == .image }.count ?? 0
        if selectedImages > 1 { return "Find Faces in \(selectedImages) Images" }
        if hasSelection && selectedImages == 1 { return "Find Faces in Image" }
        return "Find Faces in All Images"
    }

    private var infoSidebarToggleTitle: String {
        (model?.showInfoSidebar ?? false) ? "Hide Info Sidebar" : "Show Info Sidebar"
    }

    private var groupByFolderToggleTitle: String {
        model?.grouping == .folder ? "Ungroup" : "Group by Folder"
    }

    private var groupByCategoryToggleTitle: String {
        model?.grouping == .category ? "Ungroup" : "Group by Category"
    }

    // MARK: - Bindings into the focused model
    //
    // Menu `Picker`/`Toggle` need bindings. The focused model is a reference
    // type, so these read/write it directly; a nil model yields harmless
    // defaults (the controls are disabled in that case anyway).

    private func binding<T>(_ keyPath: ReferenceWritableKeyPath<BrowserModel, T>, default def: T) -> Binding<T> {
        Binding(
            get: { model?[keyPath: keyPath] ?? def },
            set: { if let model { model[keyPath: keyPath] = $0 } }
        )
    }

    private var layoutBinding: Binding<ViewLayout> { binding(\.viewLayout, default: .grid) }
    private var modeBinding: Binding<BrowseMode> { binding(\.mode, default: .flattened) }
    private var includeSubfoldersBinding: Binding<Bool> { binding(\.includeSubfolders, default: false) }
    private var hideFilenamesBinding: Binding<Bool> { binding(\.hideFilenames, default: false) }
    private var showFlaggedOnlyBinding: Binding<Bool> { binding(\.showFlaggedOnly, default: false) }
    private var showHiddenOnlyBinding: Binding<Bool> { binding(\.showHiddenOnly, default: false) }
    private var groupingBinding: Binding<GroupingDimension> { binding(\.grouping, default: .none) }
    private var sortOrderBinding: Binding<SortOrder> { binding(\.sortOrder, default: .name) }
    private var sortAscendingBinding: Binding<Bool> { binding(\.sortAscending, default: true) }
    private var thumbnailMethodBinding: Binding<ThumbnailMethod> { binding(\.thumbnailMethod, default: .hybrid) }
    private var videoThumbnailPositionBinding: Binding<VideoThumbnailPosition> {
        binding(\.videoThumbnailPosition, default: .defaultPosition)
    }
    private var stripMetadataBinding: Binding<Bool> { binding(\.imageCopyStripsMetadata, default: true) }
    private var exportFormatBinding: Binding<ImageCopyFormat> { binding(\.exportFormat, default: .defaultFormat) }
    private var exportScaleBinding: Binding<ImageCopyScale> { binding(\.exportScale, default: .original) }
    private var exportStripMetadataBinding: Binding<Bool> { binding(\.exportStripsMetadata, default: true) }
    private var formatBinding: Binding<ImageCopyFormat> { binding(\.imageCopyFormat, default: .defaultFormat) }

    // MARK: - Export

    /// Prompts for a destination folder and exports the current image
    /// selection into it using the model's current export prefs (format,
    /// resolution, metadata). No-op if nothing exportable is selected or the
    /// user cancels the folder picker.
    private func exportToChosenFolder() {
        model?.exportImagesToChosenFolder()
    }
}
