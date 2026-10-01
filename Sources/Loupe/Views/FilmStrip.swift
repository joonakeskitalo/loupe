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

    /// The item currently being viewed (highlighted and scrolled to).
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
                            isCurrent: item.id == currentID
                        )
                        .id(item.id)
                        .onTapGesture {
                            model.selectOnly(item.id)
                        }
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
    let isCurrent: Bool

    @State private var image: NSImage?

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
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isCurrent ? Color.accentColor : Color.white.opacity(0.08),
                        lineWidth: isCurrent ? 2.5 : 1)
        )
        .opacity(isCurrent ? 1 : 0.65)
        .help(item.name)
        .task(id: thumbnailKey) {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let target = CGSize(width: size, height: size)
            image = await ThumbnailProvider.shared.thumbnail(for: item.url, size: target, scale: scale)
        }
    }

    /// Reload the thumbnail when either the item or the rendered size changes,
    /// so resizing the strip larger fetches a crisper image.
    private var thumbnailKey: String {
        "\(item.id.absoluteString)@\(Int(size.rounded()))"
    }
}
