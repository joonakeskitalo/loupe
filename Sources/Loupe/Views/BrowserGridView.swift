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
    private let spacing: CGFloat = 12
    private let padding: CGFloat = 16

    private var cellWidth: CGFloat { model.thumbnailSize + 24 }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellWidth), spacing: spacing)]
    }

    /// Number of columns that fit in a given width, matching the adaptive grid.
    private func columnCount(for width: CGFloat) -> Int {
        let usable = width - padding * 2
        guard usable > 0 else { return 1 }
        let count = Int((usable + spacing) / (cellWidth + spacing))
        return max(1, count)
    }

    var body: some View {
        let items = model.displayedItems
        Group {
            if items.isEmpty {
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
                } else {
                    ContentUnavailableView(
                        "No Media Here",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text(model.mode == .folders
                            ? "This folder has no previewable files."
                            : "The dropped folder contains no previewable files.")
                    )
                }
            } else {
                GeometryReader { geo in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: spacing) {
                                ForEach(items) { item in
                                    ThumbnailView(
                                        item: item,
                                        size: model.thumbnailSize,
                                        isSelected: model.selectedItems.contains(item.id),
                                        isFlagged: model.isFlagged(item.id)
                                    )
                                    .id(item.id)
                                    .reportCellFrame(id: item.id, in: gridSpace)
                                    .contentShape(Rectangle())
                                    // AppKit-level click handling: selection fires
                                    // on mouse-down with no double-click delay.
                                    // Command toggles, Shift extends a range.
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
                                        }
                                    )
                                    .contextMenu { contextMenu(for: item) }
                                }
                            }
                            .padding(padding)
                            .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                            // Marquee layer sits behind the cells (AppKit-level,
                            // so the scroll view never sees the drag): a drag
                            // beginning on empty space rubber-band-selects; drags
                            // on a cell are consumed by the cell's own overlay.
                            .background(
                                MarqueeView { rect in
                                    handleMarquee(rect)
                                }
                            )
                            .overlay(marqueeRectangle)
                        }
                        .coordinateSpace(name: gridSpace)
                        .onPreferenceChange(CellFramesKey.self) { cellFrames = $0 }
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
                // Single unfiltered handler so we can read modifier keys
                // (Shift) alongside the arrow key from the KeyPress.
                .onKeyPress { press in handleKey(press) }
            }
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
        model.moveSelection(direction, columns: model.gridColumnCount, extend: extend)
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

        Divider()

        Button("Open with Default App\(suffix)") {
            model.openInDefaultApp(item)
        }
        Button("Reveal in Finder\(suffix)") {
            model.revealInFinder(item)
        }
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

    private func flagMenuTitle(_ state: FlagState, suffix: String) -> String {
        state == .allFlagged ? "Unflag\(suffix)" : "Flag for Later\(suffix)"
    }
}
