import SwiftUI

/// Sidebar showing the folder tree. Selecting a folder switches the grid to
/// `.folders` mode and shows that folder's direct contents.
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

    var body: some View {
        List {
            Section("Library") {
                Button {
                    model.showFlaggedOnly = false
                    model.mode = .flattened
                    model.selectedFolder = model.roots.first
                    focused = true
                } label: {
                    SidebarLabel(
                        title: "All Media",
                        systemImage: "square.grid.3x3",
                        count: nil,
                        isSelected: !model.showFlaggedOnly && model.mode == .flattened
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
                        .listRowInsets(Self.rowInsets)
                        .contextMenu {
                            Button("Remove Folder", role: .destructive) {
                                model.removeRoot(entry.key)
                            }
                        }
                    FolderRow(node: entry.tree, model: model, focused: $focused)
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

    @State private var isExpanded: Bool = true

    private var isSelected: Bool {
        !model.showFlaggedOnly && model.mode == .folders && model.selectedFolder == node.url
    }

    private var rowLabel: some View {
        Button {
            model.showFlaggedOnly = false
            model.mode = .folders
            model.selectedFolder = node.url
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

    private var title: String {
        entry.isSingleFile ? entry.key.lastPathComponent : entry.tree.name
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
        .padding(.vertical, 3)
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

/// A sidebar row with its own selection highlight, so it looks selected whether
/// or not it sits inside a `DisclosureGroup`.
private struct SidebarLabel: View {
    let title: String
    let systemImage: String
    let count: Int?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            Label(title, systemImage: systemImage)
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
