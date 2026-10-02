import SwiftUI

/// A single media cell: thumbnail image plus filename.
struct ThumbnailView: View {
    let item: MediaItem
    let size: Double
    let isSelected: Bool
    var isFlagged: Bool = false
    /// The item's color tag, if any (shows a colored swatch in the top-leading
    /// corner, opposite the flag badge).
    var colorTag: ColorTag? = nil
    /// When true, the filename caption under the thumbnail is hidden.
    var hideFilename: Bool = false

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
                if isFlagged {
                    Image(systemName: "flag.fill")
                        .font(.system(size: max(11, size * 0.13)))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Color.orange, in: Circle())
                        .shadow(radius: 2)
                        .padding(6)
                }
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
        .task(id: item.id) {
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
            priority: .visible
        )
        if let result {
            image = result
        } else {
            didFail = true
        }
    }
}
