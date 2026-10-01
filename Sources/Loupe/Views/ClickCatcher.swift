import SwiftUI
import AppKit

/// An AppKit-backed overlay that reports single and double clicks without the
/// delay SwiftUI introduces when a single- and double-tap gesture compete on
/// the same view.
///
/// The single-click handler fires immediately on mouse-down, so grid selection
/// feels instant. A double-click additionally fires the double handler.
struct ClickCatcher: NSViewRepresentable {
    var onSingle: () -> Void
    var onDouble: () -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.onSingle = onSingle
        view.onDouble = onDouble
        return view
    }

    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.onSingle = onSingle
        nsView.onDouble = onDouble
    }

    final class ClickView: NSView {
        var onSingle: () -> Void = {}
        var onDouble: () -> Void = {}

        override func mouseDown(with event: NSEvent) {
            // Select on the very first mouse-down for immediate feedback; a
            // second click of the same sequence opens the viewer.
            if event.clickCount >= 2 {
                onDouble()
            } else {
                onSingle()
            }
        }

        // Not overriding `scrollWheel(with:)` lets wheel events fall through to
        // the enclosing SwiftUI ScrollView, so scrolling still works.
    }
}

extension View {
    /// Attaches instant single/double click handling via AppKit.
    func onClick(single: @escaping () -> Void, double: @escaping () -> Void) -> some View {
        overlay(ClickCatcher(onSingle: single, onDouble: double))
    }
}
