import SwiftUI

/// A single media cell: thumbnail image plus filename.
struct ThumbnailView: View {
    let item: MediaItem
    let size: Double
    let isSelected: Bool

    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))

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
                        .font(.system(size: size * 0.22))
                        .foregroundStyle(.white, .black.opacity(0.5))
                        .shadow(radius: 2)
                }
            }
            .frame(width: size, height: size)
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
