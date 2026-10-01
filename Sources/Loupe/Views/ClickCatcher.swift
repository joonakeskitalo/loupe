import SwiftUI
import AppKit

/// Which modifier keys were held during a click, so the grid can implement
/// plain / Command (toggle) / Shift (range) selection.
struct ClickModifiers {
    let command: Bool
    let shift: Bool

    init(_ flags: NSEvent.ModifierFlags) {
        command = flags.contains(.command)
        shift = flags.contains(.shift)
    }
}

/// An AppKit-backed overlay that reports single and double clicks without the
/// delay SwiftUI introduces when a single- and double-tap gesture compete on
/// the same view, and that can also start a file drag to other apps/Finder.
///
/// The single-click handler fires immediately on mouse-down, so grid selection
/// feels instant. A double-click additionally fires the double handler. If the
/// mouse moves past a small threshold after pressing, a dragging session begins
/// carrying the file URLs from `dragURLs`.
struct ClickCatcher: NSViewRepresentable {
    var onSingle: (ClickModifiers) -> Void
    var onDouble: (ClickModifiers) -> Void
    /// Returns the file URLs to drag (called when a drag begins), or [] to
    /// disable dragging for this cell.
    var dragURLs: () -> [URL] = { [] }
    /// Optional image shown under the cursor while dragging.
    var dragImage: () -> NSImage? = { nil }

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.configure(onSingle: onSingle, onDouble: onDouble, dragURLs: dragURLs, dragImage: dragImage)
        return view
    }

    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.configure(onSingle: onSingle, onDouble: onDouble, dragURLs: dragURLs, dragImage: dragImage)
    }

    final class ClickView: NSView, NSDraggingSource {
        private var onSingle: (ClickModifiers) -> Void = { _ in }
        private var onDouble: (ClickModifiers) -> Void = { _ in }
        private var dragURLs: () -> [URL] = { [] }
        private var dragImage: () -> NSImage? = { nil }

        private var mouseDownPoint: CGPoint?
        private var mouseDownEvent: NSEvent?

        func configure(
            onSingle: @escaping (ClickModifiers) -> Void,
            onDouble: @escaping (ClickModifiers) -> Void,
            dragURLs: @escaping () -> [URL],
            dragImage: @escaping () -> NSImage?
        ) {
            self.onSingle = onSingle
            self.onDouble = onDouble
            self.dragURLs = dragURLs
            self.dragImage = dragImage
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = convert(event.locationInWindow, from: nil)
            mouseDownEvent = event

            let mods = ClickModifiers(event.modifierFlags)
            if event.clickCount >= 2 {
                onDouble(mods)
            } else {
                onSingle(mods)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownPoint, let downEvent = mouseDownEvent else { return }
            let now = convert(event.locationInWindow, from: nil)
            let moved = hypot(now.x - start.x, now.y - start.y)
            guard moved > 6 else { return }   // threshold before a drag begins

            let urls = dragURLs()
            guard !urls.isEmpty else { return }
            mouseDownPoint = nil
            mouseDownEvent = nil
            beginDrag(urls: urls, event: downEvent)
        }

        override func mouseUp(with event: NSEvent) {
            mouseDownPoint = nil
            mouseDownEvent = nil
        }

        private func beginDrag(urls: [URL], event: NSEvent) {
            let image = dragImage()
            let dragItems: [NSDraggingItem] = urls.enumerated().map { index, url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                // Stagger multiple drag previews slightly so they fan out.
                let size = CGSize(width: 96, height: 96)
                let origin = CGPoint(x: bounds.midX - size.width / 2 + CGFloat(index) * 6,
                                     y: bounds.midY - size.height / 2 - CGFloat(index) * 6)
                let frame = CGRect(origin: origin, size: size)
                item.setDraggingFrame(frame, contents: image ?? NSWorkspace.shared.icon(forFile: url.path))
                return item
            }
            // Mark this as an internal drag so our own window's drop handler
            // ignores it (dragging a file out and back shouldn't re-add it).
            InternalDrag.inProgress = true
            beginDraggingSession(with: dragItems, event: event, source: self)
        }

        // MARK: NSDraggingSource

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // Allow copying and (for Finder) moving/linking.
            [.copy, .move, .link, .generic]
        }

        func draggingSession(_ session: NSDraggingSession,
                             endedAt screenPoint: NSPoint,
                             operation: NSDragOperation) {
            InternalDrag.inProgress = false
        }

        // Not overriding `scrollWheel(with:)` lets wheel events fall through to
        // the enclosing SwiftUI ScrollView, so scrolling still works.
    }
}

/// Tracks whether a drag that originated from Loupe's own grid is in flight, so
/// the window's drop handler can ignore files dragged out and back in.
@MainActor
enum InternalDrag {
    static var inProgress = false
}

extension View {
    /// Attaches instant single/double click handling via AppKit, forwarding the
    /// modifier keys held at click time. Optionally makes the view a drag source
    /// for the given file URLs.
    func onClick(
        single: @escaping (ClickModifiers) -> Void,
        double: @escaping (ClickModifiers) -> Void,
        dragURLs: @escaping () -> [URL] = { [] },
        dragImage: @escaping () -> NSImage? = { nil }
    ) -> some View {
        overlay(ClickCatcher(onSingle: single, onDouble: double, dragURLs: dragURLs, dragImage: dragImage))
    }
}
