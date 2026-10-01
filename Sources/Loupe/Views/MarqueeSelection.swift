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
    /// into `CellFramesKey`.
    func reportCellFrame(id: URL, in space: String) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: CellFramesKey.self,
                    value: [id: geo.frame(in: .named(space))]
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
    /// Called with the current rectangle (in this view's coordinates) during a
    /// drag, and with nil when the drag ends.
    var onChange: (CGRect?) -> Void

    func makeNSView(context: Context) -> MarqueeNSView {
        let view = MarqueeNSView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: MarqueeNSView, context: Context) {
        nsView.onChange = onChange
    }
}

final class MarqueeNSView: NSView {
    var onChange: ((CGRect?) -> Void)?
    private var startPoint: CGPoint?

    override var isFlipped: Bool { true }   // match SwiftUI's top-left origin

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
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
        startPoint = nil
        onChange?(nil)
    }
}
