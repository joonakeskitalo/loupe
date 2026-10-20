import SwiftUI

/// A single media cell: thumbnail image plus filename.
struct ThumbnailView: View {
    let item: MediaItem
    let size: Double
    let isSelected: Bool
    var isFlagged: Bool = false
    /// Whether this item is hidden (shows a dimmed eye.slash badge, next to the
    /// flag badge). Only ever visible in the "Hidden" Library view, since hidden
    /// items are filtered out of every other view.
    var isHidden: Bool = false
    /// The item's color tag, if any (shows a colored swatch in the top-leading
    /// corner, opposite the flag badge).
    var colorTag: ColorTag? = nil
    /// The AI-assigned category, if the image has been classified. Shown as a
    /// small caption pill in the bottom-leading corner.
    var aiCategory: String? = nil
    /// Number of recognized people in the image (0 = none / not processed).
    /// Shown as a small person badge in the bottom-trailing corner.
    var personCount: Int = 0
    /// When true, the filename caption under the thumbnail is hidden.
    var hideFilename: Bool = false
    /// How this cell's thumbnail is generated (the window's current method).
    var method: ThumbnailMethod = .hybrid
    /// Where in a video its thumbnail frame is taken (the window's setting).
    var videoPosition: VideoThumbnailPosition = .defaultPosition

    @State private var image: NSImage?
    @State private var didFail = false

    /// Padding around each cell. Tighter than before for a denser grid, and
    /// tighter still when filenames are hidden (there's no caption to breathe
    /// around).
    private var gridItemPadding: CGFloat { hideFilename ? 0 : 4 }

    var body: some View {
        VStack(spacing: hideFilename ? 0 : 3) {
            ZStack {
                // Grey backing fill behind the thumbnail. Dropped when
                // filenames are hidden so images sit flush with no grey box.
                RoundedRectangle(cornerRadius: 6)
                    .fill(hideFilename ? Color.clear : Color.secondary.opacity(0.03))

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else {
                    Image(systemName: item.kind.fallbackSymbol)
                        .font(.system(size: size * 0.28))
                        .foregroundStyle(.secondary)
                }

                if item.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: size * 0.13))
                        .foregroundStyle(.white.opacity(0.6), .black.opacity(0.25))
                        .shadow(radius: 1)
                }
            }
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 3) {
                    if isHidden {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: max(8, size * 0.09)))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Color.secondary, in: Circle())
                            .shadow(radius: 1)
                    }
                    if isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.system(size: max(8, size * 0.09)))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Color.orange, in: Circle())
                            .shadow(radius: 1)
                    }
                }
                .padding(5)
            }
            .overlay(alignment: .topLeading) {
                if let colorTag {
                    Circle()
                        .fill(colorTag.color)
                        .frame(width: max(8, size * 0.08), height: max(8, size * 0.08))
                        .overlay(Circle().stroke(.white, lineWidth: 1))
                        .shadow(radius: 1)
                        .padding(6)
                        .help("\(colorTag.displayName) tag")
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let aiCategory, size >= 110 {
                    // Solid dark fill (not a translucent material) with white
                    // text and a soft shadow so the label stays legible over
                    // any image, light or dark — the same high-contrast
                    // approach as the flag badge.
                    Label(aiCategory, systemImage: "sparkles")
                        .font(.system(size: max(9, size * 0.07), weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .padding(6)
                        .help("AI category: \(aiCategory)")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if personCount > 0, size >= 110 {
                    // People badge: a person glyph plus a count when more than
                    // one. Solid dark fill + shadow so it reads over any image.
                    HStack(spacing: 2) {
                        Image(systemName: "person.fill")
                        if personCount > 1 { Text("\(personCount)") }
                    }
                    .font(.system(size: max(9, size * 0.07), weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.6), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .padding(6)
                    .help(personCount == 1 ? "1 person" : "\(personCount) people")
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )

            if !hideFilename {
                Text(item.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: size)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            }
        }
        .padding(gridItemPadding)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        // Re-run when the item OR the thumbnail method changes, so switching
        // method (e.g. to fix black .mp4 thumbnails) refreshes visible cells
        // instead of leaving the old image until the next scroll.
        .task(id: ThumbnailRequestKey(id: item.id, method: method, videoPosition: videoPosition)) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let target = CGSize(width: size, height: size)
        // This cell is on (or very near) screen, so it's visible-priority: it
        // jumps ahead of any prefetch work the grid queued for the viewport
        // edges. Re-requesting an already-queued prefetch here promotes it.
        let result = await ThumbnailProvider.shared.thumbnail(
            for: item.url,
            size: target,
            scale: scale,
            method: method,
            videoPosition: videoPosition,
            priority: .visible
        )
        if let result {
            image = result
        } else {
            didFail = true
        }
    }
}

/// Identity for a cell's thumbnail request, so `.task(id:)` restarts the load
/// whenever either the item or the active generation method changes.
private struct ThumbnailRequestKey: Hashable {
    let id: MediaItem.ID
    let method: ThumbnailMethod
    let videoPosition: VideoThumbnailPosition
}
