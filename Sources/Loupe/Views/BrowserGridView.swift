import SwiftUI

/// The main content area: a scrollable grid of thumbnails.
struct BrowserGridView: View {
    @Bindable var model: BrowserModel
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
                                        isSelected: model.selectedItem == item.id
                                    )
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    // AppKit-level click handling: selection fires
                                    // on mouse-down with no double-click delay.
                                    .onClick(
                                        single: {
                                            suppressNextScroll = true
                                            model.selectedItem = item.id
                                            gridFocused = true
                                        },
                                        double: {
                                            suppressNextScroll = true
                                            model.selectedItem = item.id
                                            model.isViewerPresented = true
                                        }
                                    )
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
                .onAppear { gridFocused = true }
                .onKeyPress(.leftArrow) { handleArrow(.left) }
                .onKeyPress(.rightArrow) { handleArrow(.right) }
                .onKeyPress(.upArrow) { handleArrow(.up) }
                .onKeyPress(.downArrow) { handleArrow(.down) }
            }
        }
    }

    /// Arrow keys navigate the grid. When the viewer is open it owns the arrow
    /// keys (left/right between items), so the grid ignores them.
    private func handleArrow(_ direction: BrowserModel.MoveDirection) -> KeyPress.Result {
        guard !model.isViewerPresented else { return .ignored }
        model.selectFirstIfNeeded()
        model.moveSelection(direction, columns: model.gridColumnCount)
        return .handled
    }
}
