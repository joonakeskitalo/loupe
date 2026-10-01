import SwiftUI
import AVKit
import PDFKit
import QuickLookUI

/// Full-item viewer presented over the grid. Supports image zoom/pan, video
/// playback, PDF scrolling, and a QuickLook fallback for everything else.
/// Arrow keys move between items; Escape / the close button dismisses.
struct MediaViewer: View {
    @Bindable var model: BrowserModel

    /// The items to show: all selected items, falling back to the primary one.
    private var items: [MediaItem] {
        let selected = model.selectedMediaItems
        if selected.isEmpty, let one = model.selectedMediaItem { return [one] }
        return selected
    }

    private var isMulti: Bool { items.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            // Top chrome bar (close button) — separated from the media so it
            // never overlaps content.
            toolbar

            // Media area.
            ZStack {
                Color.black
                if items.isEmpty {
                    Text("No selection").foregroundStyle(.secondary)
                } else if isMulti {
                    MultiGrid(items: items)
                } else {
                    content(for: items[0])
                        .id(items[0].id)
                        .overlay(alignment: .leading) { navButton(symbol: "chevron.left", offset: -1) }
                        .overlay(alignment: .trailing) { navButton(symbol: "chevron.right", offset: 1) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Caption bar below the media — the filename lives here so it can
            // never cover the image.
            captionBar
        }
        .background(Color.black.ignoresSafeArea())
    }

    @ViewBuilder
    private var captionBar: some View {
        HStack {
            if isMulti {
                Text("\(items.count) items selected")
            } else if let item = items.first {
                Image(systemName: item.kind.fallbackSymbol)
                Text(item.name).fontWeight(.medium)
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.white)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.08))
    }

    @ViewBuilder
    private func content(for item: MediaItem) -> some View {
        switch item.kind {
        case .image:
            ZoomableImageView(url: item.url)
        case .video, .audio:
            VideoPlayerView(url: item.url)
        case .pdf:
            PDFViewerRepresentable(url: item.url)
        case .other:
            QuickLookView(url: item.url)
        }
    }

    private var toolbar: some View {
        HStack {
            Button {
                model.isViewerPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close viewer (Esc)")

            Spacer()

            if isMulti {
                Text("Grid")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.08))
    }

    @ViewBuilder
    private func navButton(symbol: String, offset: Int) -> some View {
        // Only meaningful when viewing a single item; stepping walks the whole
        // displayed set.
        Button {
            model.moveSelection(by: offset)
        } label: {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.white)
                .padding(14)
                .background(.black.opacity(0.4), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .keyboardShortcut(offset < 0 ? .leftArrow : .rightArrow, modifiers: [])
    }
}

// MARK: - Multi-selection grid

/// A grid of previews shown when multiple items are selected. The grid picks
/// the row/column split that makes each cell as large as possible for the
/// available space, filling the viewport instead of scrolling.
private struct MultiGrid: View {
    let items: [MediaItem]

    private let gap: CGFloat = 12
    private let outerPadding: CGFloat = 16
    private let captionHeight: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let layout = bestLayout(
                count: items.count,
                in: CGSize(
                    width: max(1, geo.size.width - outerPadding * 2),
                    height: max(1, geo.size.height - outerPadding * 2)
                )
            )
            VStack(spacing: gap) {
                ForEach(0..<layout.rows, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<layout.cols, id: \.self) { col in
                            let index = row * layout.cols + col
                            if index < items.count {
                                cell(items[index])
                            } else {
                                // Keep the grid shape with empty slots.
                                Color.clear
                            }
                        }
                    }
                }
            }
            .padding(outerPadding)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func cell(_ item: MediaItem) -> some View {
        VStack(spacing: 4) {
            GridPreview(item: item)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(item.name)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: captionHeight)
        }
    }

    /// Chooses the (rows, cols) split that maximizes the area of each cell,
    /// accounting for gaps and the per-cell caption height.
    private func bestLayout(count: Int, in size: CGSize) -> (rows: Int, cols: Int) {
        guard count > 1 else { return (1, max(1, count)) }

        var best = (rows: 1, cols: count)
        var bestArea: CGFloat = 0

        for cols in 1...count {
            let rows = Int(ceil(Double(count) / Double(cols)))
            let cellW = (size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let cellH = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows) - captionHeight
            guard cellW > 0, cellH > 0 else { continue }
            let area = cellW * cellH
            if area > bestArea {
                bestArea = area
                best = (rows, cols)
            }
        }
        return best
    }
}

/// A compact, non-interactive preview used inside the multi-selection grid.
private struct GridPreview: View {
    let item: MediaItem

    var body: some View {
        switch item.kind {
        case .image:
            if let image = NSImage(contentsOf: item.url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            } else {
                fallback
            }
        case .video, .audio:
            VideoPlayerView(url: item.url)
        case .pdf:
            PDFViewerRepresentable(url: item.url)
        case .other:
            QuickLookView(url: item.url)
        }
    }

    private var fallback: some View {
        Image(systemName: item.kind.fallbackSymbol)
            .font(.system(size: 48))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Image

/// Scroll-to-zoom and drag-to-pan image view.
private struct ZoomableImageView: View {
    let url: URL
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            if let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = max(1, value)
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard scale > 1 else { return }
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in lastOffset = offset }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring) {
                            if scale > 1 {
                                scale = 1; offset = .zero; lastOffset = .zero
                            } else {
                                scale = 2
                            }
                        }
                    }
            } else {
                Text("Unable to load image")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Video

private struct VideoPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = AVPlayer(url: url)
        view.player?.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if (nsView.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            nsView.player?.pause()
            nsView.player = AVPlayer(url: url)
            nsView.player?.play()
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
    }
}

// MARK: - PDF

private struct PDFViewerRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        view.backgroundColor = .black
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}

// MARK: - QuickLook fallback

private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.previewItem = url as QLPreviewItem
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if (nsView.previewItem as? URL) != url {
            nsView.previewItem = url as QLPreviewItem
        }
    }
}
