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
/// the same view.
///
/// The single-click handler fires immediately on mouse-down, so grid selection
/// feels instant. A double-click additionally fires the double handler.
struct ClickCatcher: NSViewRepresentable {
    var onSingle: (ClickModifiers) -> Void
    var onDouble: (ClickModifiers) -> Void

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
        var onSingle: (ClickModifiers) -> Void = { _ in }
        var onDouble: (ClickModifiers) -> Void = { _ in }

        override func mouseDown(with event: NSEvent) {
            // Select on the very first mouse-down for immediate feedback; a
            // second click of the same sequence opens the viewer.
            let mods = ClickModifiers(event.modifierFlags)
            if event.clickCount >= 2 {
                onDouble(mods)
            } else {
                onSingle(mods)
            }
        }

        // Not overriding `scrollWheel(with:)` lets wheel events fall through to
        // the enclosing SwiftUI ScrollView, so scrolling still works.
    }
}

extension View {
    /// Attaches instant single/double click handling via AppKit, forwarding the
    /// modifier keys held at click time.
    func onClick(
        single: @escaping (ClickModifiers) -> Void,
        double: @escaping (ClickModifiers) -> Void
    ) -> some View {
        overlay(ClickCatcher(onSingle: single, onDouble: double))
    }
}
