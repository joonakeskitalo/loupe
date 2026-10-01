import SwiftUI
import AppKit

/// An AppKit-backed overlay that turns trackpad swipes and horizontal
/// scroll-wheel gestures into previous/next navigation.
///
/// Two input styles are supported:
///   * A deliberate two-finger trackpad **swipe** (`swipe(with:)`), which macOS
///     delivers distinctly from scrolling.
///   * A horizontal **scroll** gesture whose horizontal travel clearly exceeds
///     its vertical travel. The travel is accumulated across a single
///     continuous gesture (momentum phase ignored) so one flick steps once.
///
/// `onNext` is called for a leftward swipe / scroll (content moves forward) and
/// `onPrevious` for a rightward one, matching the chevron buttons.
struct SwipeNavigator: NSViewRepresentable {
    var onPrevious: () -> Void
    var onNext: () -> Void

    func makeNSView(context: Context) -> SwipeView {
        let view = SwipeView()
        view.configure(onPrevious: onPrevious, onNext: onNext)
        return view
    }

    func updateNSView(_ nsView: SwipeView, context: Context) {
        nsView.configure(onPrevious: onPrevious, onNext: onNext)
    }

    final class SwipeView: NSView {
        private var onPrevious: () -> Void = {}
        private var onNext: () -> Void = {}

        /// Accumulated horizontal travel for the in-flight scroll gesture.
        private var scrollAccumX: CGFloat = 0
        /// Accumulated vertical travel, used to reject mostly-vertical scrolls.
        private var scrollAccumY: CGFloat = 0
        /// True once the current gesture has already triggered a step, so a long
        /// continuous swipe doesn't fire repeatedly.
        private var didTriggerThisGesture = false

        /// Horizontal travel (points) needed before a scroll gesture navigates.
        private let scrollThreshold: CGFloat = 50

        func configure(onPrevious: @escaping () -> Void, onNext: @escaping () -> Void) {
            self.onPrevious = onPrevious
            self.onNext = onNext
        }

        // MARK: - Trackpad swipe (two-finger horizontal swipe)

        override func swipe(with event: NSEvent) {
            // deltaX: +1 for a swipe-left (go forward), -1 for swipe-right.
            if event.deltaX > 0 {
                onNext()
            } else if event.deltaX < 0 {
                onPrevious()
            }
        }

        // MARK: - Scroll

        /// Timestamp of the last mouse-wheel step, for a small cooldown so one
        /// notch (or quick flick) advances a single item.
        private var lastWheelStep: TimeInterval = 0
        private let wheelCooldown: TimeInterval = 0.15

        override func scrollWheel(with event: NSEvent) {
            // A physical mouse wheel reports coarse, non-precise deltas and no
            // gesture phase. Treat each notch as one discrete step along the
            // dominant axis (wheels are usually vertical).
            if !event.hasPreciseScrollingDeltas {
                handleMouseWheel(event)
                return
            }

            // Trackpad: accumulate a continuous gesture and step on a clear
            // horizontal (or dominant-axis) flick.
            if event.phase.contains(.began) {
                scrollAccumX = 0
                scrollAccumY = 0
                didTriggerThisGesture = false
            }

            // Ignore the momentum tail so a single flick steps exactly once.
            if !event.momentumPhase.isEmpty {
                return
            }

            scrollAccumX += event.scrollingDeltaX
            scrollAccumY += event.scrollingDeltaY

            if !didTriggerThisGesture, abs(scrollAccumX) > scrollThreshold,
               abs(scrollAccumX) > abs(scrollAccumY) {
                didTriggerThisGesture = true
                // Natural scrolling: pushing content left (positive deltaX)
                // reveals the next item.
                if scrollAccumX > 0 { onNext() } else { onPrevious() }
            }

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                scrollAccumX = 0
                scrollAccumY = 0
                didTriggerThisGesture = false
            }
        }

        private func handleMouseWheel(_ event: NSEvent) {
            // Prefer whichever axis moved more; a classic wheel only has Y.
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            let delta = abs(dx) > abs(dy) ? dx : dy
            guard delta != 0 else { return }

            let now = event.timestamp
            guard now - lastWheelStep > wheelCooldown else { return }
            lastWheelStep = now

            // Scrolling down / right advances to the next item.
            if delta < 0 { onNext() } else { onPrevious() }
        }
    }
}

extension View {
    /// Navigates to the previous/next item on a trackpad swipe or a clear
    /// horizontal scroll gesture.
    func onSwipeNavigate(
        previous: @escaping () -> Void,
        next: @escaping () -> Void
    ) -> some View {
        background(SwipeNavigator(onPrevious: previous, onNext: next))
    }
}
