import SwiftUI
import AppKit
import VisionKit

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
    /// Backing color behind the image (shown as letterboxing when the image
    /// doesn't fill the viewport). Defaults to black for the fullscreen viewer;
    /// the preview sidebar passes a light color.
    var backgroundColor: NSColor = .black
    /// Optional previous/next handlers invoked on a trackpad swipe or clear
    /// horizontal scroll while the image is fitted (not zoomed in).
    var onSwipePrevious: (() -> Void)?
    var onSwipeNext: (() -> Void)?
    /// When true, Live Text is enabled over the image: recognized text can be
    /// selected with the mouse and copied with ⌘C (see `LiveTextSelection`).
    var enableTextSelection = false

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
        scrollView.backgroundColor = backgroundColor
        scrollView.drawsBackground = true

        // Centering clip view keeps a small image centered in the viewport.
        let clip = CenteringClipView()
        clip.drawsBackground = true
        clip.backgroundColor = backgroundColor
        scrollView.contentView = clip
        clip.postsBoundsChangedNotifications = true

        let imageView = NSImageView()
        imageView.imageScaling = .scaleAxesIndependently
        scrollView.documentView = imageView
        scrollView.imageView = imageView

        context.coordinator.scrollView = scrollView
        context.coordinator.url = url
        if enableTextSelection {
            context.coordinator.installTextOverlay(on: imageView)
        }
        context.coordinator.observe(scrollView)
        context.coordinator.loadImage(url, fitWhenReady: true)

        scrollView.onDoubleClick = { [weak coordinator = context.coordinator] in
            coordinator?.toggleFitActual()
        }
        // Refit when the viewport resizes while in Fit mode.
        scrollView.onResize = { [weak coordinator = context.coordinator] in
            coordinator?.viewportResized()
        }
        // Pinch / ⌘-scroll zoom leaves Fit mode so a resize doesn't snap back.
        scrollView.onUserZoom = { [weak coordinator = context.coordinator] in
            coordinator?.userDidZoom()
        }
        scrollView.onSwipePrevious = onSwipePrevious
        scrollView.onSwipeNext = onSwipeNext

        return scrollView
    }

    func updateNSView(_ nsView: ZoomScrollView, context: Context) {
        nsView.onSwipePrevious = onSwipePrevious
        nsView.onSwipeNext = onSwipeNext

        if context.coordinator.url != url {
            context.coordinator.url = url
            // Prefer an already-decoded image from the preloader so navigation
            // swaps instantly and refits in the same pass (no flash of the
            // previous image's magnification). Falls back to an async decode
            // when the neighbor wasn't warmed yet.
            context.coordinator.loadImage(url, fitWhenReady: true)
        }

        if let cmd = command {
            // Run the zoom on the next turn of the run loop rather than inside
            // this SwiftUI update pass. Changing magnification re-lays-out the
            // Live Text overlay, and doing that re-entrantly from within a
            // view update can trap inside AppKit.
            let coordinator = context.coordinator
            guard !coordinator.commandPending else { return }
            coordinator.commandPending = true
            DispatchQueue.main.async {
                coordinator.commandPending = false
                switch cmd {
                case .fit: coordinator.fit()
                case .actualSize: coordinator.actualSize()
                case .zoomIn: coordinator.zoom(by: 1.25)
                case .zoomOut: coordinator.zoom(by: 0.8)
                }
                command = nil
            }
        }
    }

    static func dismantleNSView(_ nsView: ZoomScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
        coordinator.removeTextOverlay()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        var url: URL?
        /// True while a zoom command is queued, so repeated view updates don't
        /// run it twice.
        var commandPending = false
        weak var scrollView: ZoomScrollView?
        private var zoomFactorBinding: Binding<CGFloat>
        private var boundsObserver: NSObjectProtocol?
        /// True while the user hasn't manually zoomed, so viewport resizes refit.
        private var isFitMode = true

        init(zoomFactor: Binding<CGFloat>) {
            self.zoomFactorBinding = zoomFactor
        }

        /// Loads `url` into the image view, preferring the preloader's cache for
        /// an instant swap and falling back to a background decode otherwise.
        /// When `fitWhenReady` is true the image is refit as soon as it's set,
        /// so the new image never paints at the previous image's magnification.
        func loadImage(_ url: URL, fitWhenReady: Bool) {
            // Fast path: already decoded by the preloader — set + fit in one
            // synchronous pass, exactly like the old synchronous load.
            if let cached = ImagePreloader.shared.cachedImageSync(for: url) {
                apply(cached, for: url, fit: fitWhenReady)
                return
            }

            // Not warmed yet: decode in the background, then apply only if the
            // view is still showing this URL (navigation may have moved on).
            Task { [weak self] in
                let image = await ImagePreloader.shared.image(for: url)
                guard let self, self.url == url else { return }
                self.apply(image, for: url, fit: fitWhenReady)
            }
        }

        private func apply(_ image: NSImage?, for url: URL, fit: Bool) {
            guard let imageView = scrollView?.imageView else { return }
            imageView.image = image
            if fit { self.fit() }
            analyzeText(in: image, for: url)
        }

        // MARK: Live Text

        private var overlay: ImageAnalysisOverlayView?
        private var analysisTask: Task<Void, Never>?
        private static let analyzer = ImageAnalyzer()

        func installTextOverlay(on imageView: NSImageView) {
            guard ImageAnalyzer.isSupported else { return }
            let overlay = ImageAnalysisOverlayView()
            overlay.preferredInteractionTypes = .textSelection
            overlay.trackingImageView = imageView
            overlay.frame = imageView.bounds
            overlay.autoresizingMask = [.width, .height]
            imageView.addSubview(overlay)
            self.overlay = overlay
            LiveTextSelection.shared.overlay = overlay
        }

        func removeTextOverlay() {
            analysisTask?.cancel()
            if LiveTextSelection.shared.overlay === overlay {
                LiveTextSelection.shared.overlay = nil
            }
            overlay?.removeFromSuperview()
            overlay = nil
        }

        private func analyzeText(in image: NSImage?, for url: URL) {
            guard let overlay else { return }
            analysisTask?.cancel()
            overlay.analysis = nil
            guard let image else { return }
            analysisTask = Task { [weak self] in
                var config = ImageAnalyzer.Configuration(.text)
                config.locales = Locale.preferredLanguages
                guard let analysis = try? await Self.analyzer.analyze(
                    image, orientation: .up, configuration: config),
                      !Task.isCancelled, let self, self.url == url else { return }
                self.overlay?.analysis = analysis
            }
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
                self.boundsObserver = nil
            }
        }

        func viewportResized() {
            if isFitMode { fit() }
        }

        /// Called after a pinch or ⌘-scroll zoom.
        func userDidZoom() {
            isFitMode = false
            scrollView?.recenter()
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

    /// Hand-tool drag-pan state. When the image is larger than the viewport, a
    /// click-drag grabs the image and pans it like the hand tool in an image
    /// editor. `isPanning` is set once the pointer actually moves so a plain
    /// click (which should still reach the double-click handler) isn't
    /// mistaken for a pan.
    private var panLastPoint: NSPoint?
    private var isPanning = false

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        // Begin a potential hand-tool pan when there's something to pan to.
        // Track the pointer in WINDOW coordinates — a fixed reference frame
        // that doesn't move as we scroll the clip — and convert into document
        // space per event (see mouseDragged).
        if canPan {
            panLastPoint = event.locationInWindow
            isPanning = false
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = panLastPoint, canPan,
              let doc = documentView else {
            super.mouseDragged(with: event)
            return
        }

        let currentWindow = event.locationInWindow

        if !isPanning,
           abs(currentWindow.x - last.x) + abs(currentWindow.y - last.y) > 0 {
            isPanning = true
            NSCursor.closedHand.push()
        }

        // Hand-tool pan: grab the image so the document point under the pointer
        // stays pinned under the pointer (like dragging a sheet of paper).
        //
        // Rather than reason about magnification manually (the source of the
        // earlier not-1:1 bugs), convert both the previous and current pointer
        // positions into the DOCUMENT VIEW's coordinate space. That conversion
        // already folds in the current magnification and scroll origin, so the
        // difference between the two is exactly how far — in document units —
        // the content under the pointer would otherwise have slid. Shifting the
        // clip's bounds origin by the negative of that delta cancels the slide,
        // pinning the grabbed point to the pointer 1:1 at any zoom.
        let lastDoc = doc.convert(last, from: nil)
        let currentDoc = doc.convert(currentWindow, from: nil)
        let dx = currentDoc.x - lastDoc.x
        let dy = currentDoc.y - lastDoc.y

        let clip = contentView
        var origin = clip.bounds.origin
        origin.x -= dx
        origin.y -= dy
        clip.setBoundsOrigin(clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        reflectScrolledClipView(clip)

        panLastPoint = currentWindow
    }

    override func mouseUp(with event: NSEvent) {
        if panLastPoint == nil {
            // We never intercepted this gesture for panning (image fitted);
            // let the scroll view handle the click normally.
            super.mouseUp(with: event)
        }
        // Otherwise this release ends an intercepted press (a pan or a plain
        // click on a zoomed image). The double-click action already fired from
        // mouseDown, so there's nothing else to forward — just reset state.
        if isPanning { NSCursor.pop() }
        panLastPoint = nil
        isPanning = false
    }

    /// True when the image overflows the viewport on either axis, so there's
    /// somewhere to pan. Mirrors the fitted checks used for navigation.
    private var canPan: Bool {
        !(canNavigateHorizontally && canNavigateVertically)
    }

    override func resetCursorRects() {
        // Show an open-hand cursor over a pannable (zoomed-in) image to signal
        // the hand tool; otherwise fall back to the default arrow.
        if canPan {
            addCursorRect(bounds, cursor: .openHand)
        } else {
            super.resetCursorRects()
        }
    }

    /// Called after a user-driven zoom (pinch or ⌘-scroll).
    var onUserZoom: (() -> Void)?

    /// Scroll and swipe events belong to the scroll view. The Live Text overlay
    /// sits over the whole image and would otherwise be the hit view for them.
    /// Clicks and drags still reach the overlay for text selection.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit != nil, let type = NSApp.currentEvent?.type else { return hit }
        switch type {
        case .scrollWheel, .swipe:
            return self
        default:
            return hit
        }
    }

    // MARK: Pinch zoom
    //
    // AppKit locks a pinch gesture's target view when the gesture begins, at a
    // point where `NSApp.currentEvent` isn't yet a `.magnify` event, so the
    // `hitTest` routing above can't reliably steer it and the Live Text overlay
    // ends up swallowing the pinch. A local event monitor sees every magnify
    // event before dispatch, so pinches over this view always zoom it.

    private var magnifyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMagnifyMonitor()
        } else if magnifyMonitor == nil {
            magnifyMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.magnify, .smartMagnify]
            ) { [weak self] event in
                // Local monitors run on the main thread. Only a Bool crosses
                // the isolation boundary (NSEvent isn't Sendable).
                nonisolated(unsafe) let event = event
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, self.owns(event) else { return false }
                    if event.type == .magnify {
                        self.magnify(with: event)
                    } else {
                        self.smartMagnify(with: event)
                    }
                    self.onUserZoom?()
                    return true
                }
                return handled ? nil : event
            }
        }
    }

    private func removeMagnifyMonitor() {
        if let magnifyMonitor { NSEvent.removeMonitor(magnifyMonitor) }
        magnifyMonitor = nil
    }

    /// True when `event` is in this view's window and over this view.
    private func owns(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else {
            return false
        }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return false }
        // Make sure this view is the topmost one under the pointer, so a
        // preview-sidebar image covered by the fullscreen viewer doesn't also
        // zoom. `hitTest` on the window's root takes a point in its
        // superview's coordinates, which for the content view is the window.
        guard let root = window.contentView,
              let hit = root.hitTest(root.superview?.convert(event.locationInWindow, from: nil)
                                     ?? event.locationInWindow) else { return false }
        return hit === self || hit.isDescendant(of: self)
    }

    /// ⌘-scroll zooms around the pointer, like pinch.
    private func commandScrollZoom(_ event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY * 0.01
            : event.scrollingDeltaY * 0.1
        guard delta != 0 else { return }
        let next = min(max(magnification * exp(delta), minMagnification), maxMagnification)
        let anchor = contentView.convert(event.locationInWindow, from: nil)
        setMagnification(next, centeredAt: anchor)
        onUserZoom?()
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
        if event.modifierFlags.contains(.command) {
            commandScrollZoom(event)
            return
        }
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
        // The zoom may have crossed the fitted/pannable boundary, so refresh
        // the hand-vs-arrow cursor over the image.
        window?.invalidateCursorRects(for: self)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Tracks the fullscreen viewer's Live Text overlay so the viewer's ⌘C / ⌘A
/// hotkeys can act on selected image text instead of the image file.
@MainActor
final class LiveTextSelection {
    static let shared = LiveTextSelection()
    weak var overlay: ImageAnalysisOverlayView?

    /// Copies the selected image text to the clipboard. Returns false (and does
    /// nothing) when no text is selected, so callers can fall back to copying
    /// the file.
    @discardableResult
    func copySelectedText() -> Bool {
        guard let overlay, overlay.hasActiveTextSelection else { return false }
        let text = overlay.selectedText
        guard !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    /// Asks the overlay to select all recognized text. Returns whether it
    /// handled the action.
    @discardableResult
    func selectAllText() -> Bool {
        guard let overlay else { return false }
        overlay.window?.makeFirstResponder(overlay)
        return overlay.tryToPerform(#selector(NSResponder.selectAll(_:)), with: nil)
    }
}
