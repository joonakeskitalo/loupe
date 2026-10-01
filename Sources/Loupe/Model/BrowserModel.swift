import SwiftUI
import Observation

/// Whether the grid shows every file recursively or just one folder's files.
enum BrowseMode: String, CaseIterable {
    case flattened = "Flattened"
    case folders = "Folders"

    var symbol: String {
        switch self {
        case .flattened: return "square.grid.3x3"
        case .folders: return "folder"
        }
    }
}

enum SortOrder: String, CaseIterable {
    case name = "Name"
    case dateModified = "Date Modified"
    case size = "Size"
    case kind = "Kind"
}

@MainActor
@Observable
final class BrowserModel {
    private(set) var root: URL?
    private(set) var allItems: [MediaItem] = []
    private(set) var itemsByDirectory: [URL: [MediaItem]] = [:]
    private(set) var tree: FolderNode?
    private(set) var isScanning = false

    var mode: BrowseMode = .flattened {
        didSet { clampSelection() }
    }
    var sortOrder: SortOrder = .name
    var sortAscending = true
    var thumbnailSize: Double = 160

    /// The folder selected in the sidebar (used in `.folders` mode).
    var selectedFolder: URL? {
        didSet { clampSelection() }
    }

    /// The item currently selected in the grid.
    var selectedItem: MediaItem.ID?

    /// Whether the full-screen/detail viewer is presented.
    var isViewerPresented = false

    /// Number of columns currently shown in the grid, reported by the grid view
    /// so keyboard Up/Down navigation can jump a full row.
    var gridColumnCount = 1

    // Keep the security-scoped access alive for the dropped folder. We stop the
    // previous scope when opening a new folder; the OS reclaims any remaining
    // scope on process exit.
    private var scopedURL: URL?

    var rootName: String {
        root?.lastPathComponent ?? "Loupe"
    }

    func open(url: URL) {
        scopedURL?.stopAccessingSecurityScopedResource()
        let didScope = url.startAccessingSecurityScopedResource()
        scopedURL = didScope ? url : nil

        isScanning = true
        root = url.standardizedFileURL
        selectedFolder = url.standardizedFileURL
        selectedItem = nil

        Task {
            let result = await FolderScanner.scan(root: url)
            self.apply(result, resetSelectedFolder: true)
        }
    }

    /// Re-scans the current root, preserving the sidebar folder selection.
    func refresh() {
        guard let root else { return }
        let folderToKeep = selectedFolder
        isScanning = true
        Task {
            let result = await FolderScanner.scan(root: root)
            self.apply(result, resetSelectedFolder: false)
            // Restore the previously-selected folder if it still exists.
            if let folderToKeep, self.itemsByDirectory[folderToKeep] != nil
                || folderToKeep == result.root {
                self.selectedFolder = folderToKeep
            } else {
                self.selectedFolder = result.root
            }
        }
    }

    private func apply(_ result: ScanResult, resetSelectedFolder: Bool) {
        self.root = result.root
        self.allItems = result.allItems
        self.itemsByDirectory = result.itemsByDirectory
        self.tree = result.tree
        if resetSelectedFolder {
            self.selectedFolder = result.root
        }
        self.isScanning = false
    }

    /// Items displayed in the grid for the current mode and sort.
    var displayedItems: [MediaItem] {
        let base: [MediaItem]
        switch mode {
        case .flattened:
            base = allItems
        case .folders:
            if let folder = selectedFolder {
                base = itemsByDirectory[folder] ?? []
            } else {
                base = allItems
            }
        }
        return sorted(base)
    }

    private func sorted(_ items: [MediaItem]) -> [MediaItem] {
        let result: [MediaItem]
        switch sortOrder {
        case .name:
            result = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .dateModified:
            result = items.sorted { $0.modificationDate < $1.modificationDate }
        case .size:
            result = items.sorted { $0.fileSize < $1.fileSize }
        case .kind:
            result = items.sorted {
                if $0.kind.rawValue == $1.kind.rawValue {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return $0.kind.rawValue < $1.kind.rawValue
            }
        }
        return sortAscending ? result : result.reversed()
    }

    // MARK: - Selection helpers

    private func clampSelection() {
        let items = displayedItems
        if let sel = selectedItem, !items.contains(where: { $0.id == sel }) {
            selectedItem = items.first?.id
        }
    }

    var selectedMediaItem: MediaItem? {
        guard let id = selectedItem else { return nil }
        return displayedItems.first { $0.id == id }
    }

    func selectFirstIfNeeded() {
        if selectedItem == nil {
            selectedItem = displayedItems.first?.id
        }
    }

    func moveSelection(by offset: Int) {
        let items = displayedItems
        guard !items.isEmpty else { return }
        guard let current = selectedItem,
              let idx = items.firstIndex(where: { $0.id == current }) else {
            selectedItem = items.first?.id
            return
        }
        let next = (idx + offset).clamped(to: 0...(items.count - 1))
        selectedItem = items[next].id
    }

    /// Direction for grid keyboard navigation.
    enum MoveDirection { case left, right, up, down }

    /// Moves the grid selection in a direction, treating the grid as `columns`
    /// wide so Up/Down jump a full row.
    func moveSelection(_ direction: MoveDirection, columns: Int) {
        let items = displayedItems
        guard !items.isEmpty else { return }
        let cols = max(1, columns)

        guard let current = selectedItem,
              let idx = items.firstIndex(where: { $0.id == current }) else {
            selectedItem = items.first?.id
            return
        }

        let target: Int
        switch direction {
        case .left:  target = idx - 1
        case .right: target = idx + 1
        case .up:    target = idx - cols
        case .down:  target = idx + cols
        }
        guard target >= 0, target < items.count else { return }
        selectedItem = items[target].id
    }

    func toggleViewer() {
        if isViewerPresented {
            isViewerPresented = false
        } else {
            selectFirstIfNeeded()
            if selectedItem != nil {
                isViewerPresented = true
            }
        }
    }

    // MARK: - Folder (sidebar) navigation

    /// Folders in sidebar display order (depth-first pre-order from the root),
    /// matching how `FolderSidebar` renders its disclosure tree.
    var flatFolderOrder: [URL] {
        guard let tree else { return [] }
        var out: [URL] = []
        func visit(_ node: FolderNode) {
            out.append(node.url)
            for child in node.children { visit(child) }
        }
        visit(tree)
        return out
    }

    /// Moves the sidebar folder selection up/down the visible folder list and
    /// switches to `.folders` mode so the grid follows along.
    func moveFolderSelection(by offset: Int) {
        let folders = flatFolderOrder
        guard !folders.isEmpty else { return }

        let currentIndex = selectedFolder.flatMap { folders.firstIndex(of: $0) }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = (currentIndex + offset).clamped(to: 0...(folders.count - 1))
        } else {
            nextIndex = 0
        }
        mode = .folders
        selectedFolder = folders[nextIndex]
    }

    var statusText: String {
        let count = displayedItems.count
        let noun = count == 1 ? "item" : "items"
        if mode == .folders, let folder = selectedFolder {
            return "\(count) \(noun) in \(folder.lastPathComponent)"
        }
        return "\(count) \(noun)"
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
