import SwiftUI

/// The main content area: a scrollable grid of thumbnails.
struct BrowserGridView: View {
    @Bindable var model: BrowserModel
    /// When false (e.g. the search field is focused), the grid must not grab
    /// keyboard focus on appear, so typing in search is never interrupted.
    var canAutoFocus: Bool = true

    @FocusState private var gridFocused: Bool
    /// Set when selection changes via a click, so the auto-scroll (used for
    /// keyboard navigation) doesn't yank a clicked, already-visible item.
    @State private var suppressNextScroll = false

    // Rubber-band (marquee) selection state, in the "grid" coordinate space.
    @State private var cellFrames: [URL: CGRect] = [:]
    @State private var marqueeRect: CGRect?

    private let gridSpace = "grid"
    /// Gap between cells. Collapsed to zero when filenames are hidden so the
    /// image-only grid packs edge to edge (the cell's own padding also drops to
    /// zero there).
    private var spacing: CGFloat { model.hideFilenames ? 0 : 2 }
    private let padding: CGFloat = 8

    private var cellWidth: CGFloat { model.thumbnailSize + 12 }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellWidth), spacing: spacing)]
    }

    /// How many items past a newly-appeared cell to warm. Roughly a couple of
    /// rows ahead so a continued downward scroll lands on ready thumbnails
    /// without warming the whole folder. Prefetch work is low priority, so it
    /// never delays a cell the user can actually see.
    private var prefetchWindow: Int { max(8, liveColumnCount * 3) }

    /// Warms thumbnails for the items just after `index` at prefetch priority.
    /// Driven off each cell's `onAppear`, which LazyVGrid fires slightly ahead
    /// of the viewport, so neighbors decode before the user scrolls to them.
    private func prefetchAhead(from index: Int, in items: [MediaItem]) {
        guard index >= 0, index < items.count else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let target = CGSize(width: model.thumbnailSize, height: model.thumbnailSize)
        let upper = min(items.count, index + 1 + prefetchWindow)
        guard index + 1 < upper else { return }
        let urls = items[(index + 1)..<upper].map(\.url)
        let method = model.thumbnailMethod
        let videoPosition = model.videoThumbnailPosition
        Task {
            for url in urls {
                await ThumbnailProvider.shared.prefetch(
                    url, size: target, scale: scale, method: method, videoPosition: videoPosition
                )
            }
        }
    }

    /// Position of each item in the full display order, so a grouped layout can
    /// still warm neighbors across section boundaries (prefetch is driven by a
    /// cell's index into the flat `displayedItems`, not its index within a
    /// section). Backed by the model's memoized `displayedItemIndex`, so it's
    /// built once per display change rather than once per rendered cell.
    private var globalIndex: [MediaItem.ID: Int] {
        guard model.grouping != .none else { return [:] }
        return model.displayedItemIndex
    }

    /// A single grid cell: the thumbnail plus all its selection, drag, prefetch
    /// and context-menu wiring. Shared by the flat and grouped layouts so both
    /// behave identically. `index` is the item's position in the full display
    /// order, used to warm the following thumbnails.
    @ViewBuilder
    private func cell(for item: MediaItem, index: Int, in items: [MediaItem]) -> some View {
        ThumbnailView(
            item: item,
            size: model.thumbnailSize,
            isSelected: model.selectedItems.contains(item.id),
            isFlagged: model.isFlagged(item.id),
            isHidden: model.isHidden(item.id),
            colorTag: model.colorTag(item.id),
            aiCategory: model.aiCategory(item.id),
            textTags: model.textTags(item.id),
            personCount: model.persons(item.id).count,
            hideFilename: model.hideFilenames,
            method: model.thumbnailMethod,
            videoPosition: model.videoThumbnailPosition
        )
        // The ScrollViewReader scrolls to this id; a grouped person view may
        // show the same item under several people, so scrolling resolves to the
        // first matching cell, which is fine.
        .id(item.id)
        // As the grid instantiates this cell (which LazyVGrid does just before
        // it scrolls into view), warm the next few items at low priority so a
        // continued scroll finds them ready. Visible cells still take priority.
        .onAppear { prefetchAhead(from: index, in: items) }
        .reportCellFrame(id: item.id, in: gridSpace)
        .contentShape(Rectangle())
        // AppKit-level click handling: selection fires on mouse-down with no
        // double-click delay. Command toggles, Shift extends a range.
        .onClick(
            single: { mods in
                suppressNextScroll = true
                if mods.command {
                    model.toggleSelection(item.id)
                } else if mods.shift {
                    model.extendSelection(to: item.id)
                } else {
                    model.selectOnly(item.id)
                }
                gridFocused = true
            },
            double: { _ in
                suppressNextScroll = true
                if !model.selectedItems.contains(item.id) {
                    model.selectOnly(item.id)
                }
                model.isViewerPresented = true
            },
            dragURLs: { dragURLs(for: item) },
            isSelected: { model.selectedItems.contains(item.id) }
        )
        .contextMenu { contextMenu(for: item) }
    }

    /// A pinned category section header: the category name, an item count, and
    /// a tap target that filters the grid to just that category.
    @ViewBuilder
    private func sectionHeader(_ group: BrowserModel.CategoryGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: group.symbol)
                .foregroundStyle(.secondary)
            Text(group.title)
                .font(.headline)
                .foregroundStyle(group.isResidual ? .secondary : .primary)
            Text("\(group.items.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    /// Vertical gap below each group (except the last) that separates adjacent
    /// sections in the grouped grid.
    private static let groupSpacing: CGFloat = 20

    /// Number of columns that fit in a given width, matching the adaptive grid.
    /// Used as a fallback before any cells have reported their frames.
    private func columnCount(for width: CGFloat) -> Int {
        let usable = width - padding * 2
        guard usable > 0 else { return 1 }
        let count = Int((usable + spacing) / (cellWidth + spacing))
        return max(1, count)
    }

    /// The number of columns actually on screen, derived from the rendered cell
    /// frames rather than a width estimate. The adaptive `LazyVGrid` decides the
    /// real column count internally, and an external window-snapping tool can
    /// resize the grid without the width-based `onChange` producing a count that
    /// matches what SwiftUI laid out.
    ///
    /// We take the *widest* instantiated row — the most cells sharing a single
    /// `minY` — not simply the topmost row. `cellFrames` only holds the cells
    /// LazyVGrid has realized (roughly the viewport), and with grouping the top
    /// realized row is often a partial row: the tail of a section scrolled just
    /// off the top, or a section's short first/last row. Counting a partial row
    /// yields too few columns and throws off every Up/Down jump. A full row has
    /// the true column count, and at least one is almost always realized, so the
    /// maximum row width is the reliable signal. Falls back to the cached
    /// estimate until frames are reported.
    private var liveColumnCount: Int {
        Self.columnCount(from: cellFrames, fallback: max(1, model.gridColumnCount))
    }

    /// Bucket cells into rows by shared minY (tolerance absorbs sub-pixel
    /// drift), then take the widest row's cell count. Static so it can be
    /// computed from freshly-reported frames before the `@State` settles.
    private static func columnCount(from frames: [MediaItem.ID: CGRect], fallback: Int) -> Int {
        guard !frames.isEmpty else { return fallback }
        let tolerance: CGFloat = 1
        let sortedMinY = frames.values.map(\.minY).sorted()
        var widest = 1
        var rowStartY = sortedMinY[0]
        var rowCount = 0
        for y in sortedMinY {
            if y - rowStartY <= tolerance {
                rowCount += 1
            } else {
                widest = max(widest, rowCount)
                rowStartY = y
                rowCount = 1
            }
        }
        widest = max(widest, rowCount)
        return max(1, widest)
    }

    var body: some View {
        let items = model.displayedItems
        Group {
            if items.isEmpty {
                emptyState
                    // Fill the available area so the surrounding VStack keeps
                    // the filter bar pinned to the top instead of centering it
                    // vertically alongside a compact empty-state view.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: spacing, pinnedViews: [.sectionHeaders]) {
                                if model.grouping != .none {
                                    // Grouped: one section per category/person,
                                    // with a pinned header. Cells warm by their
                                    // position in the full display order
                                    // (globalIndex) so prefetch spans sections.
                                    // A person can appear in several sections, so
                                    // each cell's SwiftUI identity is scoped to
                                    // its group to avoid duplicate-id collisions.
                                    let groups = model.groupedDisplayedItems
                                    ForEach(Array(groups.enumerated()),
                                            id: \.element.id) { groupIndex, group in
                                        Section {
                                            // Composite data identity (group +
                                            // item) so a person who appears in
                                            // several sections doesn't produce
                                            // duplicate ForEach identities within
                                            // the one LazyVGrid.
                                            ForEach(group.entries) { entry in
                                                cell(for: entry.item,
                                                     index: globalIndex[entry.item.id] ?? 0,
                                                     in: items)
                                            }
                                        } header: {
                                            sectionHeader(group)
                                        } footer: {
                                            // Gap below every group but the
                                            // last. A footer spans the full grid
                                            // width and isn't pinned, so the next
                                            // header still sticks flush to top.
                                            if groupIndex < groups.count - 1 {
                                                Color.clear.frame(height: Self.groupSpacing)
                                            }
                                        }
                                    }
                                } else {
                                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                        cell(for: item, index: index, in: items)
                                    }
                                }
                            }
                            .padding(padding)
                            .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                            // Marquee layer sits behind the cells (AppKit-level,
                            // so the scroll view never sees the drag): a drag
                            // beginning on empty space rubber-band-selects; drags
                            // on a cell are consumed by the cell's own overlay.
                            .background(
                                MarqueeView(
                                    onChange: { rect in handleMarquee(rect) },
                                    onEmptyClick: {
                                        gridFocused = true
                                        model.clearSelection()
                                    }
                                )
                            )
                            .overlay(marqueeRectangle)
                        }
                        .coordinateSpace(name: gridSpace)
                        .onPreferenceChange(CellFramesKey.self) { frames in
                            cellFrames = frames
                            // Publish the accurate, rendered column count so
                            // other surfaces (e.g. the tag overlay's Up/Down
                            // navigation) jump exactly one row. Computed from
                            // the freshly-reported frames (not `liveColumnCount`,
                            // which reads the not-yet-settled @State). The
                            // width-based estimate elsewhere is only a fallback
                            // before frames arrive; it tends to be too small and
                            // threw off Up/Down when read from outside the grid.
                            let live = Self.columnCount(from: frames,
                                                        fallback: max(1, model.gridColumnCount))
                            if model.gridColumnCount != live {
                                model.gridColumnCount = live
                            }
                        }
                        .onChange(of: model.selectedItem) { _, newValue in
                            // Clicks already land on a visible item, so only
                            // auto-scroll for keyboard navigation.
                            if suppressNextScroll {
                                suppressNextScroll = false
                                return
                            }
                            if let newValue {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    proxy.scrollTo(newValue, anchor: .center)
                                }
                            }
                        }
                    }
                    .onChange(of: geo.size.width, initial: true) { _, width in
                        model.gridColumnCount = columnCount(for: width)
                    }
                }
                .focusable()
                .focused($gridFocused)
                .focusEffectDisabled()
                // Only auto-focus when permitted. This branch reappears every
                // time search results return after being empty, so grabbing
                // focus unconditionally here would steal it from the search
                // field mid-type.
                .onAppear { if canAutoFocus { gridFocused = true } }
                // Reclaim keyboard focus when the viewer closes. The grid stays
                // mounted beneath the viewer overlay, so its `.onAppear` never
                // fires again on dismiss; without this the arrow keys stay dead
                // until the user clicks a cell. Deferred a runloop tick so the
                // viewer has fully relinquished focus first.
                .onChange(of: model.isViewerPresented) { _, presented in
                    if !presented && canAutoFocus {
                        DispatchQueue.main.async { gridFocused = true }
                    }
                }
                // Likewise reclaim focus when the tag-input overlay closes. Its
                // text field takes first responder while open, so on dismiss
                // the grid would otherwise stay unfocused and arrow-key
                // navigation would be dead until the user clicks a cell.
                .onChange(of: model.showTagInput) { _, showing in
                    if !showing && canAutoFocus && !model.isViewerPresented {
                        DispatchQueue.main.async { gridFocused = true }
                    }
                }
                // Arrow keys get their own handler, matched on the specific
                // keys. This is what makes them take precedence over the
                // enclosing ScrollView's built-in arrow-key scrolling —
                // ↑/↓ would otherwise scroll the grid instead of moving the
                // selection (←/→ have no scroll action, which is why only
                // up/down appeared broken). The KeyPress still carries the
                // modifiers, so Shift-extend keeps working.
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                    handleKey(press)
                }
                // Everything else (⌘A, F) via a catch-all handler.
                .onKeyPress { press in handleKey(press) }
            }
        }
    }

    /// Shown when nothing matches the current scope/filters. Kept as a separate
    /// view so it can be given an expanding frame; a bare `ContentUnavailableView`
    /// in a `VStack` sizes to its content and lets siblings drift to the middle.
    @ViewBuilder
    private var emptyState: some View {
        if model.hasActiveChipFilters && !model.scopedItems.isEmpty {
            ContentUnavailableView(
                "No Matching Files",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("No files match the selected type/extension filters.")
            )
        } else if model.showFlaggedOnly {
            ContentUnavailableView(
                "No Flagged Files",
                systemImage: "flag",
                description: Text("Flag files with F to see them here, or turn off the flagged filter.")
            )
        } else if model.showHiddenOnly {
            ContentUnavailableView(
                "No Hidden Files",
                systemImage: "eye.slash",
                description: Text("Hide files with ⌫ to see them here, or pick All Media.")
            )
        } else if let tag = model.colorTagFilter {
            ContentUnavailableView(
                "No \(tag.displayName) Files",
                systemImage: tag.symbol,
                description: Text("Tag files with ⌃ and a number to see them here, or pick All Media.")
            )
        } else {
            ContentUnavailableView(
                "Nothing Here",
                systemImage: "photo.on.rectangle.angled",
                description: Text(model.mode == .folders
                    ? "This folder has no files."
                    : "The dropped folder has no files.")
            )
        }
    }

    // MARK: - Marquee (rubber-band) selection

    /// A transparent background that captures drags starting on empty space and
    /// turns them into a rubber-band selection.
    /// The visible selection rectangle while dragging.
    @ViewBuilder
    private var marqueeRectangle: some View {
        if let rect = marqueeRect {
            Rectangle()
                .fill(Color.accentColor.opacity(0.15))
                .overlay(Rectangle().stroke(Color.accentColor.opacity(0.8), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    /// File URLs to drag out when dragging `item`: the whole selection if the
    /// item is part of it, otherwise just that item.
    private func dragURLs(for item: MediaItem) -> [URL] {
        if model.selectedItems.contains(item.id) {
            return model.selectedMediaItems.map(\.url)
        }
        return [item.url]
    }

    /// Called by the AppKit marquee layer: `rect` is the live rectangle, or nil
    /// when the drag ends.
    private func handleMarquee(_ rect: CGRect?) {
        marqueeRect = rect
        guard let rect else { return }
        gridFocused = true
        suppressNextScroll = true
        let hits = cellFrames.compactMap { $0.value.intersects(rect) ? $0.key : nil }
        model.setSelection(hits)
    }

    /// Arrow keys navigate the grid; holding Shift extends the selection as a
    /// range. When the viewer is open it owns the arrow keys, so the grid
    /// ignores them.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard !model.isViewerPresented else { return .ignored }

        // Cmd+A selects everything in the grid.
        if press.modifiers.contains(.command), press.key == KeyEquivalent("a") {
            model.selectAll()
            return .handled
        }

        // Note: ⌘⌫ "Move to Trash" is handled by the menu-bar command (see
        // LoupeApp), which AppKit routes to the key window through the
        // responder chain. We intentionally don't handle it here so there's a
        // single, unambiguous owner of the shortcut.

        // F (no modifiers) flags/unflags the current selection.
        if press.modifiers.isEmpty, press.key == KeyEquivalent("f") {
            model.toggleFlag()
            return .handled
        }

        let direction: BrowserModel.MoveDirection
        switch press.key {
        case .leftArrow:  direction = .left
        case .rightArrow: direction = .right
        case .upArrow:    direction = .up
        case .downArrow:  direction = .down
        default:          return .ignored
        }

        model.selectFirstIfNeeded()
        let extend = press.modifiers.contains(.shift)
        // Use the live, rendered column count so Up/Down jump exactly one row
        // even if an external resize changed the grid without the width-based
        // observer catching up.
        model.moveSelection(direction, columns: liveColumnCount, extend: extend)
        return .handled
    }

    /// Right-click menu for a grid item. Actions apply to the whole selection
    /// when the clicked item is part of it, otherwise just to that item.
    @ViewBuilder
    private func contextMenu(for item: MediaItem) -> some View {
        let count = model.actionURLs(preferring: item).count
        let suffix = count > 1 ? " (\(count) items)" : ""

        Button("Open in Viewer") {
            if !model.selectedItems.contains(item.id) { model.selectOnly(item.id) }
            model.isViewerPresented = true
        }

        Divider()

        // Flag label reflects whether the acted-on target(s) are flagged.
        let targetsFlagged = flagStateForMenu(item)
        Button(flagMenuTitle(targetsFlagged, suffix: suffix),
               systemImage: targetsFlagged == .allFlagged ? "flag.slash" : "flag") {
            model.toggleFlag(item)
        }

        // Hide label mirrors the flag item: shows "Unhide" when every target is
        // already hidden, else "Hide".
        let targetsHidden = hiddenStateForMenu(item)
        Button(targetsHidden ? "Unhide\(suffix)" : "Hide\(suffix)",
               systemImage: targetsHidden ? "eye" : "eye.slash") {
            model.toggleHidden(item)
        }

        colorTagMenu(for: item, suffix: suffix)

        if classifyTargetCount(for: item) > 0 {
            Button("Classify with AI\(suffix)", systemImage: "sparkles") {
                model.classifySelection(item)
            }
            .disabled(model.isClassifying)
            Button("Find Faces\(suffix)", systemImage: "person.crop.circle") {
                model.recognizeFacesInSelection(item)
            }
            .disabled(model.isClassifying)

            // Manual corrections: move file(s) between categories/people.
            ClassificationEditMenu(model: model, item: item)
        }

        Divider()

        Button("Copy\(suffix)", systemImage: "doc.on.doc") {
            model.copyToClipboard(item)
        }
        // Copy the picture itself (pixels) at a chosen size, optionally with
        // metadata stripped. Only offered when the target(s) include an image.
        if model.imageURLs(preferring: item).isEmpty == false {
            Menu("Copy Image As") {
                Picker("Format", selection: $model.imageCopyFormat) {
                    ForEach(ImageCopyFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.inline)
                Toggle("Remove EXIF / Metadata", isOn: $model.imageCopyStripsMetadata)
                    .disabled(!model.imageCopyFormat.canCarryMetadata)
                Divider()
                ForEach(ImageCopyScale.allCases, id: \.self) { scale in
                    Button(scale.displayName) {
                        model.copyImageToClipboard(
                            item,
                            scale: scale,
                            format: model.imageCopyFormat,
                            stripMetadata: model.imageCopyStripsMetadata
                        )
                    }
                }
            }
            // Export the picture(s) to a chosen folder, re-encoded at a picked
            // resolution and format (optionally without EXIF).
            Menu("Export Image As") {
                Picker("Format", selection: $model.exportFormat) {
                    ForEach(ImageCopyFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.inline)
                Picker("Resolution", selection: $model.exportScale) {
                    ForEach(ImageCopyScale.allCases, id: \.self) { scale in
                        Text(scale.displayName).tag(scale)
                    }
                }
                .pickerStyle(.inline)
                if model.exportFormat == .jpeg {
                    Picker("Quality", selection: $model.exportJPEGQuality) {
                        ForEach(LoupeCommands.jpegQualityPresets, id: \.self) { q in
                            Text("\(q)").tag(q)
                        }
                    }
                    .pickerStyle(.inline)
                }
                Toggle("Remove EXIF / Metadata", isOn: $model.exportStripsMetadata)
                    .disabled(!model.exportFormat.canCarryMetadata)
                Divider()
                Button("Export to Folder…") {
                    model.exportImagesToChosenFolder(item)
                }
            }
            .disabled(model.isExportingImages)
        }
        Button("Open with Default App\(suffix)") {
            model.openInDefaultApp(item)
        }
        Button("Reveal in Finder\(suffix)") {
            model.revealInFinder(item)
        }

        Divider()

        Button("Move to Trash\(suffix)", systemImage: "trash", role: .destructive) {
            model.moveToTrash(item)
        }
        // No .keyboardShortcut here: a shortcut on a context-menu button is
        // registered globally for every item while the grid is visible, so
        // dozens of buttons would claim ⌘⌫ at once and fight the single global
        // handler in ContentView — the cause of the key working only sometimes.
        // The global hotkey covers ⌘⌫; the menu still shows it as a hint.
    }

    /// How many image items a classify action would act on for `item`: the
    /// image(s) in the selection when the clicked item is part of it, else just
    /// the clicked item if it's an image. Zero hides the menu entry.
    private func classifyTargetCount(for item: MediaItem) -> Int {
        if model.selectedItems.contains(item.id) {
            return model.selectedMediaItems.filter { $0.kind == .image }.count
        }
        return item.kind == .image ? 1 : 0
    }

    private enum FlagState { case allFlagged, someOrNone }

    /// Whether every target of a flag action is already flagged, to choose
    /// between "Flag" and "Unflag" in the menu.
    private func flagStateForMenu(_ item: MediaItem) -> FlagState {
        let targets: [MediaItem.ID]
        if model.selectedItems.contains(item.id) {
            targets = Array(model.selectedItems)
        } else {
            targets = [item.id]
        }
        let allFlagged = !targets.isEmpty && targets.allSatisfy { model.isFlagged($0) }
        return allFlagged ? .allFlagged : .someOrNone
    }

    /// Whether every target of a hide action is already hidden, to choose
    /// between "Hide" and "Unhide" in the menu.
    private func hiddenStateForMenu(_ item: MediaItem) -> Bool {
        let targets: [MediaItem.ID]
        if model.selectedItems.contains(item.id) {
            targets = Array(model.selectedItems)
        } else {
            targets = [item.id]
        }
        return !targets.isEmpty && targets.allSatisfy { model.isHidden($0) }
    }

    private func flagMenuTitle(_ state: FlagState, suffix: String) -> String {
        state == .allFlagged ? "Unflag\(suffix)" : "Flag for Later\(suffix)"
    }

    /// Right-click "Color Tag" submenu. Mirrors the flag item: acts on the
    /// whole selection when the clicked item is part of it, else just that
    /// item. No keyboard shortcuts here (the global ⌃1–⌃5 own those).
    @ViewBuilder
    private func colorTagMenu(for item: MediaItem, suffix: String) -> some View {
        Menu("Color Tag\(suffix)") {
            ForEach(ColorTag.allInHotkeyOrder, id: \.self) { tag in
                Button(tag.displayName, systemImage: tag.symbol) {
                    model.toggleColorTag(tag, item: item)
                }
            }
            Divider()
            Button("Remove Tag") { model.clearColorTag(item: item) }
        }
    }
}
