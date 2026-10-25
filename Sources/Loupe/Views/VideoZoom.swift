import SwiftUI
import AppKit

/// Live zoom/pan state for the video surface, shared between the player view
/// (which applies it) and the viewer (which drives it from the toolbar and
/// keyboard, and reads back the current factor to show "150%").
///
/// Unlike images — zoomed natively by `ZoomableImageView`'s `NSScrollView` —
/// the two video backends are heavyweight native surfaces (AVKit's player view
/// and an mpv GL view) that don't take kindly to being embedded in a
/// magnifying scroll view. So video zoom is a SwiftUI-level transform applied
/// to the whole surface: a `scaleEffect` plus a pan `offset`. That's backend
/// agnostic — it works identically whether AVFoundation or libmpv is decoding,
/// because it never touches either surface's internals.
///
/// `magnification` is relative to the fitted picture (1.0 == the normal
/// aspect-fit size), matching how the viewer labels image zoom.
@MainActor
final class VideoZoomState: ObservableObject {
    /// Scale relative to the fitted picture. 1.0 is "fit"; higher zooms in.
    @Published var magnification: CGFloat = 1
    /// Pan offset, in points, applied after scaling. Zero re-centers.
    @Published var offset: CGSize = .zero

    /// The viewport size the surface is laid out in, kept current by the
    /// container so pan can be clamped to the magnified content's bounds.
    var viewportSize: CGSize = .zero

    static let minMagnification: CGFloat = 1
    static let maxMagnification: CGFloat = 8
    private static let step: CGFloat = 1.25

    /// Whether the picture is zoomed past its fitted size (so pan/reset apply).
    var isZoomed: Bool { magnification > Self.minMagnification + 0.001 }

    func zoomIn() { setMagnification(magnification * Self.step) }
    func zoomOut() { setMagnification(magnification / Self.step) }

    /// Reset to the fitted picture, re-centered.
    func fit() {
        magnification = Self.minMagnification
        offset = .zero
    }

    /// Toggle between fit and 2×, used by a double-click.
    func toggleZoom() {
        if isZoomed { fit() } else { setMagnification(2) }
    }

    /// Clamp to the allowed range and, when returning to fit, re-center.
    func setMagnification(_ value: CGFloat) {
        let clamped = min(max(value, Self.minMagnification), Self.maxMagnification)
        magnification = clamped
        if !isZoomed {
            offset = .zero
        } else {
            offset = clampedOffset(offset)
        }
    }

    /// Pan by a drag delta, keeping the picture from being dragged off-screen.
    func pan(by delta: CGSize) {
        guard isZoomed else { return }
        offset = clampedOffset(CGSize(width: offset.width + delta.width,
                                      height: offset.height + delta.height))
    }

    /// Clamps a proposed offset so the magnified picture can't be panned past
    /// its own edges (the extra content on each axis is split between the two
    /// sides, so the max shift is half of it).
    private func clampedOffset(_ proposed: CGSize) -> CGSize {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return proposed }
        let extraX = viewportSize.width * (magnification - 1) / 2
        let extraY = viewportSize.height * (magnification - 1) / 2
        return CGSize(
            width: min(max(proposed.width, -extraX), extraX),
            height: min(max(proposed.height, -extraY), extraY))
    }
}

/// Wraps a video surface with zoom + pan driven by a `VideoZoomState`. Applies
/// the scale/offset transform, supports pinch-to-zoom and drag-to-pan (only
/// while zoomed, so a plain click still reaches the surface's play/pause), and
/// double-click to toggle fit/2×. Clipped so a zoomed picture doesn't spill
/// over the control bar or sidebars.
///
/// The transform is applied at the Core Animation layer level — on the backing
/// layer of a thin host `NSView` that the native player surface lives inside —
/// rather than with a SwiftUI `scaleEffect`/`offset` on an ancestor view.
/// Scaling an ancestor of a live `AVPlayerView` makes SwiftUI re-apply an
/// animated transform and re-clip the host each gesture tick; the actively
/// decoding video layer gets re-rasterized mid-frame and flickers. A direct
/// layer transform on the surface's own host is composited by Core Animation
/// without disturbing the video layer's frame production, so it stays smooth.
struct ZoomableVideoContainer<Content: View>: View {
    @ObservedObject var zoom: VideoZoomState
    @ViewBuilder var content: () -> Content

    @State private var dragStart: CGSize?

    var body: some View {
        GeometryReader { geo in
            LayerZoomHost(magnification: zoom.magnification, offset: zoom.offset) {
                content()
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(panGesture)
            .gesture(magnifyGesture)
            .onAppear { zoom.viewportSize = geo.size }
            .onChange(of: geo.size) { _, newSize in
                zoom.viewportSize = newSize
                // A viewport resize can leave a stale pan out of bounds.
                zoom.setMagnification(zoom.magnification)
            }
        }
    }

    /// Drag-to-pan, active only when zoomed so a plain click on a fitted video
    /// still falls through to the surface (play/pause). Tracks from the offset
    /// at gesture start so panning doesn't jump.
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard zoom.isZoomed else { return }
                if dragStart == nil { dragStart = zoom.offset }
                let base = dragStart ?? .zero
                zoom.offset = clamped(CGSize(
                    width: base.width + value.translation.width,
                    height: base.height + value.translation.height))
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Pinch-to-zoom on the trackpad. Scales from the magnification at gesture
    /// start so the zoom tracks the pinch smoothly.
    @State private var magnifyStart: CGFloat?
    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                let base = magnifyStart ?? zoom.magnification
                if magnifyStart == nil { magnifyStart = zoom.magnification }
                zoom.setMagnification(base * value.magnification)
            }
            .onEnded { _ in magnifyStart = nil }
    }

    /// Mirror of `VideoZoomState.clampedOffset`, inlined for the live drag so
    /// the picture can't be dragged off its own edges.
    private func clamped(_ proposed: CGSize) -> CGSize {
        let size = zoom.viewportSize
        guard size.width > 0, size.height > 0 else { return proposed }
        let extraX = size.width * (zoom.magnification - 1) / 2
        let extraY = size.height * (zoom.magnification - 1) / 2
        return CGSize(
            width: min(max(proposed.width, -extraX), extraX),
            height: min(max(proposed.height, -extraY), extraY))
    }
}

/// Hosts a SwiftUI view (the native player surface) inside a layer-backed
/// `NSView` and applies zoom/pan as a Core Animation transform on that host's
/// backing layer. Clipping is done with the layer's `masksToBounds`.
///
/// Doing the transform here — on the surface's own host layer — instead of via
/// a SwiftUI `scaleEffect` on an ancestor avoids the flicker you get when an
/// animated ancestor transform forces a live `AVPlayerView`'s video layer to
/// re-rasterize mid-frame. Core Animation composites the host layer's
/// transform without interrupting the video layer beneath it.
private struct LayerZoomHost<Content: View>: NSViewRepresentable {
    let magnification: CGFloat
    let offset: CGSize
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> ZoomHostView {
        let host = ZoomHostView()
        let hosting = NSHostingView(rootView: content())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        host.embed(hosting)
        context.coordinator.hosting = hosting
        host.apply(magnification: magnification, offset: offset)
        return host
    }

    func updateNSView(_ nsView: ZoomHostView, context: Context) {
        context.coordinator.hosting?.rootView = content()
        nsView.apply(magnification: magnification, offset: offset)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hosting: NSHostingView<Content>?
    }
}

/// Layer-backed container whose backing-layer transform is driven by the zoom
/// state. The hosted player surface fills it edge to edge; the transform scales
/// and pans about the view's center, and `masksToBounds` clips the overflow so
/// a zoomed picture never spills onto the control bar or sidebars.
final class ZoomHostView: NSView {
    override var isFlipped: Bool { true }

    /// The current zoom/pan, remembered so the transform can be rebuilt against
    /// fresh bounds on every resize (not just when the gesture changes it).
    private var magnification: CGFloat = 1
    private var panOffset: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    /// Keep the hosted surface filling the host; the transform (below) is what
    /// scales/pans it, so the hosted view itself always stays at full size.
    func embed(_ subview: NSView) {
        addSubview(subview)
        NSLayoutConstraint.activate([
            subview.leadingAnchor.constraint(equalTo: leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: trailingAnchor),
            subview.topAnchor.constraint(equalTo: topAnchor),
            subview.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Store the new zoom/pan and rebuild the transform against the current
    /// bounds. Called from `updateNSView` (gesture/toolbar changes).
    func apply(magnification: CGFloat, offset: CGSize) {
        self.magnification = magnification
        self.panOffset = offset
        applyTransform()
    }

    /// Build the scale+pan transform about the view's center.
    ///
    /// Crucially this leaves the backing layer's `anchorPoint` and `position`
    /// at the defaults AppKit manages for a layer-backed view. We previously
    /// set `anchorPoint = (0.5, 0.5)` so the scale would grow about the middle,
    /// but AppKit lays a layer-backed view's layer out assuming the default
    /// `(0, 0)` anchor: on a resize it writes a fresh `frame` computed for that
    /// anchor, so a `(0.5, 0.5)` anchor left the content shifted by half the
    /// size delta — the picture jumped into a corner (top-right) and, for a
    /// paused clip, stayed there until the next frame repainted.
    ///
    /// Instead we keep the default anchor and center the scale ourselves:
    /// translate to the center, scale, translate back, then apply the pan. The
    /// transform is recomputed from the live `bounds` here and in `layout()`,
    /// so a resize always re-centers correctly. Wrapped in a non-animated
    /// transaction so gesture ticks snap instead of CA interpolating.
    private func applyTransform() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let cx = bounds.midX
        let cy = bounds.midY
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, panOffset.width, panOffset.height, 0)
        t = CATransform3DTranslate(t, cx, cy, 0)
        t = CATransform3DScale(t, magnification, magnification, 1)
        t = CATransform3DTranslate(t, -cx, -cy, 0)
        layer.transform = t
        CATransaction.commit()
    }

    /// Rebuild the transform whenever the view is resized so the scale stays
    /// centered on the new bounds (and a fitted 1× video stays put instead of
    /// detaching to a corner).
    override func layout() {
        super.layout()
        applyTransform()
    }
}

/// The video-zoom toolbar shown in the viewer's top chrome for a single video:
/// zoom out / live "%" / zoom in, plus a Fit pill. Mirrors the single-image
/// viewer's `zoomControls` so the two media types feel the same. An
/// `@ObservedObject` so the percentage stays live as the picture scales.
struct VideoZoomControls: View {
    @ObservedObject var zoom: VideoZoomState

    var body: some View {
        HStack(spacing: 8) {
            zoomButton("minus.magnifyingglass", help: "Zoom out (⌘− or −)") {
                zoom.zoomOut()
            }

            Text("\(Int((zoom.magnification * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 56)

            zoomButton("plus.magnifyingglass", help: "Zoom in (⌘+ or +)") {
                zoom.zoomIn()
            }

            Divider().frame(height: 16).overlay(Color.white.opacity(0.2))

            Button {
                zoom.fit()
            } label: {
                Text("Fit")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.15), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Fit video to the view (⌘0 or Z)")
            .disabled(!zoom.isZoomed)
        }
    }

    private func zoomButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.white)
                .padding(6)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
