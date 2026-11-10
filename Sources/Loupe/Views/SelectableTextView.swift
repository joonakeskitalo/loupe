import SwiftUI
import AppKit

/// A read-only, selectable text view backed by a real `NSTextView`. Unlike
/// SwiftUI's `.textSelection(.enabled)`, it becomes a genuine first responder,
/// so the menu commands can detect it and route ⌘C / ⌘A to it (see
/// `LoupeCommands`) instead of acting on the grid selection.
struct SelectableTextView: NSViewRepresentable {
    let text: String
    var font: NSFont = .preferredFont(forTextStyle: .callout)

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        if view.string != text { view.string = text }
        view.font = font
        view.textColor = .labelColor
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView,
                      context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        guard let container = view.textContainer, let layout = view.layoutManager else {
            return nil
        }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height)
        return CGSize(width: width, height: max(height, 1))
    }
}

extension NSApplication {
    /// The text view (including a text field's field editor) that currently
    /// has keyboard focus in the key window, if any.
    var focusedTextView: NSTextView? {
        keyWindow?.firstResponder as? NSTextView
    }
}
