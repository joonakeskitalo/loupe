import Foundation

/// A node in the folder tree shown in the sidebar.
///
/// Immutable after construction, so it is safe to pass across concurrency
/// boundaries (`@unchecked Sendable`): all stored properties are value types
/// or arrays of other immutable `FolderNode`s.
final class FolderNode: Identifiable, Hashable, @unchecked Sendable {
    let id: URL
    let url: URL
    let name: String
    let children: [FolderNode]
    /// Number of previewable media files directly in this folder (non-recursive).
    let directMediaCount: Int

    init(url: URL, children: [FolderNode] = [], directMediaCount: Int = 0) {
        self.id = url
        self.url = url
        self.name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        self.children = children
        self.directMediaCount = directMediaCount
    }

    static func == (lhs: FolderNode, rhs: FolderNode) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}
