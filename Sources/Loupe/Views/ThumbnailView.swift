import SwiftUI

/// A single media cell: thumbnail image plus filename.
struct ThumbnailView: View {
    let item: MediaItem
    let size: Double
    let isSelected: Bool
    var isFlagged: Bool = false

    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.03))

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
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )

            Text(item.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: size)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .padding(6)
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
        let result = await ThumbnailProvider.shared.thumbnail(for: item.url, size: target, scale: scale)
        if let result {
            image = result
        } else {
            didFail = true
        }
    }
}
