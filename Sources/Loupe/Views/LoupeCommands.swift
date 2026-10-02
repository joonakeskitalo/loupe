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

    var body: some Commands {
        // MARK: Item actions — placed after the Edit menu's pasteboard group.
        CommandGroup(after: .pasteboard) {
            Divider()

            // Copy the selected file(s) to the clipboard as file references, so
            // ⌘C here then ⌘V in Finder copies the actual files. Gated on a
            // selection; the disabled state releases ⌘C so a focused search
            // field still copies text normally. Also released while the viewer
            // is open, where the viewer owns ⌘C via its own hidden button —
            // keeping exactly one owner of the key live (same pattern as ⌘⌫).
            Button(copyTitle) { model?.copyToClipboard() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!hasSelection || viewerOpen)

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

            Button("Move to Trash") { model?.moveToTrash() }
                .keyboardShortcut(.deleteBackspace, modifiers: .command)
                // A disabled Button releases its shortcut, so gating on
                // eligibility means the menu owns ⌘⌫ only when it should (not
                // while searching or over the viewer, which carries its own
                // ⌘⌫). That keeps exactly one owner of the key live.
                .disabled(!canTrash || trashEligible != true)
        }

        // MARK: Select All — standard text-editing group.
        CommandGroup(after: .textEditing) {
            Button("Select All Items") { model?.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!hasItems || viewerOpen)
        }

        // MARK: View menu — merged into SwiftUI's built-in "View" menu (via
        // the `.sidebar` placement) rather than a second `CommandMenu("View")`,
        // which would create a duplicate menu with the same name.
        CommandGroup(after: .sidebar) {
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

            // Break the grid/list into sections, one per AI category. Only
            // meaningful once something has been classified.
            Toggle("Group by Category", isOn: groupByCategoryBinding)
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
    private var hasItems: Bool { !(model?.displayedItems.isEmpty ?? true) }
    private var hasSelection: Bool { !(model?.selectedItems.isEmpty ?? true) }
    private var canTrash: Bool { model?.canTrashSelection ?? false }
    private var canOpen: Bool { hasItems && !viewerOpen }

    private var flagTitle: String {
        let count = model?.selectedItems.count ?? 0
        return count > 1 ? "Flag / Unflag Selection" : "Flag / Unflag"
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
        if model?.isClassifying == true { return "Classifying…" }
        let selectedImages = model?.selectedMediaItems.filter { $0.kind == .image }.count ?? 0
        if selectedImages > 1 { return "Classify \(selectedImages) Images with AI" }
        if hasSelection && selectedImages == 1 { return "Classify Image with AI" }
        return "Classify All Images with AI"
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
    private var groupByCategoryBinding: Binding<Bool> { binding(\.groupByCategory, default: false) }
    private var sortOrderBinding: Binding<SortOrder> { binding(\.sortOrder, default: .name) }
    private var sortAscendingBinding: Binding<Bool> { binding(\.sortAscending, default: true) }
}
