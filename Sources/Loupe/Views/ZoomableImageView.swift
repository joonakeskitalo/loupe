import SwiftUI
import AppKit

/// A one-shot zoom command sent from the toolbar to the image view.
enum ZoomCommand: Equatable {
    case fit
    case actualSize   // 100% (1 image pixel == 1 point)
    case zoomIn
    case zoomOut
}

/// An AppKit-backed zoomable, pannable image view.
///
/// Backed by `NSScrollView` + a centering clip view + `NSImageView`, so we get
/// real magnification, native trackpad/scroll-wheel panning, an accurate zoom
/// factor (1.0 == one image pixel per point), and the image stays centered when
/// it is smaller than the viewport. The parent drives Fit / 100% / zoom through
/// `command` and reads the live zoom back via `zoomFactor`.
struct ZoomableImageView: NSViewRepresentable {
    let url: URL
    @Binding var command: ZoomCommand?
    @Binding var zoomFactor: CGFloat
    /// Optional previous/next handlers invoked on a trackpad swipe or clear
    /// horizontal scroll while the image is fitted (not zoomed in).
    var onSwipePrevious: (() -> Void)?
    var onSwipeNext: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomFactor: $zoomFactor)
    }

    func makeNSView(context: Context) -> ZoomScrollView {
        let scrollView = ZoomScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 40
        scrollView.backgroundColor = .black
        scrollView.drawsBackground = true

        // Centering clip view keeps a small image centered in the viewport.
        let clip = CenteringClipView()
        clip.drawsBackground = true
        clip.backgroundColor = .black
        scrollView.contentView = clip
        clip.postsBoundsChangedNotifications = true

        let imageView = NSImageView()
        imageView.imageScaling = .scaleAxesIndependently
        imageView.image = NSImage(contentsOf: url)
        scrollView.documentView = imageView
        scrollView.imageView = imageView

        context.coordinator.scrollView = scrollView
        context.coordinator.url = url
        context.coordinator.observe(scrollView)

        scrollView.onDoubleClick = { [weak coordinator = context.coordinator] in
            coordinator?.toggleFitActual()
        }
        // Refit when the viewport resizes while in Fit mode.
        scrollView.onResize = { [weak coordinator = context.coordinator] in
            coordinator?.viewportResized()
        }
        scrollView.onSwipePrevious = onSwipePrevious
        scrollView.onSwipeNext = onSwipeNext

        DispatchQueue.main.async { context.coordinator.fit() }
        return scrollView
    }

    func updateNSView(_ nsView: ZoomScrollView, context: Context) {
        nsView.onSwipePrevious = onSwipePrevious
        nsView.onSwipeNext = onSwipeNext

        if context.coordinator.url != url {
            context.coordinator.url = url
            nsView.imageView?.image = NSImage(contentsOf: url)
            // Refit synchronously so the new image never paints at the previous
            // image's magnification first (which caused a visible flash). The
            // viewport already has a valid size on an on-screen view.
            context.coordinator.fit()
        }

        if let cmd = command {
            switch cmd {
            case .fit: context.coordinator.fit()
            case .actualSize: context.coordinator.actualSize()
            case .zoomIn: context.coordinator.zoom(by: 1.25)
            case .zoomOut: context.coordinator.zoom(by: 0.8)
            }
            DispatchQueue.main.async { command = nil }
        }
    }

    static func dismantleNSView(_ nsView: ZoomScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        var url: URL?
        weak var scrollView: ZoomScrollView?
        private var zoomFactorBinding: Binding<CGFloat>
        private var boundsObserver: NSObjectProtocol?
        /// True while the user hasn't manually zoomed, so viewport resizes refit.
        private var isFitMode = true

        init(zoomFactor: Binding<CGFloat>) {
            self.zoomFactorBinding = zoomFactor
        }

        func observe(_ scrollView: ZoomScrollView) {
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                // The .main queue guarantees main-thread delivery; hop to the
                // main actor so we can touch AppKit + the binding safely.
                MainActor.assumeIsolated {
                    guard let self, let scrollView else { return }
                    self.reportZoom(scrollView.magnification)
                }
            }
        }

        func stopObserving() {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        func viewportResized() {
            if isFitMode { fit() }
        }

        private func reportZoom(_ magnification: CGFloat) {
            guard abs(zoomFactorBinding.wrappedValue - magnification) > 0.001 else { return }
            // Defer so we never mutate SwiftUI state inside an update pass
            // (which can cause warnings and extra re-render churn).
            let binding = zoomFactorBinding
            DispatchQueue.main.async {
                if abs(binding.wrappedValue - magnification) > 0.001 {
                    binding.wrappedValue = magnification
                }
            }
        }

        /// Scale so the whole image fits inside the viewport, centered.
        func fit() {
            guard let scrollView, let image = scrollView.imageView?.image else { return }
            // Use the clip view's FRAME, not its bounds: bounds is expressed in
            // the document's magnified coordinate space (bounds = frame /
            // magnification), so measuring bounds would scale the viewport by
            // the previous image's zoom and produce a wrong fit scale.
            let viewport = scrollView.contentView.frame.size
            let imageSize = pixelSize(of: image)
            guard viewport.width > 0, viewport.height > 0,
                  imageSize.width > 0, imageSize.height > 0 else { return }

            sizeImageViewToPixels(image)
            let scale = min(viewport.width / imageSize.width,
                            viewport.height / imageSize.height)
            isFitMode = true
            scrollView.magnification = scale
            scrollView.recenter()
            reportZoom(scale)
        }

        /// Toggle between fit-to-view and 100% (used by double-click).
        func toggleFitActual() {
            guard let scrollView else { return }
            if abs(scrollView.magnification - 1.0) < 0.01 {
                fit()
            } else {
                actualSize()
            }
        }

        /// Show at 100% — one image pixel per point, centered.
        func actualSize() {
            guard let scrollView, let image = scrollView.imageView?.image else { return }
            sizeImageViewToPixels(image)
            isFitMode = false
            scrollView.magnification = 1.0
            scrollView.recenter()
            reportZoom(1.0)
        }

        func zoom(by factor: CGFloat) {
            guard let scrollView else { return }
            let next = (scrollView.magnification * factor)
                .clamped(to: scrollView.minMagnification...scrollView.maxMagnification)
            isFitMode = false
            let center = CGPoint(x: scrollView.contentView.bounds.midX,
                                 y: scrollView.contentView.bounds.midY)
            scrollView.setMagnification(next, centeredAt: center)
            scrollView.recenter()
            reportZoom(next)
        }

        private func sizeImageViewToPixels(_ image: NSImage) {
            guard let imageView = scrollView?.imageView else { return }
            imageView.frame = CGRect(origin: .zero, size: pixelSize(of: image))
        }

        private func pixelSize(of image: NSImage) -> CGSize {
            if let rep = image.representations.first {
                return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            }
            return image.size
        }
    }
}

/// A clip view that centers the document view when it is smaller than the clip
/// bounds, so zoomed-out images sit in the middle instead of the bottom-left.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }

        let docFrame = doc.frame
        // `bounds.size` is already divided by the magnification, so comparing
        // against the (unscaled) document frame keeps a small image centered.
        if rect.width > docFrame.width {
            rect.origin.x = (docFrame.width - rect.width) / 2
        }
        if rect.height > docFrame.height {
            rect.origin.y = (docFrame.height - rect.height) / 2
        }
        return rect
    }
}

/// NSScrollView subclass that keeps a reference to its image view and reports
/// double-clicks and viewport resizes.
final class ZoomScrollView: NSScrollView {
    weak var imageView: NSImageView?
    var onDoubleClick: (() -> Void)?
    var onResize: (() -> Void)?
    var onSwipePrevious: (() -> Void)?
    var onSwipeNext: (() -> Void)?

    /// Accumulated horizontal scroll for the in-flight gesture, and whether it
    /// has already stepped, so one flick navigates exactly once.
    private var navAccumX: CGFloat = 0
    private var navAccumY: CGFloat = 0
    private var navTriggered = false
    private let navThreshold: CGFloat = 50
    /// Cooldown for discrete mouse-wheel steps (one notch == one item).
    private var lastWheelStep: TimeInterval = 0
    private let wheelCooldown: TimeInterval = 0.15

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }

    private var hasNavHandlers: Bool { onSwipeNext != nil || onSwipePrevious != nil }

    /// True when the whole image is visible horizontally (nothing to pan
    /// sideways), so a horizontal gesture can be read as navigation.
    private var canNavigateHorizontally: Bool {
        guard let doc = documentView else { return false }
        let docWidth = doc.frame.width * magnification
        return docWidth <= contentView.frame.width + 1
    }

    /// True when the whole image is visible vertically (nothing to pan up or
    /// down), so a mouse wheel can be read as navigation.
    private var canNavigateVertically: Bool {
        guard let doc = documentView else { return false }
        let docHeight = doc.frame.height * magnification
        return docHeight <= contentView.frame.height + 1
    }

    override func swipe(with event: NSEvent) {
        if event.deltaX > 0 {
            onSwipeNext?()
        } else if event.deltaX < 0 {
            onSwipePrevious?()
        } else {
            super.swipe(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard hasNavHandlers else {
            super.scrollWheel(with: event)
            return
        }

        // Physical mouse wheel: coarse, non-precise, no gesture phase. Treat a
        // notch as one step when the image can't be panned along that axis.
        if !event.hasPreciseScrollingDeltas {
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            let delta = abs(dx) > abs(dy) ? dx : dy
            let axisIsVertical = abs(dy) >= abs(dx)
            let fittedOnAxis = axisIsVertical ? canNavigateVertically : canNavigateHorizontally

            if delta != 0, fittedOnAxis {
                let now = event.timestamp
                if now - lastWheelStep > wheelCooldown {
                    lastWheelStep = now
                    if delta < 0 { onSwipeNext?() } else { onSwipePrevious?() }
                }
                return
            }
            // Zoomed in on this axis: let the scroll view pan.
            super.scrollWheel(with: event)
            return
        }

        // Trackpad precise scroll: navigate only when horizontally fitted,
        // otherwise pan.
        guard canNavigateHorizontally else {
            super.scrollWheel(with: event)
            return
        }

        if event.phase.contains(.began) {
            navAccumX = 0
            navAccumY = 0
            navTriggered = false
        }

        if !event.momentumPhase.isEmpty { return }

        navAccumX += event.scrollingDeltaX
        navAccumY += event.scrollingDeltaY

        if !navTriggered, abs(navAccumX) > navThreshold,
           abs(navAccumX) > abs(navAccumY) {
            navTriggered = true
            if navAccumX > 0 { onSwipeNext?() } else { onSwipePrevious?() }
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            navAccumX = 0
            navAccumY = 0
            navTriggered = false
        }
    }

    /// Re-apply the clip view centering after a programmatic zoom change.
    func recenter() {
        let clip = contentView
        clip.setBoundsOrigin(clip.constrainBoundsRect(clip.bounds).origin)
        reflectScrolledClipView(clip)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
