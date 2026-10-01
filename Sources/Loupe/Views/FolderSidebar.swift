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
                    model.mode = .flattened
                    model.selectedFolder = model.root
                    focused = true
                } label: {
                    SidebarLabel(
                        title: "All Media",
                        systemImage: "square.grid.3x3",
                        count: nil,
                        isSelected: model.mode == .flattened
                    )
                }
                .buttonStyle(.plain)
            }

            if let tree = model.tree {
                Section("Folders") {
                    FolderRow(node: tree, model: model, focused: $focused)
                }
            }
        }
        .listStyle(.sidebar)
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
}

/// Recursive disclosure row for a folder and its children.
private struct FolderRow: View {
    let node: FolderNode
    @Bindable var model: BrowserModel
    var focused: FocusState<Bool>.Binding

    @State private var isExpanded: Bool = true

    private var isSelected: Bool {
        model.mode == .folders && model.selectedFolder == node.url
    }

    private var rowLabel: some View {
        Button {
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
