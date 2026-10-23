import SwiftUI

/// A right-hand sidebar showing a live preview of the currently selected item.
///
/// Mirrors `ItemInfoSidebar`'s toggle/placement pattern, but instead of
/// metadata it renders the actual media using the same per-kind renderers the
/// fullscreen viewer uses (zoomable image, video/audio player, PDF, text /
/// markdown, or a QuickLook fallback for anything else). It only previews a
/// single item — the primary selection — and shows a summary when the
/// selection is empty or holds more than one item.
///
/// Unlike the fixed-width info sidebar, this panel is resizable: a thin drag
/// handle on its leading edge adjusts `model.previewSidebarWidth` (persisted
/// and clamped by the model).
struct ItemPreviewSidebar: View {
    @Bindable var model: BrowserModel

    /// Width captured when a resize drag begins, so the drag delta is applied
    /// against a stable base rather than accumulating rounding error.
    @State private var dragStartWidth: Double?

    var body: some View {
        HStack(spacing: 0) {
            resizeHandle
            panel
        }
        .frame(width: CGFloat(model.previewSidebarWidth))
    }

    // MARK: Panel

    private var panel: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        .background(.bar)
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("Preview")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        let selected = model.selectedMediaItems
        if selected.count > 1 {
            multiSelection(count: selected.count)
        } else if let item = model.primarySelectedItem {
            // Keyed by item id so each new selection rebuilds its renderer
            // (and resets image zoom / reloads the player) instead of reusing
            // the previous item's view state.
            ItemPreviewContent(item: item)
                .id(item.id)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        placeholder(symbol: "sidebar.squares.right", text: "No selection")
    }

    private func multiSelection(count: Int) -> some View {
        placeholder(symbol: "square.stack.3d.up", text: "\(count) items selected")
    }

    private func placeholder(symbol: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Resize handle

    /// A thin, draggable strip on the sidebar's leading edge. Dragging it left
    /// grows the sidebar, right shrinks it; the model clamps the result to its
    /// min/max. A divider is drawn over it so it reads as the panel's edge.
    private var resizeHandle: some View {
        Divider()
            .frame(width: 6)
            .contentShape(Rectangle())
            .overlay(alignment: .center) {
                // Subtle grip affordance.
                Capsule()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 2, height: 26)
            }
            .background(.bar)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let base = dragStartWidth ?? model.previewSidebarWidth
                        if dragStartWidth == nil { dragStartWidth = base }
                        // Handle is on the leading edge: dragging left
                        // (negative translation) widens the panel.
                        model.previewSidebarWidth = base - Double(value.translation.width)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }
}

/// Renders a single item's live preview, choosing a renderer by kind — the
/// same switch the fullscreen viewer uses. Owns the per-item image zoom state
/// so an image preview can be zoomed/panned within the sidebar.
private struct ItemPreviewContent: View {
    let item: MediaItem

    @State private var zoomCommand: ZoomCommand?
    @State private var zoomFactor: CGFloat = 1

    var body: some View {
        Group {
            switch item.kind {
            case .image:
                ZoomableImageView(url: item.url, command: $zoomCommand, zoomFactor: $zoomFactor)
            case .video, .audio:
                VideoPlayerView(url: item.url)
            case .pdf:
                PDFViewerRepresentable(url: item.url)
            case .markdown:
                TextDocumentView(url: item.url, renderMarkdown: true)
            case .text:
                TextDocumentView(url: item.url, renderMarkdown: false)
            case .other:
                QuickLookView(url: item.url)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
