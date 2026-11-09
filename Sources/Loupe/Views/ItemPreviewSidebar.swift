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
/// handle on its leading edge adjusts `model.previewSidebarWidth` (clamped by
/// the model). The width is session- and window-scoped only — it isn't
/// persisted across windows or launches.
struct ItemPreviewSidebar: View {
    @Bindable var model: BrowserModel

    /// The live width while a resize drag is in flight. Driving the frame off
    /// local state (not the model) keeps dragging smooth: it avoids the model's
    /// per-tick `UserDefaults` write and the observation churn that re-rendered
    /// the whole sidebar (including the live preview) on every delta. The
    /// committed width lands back on the model only when the drag ends.
    @State private var dragWidth: Double?

    /// Width captured when a resize drag begins, so the delta is applied
    /// against a stable base rather than accumulating rounding error.
    @State private var dragStartWidth: Double?
    @State private var handleHovered = false

    /// The width the panel should render at right now.
    private var effectiveWidth: Double { dragWidth ?? model.previewSidebarWidth }

    /// True while a resize drag is in flight. During the drag the live preview
    /// is swapped for a static placeholder so the expensive media renderers
    /// (`NSViewRepresentable`s that re-layout/refit on every size change) don't
    /// run once per drag tick — that layout work was the source of the stutter.
    private var isResizing: Bool { dragWidth != nil }

    private var isBottom: Bool { model.previewPlacement == .bottom }

    /// The height the panel should render at right now (bottom placement).
    private var effectiveHeight: Double { dragWidth ?? model.previewSidebarHeight }

    var body: some View {
        if isBottom {
            VStack(spacing: 0) {
                resizeHandle
                panel
            }
            .frame(height: CGFloat(effectiveHeight))
        } else {
            HStack(spacing: 0) {
                resizeHandle
                panel
            }
            .frame(width: CGFloat(effectiveWidth))
        }
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
        // Force a light background (and matching light color scheme) regardless
        // of the system appearance, so the preview reads on a bright panel.
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("Preview")
                .font(.headline)
            Spacer()
            Button {
                model.togglePreviewPlacement()
            } label: {
                Image(systemName: isBottom ? "rectangle.righthalf.inset.filled"
                                           : "rectangle.bottomhalf.inset.filled")
            }
            .buttonStyle(.borderless)
            .help(isBottom ? "Move preview to the side" : "Move preview below the grid")
            .accessibilityLabel(isBottom ? "Move preview to the side" : "Move preview below the grid")
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
            if isResizing && !keepsRendererWhileResizing(item.kind) {
                // Cheap stand-in during the drag: no media renderer, so the
                // panel resizes at a steady frame rate. The real preview comes
                // back (once) when the drag ends. Only used for the heavy
                // representables (image zoom refit, PDF, QuickLook) — a
                // playing video/audio preview is exempt (see below), because
                // swapping it out tears the player down and would restart it
                // from the beginning when the drag ends.
                placeholder(symbol: item.kind.fallbackSymbol, text: item.name)
            } else {
                // Keyed by item id so each new selection rebuilds its renderer
                // (and resets image zoom / reloads the player) instead of
                // reusing the previous item's view state. `isViewerActive`
                // pauses a playing video preview while the fullscreen viewer is
                // up, so two players don't play the same clip at once.
                ItemPreviewContent(model: model, item: item,
                                   isViewerActive: model.isViewerPresented)
                    .id(item.id)
            }
        } else {
            emptyState
        }
    }

    /// Kinds whose renderer stays mounted through a resize drag rather than
    /// being swapped for the static placeholder. Video and audio run a live
    /// player whose view owns the playback position; tearing it out mid-resize
    /// and rebuilding it when the drag ends reloads the asset and restarts from
    /// the beginning — exactly the reset we want to avoid. An AVPlayerView / mpv
    /// surface resizes cheaply on its own, so keeping it mounted costs nothing
    /// the way refitting an image/PDF does. Every other kind keeps using the
    /// placeholder to stay smooth under a drag.
    private func keepsRendererWhileResizing(_ kind: MediaKind) -> Bool {
        kind == .video || kind == .audio
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
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Resize handle

    /// A thin, draggable strip on the sidebar's leading edge. Dragging it left
    /// grows the sidebar, right shrinks it; the model clamps the result to its
    /// min/max. A divider is drawn over it so it reads as the panel's edge.
    private var resizeHandle: some View {
        Divider()
            .frame(width: isBottom ? nil : 8, height: isBottom ? 8 : nil)
            .overlay(alignment: .center) {
                // Subtle grip affordance.
                Capsule()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: isBottom ? 26 : 2, height: isBottom ? 2 : 26)
            }
            .background(.bar)
            // The real hit target is wider than the visible strip. One AppKit
            // view owns the cursor (via a cursor rect), the hover state and the
            // drag, so the cursor and highlight always cover the same area.
            .overlay {
                ZStack {
                    Rectangle()
                        .fill(handleHovered || isResizing ? Color.accentColor.opacity(0.25) : Color.clear)
                    ResizeHitArea(
                        vertical: isBottom,
                        onHover: { handleHovered = $0 },
                        onBegan: beginResize,
                        onChanged: updateResize,
                        onEnded: endResize
                    )
                }
                .frame(width: isBottom ? nil : Self.handleHitWidth,
                       height: isBottom ? Self.handleHitWidth : nil)
            }
            // Sit above the neighbouring panel/grid so the wide hit area wins.
            .zIndex(1)
    }

    private static let handleHitWidth: CGFloat = 4
    
    private func beginResize() {
        dragStartWidth = isBottom ? model.previewSidebarHeight : model.previewSidebarWidth
        // Tell the grid a resize started so it freezes its column layout
        // (see `isResizingPreviewSidebar`).
        model.isResizingPreviewSidebar = true
    }

    /// `delta` is the pointer's leftward displacement since the drag began, in
    /// window space, which tracks the cursor exactly even as the handle moves.
    /// Moving left widens the panel (it is pinned to the trailing edge).
    private func updateResize(_ delta: CGFloat) {
        if isBottom {
            let base = dragStartWidth ?? model.previewSidebarHeight
            dragWidth = min(max(base + Double(delta), BrowserModel.minPreviewSidebarHeight),
                            BrowserModel.maxPreviewSidebarHeight)
        } else {
            let base = dragStartWidth ?? model.previewSidebarWidth
            dragWidth = min(max(base + Double(delta), BrowserModel.minPreviewSidebarWidth),
                            BrowserModel.maxPreviewSidebarWidth)
        }
    }

    private func endResize() {
        // Commit the final width once (session-scoped), then drop the live
        // override so the grid reflows in a single pass.
        if let dragWidth {
            if isBottom { model.previewSidebarHeight = dragWidth }
            else { model.previewSidebarWidth = dragWidth }
        }
        dragWidth = nil
        dragStartWidth = nil
        model.isResizingPreviewSidebar = false
    }
}

/// Transparent AppKit view covering the resize grab zone. Cursor rects keep the
/// resize cursor exactly in sync with the view's bounds, and it reports hover
/// and drag itself so no SwiftUI gesture has to compete with the media views.
struct ResizeHitArea: NSViewRepresentable {
    /// True for a horizontal strip dragged up/down (bottom placement).
    var vertical = false
    var onHover: (Bool) -> Void
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: () -> Void

    func makeNSView(context: Context) -> HitView { HitView() }

    func updateNSView(_ view: HitView, context: Context) {
        if view.vertical != vertical {
            view.vertical = vertical
            view.window?.invalidateCursorRects(for: view)
        }
        view.onHover = onHover
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
    }

    final class HitView: NSView {
        var onHover: (Bool) -> Void = { _ in }
        var onBegan: () -> Void = {}
        var onChanged: (CGFloat) -> Void = { _ in }
        var onEnded: () -> Void = {}
        var vertical = false
        private var startX: CGFloat = 0
        private var dragging = false

        private var cursor: NSCursor { vertical ? .resizeUpDown : .resizeLeftRight }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            // Horizontal: window x. Vertical: window y (origin bottom-left, so
            // moving the pointer up increases y and should grow the panel).
            startX = vertical ? -event.locationInWindow.y : event.locationInWindow.x
            dragging = true
            onBegan()
        }

        override func mouseDragged(with event: NSEvent) {
            guard dragging else { return }
            // Keep the resize cursor even if the pointer outruns the strip.
            cursor.set()
            let current = vertical ? -event.locationInWindow.y : event.locationInWindow.x
            onChanged(startX - current)
        }

        override func mouseUp(with event: NSEvent) {
            guard dragging else { return }
            dragging = false
            onEnded()
            // Re-evaluate hover now that the drag is over.
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            onHover(inside)
        }
    }
}

/// Renders a single item's live preview, choosing a renderer by kind — the
/// same switch the fullscreen viewer uses. Owns the per-item image zoom state
/// so an image preview can be zoomed/panned within the sidebar.
private struct ItemPreviewContent: View {
    var model: BrowserModel
    let item: MediaItem
    /// True while the fullscreen viewer is open. The preview pauses its video
    /// playback for the duration so the sidebar and the viewer don't both play
    /// the same clip (doubled audio, wasted decode).
    var isViewerActive: Bool

    @State private var zoomCommand: ZoomCommand?
    @State private var zoomFactor: CGFloat = 1

    /// The preview's video backend, captured so we can pause/resume it when the
    /// viewer opens and closes, and so the grid's O / U seek can reach it via
    /// the model. Nil for non-video items.
    @State private var playback: (any PlaybackController)?

    /// Light backing so an image/PDF that doesn't fill the panel letterboxes
    /// onto a bright background instead of the renderers' default black.
    private let previewBackground = NSColor.white

    var body: some View {
        Group {
            switch item.kind {
            case .image:
                ZoomableImageView(url: item.url, command: $zoomCommand,
                                  zoomFactor: $zoomFactor, backgroundColor: previewBackground)
            case .video, .audio:
                VideoPlayerView(url: item.url) { controller in
                    playback = controller
                    // Register with the model so the grid's O / U seek can
                    // drive this player while the preview is showing.
                    model.previewPlaybackController = controller
                    // If the viewer is already up when the player mounts (e.g.
                    // selection changed while the viewer is open), start paused.
                    if isViewerActive { controller.pause() }
                }
            case .pdf:
                PDFViewerRepresentable(url: item.url, backgroundColor: previewBackground)
            case .markdown:
                TextDocumentView(url: item.url, renderMarkdown: true)
            case .text:
                TextDocumentView(url: item.url, renderMarkdown: false)
            case .other:
                QuickLookView(url: item.url)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .white))
        // Pause the preview when the viewer takes over; resume when it closes.
        .onChange(of: isViewerActive) { _, active in
            if active { playback?.pause() } else { playback?.play() }
        }
        // Drop the model's seek channel when this preview is torn down (the
        // selection changed to a non-video, or the sidebar closed), so a stale
        // controller for a gone item isn't driven by O / U. Only clear it if it
        // still points at this preview's player.
        .onDisappear {
            if model.previewPlaybackController === playback {
                model.previewPlaybackController = nil
            }
        }
    }
}
