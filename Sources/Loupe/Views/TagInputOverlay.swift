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
    @FocusState private var fieldFocused: Bool

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
        .onExitCommand { dismiss() }   // Esc
        .onAppear {
            quickTags = Array(model.allTextTags.prefix(9))
            // Focus the field next tick so typing starts immediately.
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    @ViewBuilder
    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(targetCount > 1 ? "Tag \(targetCount) Items" : "Tag Item")
                .font(.headline)

            // New-tag field: type a name, Return adds it (and closes).
            // A number key 1–9 (while the field is focused and the draft is
            // empty) quick-toggles the matching existing tag instead of typing
            // the digit — so the user can either type a new tag or press a
            // number to assign an existing one. Once they've started typing a
            // name, digits type normally so numeric tag names still work.
            TextField("Add a tag…", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { commitDraft() }
                .onKeyPress(phases: .down) { press in
                    guard draft.isEmpty,
                          let digit = press.characters.first?.wholeNumberValue,
                          (1...9).contains(digit),
                          digit <= quickTags.count
                    else { return .ignored }
                    model.toggleTextTag(quickTags[digit - 1])
                    return .handled
                }

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
