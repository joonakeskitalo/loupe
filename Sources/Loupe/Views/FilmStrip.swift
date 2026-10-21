import SwiftUI

/// A horizontal strip of thumbnails shown beneath the single-item viewer.
/// Mirrors the full set of items currently on screen, highlights the one being
/// viewed, keeps it scrolled into view, and lets a click jump straight to any
/// item.
///
/// The strip is resizable: dragging the handle on its top edge changes its
/// height (persisted on the model), and the thumbnails scale to fill it.
struct FilmStrip: View {
    @Bindable var model: BrowserModel

    /// The items to represent — the same ordered set the grid shows.
    let items: [MediaItem]

    /// Every selected item (all are highlighted). Mirrors the grid's
    /// multi-selection so the strip and grid stay in sync.
    let selectedIDs: Set<MediaItem.ID>

    /// The primary/anchor item — the one scrolled into view and drawn with the
    /// strongest highlight.
    let currentID: MediaItem.ID?

    private let spacing: CGFloat = 6
    private let verticalPadding: CGFloat = 8

    /// Thumbnail edge derived from the strip height, leaving room for padding.
    private var thumbnailSize: CGFloat {
        max(32, model.filmStripHeight - verticalPadding * 2)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: spacing) {
                    ForEach(items) { item in
                        FilmStripCell(
                            item: item,
                            size: thumbnailSize,
                            isSelected: selectedIDs.contains(item.id),
                            isCurrent: item.id == currentID,
                            isFlagged: model.isFlagged(item.id),
                            isHidden: model.isHidden(item.id),
                            colorTag: model.colorTag(item.id),
                            textTags: model.textTags(item.id),
                            method: model.thumbnailMethod,
                            videoPosition: model.videoThumbnailPosition
                        )
                        .id(item.id)
                        // Match the grid's click conventions: plain click
                        // selects one, Command toggles, Shift extends a range.
                        // Double-click isn't needed here — the viewer is
                        // already open — so it collapses to a single select.
                        .onClick(
                            single: { mods in
                                if mods.command {
                                    model.toggleSelection(item.id)
                                } else if mods.shift {
                                    model.extendSelection(to: item.id)
                                } else {
                                    model.selectOnly(item.id)
                                }
                            },
                            double: { _ in model.selectOnly(item.id) },
                            dragURLs: { dragURLs(for: item) },
                            isSelected: { selectedIDs.contains(item.id) }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, verticalPadding)
            }
            .frame(height: model.filmStripHeight)
            .background(Color(white: 0.08))
            .overlay(alignment: .top) { resizeHandle }
            .onChange(of: currentID) { _, newValue in
                scrollTo(newValue, in: proxy)
            }
            .onAppear {
                // Jump (no animation) so the viewed item is already centered
                // when the strip first appears.
                if let currentID {
                    proxy.scrollTo(currentID, anchor: .center)
                }
            }
        }
    }

    /// A thin grab handle along the top edge. Dragging it up grows the strip,
    /// down shrinks it. The model clamps the height to its allowed range.
    private var resizeHandle: some View {
        ZStack {
            Color.white.opacity(0.001) // widen the hit area without a visible fill
            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 40, height: 4)
        }
        .frame(height: 12)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Dragging up (negative translation) increases height.
                    model.filmStripHeight -= value.translation.height
                }
        )
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .help("Drag to resize the film strip")
    }

    /// File URLs to drag out: the whole selection if the item is part of it,
    /// otherwise just that item. Mirrors the grid so a drag from either place
    /// behaves identically.
    private func dragURLs(for item: MediaItem) -> [URL] {
        if selectedIDs.contains(item.id) {
            return items.filter { selectedIDs.contains($0.id) }.map(\.url)
        }
        return [item.url]
    }

    private func scrollTo(_ id: MediaItem.ID?, in proxy: ScrollViewProxy) {
        guard let id else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

/// One thumbnail in the film strip. Reuses `ThumbnailProvider` so cells share
/// the same cached images as the grid.
private struct FilmStripCell: View {
    let item: MediaItem
    let size: CGFloat
    /// Part of the current multi-selection.
    let isSelected: Bool
    /// The primary/anchor item within the selection.
    let isCurrent: Bool
    /// Whether this item is flagged (shows a flag badge, like the grid).
    var isFlagged: Bool = false
    /// Whether this item is hidden (shows an eye.slash badge next to the flag).
    var isHidden: Bool = false
    /// The item's color tag, if any (shown opposite the flag badge).
    var colorTag: ColorTag? = nil
    /// Free-text tags assigned to the item (shows a tag badge, like the grid).
    var textTags: [String] = []
    /// The window's active thumbnail-generation method.
    var method: ThumbnailMethod = .hybrid
    /// Where in a video its thumbnail frame is taken (the window's setting).
    var videoPosition: VideoThumbnailPosition = .defaultPosition

    @State private var image: NSImage?

    /// Border color: strongest for the primary item, accent for other selected
    /// items, faint otherwise.
    private var borderColor: Color {
        if isCurrent || isSelected { return .accentColor }
        return .white.opacity(0.08)
    }

    private var borderWidth: CGFloat {
        if isCurrent { return 3 }
        if isSelected { return 2 }
        return 1
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.16))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(2)
            } else {
                Image(systemName: item.kind.fallbackSymbol)
                    .font(.system(size: size * 0.3))
                    .foregroundStyle(.white.opacity(0.5))
            }

            if item.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: size * 0.26))
                    .foregroundStyle(.white, .black.opacity(0.5))
                    .shadow(radius: 1)
            }
        }
        .frame(width: size, height: size)
        // Dim only the thumbnail content for unselected items; the flag badge
        // and border overlays below stay at full opacity so a flag is always
        // clearly visible.
        .opacity(isCurrent || isSelected ? 1 : 0.65)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: max(2, size * 0.03)) {
                if isHidden {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: max(8, size * 0.16)))
                        .foregroundStyle(.white)
                        .padding(max(2, size * 0.05))
                        .background(Color.secondary, in: Circle())
                        .shadow(radius: 1)
                }
                if isFlagged {
                    Image(systemName: "flag.fill")
                        .font(.system(size: max(8, size * 0.16)))
                        .foregroundStyle(.white)
                        .padding(max(2, size * 0.05))
                        .background(Color.orange, in: Circle())
                        .shadow(radius: 1)
                }
                if !textTags.isEmpty {
                    Image(systemName: "tag.fill")
                        .font(.system(size: max(8, size * 0.16)))
                        .foregroundStyle(.white)
                        .padding(max(2, size * 0.05))
                        .background(Color.accentColor, in: Circle())
                        .shadow(radius: 1)
                        .help(textTags.joined(separator: ", "))
                }
            }
            .padding(3)
        }
        .overlay(alignment: .topLeading) {
            if let colorTag {
                Circle()
                    .fill(colorTag.color)
                    .frame(width: max(6, size * 0.1), height: max(6, size * 0.1))
                    .overlay(Circle().stroke(.white, lineWidth: 1))
                    .shadow(radius: 1)
                    .padding(3)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .help(item.name)
        .task(id: thumbnailKey) {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let target = CGSize(width: size, height: size)
            image = await ThumbnailProvider.shared.thumbnail(
                for: item.url, size: target, scale: scale, method: method, videoPosition: videoPosition
            )
        }
    }

    /// Reload the thumbnail when the item, the rendered size, or either of the
    /// active generation options changes, so resizing the strip larger fetches
    /// a crisper image and switching method/position re-renders.
    private var thumbnailKey: String {
        "\(method.rawValue)@\(videoPosition.rawValue)@\(item.id.absoluteString)@\(Int(size.rounded()))"
    }
}
