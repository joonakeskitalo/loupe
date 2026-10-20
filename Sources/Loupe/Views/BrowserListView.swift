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

    /// Vertical gap below each group (except the last) that separates adjacent
    /// sections when grouping is active, so sections read as distinct.
    private static let groupSpacing: CGFloat = 20

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

    /// At the very smallest row size, rows show a file-type icon instead of a
    /// generated thumbnail — the thumbnail is too tiny to read there, and
    /// skipping it avoids the thumbnail work entirely at the most compact zoom.
    private var showsThumbnail: Bool {
        zoomFraction > 0.001
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
                  VStack(spacing: 0) {
                    // Pinned above the scroll view so the sortable column
                    // headers stay visible while the rows scroll underneath.
                    header
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            if model.grouping != .none {
                                let groups = model.groupedDisplayedItems
                                ForEach(Array(groups.enumerated()),
                                        id: \.element.id) { groupIndex, group in
                                    Section {
                                        ForEach(group.entries) { entry in row(for: entry.item) }
                                    } header: {
                                        sectionHeader(group)
                                    } footer: {
                                        // Gap below every group but the last.
                                        // A footer spans the full width and is
                                        // not pinned, so the next group's header
                                        // still sticks flush to the top.
                                        if groupIndex < groups.count - 1 {
                                            Color.clear.frame(height: Self.groupSpacing)
                                        }
                                    }
                                }
                            } else {
                                ForEach(items) { item in row(for: item) }
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
                }
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onAppear { if canAutoFocus { listFocused = true } }
                // Reclaim keyboard focus when the viewer closes. The list stays
                // mounted beneath the viewer overlay, so its `.onAppear` never
                // fires again on dismiss; without this the arrow keys stay dead
                // until the user clicks a row. Deferred a runloop tick so the
                // viewer has fully relinquished focus first.
                .onChange(of: model.isViewerPresented) { _, presented in
                    if !presented && canAutoFocus {
                        DispatchQueue.main.async { listFocused = true }
                    }
                }
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

    /// Column header row, aligned with the row layout in `ListRowView`. Each
    /// header is a button: clicking sorts by that column, clicking the active
    /// column again flips the direction.
    private var header: some View {
        HStack(spacing: ListRowMetrics.columnSpacing) {
            // Thumbnail + name share the leading flexible column.
            columnHeader("Name", sort: .name, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, thumbSize + ListRowMetrics.columnSpacing)
            columnHeader("Type", sort: .type, alignment: .leading)
                .frame(width: ListRowMetrics.typeWidth, alignment: .leading)
            columnHeader("Created", sort: .dateCreated, alignment: .leading)
                .frame(width: ListRowMetrics.dateWidth, alignment: .leading)
            columnHeader("Modified", sort: .dateModified, alignment: .leading)
                .frame(width: ListRowMetrics.dateWidth, alignment: .leading)
            columnHeader("Size", sort: .size, alignment: .trailing)
                .frame(width: ListRowMetrics.sizeWidth, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// A single clickable column header showing its title and, when it's the
    /// active sort column, a chevron for the direction.
    private func columnHeader(
        _ title: String,
        sort: SortOrder,
        alignment: HorizontalAlignment
    ) -> some View {
        let isActive = model.sortOrder == sort
        return Button {
            model.toggleSort(sort)
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title)
                if isActive {
                    Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .contentShape(Rectangle())
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .help("Sort by \(title)")
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

        // Note: ⌘⌫ "Move to Trash" is handled by the menu-bar command (see
        // LoupeApp), which AppKit routes to the key window through the
        // responder chain. We intentionally don't handle it here so there's a
        // single, unambiguous owner of the shortcut.

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

    /// A single list row with all its selection, drag, and context-menu wiring.
    /// Shared by the flat and grouped layouts so both behave identically.
    @ViewBuilder
    private func row(for item: MediaItem) -> some View {
        ListRowView(
            item: item,
            thumbSize: thumbSize,
            showsThumbnail: showsThumbnail,
            verticalPadding: rowVerticalPadding,
            isSelected: model.selectedItems.contains(item.id),
            isFlagged: model.isFlagged(item.id),
            isHidden: model.isHidden(item.id),
            colorTag: model.colorTag(item.id),
            aiCategory: model.aiCategory(item.id),
            method: model.thumbnailMethod,
            videoPosition: model.videoThumbnailPosition
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

    /// A pinned section header for the grouped list layout.
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
        // Export the picture(s) to a chosen folder, re-encoded at a picked
        // resolution and format (optionally without EXIF). Only offered when
        // the target(s) include an image.
        if model.imageURLs(preferring: item).isEmpty == false {
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
        // registered globally for every row while the list is visible, so many
        // buttons would claim ⌘⌫ at once and fight the single global handler in
        // ContentView — the cause of the key working only sometimes. The global
        // hotkey covers ⌘⌫; the menu still shows it as a hint.
    }

    /// How many image items a classify action would act on for `item`: the
    /// image(s) in the selection when the clicked row is part of it, else just
    /// the clicked row if it's an image. Zero hides the menu entry.
    private func classifyTargetCount(for item: MediaItem) -> Int {
        if model.selectedItems.contains(item.id) {
            return model.selectedMediaItems.filter { $0.kind == .image }.count
        }
        return item.kind == .image ? 1 : 0
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

    /// Right-click "Color Tag" submenu, mirroring the grid's.
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

/// Fixed metrics shared by the list header and its rows so columns line up.
enum ListRowMetrics {
    static let columnSpacing: CGFloat = 12
    static let typeWidth: CGFloat = 180
    static let dateWidth: CGFloat = 140
    static let sizeWidth: CGFloat = 80
}

/// A single file row: small thumbnail, filename, creation & modification dates,
/// and size.
private struct ListRowView: View {
    let item: MediaItem
    let thumbSize: Double
    /// When false (smallest row size), show a file-type icon instead of a
    /// generated thumbnail and skip thumbnail loading entirely.
    var showsThumbnail: Bool = true
    let verticalPadding: Double
    let isSelected: Bool
    var isFlagged: Bool = false
    /// Whether this item is hidden (shows an eye.slash badge). Only visible in
    /// the "Hidden" Library view.
    var isHidden: Bool = false
    var colorTag: ColorTag? = nil
    /// AI-assigned category, if classified. Shown as a small pill after the name.
    var aiCategory: String? = nil
    /// The window's active thumbnail-generation method.
    var method: ThumbnailMethod = .hybrid
    /// Where in a video its thumbnail frame is taken (the window's setting).
    var videoPosition: VideoThumbnailPosition = .defaultPosition

    @State private var image: NSImage?
    /// Codec + pixel dimensions, probed lazily for video and image rows.
    @State private var metadata: MediaMetadata = .empty

    /// Uppercased file extension shown as the file type (e.g. "MP4", "PNG").
    private var fileType: String {
        item.url.pathExtension.uppercased()
    }

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
                    HStack(spacing: 2) {
                        if isHidden {
                            Image(systemName: "eye.slash.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .padding(2)
                                .background(Color.secondary, in: Circle())
                        }
                        if isFlagged {
                            Image(systemName: "flag.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .padding(2)
                                .background(Color.orange, in: Circle())
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let colorTag {
                        Circle()
                            .fill(colorTag.color)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(.white, lineWidth: 1))
                            .padding(2)
                            .help("\(colorTag.displayName) tag")
                    }
                }

            HStack(spacing: 6) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let aiCategory {
                    Label(aiCategory, systemImage: "sparkles")
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .help("AI category: \(aiCategory)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            typeColumn
                .frame(width: ListRowMetrics.typeWidth, alignment: .leading)

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
        // Only load a thumbnail when the row actually shows one; at the
        // smallest size we display a file-type icon and skip the work.
        .task(id: showsThumbnail ? "\(method.rawValue)@\(videoPosition.rawValue)@\(item.id.absoluteString)" : nil) {
            await loadThumbnail()
        }
        // Metadata (codec/dimensions) is only probed for video/image rows, and
        // an already-resolved value is read synchronously from the main-actor
        // cache below — so most rows never spawn a task here while scrolling.
        .task(id: metadataNeedsProbe ? item.id : nil) { await probeMetadata() }
        .onChange(of: item.id, initial: true) { _, _ in
            metadata = MediaMetadataCache.cached(for: item.url) ?? .empty
        }
    }

    /// True only for video/image rows whose metadata isn't cached yet, so the
    /// probe task is attached only when there is real work to do.
    private var metadataNeedsProbe: Bool {
        guard item.kind == .video || item.kind == .image else { return false }
        return MediaMetadataCache.cached(for: item.url) == nil
    }

    /// The Type column: the uppercased extension plus, for video and image
    /// files, the codec (video only) and pixel dimensions — all on one line so
    /// every row stays the same height.
    @ViewBuilder
    private var typeColumn: some View {
        Text(typeText)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.secondary)
    }

    /// Single-line type text: the extension, then codec (video only) and
    /// dimensions as they resolve, joined by " · ".
    private var typeText: String {
        var parts: [String] = [fileType.isEmpty ? "—" : fileType]
        if item.kind == .video, let codec = metadata.codec {
            parts.append(codec.uppercased())
        }
        if let size = metadata.pixelSize {
            parts.append(size.displayString)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if showsThumbnail {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.12))

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
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
        } else {
            // Smallest row size: a plain file-type icon, no thumbnail.
            Image(systemName: item.kind.fallbackSymbol)
                .font(.system(size: thumbSize * 0.6))
                .foregroundStyle(.secondary)
        }
    }

    private func dateString(_ date: Date) -> String {
        guard date != .distantPast else { return "—" }
        return Self.dateFormatter.string(from: date)
    }

    private func loadThumbnail() async {
        guard showsThumbnail else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let target = CGSize(width: thumbSize, height: thumbSize)
        if let result = await ThumbnailProvider.shared.thumbnail(
            for: item.url, size: target, scale: scale, method: method, videoPosition: videoPosition
        ) {
            image = result
        }
    }

    private func probeMetadata() async {
        guard item.kind == .video || item.kind == .image else { return }
        let result = await VideoMetadataProvider.shared.metadata(for: item.url, kind: item.kind)
        metadata = result
    }
}
