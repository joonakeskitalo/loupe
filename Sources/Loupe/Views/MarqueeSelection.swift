import SwiftUI
import AppKit

/// Collects each grid cell's frame (in the grid coordinate space) so the
/// rubber-band selection can hit-test items against the dragged rectangle.
struct CellFramesKey: PreferenceKey {
    static let defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Reports this view's frame in the named coordinate space, keyed by `id`,
    /// into `CellFramesKey` — but only while `active` is true.
    ///
    /// The per-cell `GeometryReader` recomputes its frame on every layout pass,
    /// which during scrolling is effectively every frame, and the enclosing
    /// `onPreferenceChange` then re-runs the grid body and re-derives the column
    /// count each tick — a measurable scroll cost proportional to the number of
    /// on-screen cells. The frames are only actually needed during a marquee
    /// drag (to hit-test the rubber band), so reporting is gated: when inactive
    /// the `GeometryReader` emits the EMPTY default, so the aggregated
    /// preference stays constant and `onPreferenceChange` doesn't fire while
    /// scrolling — plain scrolling pays nothing.
    ///
    /// Crucially the `GeometryReader` background is attached UNCONDITIONALLY:
    /// the view's structure (and therefore its SwiftUI identity) must not change
    /// when `active` toggles. The previous form switched between `background(…)`
    /// and bare `self`, which restructured every cell the instant a background
    /// press armed `active = true`. That restructuring tore down and rebuilt the
    /// cell subtrees mid-interaction and stranded the old cells — leaving their
    /// selection border painted on screen after the selection had cleared (the
    /// "stale blue border" bug). Keeping the structure fixed and only varying
    /// the emitted preference VALUE avoids the teardown entirely.
    func reportCellFrame(id: URL, in space: String, active: Bool) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: CellFramesKey.self,
                    value: active ? [id: geo.frame(in: .named(space))] : [:]
                )
            }
        )
    }
}

/// An AppKit-backed rubber-band selection layer placed behind the grid cells.
///
/// Handling the drag in AppKit (rather than a SwiftUI `DragGesture`) means the
/// enclosing `NSScrollView` never receives these mouse events, so the view no
/// longer scrolls while you drag the selection rectangle. Because it sits
/// *behind* the cells (each of which has its own click overlay), it only
/// receives drags that begin on empty space — matching Finder.
struct MarqueeView: NSViewRepresentable {
    /// Called the instant a press begins on empty space (mouse-down), before
    /// any drag rectangle. Lets the grid arm per-cell frame reporting just for
    /// the duration of a potential marquee drag, so cells don't emit frame
    /// preferences on every ordinary scroll frame.
    var onDragBegan: () -> Void
    /// Called with the current rectangle (in this view's coordinates) during a
    /// drag, and with nil when the drag ends.
    var onChange: (CGRect?) -> Void
    /// Called when the user clicks empty space without dragging (clear).
    var onEmptyClick: () -> Void

    func makeNSView(context: Context) -> MarqueeNSView {
        let view = MarqueeNSView()
        view.onDragBegan = onDragBegan
        view.onChange = onChange
        view.onEmptyClick = onEmptyClick
        return view
    }

    func updateNSView(_ nsView: MarqueeNSView, context: Context) {
        nsView.onDragBegan = onDragBegan
        nsView.onChange = onChange
        nsView.onEmptyClick = onEmptyClick
    }
}

final class MarqueeNSView: NSView {
    var onDragBegan: (() -> Void)?
    var onChange: ((CGRect?) -> Void)?
    var onEmptyClick: (() -> Void)?
    private var startPoint: CGPoint?
    private var didDrag = false

    override var isFlipped: Bool { true }   // match SwiftUI's top-left origin

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        didDrag = false
        // Arm frame reporting now so the first drag rect can hit-test against
        // freshly reported cell frames.
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        didDrag = true
        let current = convert(event.locationInWindow, from: nil)
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        onChange?(rect)
    }

    override func mouseUp(with event: NSEvent) {
        let dragged = didDrag
        startPoint = nil
        didDrag = false
        onChange?(nil)
        // A click on empty space (no drag) clears the selection, like Finder.
        if !dragged { onEmptyClick?() }
    }
}
