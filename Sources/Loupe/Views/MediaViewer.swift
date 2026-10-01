import SwiftUI
import AVKit
import PDFKit
import QuickLookUI

/// Full-item viewer presented over the grid. Supports image zoom/pan, video
/// playback, PDF scrolling, and a QuickLook fallback for everything else.
/// Arrow keys move between items; Escape / the close button dismisses.
struct MediaViewer: View {
    @Bindable var model: BrowserModel

    /// Pending zoom command and live zoom factor for the single-image viewer.
    @State private var zoomCommand: ZoomCommand?
    @State private var zoomFactor: CGFloat = 1

    /// The active video controller (when a single video/audio item is shown),
    /// so the spacebar can toggle playback.
    @State private var videoController: VideoController?

    private var showingSingleVideo: Bool {
        !isMulti && (items.first?.kind == .video || items.first?.kind == .audio)
    }

    /// The items to show: all selected items, falling back to the primary one.
    private var items: [MediaItem] {
        let selected = model.selectedMediaItems
        if selected.isEmpty, let one = model.selectedMediaItem { return [one] }
        return selected
    }

    private var isMulti: Bool { items.count > 1 }

    /// True when the single-item view is showing a zoomable image.
    private var showingSingleImage: Bool {
        !isMulti && items.first?.kind == .image
    }

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
                    // No `.id(...)` here: reusing the same underlying view across
                    // navigation lets the image swap + refit happen in one pass,
                    // avoiding the flash of recreating the NSView from scratch.
                    content(for: items[0])
                        .overlay(alignment: .leading) { navButton(symbol: "chevron.left", offset: -1) }
                        .overlay(alignment: .trailing) { navButton(symbol: "chevron.right", offset: 1) }
                        // Always start a freshly-opened image fitted — never
                        // inherit a previous zoom level.
                        .onAppear { zoomCommand = .fit }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { if showingSingleImage { zoomHotkeys } }

            // Caption bar below the media — the filename lives here so it can
            // never cover the image.
            captionBar
        }
        .background(Color.black.ignoresSafeArea())
        .focusable()
        .focusEffectDisabled()
        // Consume the spacebar so it never bubbles up to the window's hidden
        // shortcut buttons (which previously closed the viewer). For a single
        // video/audio item, Space toggles play/pause.
        .onKeyPress(.space) {
            if showingSingleVideo, let videoController {
                videoController.togglePlay()
            }
            return .handled
        }
        .onChange(of: items.first?.id) { _, _ in
            if !showingSingleVideo { videoController = nil }
        }
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
            ZoomableImageView(url: item.url, command: $zoomCommand, zoomFactor: $zoomFactor)
        case .video, .audio:
            VideoPlayerView(url: item.url) { controller in
                videoController = controller
            }
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

            if showingSingleImage {
                zoomControls
            } else if isMulti {
                Text("Grid")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.08))
    }

    /// Zoom toolbar for the single-image viewer: zoom out / level / zoom in,
    /// plus Fit and 100% buttons.
    private var zoomControls: some View {
        HStack(spacing: 8) {
            zoomButton("minus.magnifyingglass", command: .zoomOut, help: "Zoom out (⌘− or −)")

            Text("\(Int((zoomFactor * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 56)

            zoomButton("plus.magnifyingglass", command: .zoomIn, help: "Zoom in (⌘+ or +)")

            Divider().frame(height: 16).overlay(Color.white.opacity(0.2))

            pillButton("Fit", help: "Fit image to the view (⌘0 or F)") { zoomCommand = .fit }

            pillButton("100%", help: "Actual pixel size (⌘1 or 1)") { zoomCommand = .actualSize }
        }
    }

    /// Invisible buttons carrying the zoom keyboard shortcuts for the single
    /// image viewer. Both the macOS-standard ⌘-based shortcuts and the bare
    /// single-key alternates are provided. Kept out of `zoomControls` so each
    /// shortcut is registered exactly once even though some keys repeat.
    @ViewBuilder
    private var zoomHotkeys: some View {
        ZStack {
            // Zoom in: ⌘+, ⌘=, and bare = / +
            hotkey("=", [.command]) { zoomCommand = .zoomIn }
            hotkey("+", [.command]) { zoomCommand = .zoomIn }
            hotkey("=", []) { zoomCommand = .zoomIn }
            hotkey("+", []) { zoomCommand = .zoomIn }

            // Zoom out: ⌘- and bare -
            hotkey("-", [.command]) { zoomCommand = .zoomOut }
            hotkey("-", []) { zoomCommand = .zoomOut }

            // Fit: ⌘0 and bare F
            hotkey("0", [.command]) { zoomCommand = .fit }
            hotkey("f", []) { zoomCommand = .fit }

            // Actual size (100%): ⌘1 and bare 1
            hotkey("1", [.command]) { zoomCommand = .actualSize }
            hotkey("1", []) { zoomCommand = .actualSize }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func hotkey(_ key: KeyEquivalent, _ modifiers: EventModifiers, action: @escaping () -> Void) -> some View {
        Button(action: action) { EmptyView() }
            .keyboardShortcut(key, modifiers: modifiers)
    }

    /// A clearly-tappable pill button for the dark viewer toolbar.
    private func pillButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.white.opacity(0.15), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func zoomButton(_ symbol: String, command: ZoomCommand, help: String) -> some View {
        Button {
            zoomCommand = command
        } label: {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.white)
                .padding(6)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
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
            // Tie the cell's identity to the item so its per-cell zoom state is
            // reset when a grid position maps to a different image, rather than
            // inheriting the previous item's zoom.
            GridPreview(item: item)
                .id(item.id)
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

/// A preview used inside the multi-selection grid. Images are individually
/// zoomable/pannable (pinch or scroll-wheel to zoom, drag to pan); other kinds
/// use their native players/preview.
private struct GridPreview: View {
    let item: MediaItem

    // Per-cell zoom state so each image in the grid zooms independently.
    @State private var command: ZoomCommand?
    @State private var zoomFactor: CGFloat = 1

    var body: some View {
        switch item.kind {
        case .image:
            ZoomableImageView(url: item.url, command: $command, zoomFactor: $zoomFactor)
                .overlay(alignment: .bottomTrailing) { zoomBadge }
        case .video, .audio:
            VideoPlayerView(url: item.url)
        case .pdf:
            PDFViewerRepresentable(url: item.url)
        case .other:
            QuickLookView(url: item.url)
        }
    }

    /// Small live zoom readout / reset for a grid cell.
    private var zoomBadge: some View {
        Button {
            command = .fit
        } label: {
            Text("\(Int((zoomFactor * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Click to fit")
        .padding(6)
    }
}

// MARK: - Image

/// Scroll-to-zoom and drag-to-pan image view.
// MARK: - Video

// VideoPlayerView now lives in VideoPlayer.swift (controls sit below the video,
// not over it).

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
