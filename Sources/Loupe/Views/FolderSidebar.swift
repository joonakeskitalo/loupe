import SwiftUI

/// Sidebar showing the folder tree. Selecting a folder switches the grid to
/// `.folders` mode and shows that folder's direct contents.
struct FolderSidebar: View {
    @Bindable var model: BrowserModel

    var body: some View {
        List(selection: Binding(
            get: { model.selectedFolder },
            set: { newValue in
                if let newValue {
                    model.selectedFolder = newValue
                    model.mode = .folders
                }
            }
        )) {
            Section("Library") {
                Label("All Media", systemImage: "square.grid.3x3")
                    .tag(Optional<URL>.none)
                    .foregroundStyle(model.mode == .flattened ? Color.accentColor : Color.primary)
                    .onTapGesture {
                        model.mode = .flattened
                        model.selectedFolder = model.root
                    }
            }

            if let tree = model.tree {
                Section("Folders") {
                    FolderRow(node: tree, model: model, level: 0)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// Recursive disclosure row for a folder and its children.
private struct FolderRow: View {
    let node: FolderNode
    @Bindable var model: BrowserModel
    let level: Int

    @State private var isExpanded: Bool = true

    var body: some View {
        if node.children.isEmpty {
            label
                .tag(Optional(node.url))
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children) { child in
                    FolderRow(node: child, model: model, level: level + 1)
                }
            } label: {
                label
                    .tag(Optional(node.url))
            }
        }
    }

    private var label: some View {
        HStack {
            Label(node.name, systemImage: "folder")
                .lineLimit(1)
            Spacer()
            if node.directMediaCount > 0 {
                Text("\(node.directMediaCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.mode = .folders
            model.selectedFolder = node.url
        }
    }
}
