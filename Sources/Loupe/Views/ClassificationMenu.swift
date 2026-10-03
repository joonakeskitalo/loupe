import SwiftUI
import AppKit

/// Shared context-menu content for manually correcting the AI classifications
/// on a set of files — reused by both the grid and the list so the two stay in
/// lockstep.
///
/// It offers two submenus:
///   * **Move to Category** — reassign the target files to an existing
///     category, a brand-new one (prompted), or remove them from any category.
///   * **Assign to Person** — add the target files to an existing person, or
///     remove a person currently on them. (People are multi-valued: a photo can
///     belong to several, so "assign" adds rather than replaces.)
///
/// `item` is the right-clicked file; the model decides whether the action
/// covers just that file or the whole selection (same rule as flag/tag).
struct ClassificationEditMenu: View {
    @Bindable var model: BrowserModel
    let item: MediaItem

    var body: some View {
        // Category editing: available once anything has been classified, or so
        // the user can start assigning categories by hand.
        Menu("Move to Category") {
            ForEach(model.aiCategoryList, id: \.self) { category in
                Button(category) { model.assignCategory(category, item: item) }
            }
            if !model.aiCategoryList.isEmpty { Divider() }
            Button("New Category…") {
                if let name = Self.promptForName(
                    title: "New Category",
                    message: "Name the category for the selected file(s)."
                ) {
                    model.assignCategory(name, item: item)
                }
            }
            if model.canRemoveFromCategory(item: item) {
                Divider()
                Button("Remove from Category", role: .destructive) {
                    model.removeFromCategory(item: item)
                }
            }
        }

        // Person editing: only meaningful once people exist. Assigning adds the
        // person; a separate section removes any person already on the targets.
        if !model.personList.isEmpty {
            Menu("Assign to Person") {
                ForEach(model.personList, id: \.self) { person in
                    Button(model.personName(person)) {
                        model.assignPerson(person, item: item)
                    }
                }

                let removable = model.personList.filter {
                    model.targetsContainPerson($0, item: item)
                }
                if !removable.isEmpty {
                    Divider()
                    Menu("Remove from Person") {
                        ForEach(removable, id: \.self) { person in
                            Button(model.personName(person), role: .destructive) {
                                model.removePerson(person, item: item)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Prompts for a short text value with a modal `NSAlert` + text field.
    /// Synchronous (returns when the user dismisses), which keeps it usable
    /// straight from a context-menu button without threading sheet state
    /// through two different container views. Returns nil on cancel/empty.
    static func promptForName(title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name"
        alert.accessoryView = field
        // Focus the text field so the user can type immediately.
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
