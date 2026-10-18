import SwiftUI
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

/// The consolidated on-device AI control in the toolbar: a single "AI" menu
/// (sparkles) holding scene-classification actions and the face-recognition
/// controls. Crucially, the face **engine** and **sensitivity** are chosen
/// here, *before* running "Find Faces", so the user isn't forced to run first
/// and adjust afterward.
struct AIMenu: View {
    @Bindable var model: BrowserModel

    private var hasSelectedImages: Bool {
        model.selectedMediaItems.contains { $0.kind == .image }
    }

    var body: some View {
        Menu {
            // MARK: Scene classification
            Section("Categories") {
                Button(classifyTitle, systemImage: "sparkles") {
                    if hasSelectedImages { model.classifySelection() }
                    else { model.classifyAllImages() }
                }
                if model.classifiedCount > 0 {
                    Button("Clear Categories", role: .destructive) {
                        model.clearAICategories()
                    }
                }
            }

            // MARK: Face recognition — settings first, then the action.
            Section("People") {
                // Engine picker only when more than one engine is selectable.
                // Core ML is disabled for now, leaving just Vision.
                if FaceRecognitionEngine.selectableCases.count > 1 {
                    Picker("Engine", selection: $model.faceEngine) {
                        ForEach(FaceRecognitionEngine.selectableCases, id: \.self) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }

                    if model.faceEngine == .coreMLEmbedding && !model.coreMLFaceModelAvailable {
                        Text("No Core ML face model installed")
                    }
                }

                // Sensitivity slider lives in the menu so it's set before a run.
                // Re-clusters live if people already exist.
                Menu("Sensitivity: \(sensitivityLabel)") {
                    // A compact set of presets keeps this usable inside a menu,
                    // where a free Slider is awkward. The sidebar still offers a
                    // continuous slider for fine tuning after a run.
                    ForEach(sensitivityPresets, id: \.label) { preset in
                        Button {
                            model.faceClusterThreshold = preset.value
                            model.reclusterFaces()
                        } label: {
                            if isCurrent(preset.value) {
                                Label(preset.label, systemImage: "checkmark")
                            } else {
                                Text(preset.label)
                            }
                        }
                    }
                }

                Button(faceTitle, systemImage: "person.crop.circle") {
                    if hasSelectedImages { model.recognizeFacesInSelection() }
                    else { model.recognizeAllFaces() }
                }
                .disabled(faceDisabled)

                if model.withFacesCount > 0 {
                    Button("Clear People", role: .destructive) {
                        model.clearFaces()
                    }
                }
            }
        } label: {
            Label("AI", systemImage: "sparkles")
        }
        .menuIndicator(.visible)
        .help("On-device image classification and face recognition")
        // Resolve whether a Core ML model is installed so the engine options
        // reflect reality the first time the menu is shown.
        .task { model.refreshCoreMLFaceAvailability() }
    }

    // MARK: - Titles / state

    private var classifyTitle: String {
        hasSelectedImages ? "Classify Selected Images" : "Classify All Images"
    }

    private var faceTitle: String {
        hasSelectedImages ? "Find Faces in Selected" : "Find Faces in All Images"
    }

    /// Disable the run button when the chosen engine can't produce embeddings
    /// (Core ML selected but no model installed).
    private var faceDisabled: Bool {
        model.faceEngine == .coreMLEmbedding && !model.coreMLFaceModelAvailable
    }

    // MARK: - Sensitivity presets

    private struct Preset { let label: String; let value: Double }

    /// Three presets spanning the current engine's threshold range: stricter
    /// (more, purer people) → looser (fewer, risk of merging).
    private var sensitivityPresets: [Preset] {
        let range = model.faceEngine.thresholdRange
        let lo = range.lowerBound, hi = range.upperBound
        return [
            Preset(label: "Stricter", value: lo + (hi - lo) * 0.25),
            Preset(label: "Balanced", value: lo + (hi - lo) * 0.5),
            Preset(label: "Looser", value: lo + (hi - lo) * 0.75)
        ]
    }

    private func isCurrent(_ value: Double) -> Bool {
        abs(model.faceClusterThreshold - value) < 0.001
    }

    private var sensitivityLabel: String {
        let range = model.faceEngine.thresholdRange
        let span = range.upperBound - range.lowerBound
        let t = (model.faceClusterThreshold - range.lowerBound) / span
        switch t {
        case ..<0.33: return "Stricter"
        case ..<0.66: return "Balanced"
        default: return "Looser"
        }
    }
}
