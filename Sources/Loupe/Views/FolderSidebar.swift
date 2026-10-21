import SwiftUI
import AppKit

/// Sidebar showing the folder tree. Selecting a folder switches the grid to
/// `.folders` mode and shows that folder's contents. Cmd-click adds or removes
/// folders from a multi-selection, so the grid can show several folders at once.
///
/// We drive selection highlighting manually (rather than through `List`'s
/// selection binding) because a `DisclosureGroup`'s label row does not reliably
/// participate in `List` selection, which previously left parent folders with
/// children looking unselected.
struct FolderSidebar: View {
    @Bindable var model: BrowserModel
    @FocusState private var focused: Bool

    /// Shared row insets applied to both each section's header and its rows so
    /// their content shares identical leading/trailing edges — the only way to
    /// make the header's remove button line up with the rows' count badges
    /// without hand-tuning version-specific `List` insets.
    private static let rowInsets = EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 0)

    /// Insets for a root header row. Same leading/trailing/top as `rowInsets`
    /// so edges stay aligned, but no bottom inset so the header sits snug
    /// against its first folder row (a smaller title-to-content gap).
    private static let headerRowInsets = EdgeInsets(top: 2, leading: 2, bottom: 0, trailing: 0)

    var body: some View {
        List {
            Section("Library") {
                Button {
                    model.showFlaggedOnly = false
                    model.showHiddenOnly = false
                    model.colorTagFilter = nil
                    model.textTagFilter = nil
                    model.aiCategoryFilter = nil
                    model.personFilter = nil
                    model.mode = .flattened
                    model.selectedFolder = model.roots.first
                    focused = true
                } label: {
                    SidebarLabel(
                        title: "All Media",
                        systemImage: "square.grid.3x3",
                        count: model.allItems.count > 0 ? model.allItems.count : nil,
                        isSelected: !model.showFlaggedOnly && !model.showHiddenOnly
                            && model.colorTagFilter == nil && model.textTagFilter == nil
                            && model.aiCategoryFilter == nil && model.personFilter == nil
                            && model.mode == .flattened
                    )
                    // Counteract the List section's leading content inset so
                    // the Library rows sit flush-left like the root headers.
                    .padding(.leading, -12)
                }
                .buttonStyle(.plain)
                .listRowInsets(Self.rowInsets)

                Button {
                    model.showFlaggedOnly = true
                    focused = true
                } label: {
                    SidebarLabel(
                        title: "Flagged",
                        systemImage: model.showFlaggedOnly ? "flag.fill" : "flag",
                        count: model.flaggedCount > 0 ? model.flaggedCount : nil,
                        isSelected: model.showFlaggedOnly
                    )
                    .padding(.leading, -12)
                }
                .buttonStyle(.plain)
                .disabled(model.flaggedCount == 0 && !model.showFlaggedOnly)
                .listRowInsets(Self.rowInsets)

                Button {
                    model.showHiddenOnly = true
                    focused = true
                } label: {
                    SidebarLabel(
                        title: "Hidden",
                        systemImage: model.showHiddenOnly ? "eye.slash.fill" : "eye.slash",
                        count: model.hiddenCount > 0 ? model.hiddenCount : nil,
                        isSelected: model.showHiddenOnly
                    )
                    .padding(.leading, -12)
                }
                .buttonStyle(.plain)
                .disabled(model.hiddenCount == 0 && !model.showHiddenOnly)
                .listRowInsets(Self.rowInsets)

                // One row per color tag, directly under Flagged. Each filters
                // the grid to items carrying that tag; selecting it again (via
                // All Media) clears the filter. A row is disabled when nothing
                // carries that tag and it isn't the active filter.
                ForEach(ColorTag.allInHotkeyOrder, id: \.self) { tag in
                    let count = model.colorTagCount(tag)
                    Button {
                        model.colorTagFilter = tag
                        focused = true
                    } label: {
                        SidebarLabel(
                            title: tag.displayName,
                            systemImage: tag.symbol,
                            iconTint: tag.color,
                            count: count > 0 ? count : nil,
                            isSelected: model.colorTagFilter == tag
                        )
                        .padding(.leading, -12)
                    }
                    .buttonStyle(.plain)
                    .disabled(count == 0 && model.colorTagFilter != tag)
                    .listRowInsets(Self.rowInsets)
                }
            }

            // Free-text tags, as an expandable list. Shown only once some tags
            // exist; the header's trailing button clears them all. Each row
            // filters the grid to items carrying that tag.
            if !model.allTextTags.isEmpty {
                Section {
                    TextTagSection(model: model, focused: $focused, rowInsets: Self.rowInsets)
                }
            }

            // AI scene categories, as an expandable list. Shown only once the
            // classifier has produced some; the header's trailing button clears
            // all categories. Each row filters the grid to that category.
            if !model.aiCategoryList.isEmpty {
                Section {
                    AICategorySection(model: model, focused: $focused, rowInsets: Self.rowInsets)
                }
            }

            // Recognized people, as an expandable list. Shown only once faces
            // have been found; the header's trailing button clears all people.
            // Each row filters the grid to photos containing that person.
            if !model.personList.isEmpty {
                Section {
                    PeopleSection(model: model, focused: $focused, rowInsets: Self.rowInsets)
                }
            }

            // One section per root, each with its own tree and a Remove action.
            // We iterate root entries (keyed by the stable root identity) rather
            // than the trees, so a single dropped file — whose tree node is its
            // parent directory — still removes correctly and stays unique.
            ForEach(model.rootEntries) { entry in
                // The root header is rendered as a regular row (not a Section
                // header) so its content sits in the SAME layout context as the
                // folder rows below. That's the only reliable way to make the
                // remove button line up with the rows' trailing count badges —
                // `List` gives section headers a different inset than rows, so
                // no amount of header padding matches the counts.
                Section {
                    RootHeaderRow(entry: entry) { model.removeRoot(entry.key) }
                        // Zero the header row's bottom inset so it hugs the
                        // folder row directly beneath it; the rest of the
                        // insets match the folder rows for aligned edges.
                        .listRowInsets(Self.headerRowInsets)
                        .contextMenu {
                            Button("Remove Folder", role: .destructive) {
                                model.removeRoot(entry.key)
                            }
                        }
                    FolderRow(node: entry.tree, model: model, focused: $focused, isRoot: true)
                        .listRowInsets(Self.rowInsets)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                addFolder()
            } label: {
                Label("Add Folder…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        // Make the whole sidebar focusable so arrow keys move the folder
        // selection once a folder is selected or the sidebar is clicked.
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            model.moveFolderSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.moveFolderSelection(by: 1)
            return .handled
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls { model.open(url: url) }
        }
    }
}

/// Recursive disclosure row for a folder and its children.
private struct FolderRow: View {
    let node: FolderNode
    @Bindable var model: BrowserModel
    var focused: FocusState<Bool>.Binding
    /// True for a root's top-level folder row, so it's pulled flush-left to
    /// line up under its root header. Nested children keep the default indent.
    var isRoot: Bool = false

    @State private var isExpanded: Bool = true

    private var isSelected: Bool {
        !model.showFlaggedOnly && !model.showHiddenOnly && model.colorTagFilter == nil
            && model.textTagFilter == nil
            && model.aiCategoryFilter == nil && model.personFilter == nil
            && model.mode == .folders && model.selectedFolders.contains(node.url)
    }

    private var rowLabel: some View {
        Button {
            model.showFlaggedOnly = false
            model.showHiddenOnly = false
            model.colorTagFilter = nil
            model.textTagFilter = nil
            model.aiCategoryFilter = nil
            model.personFilter = nil
            model.mode = .folders
            // Cmd-click toggles the folder in/out of a multi-selection;
            // a plain click selects just this folder.
            if NSEvent.modifierFlags.contains(.command) {
                model.toggleFolderSelection(node.url)
            } else {
                model.selectFolder(node.url)
            }
            focused.wrappedValue = true
        } label: {
            SidebarLabel(
                title: node.name,
                systemImage: "folder",
                count: node.directMediaCount > 0 ? node.directMediaCount : nil,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        if node.children.isEmpty {
            rowLabel
                // A childless root row has no disclosure chevron, so counteract
                // the List's leading content inset to sit flush-left under the
                // root header (matching the header name's alignment).
                .padding(.leading, isRoot ? -12 : 0)
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children) { child in
                    FolderRow(node: child, model: model, focused: focused)
                }
            } label: {
                rowLabel
                    // Pull the label back toward the disclosure chevron, which
                    // otherwise leaves a wide default gap on macOS.
                    .padding(.leading, -3)
            }
        }
    }
}

/// The header row for a root folder: its name and a trailing remove button.
///
/// Mirrors `SidebarLabel`'s internal layout (same `Spacer` + `.padding(6)`),
/// so — because this is a real `List` row with the same `listRowInsets` as the
/// folder rows — the remove button's glyph lands at exactly the same trailing
/// x-position as the rows' count badges.
private struct RootHeaderRow: View {
    let entry: BrowserModel.RootEntry
    let onRemove: () -> Void

    // Both normal roots and grouped file-drop roots name their header after the
    // folder the sidebar node represents (`tree.name`). For grouped roots that
    // node is the dropped files' shared parent directory, so sibling files land
    // under one folder header instead of a per-file entry.
    private var title: String {
        entry.tree.name
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.body)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    // Glyph flush to the trailing edge (matching the count
                    // badge's trailing edge in the rows below); the wider frame
                    // only extends the clickable area to the left.
                    .frame(width: 28, height: 20, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove this folder from the window")
        }
        // Asymmetric vertical padding: keep the top breathing room that
        // separates this root header from the section above, but trim the
        // bottom so the header sits closer to its own folder rows (a tighter
        // title-to-content gap, which reads as one grouped unit).
        .padding(.top, 3)
        .padding(.bottom, 0)
        // Slightly less trailing inset than the rows below so the remove button
        // sits a touch further right (toward the sidebar edge).
        .padding(.trailing, 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Counteract the List section's built-in leading content inset so the
        // root folder name sits flush at the sidebar's left edge instead of
        // lining up with the folder icons in the rows below.
        .padding(.leading, -12)
    }
}

/// Expandable "Categories" list: a header with a clear-all button, disclosing
/// one row per AI scene category. Each row filters the grid to that category.
private struct AICategorySection: View {
    @Bindable var model: BrowserModel
    var focused: FocusState<Bool>.Binding
    let rowInsets: EdgeInsets

    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(model.aiCategoryList, id: \.self) { category in
                Button {
                    model.aiCategoryFilter = category
                    focused.wrappedValue = true
                } label: {
                    SidebarLabel(
                        title: category,
                        systemImage: "sparkles",
                        count: model.aiCategoryCount(category),
                        isSelected: model.aiCategoryFilter == category
                    )
                }
                .buttonStyle(.plain)
                .listRowInsets(rowInsets)
                .contextMenu {
                    // Merge this category into another — relabels every item.
                    let others = model.aiCategoryList.filter { $0 != category }
                    if !others.isEmpty {
                        Menu("Merge Into") {
                            ForEach(others, id: \.self) { other in
                                Button(other) { model.mergeCategory(category, into: other) }
                            }
                        }
                    }
                    Button("Remove Category", role: .destructive) {
                        model.deleteCategory(category)
                    }
                }
            }
        } label: {
            SidebarSectionHeader(
                title: "Categories",
                clearHelp: "Clear all AI categories"
            ) {
                model.clearAICategories()
            }
            .padding(.leading, -3)
        }
        .listRowInsets(rowInsets)
    }
}

/// Expandable "Tags" list: a header with a clear-all button, disclosing one
/// row per free-text tag. Each row filters the grid to items carrying that tag;
/// a right-click removes the tag everywhere.
private struct TextTagSection: View {
    @Bindable var model: BrowserModel
    var focused: FocusState<Bool>.Binding
    let rowInsets: EdgeInsets

    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(model.allTextTags, id: \.self) { tag in
                Button {
                    model.textTagFilter = tag
                    focused.wrappedValue = true
                } label: {
                    SidebarLabel(
                        title: tag,
                        systemImage: "tag",
                        count: model.textTagCount(tag),
                        isSelected: model.textTagFilter == tag
                    )
                }
                .buttonStyle(.plain)
                .listRowInsets(rowInsets)
                .contextMenu {
                    Button("Remove Tag", role: .destructive) {
                        model.deleteTextTag(tag)
                    }
                }
            }
        } label: {
            SidebarSectionHeader(
                title: "Tags",
                clearHelp: "Clear all tags"
            ) {
                model.clearTextTags()
            }
            .padding(.leading, -3)
        }
        .listRowInsets(rowInsets)
    }
}

/// Expandable "People" list: a header with a clear-all button, disclosing one
/// row per recognized person. Each row filters the grid to photos with that
/// person.
private struct PeopleSection: View {
    @Bindable var model: BrowserModel
    var focused: FocusState<Bool>.Binding
    let rowInsets: EdgeInsets

    @State private var isExpanded = true
    /// The person row currently highlighted as a drag-and-drop target, if any.
    @State private var dropTargetPerson: Int?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            // Engine + threshold controls for face clustering.
            FaceControls(model: model)
                .listRowInsets(rowInsets)

            ForEach(model.personList, id: \.self) { person in
                Button {
                    model.personFilter = person
                    focused.wrappedValue = true
                } label: {
                    SidebarLabel(
                        title: model.personName(person),
                        systemImage: "person.crop.circle",
                        count: model.personCount(person),
                        isSelected: model.personFilter == person
                    )
                }
                .buttonStyle(.plain)
                .listRowInsets(rowInsets)
                // Drag images from the grid/list and drop them here to assign
                // them to this person. If the grid is currently filtered to a
                // person, the drop *moves* the files out of that person into
                // this one; otherwise it just adds this person to them.
                .dropDestination(for: URL.self) { urls, _ in
                    let movingFrom = model.personFilter == person ? nil : model.personFilter
                    let n = model.assignPerson(person, toURLs: urls, movingFrom: movingFrom)
                    return n > 0
                } isTargeted: { targeted in
                    dropTargetPerson = targeted ? person : (dropTargetPerson == person ? nil : dropTargetPerson)
                }
                .listRowBackground(
                    dropTargetPerson == person
                        ? RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.25))
                        : nil
                )
                .contextMenu {
                    // Merge this person into another — the clusterer often
                    // splits one person across IDs; this stitches them back.
                    let others = model.personList.filter { $0 != person }
                    if !others.isEmpty {
                        Menu("Merge Into") {
                            ForEach(others, id: \.self) { other in
                                Button(model.personName(other)) {
                                    model.mergePerson(person, into: other)
                                }
                            }
                        }
                    }
                    Button("Remove Person", role: .destructive) {
                        model.deletePerson(person)
                    }
                }
            }
        } label: {
            SidebarSectionHeader(
                title: "People",
                clearHelp: "Clear all recognized people"
            ) {
                model.clearFaces()
            }
            .padding(.leading, -3)
        }
        .listRowInsets(rowInsets)
    }
}

/// Face-clustering controls shown at the top of the People section: which
/// embedding engine to use, and the clustering sensitivity. The threshold
/// slider re-groups the already-extracted faces live (cheap); switching engines
/// requires a fresh "Find Faces" run, which the hint explains.
private struct FaceControls: View {
    @Bindable var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Engine picker — only shown when more than one engine is
            // selectable. (Core ML is currently disabled, leaving just Vision,
            // so the picker is hidden to avoid a pointless single-option menu.)
            if FaceRecognitionEngine.selectableCases.count > 1 {
                Picker("Engine", selection: $model.faceEngine) {
                    ForEach(FaceRecognitionEngine.selectableCases, id: \.self) { engine in
                        Text(engine.displayName)
                            .tag(engine)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(model.isClassifying)
            }

            if FaceRecognitionEngine.coreMLEngineEnabled && model.faceEngine == .coreMLEmbedding {
                HStack(spacing: 8) {
                    Button(model.coreMLFaceModelAvailable ? "Change Model…" : "Choose Model…") {
                        model.chooseFaceModel()
                    }
                    .controlSize(.small)
                    if model.coreMLFaceModelAvailable {
                        Button("Remove") { model.clearFaceModel() }
                            .controlSize(.small)
                    }
                }
                if !model.coreMLFaceModelAvailable {
                    Text("Pick a Core ML face-embedding model (.mlmodel/.mlpackage) to use this engine.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Why a recent run found nothing (e.g. the model's output couldn't
            // be read as an embedding).
            if let note = model.faceRecognitionNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Clustering sensitivity. Re-groups the existing faces as it moves.
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(
                    value: $model.faceClusterThreshold,
                    in: model.faceEngine.thresholdRange
                ) { editing in
                    // Re-cluster when the drag ends (not on every tick).
                    if !editing { model.reclusterFaces() }
                }
                .controlSize(.mini)
                .disabled(model.isClassifying || model.personList.isEmpty)
            }
            Text("Grouping: \(thresholdLabel)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.leading, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { model.refreshCoreMLFaceAvailability() }
        .onChange(of: model.faceEngine) { _, _ in
            model.refreshCoreMLFaceAvailability()
        }
    }

    /// A plain-language read of the threshold: lower is stricter (splits more),
    /// higher is looser (merges more).
    private var thresholdLabel: String {
        let range = model.faceEngine.thresholdRange
        let span = range.upperBound - range.lowerBound
        let t = (model.faceClusterThreshold - range.lowerBound) / span
        switch t {
        case ..<0.33: return "stricter"
        case ..<0.66: return "balanced"
        default: return "looser"
        }
    }
}

/// A disclosure-group header for the AI sidebar sections: a title plus a
/// trailing button that clears that section's classifications. Mirrors
/// `RootHeaderRow`'s layout so the clear button lines up with the count badges.
private struct SidebarSectionHeader: View {
    let title: String
    let clearHelp: String
    let onClear: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 20, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(clearHelp)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A sidebar row with its own selection highlight, so it looks selected whether
/// or not it sits inside a `DisclosureGroup`.
private struct SidebarLabel: View {
    let title: String
    let systemImage: String
    /// When set, tints just the leading icon (used for color-tag swatches) so
    /// the glyph keeps its color even when the row isn't selected.
    var iconTint: Color? = nil
    let count: Int?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(iconTint ?? (isSelected ? Color.white : Color.primary))
            }
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            Spacer(minLength: 4)
            if let count {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : .secondary)
            }
        }
        .padding(.vertical, 3)
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
