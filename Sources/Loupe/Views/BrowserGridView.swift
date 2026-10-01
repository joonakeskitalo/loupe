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
                ContentUnavailableView(
                    "No Media Here",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(model.mode == .folders
                        ? "This folder has no previewable files."
                        : "The dropped folder contains no previewable files.")
                )
            } else {
                GeometryReader { geo in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: spacing) {
                                ForEach(items) { item in
                                    ThumbnailView(
                                        item: item,
                                        size: model.thumbnailSize,
                                        isSelected: model.selectedItems.contains(item.id)
                                    )
                                    .id(item.id)
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
                // Single unfiltered handler so we can read modifier keys
                // (Shift) alongside the arrow key from the KeyPress.
                .onKeyPress { press in handleKey(press) }
            }
        }
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
        Button("Open with Default App\(suffix)") {
            model.openInDefaultApp(item)
        }
        Button("Reveal in Finder\(suffix)") {
            model.revealInFinder(item)
        }
    }
}
