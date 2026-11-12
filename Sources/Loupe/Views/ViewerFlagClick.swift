import SwiftUI
import AppKit

extension View {
    /// Calls `action` when the user right-clicks or Control-clicks inside this
    /// view's bounds, and consumes the click so the content underneath (zoomable
    /// image, video player, QuickLook, ...) never sees it. Implemented with a
    /// local event monitor because those AppKit-backed views take mouse events
    /// before SwiftUI gestures could.
    func onSecondaryClick(isEnabled: Bool = true, perform action: @escaping () -> Void) -> some View {
        background { if isEnabled { SecondaryClickMonitor(action: action) } }
    }
}

private struct SecondaryClickMonitor: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.action = action
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.removeMonitor()
    }

    final class MonitorView: NSView {
        var action: () -> Void = {}
        private var monitor: Any?
        /// True between a consumed mouse-down and its matching mouse-up, so the
        /// content below never receives an unpaired mouse-up.
        private var swallowingUp = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.rightMouseDown, .leftMouseDown, .rightMouseUp, .leftMouseUp]
            ) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            swallowingUp = false
        }

        deinit { removeMonitor() }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.window === window else { return event }
            switch event.type {
            case .rightMouseDown, .leftMouseDown:
                let isSecondary = event.type == .rightMouseDown
                    || event.modifierFlags.contains(.control)
                guard isSecondary else { return event }
                let point = convert(event.locationInWindow, from: nil)
                guard bounds.contains(point) else { return event }
                swallowingUp = true
                action()
                return nil
            case .rightMouseUp, .leftMouseUp:
                if swallowingUp {
                    swallowingUp = false
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }
}
