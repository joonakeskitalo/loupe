import SwiftUI
import AVKit
import PDFKit
import QuickLookUI

/// Full-item viewer presented over the grid. Supports image zoom/pan, video
/// playback, PDF scrolling, and a QuickLook fallback for everything else.
/// Arrow keys move between items; Escape / the close button dismisses.
struct MediaViewer: View {
    @Bindable var model: BrowserModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let item = model.selectedMediaItem {
                content(for: item)
                    .id(item.id)
            } else {
                Text("No selection")
                    .foregroundStyle(.secondary)
            }

            VStack {
                toolbar
                Spacer()
                if let item = model.selectedMediaItem {
                    Text(item.name)
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.bottom, 16)
                }
            }
        }
        .overlay(alignment: .leading) { navButton(symbol: "chevron.left", offset: -1) }
        .overlay(alignment: .trailing) { navButton(symbol: "chevron.right", offset: 1) }
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
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close viewer (Esc)")

            Spacer()
        }
        .padding(16)
    }

    private func navButton(symbol: String, offset: Int) -> some View {
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
