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
        ZStack {
            // Dimmed backdrop; a click dismisses.
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            panel
                .frame(width: 360)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.1)))
                .shadow(radius: 24, y: 8)
        }
        .onExitCommand { dismiss() }   // Esc (backstop; the field also handles it)
        .onAppear {
            quickTags = Array(model.allTextTags.prefix(9))
        }
    }

    @ViewBuilder
    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(targetCount > 1 ? "Tag \(targetCount) Items" : "Tag Item")
                .font(.headline)

            // New-tag field: type a name, Return adds it (and closes). Backed
            // by an AppKit NSTextField so its field editor owns the standard
            // editing keys (⌘A select-all, Backspace, ⌘C/V/X) at the responder
            // level — a SwiftUI TextField let the menu-bar ⌘A command win.
            //
            // A number key 1–9 pressed while the draft is empty quick-toggles
            // the matching existing tag instead of typing the digit; once the
            // user has started a name, digits type normally so numeric tag
            // names still work.
            TaggingTextField(
                text: $draft,
                placeholder: "Add a tag…",
                onSubmit: { commitDraft() },
                onCancel: { dismiss() },
                onDigit: { digit in
                    guard draft.isEmpty, digit >= 1, digit <= quickTags.count else { return false }
                    model.toggleTextTag(quickTags[digit - 1])
                    return true
                }
            )

            if !quickTags.isEmpty {
                Divider()
                Text("Existing Tags")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    ForEach(Array(quickTags.enumerated()), id: \.element) { index, tag in
                        existingTagRow(index: index, tag: tag)
                    }
                }
            }

            Divider()
            HStack {
                Text("Return to add · 1–9 to toggle · Esc to close")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .hidden()   // Return is handled by the field's onSubmit.
            }
        }
        .padding(16)
    }

    /// A clickable row for an existing tag: its number key, the name, and a
    /// checkmark when every target already carries it.
    private func existingTagRow(index: Int, tag: String) -> some View {
        let applied = model.allTargetsHaveTextTag(tag)
        return Button {
            model.toggleTextTag(tag)
        } label: {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(tag)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Image(systemName: applied ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(applied ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(applied ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
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

                let mods = event.modifierFlags.intersection([.command, .control, .option])
                guard mods.isEmpty, field.stringValue.isEmpty,
                      let ch = event.charactersIgnoringModifiers, ch.count == 1,
                      let digit = Int(ch), (1...9).contains(digit)
                else { return event }

                if self.parent.onDigit(digit) {
                    return nil   // consumed as a quick-assign
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
