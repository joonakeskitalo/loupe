import SwiftUI

/// The main content area in list layout: a scrollable, selectable table of
/// files showing a small thumbnail, filename, creation/modification dates and
/// size. Shares selection, drag-out and context-menu behavior with the grid.
struct BrowserListView: View {
    @Bindable var model: BrowserModel
    /// When false (e.g. the search field is focused), the list must not grab
    /// keyboard focus on appear, so typing in search is never interrupted.
    var canAutoFocus: Bool = true

    @FocusState private var listFocused: Bool
    /// Set when selection changes via a click, so the auto-scroll (used for
    /// keyboard navigation) doesn't yank a clicked, already-visible item.
    @State private var suppressNextScroll = false

    /// Normalized zoom position in 0...1 across the grid's 90–320 range.
    private var zoomFraction: Double {
        (model.thumbnailSize - BrowserModel.minThumbnailSize)
            / (BrowserModel.maxThumbnailSize - BrowserModel.minThumbnailSize)
    }

    /// Row thumbnail size, derived from the shared zoom value so the toolbar
    /// slider scales list rows too. The grid's 90–320 range is mapped down to a
    /// compact 28–72 pt range that keeps rows readable.
    private var thumbSize: Double {
        28 + zoomFraction * (72 - 28)
    }

    /// Vertical padding around each row, scaled with the zoom so the smallest
    /// setting yields noticeably shorter rows (2 pt) and the largest stays
    /// comfortable (6 pt).
    private var rowVerticalPadding: Double {
        2 + zoomFraction * (6 - 2)
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            header
                            ForEach(items) { item in
                                ListRowView(
                                    item: item,
                                    thumbSize: thumbSize,
                                    verticalPadding: rowVerticalPadding,
                                    isSelected: model.selectedItems.contains(item.id),
                                    isFlagged: model.isFlagged(item.id)
                                )
                                .id(item.id)
                                .contentShape(Rectangle())
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
                                        listFocused = true
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
                        }
                    }
                    .onChange(of: model.selectedItem) { _, newValue in
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
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onAppear { if canAutoFocus { listFocused = true } }
                .onKeyPress { press in handleKey(press) }
            }
        }
    }

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

    /// Column header row, aligned with the row layout in `ListRowView`.
    private var header: some View {
        HStack(spacing: ListRowMetrics.columnSpacing) {
            // Thumbnail + name share the leading flexible column.
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, thumbSize + ListRowMetrics.columnSpacing)
            Text("Created")
                .frame(width: ListRowMetrics.dateWidth, alignment: .leading)
            Text("Modified")
                .frame(width: ListRowMetrics.dateWidth, alignment: .leading)
            Text("Size")
                .frame(width: ListRowMetrics.sizeWidth, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func dragURLs(for item: MediaItem) -> [URL] {
        if model.selectedItems.contains(item.id) {
            return model.selectedMediaItems.map(\.url)
        }
        return [item.url]
    }

    /// Arrow keys move the selection up/down the list; Shift extends a range.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard !model.isViewerPresented else { return .ignored }

        if press.modifiers.contains(.command), press.key == KeyEquivalent("a") {
            model.selectAll()
            return .handled
        }

        if press.modifiers.isEmpty, press.key == KeyEquivalent("f") {
            model.toggleFlag()
            return .handled
        }

        let direction: BrowserModel.MoveDirection
        switch press.key {
        case .upArrow:   direction = .up
        case .downArrow: direction = .down
        default:         return .ignored
        }

        model.selectFirstIfNeeded()
        let extend = press.modifiers.contains(.shift)
        // A list is a single column, so Up/Down step one row.
        model.moveSelection(direction, columns: 1, extend: extend)
        return .handled
    }

    @ViewBuilder
    private func contextMenu(for item: MediaItem) -> some View {
        let count = model.actionURLs(preferring: item).count
        let suffix = count > 1 ? " (\(count) items)" : ""

        Button("Open in Viewer") {
            if !model.selectedItems.contains(item.id) { model.selectOnly(item.id) }
            model.isViewerPresented = true
        }

        Divider()

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

        Divider()

        Button("Move to Trash\(suffix)", systemImage: "trash", role: .destructive) {
            model.moveToTrash(item)
        }
        // No .keyboardShortcut here: a shortcut on a context-menu button is
        // registered globally for every row while the list is visible, so many
        // buttons would claim ⌘⌫ at once and fight the single global handler in
        // ContentView — the cause of the key working only sometimes. The global
        // hotkey covers ⌘⌫; the menu still shows it as a hint.
    }

    private enum FlagState { case allFlagged, someOrNone }

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

/// Fixed metrics shared by the list header and its rows so columns line up.
enum ListRowMetrics {
    static let columnSpacing: CGFloat = 12
    static let dateWidth: CGFloat = 140
    static let sizeWidth: CGFloat = 80
}

/// A single file row: small thumbnail, filename, creation & modification dates,
/// and size.
private struct ListRowView: View {
    let item: MediaItem
    let thumbSize: Double
    let verticalPadding: Double
    let isSelected: Bool
    var isFlagged: Bool = false

    @State private var image: NSImage?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    var body: some View {
        HStack(spacing: ListRowMetrics.columnSpacing) {
            thumbnail
                .frame(width: thumbSize, height: thumbSize)
                .overlay(alignment: .topTrailing) {
                    if isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.white)
                            .padding(2)
                            .background(Color.orange, in: Circle())
                    }
                }

            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(dateString(item.creationDate))
                .frame(width: ListRowMetrics.dateWidth, alignment: .leading)
                .foregroundStyle(.secondary)

            Text(dateString(item.modificationDate))
                .frame(width: ListRowMetrics.dateWidth, alignment: .leading)
                .foregroundStyle(.secondary)

            Text(Self.byteFormatter.string(fromByteCount: item.fileSize))
                .frame(width: ListRowMetrics.sizeWidth, alignment: .trailing)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, verticalPadding)
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .background(
            isSelected ? Color.accentColor.opacity(0.15) : Color.clear
        )
        .task(id: item.id) { await loadThumbnail() }
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.12))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(2)
            } else {
                Image(systemName: item.kind.fallbackSymbol)
                    .font(.system(size: thumbSize * 0.4))
                    .foregroundStyle(.secondary)
            }

            if item.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: thumbSize * 0.32))
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
        }
    }

    private func dateString(_ date: Date) -> String {
        guard date != .distantPast else { return "—" }
        return Self.dateFormatter.string(from: date)
    }

    private func loadThumbnail() async {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let target = CGSize(width: thumbSize, height: thumbSize)
        if let result = await ThumbnailProvider.shared.thumbnail(for: item.url, size: target, scale: scale) {
            image = result
        }
    }
}
