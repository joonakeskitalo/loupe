import SwiftUI

/// A centered, modal-style overlay for assigning free-text tags to the current
/// selection, opened with the `y` hotkey. The user can:
///   * type a tag name and press Return to add it, or
///   * press a number key (1–9) to toggle one of the existing tags listed, or
///   * click an existing tag to toggle it.
/// Escape (or clicking the dimmed backdrop) dismisses.
///
/// The overlay owns keyboard focus while open, and the surfaces that present it
/// (grid / viewer) suspend their own single-key hotkeys so typing and the 1–9
/// quick-assign keys don't collide with the background shortcuts.
struct TagInputOverlay: View {
    @Bindable var model: BrowserModel
    @Binding var isPresented: Bool

    /// The text being typed for a new tag.
    @State private var draft: String = ""

    /// Existing tags offered for quick-assign, capped at 9 so each maps to a
    /// single number key. Snapshotted on appear so the list (and its number
    /// mapping) stays stable while the overlay is open.
    @State private var quickTags: [String] = []

    /// How many items this action will affect, for the header.
    private var targetCount: Int {
        max(model.selectedItems.count, model.primarySelectedItem == nil ? 0 : 1)
    }

    var body: some View {
        // A compact panel pinned to the bottom-center, with no full-screen dim,
        // so the image/content behind stays visible and the user can keep
        // browsing with the arrow keys while tagging. A click outside the panel
        // falls through to the content (the panel doesn't block it).
        // Pinned to the bottom-center. The surrounding area has no background,
        // so taps there pass through to the content behind — only the panel
        // itself is interactive, keeping the overlay non-modal.
        VStack {
            Spacer(minLength: 0)
            panel
                .frame(width: 420)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12)))
                .shadow(radius: 20, y: 6)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onExitCommand { dismiss() }   // Esc (backstop; the field also handles it)
        .onAppear {
            quickTags = Array(model.allTextTags.prefix(9))
        }
    }

    @ViewBuilder
    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "tag")
                    .foregroundStyle(.secondary)
                Text(headerTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
            }

            // New-tag field: type a name, Return adds it. Backed by an AppKit
            // NSTextField so its field editor owns the standard editing keys
            // (⌘A select-all, Backspace, ⌘C/V/X) at the responder level — a
            // SwiftUI TextField let the menu-bar ⌘A command win.
            //
            // While the field is empty: 1–9 quick-toggle an existing tag and
            // ←/→ (and J/L) browse to the previous/next item so you can tag a
            // run of images without leaving the overlay. Once you start typing
            // a name, those keys edit/type normally.
            TaggingTextField(
                text: $draft,
                placeholder: "Add a tag…",
                onSubmit: { commitDraft() },
                onCancel: { dismiss() },
                onDigit: { digit in
                    guard draft.isEmpty, digit >= 1, digit <= quickTags.count else { return false }
                    model.toggleTextTag(quickTags[digit - 1])
                    return true
                },
                onNavigate: { forward, shift in
                    guard draft.isEmpty else { return false }
                    if shift {
                        // Grow/shrink the multi-selection so several images can
                        // be tagged at once.
                        model.extendViewerSelection(by: forward ? 1 : -1)
                    } else {
                        model.moveSelection(by: forward ? 1 : -1)
                    }
                    return true
                }
            )

            if !quickTags.isEmpty {
                // Existing tags as compact wrapping chips — tap or press its
                // number to toggle. Kept to one or two rows so the panel stays
                // small and unobtrusive over the image.
                FlowChips(tags: quickTags, model: model)
            }

            Text("Return add · 1–9 toggle · ←/→ browse · ⇧←/→ select · Esc close")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
    }

    /// The panel header: the current item's name (so the user knows what
    /// they're tagging as they browse), or a count for a multi-selection.
    private var headerTitle: String {
        if model.selectedItems.count > 1 {
            return "Tag \(model.selectedItems.count) Items"
        }
        return model.primarySelectedItem?.name ?? "Tag Item"
    }

    private func commitDraft() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { dismiss(); return }
        model.addTextTag(name)
        dismiss()
    }

    private func dismiss() {
        isPresented = false
    }
}

/// A compact wrapping row of existing-tag chips. Each chip shows its 1–9 number
/// (for the keyboard shortcut) and highlights when every target already carries
/// it; tapping toggles it. Uses SwiftUI's native `Layout`-free wrapping via a
/// `WrapLayout` so a long tag list flows onto multiple lines without a scroll
/// view bloating the panel.
private struct FlowChips: View {
    let tags: [String]
    @Bindable var model: BrowserModel

    var body: some View {
        WrapLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(tags.enumerated()), id: \.element) { index, tag in
                let applied = model.allTargetsHaveTextTag(tag)
                Button {
                    model.toggleTextTag(tag)
                } label: {
                    HStack(spacing: 4) {
                        Text("\(index + 1)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(applied ? Color.white.opacity(0.8) : .secondary)
                        Text(tag)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(applied ? Color.accentColor : Color.secondary.opacity(0.18))
                    )
                    .foregroundStyle(applied ? Color.white : Color.primary)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A minimal flow (wrapping) layout: places subviews left-to-right, wrapping to
/// a new line when the next one would overflow the proposed width.
private struct WrapLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                      proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

import AppKit

/// An AppKit-backed single-line text field for the tag overlay. Using
/// `NSTextField` (rather than SwiftUI's `TextField`) gives us the field
/// editor's native handling of the standard editing keys — ⌘A select-all,
/// Backspace/⌦, ⌘C/⌘V/⌘X — at the responder level, so the menu-bar ⌘A
/// ("Select All Items") can't steal them. It makes itself first responder on
/// appear so typing starts immediately, and routes Return/Esc and empty-field
/// digit presses back to the overlay.
private struct TaggingTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onCancel: () -> Void
    /// Called when a 1–9 digit is pressed; return true to consume it (the
    /// overlay toggles a quick tag) or false to let it type normally.
    var onDigit: (Int) -> Bool
    /// Called for a browse key (←/→ or J/L); `forward` is true for next,
    /// `shift` is true when extending the selection. Return true to consume it
    /// (navigated) or false to let it act normally.
    var onNavigate: (_ forward: Bool, _ shift: Bool) -> Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.stringValue = text
        field.delegate = context.coordinator
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.isAutomaticTextCompletionEnabled = false
        context.coordinator.field = field
        context.coordinator.installMonitor()
        // Grab focus once the field is in a window.
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TaggingTextField
        weak var field: NSTextField?
        private var monitor: Any?

        init(_ parent: TaggingTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        // Return commits, Esc cancels. Other command selectors (select-all,
        // delete, copy/paste) fall through to the field editor's defaults.
        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }

        /// A local key-down monitor is the reliable way to intercept bare 1–9
        /// digits: once the field is first responder, keystrokes go to the
        /// window's field editor (an `NSTextView`), NOT to the `NSTextField`,
        /// so overriding the field's `keyDown` never sees them. The monitor
        /// runs before the field editor, so it can swallow a quick-assign digit
        /// (field empty, no modifiers) and let every other key type normally.
        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let field = self.field,
                      field.window?.isKeyWindow == true,
                      field.currentEditor() != nil  // field is focused
                else { return event }

                // Ignore ⌘/⌃/⌥ combos (their own shortcuts). Shift is allowed —
                // it's the "extend selection" modifier for the arrow keys.
                let mods = event.modifierFlags.intersection([.command, .control, .option])
                guard mods.isEmpty, field.stringValue.isEmpty else { return event }

                let shift = event.modifierFlags.contains(.shift)

                // Browse keys: ←/→ arrows (plain = move cursor/item, Shift =
                // extend the multi-selection) and J/L (move only). Only active
                // while the draft is empty, so they don't interfere with
                // cursor movement / typing.
                switch event.keyCode {
                case 123:  // ←
                    if self.parent.onNavigate(false, shift) { return nil }
                    return event
                case 124:  // →
                    if self.parent.onNavigate(true, shift) { return nil }
                    return event
                case 38:   // J (move only; ignore if Shift to avoid uppercase)
                    if !shift, self.parent.onNavigate(false, false) { return nil }
                    return event
                case 37:   // L (move only)
                    if !shift, self.parent.onNavigate(true, false) { return nil }
                    return event
                default:
                    break
                }

                // Quick-assign digits 1–9 (plain only — Shift+digit is a
                // symbol, not a tag shortcut).
                if !shift,
                   let ch = event.charactersIgnoringModifiers, ch.count == 1,
                   let digit = Int(ch), (1...9).contains(digit),
                   self.parent.onDigit(digit) {
                    return nil
                }
                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
