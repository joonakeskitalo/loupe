import SwiftUI

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
struct ZoomableVideoContainer<Content: View>: View {
    @ObservedObject var zoom: VideoZoomState
    @ViewBuilder var content: () -> Content

    @State private var dragStart: CGSize?

    var body: some View {
        GeometryReader { geo in
            content()
                .scaleEffect(zoom.magnification)
                .offset(zoom.offset)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
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
