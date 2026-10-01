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
                }
                .buttonStyle(.plain)

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
                }
                .buttonStyle(.plain)
                .disabled(model.flaggedCount == 0 && !model.showFlaggedOnly)
            }

            // One section per root, each with its own tree and a Remove action.
            // We iterate root entries (keyed by the stable root identity) rather
            // than the trees, so a single dropped file — whose tree node is its
            // parent directory — still removes correctly and stays unique.
            ForEach(model.rootEntries) { entry in
                Section {
                    FolderRow(node: entry.tree, model: model, focused: $focused)
                } header: {
                    HStack {
                        Text(entry.isSingleFile ? entry.key.lastPathComponent : entry.tree.name)
                        Spacer()
                        Button {
                            model.removeRoot(entry.key)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove this folder from the window")
                    }
                    .contextMenu {
                        Button("Remove Folder", role: .destructive) {
                            model.removeRoot(entry.key)
                        }
                    }
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
            }
        }
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
        HStack {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let count {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : .secondary)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
