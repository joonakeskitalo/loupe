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
    /// Root folders added to this window, in the order they were added.
    private(set) var roots: [URL] = []
    /// Per-root scan results, keyed by root URL.
    private var resultsByRoot: [URL: ScanResult] = [:]

    private(set) var allItems: [MediaItem] = []
    private(set) var itemsByDirectory: [URL: [MediaItem]] = [:]
    /// One folder tree per root, in `roots` order.
    private(set) var trees: [FolderNode] = []
    private(set) var isScanning = false

    /// True once at least one folder (or file) has been added.
    var hasContent: Bool { !roots.isEmpty }

    var mode: BrowseMode = .flattened {
        didSet {
            // When entering per-folder view with an image selected, jump the
            // sidebar to that image's parent folder so the selection stays
            // visible instead of showing an unrelated folder.
            if mode == .folders, oldValue != .folders,
               let item = primarySelectedItem {
                selectedFolder = item.parentDirectory
            }
            clampSelection()
        }
    }
    var sortOrder: SortOrder = .name
    var sortAscending = true
    var thumbnailSize: Double = 160

    /// The folder selected in the sidebar (used in `.folders` mode).
    var selectedFolder: URL? {
        didSet { clampSelection() }
    }

    /// The anchor/primary item: the moving cursor for arrow-key navigation.
    var selectedItem: MediaItem.ID?

    /// Fixed anchor for Shift range selection (click or Shift+arrow). The
    /// selected range always spans from this anchor to `selectedItem`.
    private var rangeAnchor: MediaItem.ID?

    /// All currently selected items (supports multi-selection).
    var selectedItems: Set<MediaItem.ID> = []

    /// Free-text filter, scoped to the current browse mode / selected folder.
    var searchText: String = "" {
        didSet { clampSelection() }
    }

    /// Files flagged "for later". In-session only: cleared when a new folder is
    /// opened and gone when the window closes (the model is per-window).
    var flaggedItems: Set<MediaItem.ID> = []

    /// When true, the grid shows only flagged items.
    var showFlaggedOnly = false {
        didSet { clampSelection() }
    }

    /// Active media-type chip filters (empty = all types).
    var selectedKinds: Set<MediaKind> = [] {
        didSet { clampSelection() }
    }

    /// Active file-extension chip filters, lowercased (empty = all extensions).
    var selectedExtensions: Set<String> = [] {
        didSet { clampSelection() }
    }

    /// Whether the full-screen/detail viewer is presented.
    var isViewerPresented = false

    /// Number of columns currently shown in the grid, reported by the grid view
    /// so keyboard Up/Down navigation can jump a full row.
    var gridColumnCount = 1

    // Security-scoped access is kept alive per root for the lifetime of the
    // window; stopped when a root is removed. The OS reclaims the rest on exit.
    private var scopedURLs: Set<URL> = []
    /// Single-file roots (dropped files whose folder couldn't be enumerated),
    /// so refresh/merge treats them specially.
    private var singleFileRoots: Set<URL> = []

    /// Window title: the folder name for a single root, else a folder count.
    var rootName: String {
        switch roots.count {
        case 0: return "Loupe"
        case 1: return roots[0].lastPathComponent
        default: return "\(roots.count) Folders"
        }
    }

    /// Adds a folder as an additional root (or the first one). Existing roots
    /// are kept; the new folder's contents are merged in.
    func open(url: URL) {
        let root = url.standardizedFileURL
        guard !roots.contains(root) else { return }   // already added

        if scopeAccess(root) { scopedURLs.insert(root) }
        roots.append(root)
        isScanning = true
        if selectedFolder == nil { selectedFolder = root }

        Task {
            await Task.yield()
            let result = await FolderScanner.scan(root: root)
            self.resultsByRoot[root] = result
            self.rebuildMerged()
            self.isScanning = false
        }
    }

    /// Adds a dropped single file. If its folder can't be enumerated (sandbox),
    /// the file is added as a single-file root.
    func openFile(_ fileURL: URL) {
        let file = fileURL.standardizedFileURL
        let parent = file.deletingLastPathComponent()

        if scopeAccess(file) { scopedURLs.insert(file) }
        isScanning = true

        Task {
            await Task.yield()
            let result = await FolderScanner.scan(root: parent)
            if result.allItems.contains(where: { $0.id == file }),
               !self.roots.contains(parent) {
                // Folder is readable: add it as a normal root, select the file.
                self.roots.append(parent)
                self.resultsByRoot[parent] = result
                self.rebuildMerged()
                self.selectOnly(file)
            } else {
                // Add just the file as a single-file root.
                self.addSingleFileRoot(file)
            }
            self.isScanning = false
        }
    }

    private func addSingleFileRoot(_ file: URL) {
        guard !roots.contains(file) else { selectOnly(file); return }
        let item = MediaItem(url: file)
        let parent = file.deletingLastPathComponent()

        // The sidebar node represents the file's PARENT directory (not the file
        // itself), and items are keyed under that directory — so selecting the
        // sidebar row in Folders mode finds the file. The root is still keyed by
        // the file URL in `roots`/`resultsByRoot`/`singleFileRoots` so it has a
        // unique identity and can be removed independently.
        let node = FolderNode(url: parent, children: [], directMediaCount: 1)
        let result = ScanResult(
            root: parent,
            allItems: [item],
            itemsByDirectory: [parent: [item]],
            tree: node
        )
        roots.append(file)
        singleFileRoots.insert(file)
        resultsByRoot[file] = result
        rebuildMerged()
        selectOnly(file)
    }

    /// Removes a root folder, releasing its security scope and un-merging it.
    func removeRoot(_ root: URL) {
        let std = root.standardizedFileURL
        guard roots.contains(std) else { return }
        if scopedURLs.remove(std) != nil {
            std.stopAccessingSecurityScopedResource()
        }
        roots.removeAll { $0 == std }
        resultsByRoot[std] = nil
        singleFileRoots.remove(std)
        if selectedFolder == std || !(selectedFolder.map(allDirectories.contains) ?? false) {
            selectedFolder = roots.first
        }
        rebuildMerged()
    }

    /// Re-scans every root, preserving the sidebar folder selection.
    func refresh() {
        guard !roots.isEmpty else { return }
        let folderToKeep = selectedFolder
        isScanning = true
        let currentRoots = roots
        Task {
            for root in currentRoots where !self.singleFileRoots.contains(root) {
                let result = await FolderScanner.scan(root: root)
                self.resultsByRoot[root] = result
            }
            self.rebuildMerged()
            if let folderToKeep, self.allDirectories.contains(folderToKeep) {
                self.selectedFolder = folderToKeep
            } else {
                self.selectedFolder = self.roots.first
            }
            self.isScanning = false
        }
    }

    /// A root paired with its tree, for the sidebar. `key` is the stable root
    /// identity used for removal (the file URL for single-file roots); `tree`
    /// is what to render (its parent directory for single-file roots).
    struct RootEntry: Identifiable {
        let key: URL
        let tree: FolderNode
        var id: URL { key }
        var isSingleFile: Bool
    }

    var rootEntries: [RootEntry] {
        roots.compactMap { root in
            guard let result = resultsByRoot[root] else { return nil }
            return RootEntry(key: root, tree: result.tree,
                             isSingleFile: singleFileRoots.contains(root))
        }
    }

    /// Merge all per-root scan results into the flattened item list, the
    /// directory map, and the ordered list of trees.
    private func rebuildMerged() {
        var merged: [MediaItem] = []
        var byDir: [URL: [MediaItem]] = [:]
        var newTrees: [FolderNode] = []

        for root in roots {
            guard let result = resultsByRoot[root] else { continue }
            merged.append(contentsOf: result.allItems)
            for (dir, items) in result.itemsByDirectory {
                byDir[dir, default: []].append(contentsOf: items)
            }
            newTrees.append(result.tree)
        }

        merged.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        allItems = merged
        itemsByDirectory = byDir
        trees = newTrees
        clampSelection()
    }

    /// All directory URLs across every root's tree (used to validate the
    /// sidebar selection after changes).
    private var allDirectories: Set<URL> {
        var out: Set<URL> = []
        func visit(_ node: FolderNode) {
            out.insert(node.url)
            for c in node.children { visit(c) }
        }
        trees.forEach(visit)
        return out
    }

    private func scopeAccess(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    /// Items in the current scope (folder/flag) after the text search, but
    /// BEFORE the type/extension chip filters. Chip availability and counts are
    /// derived from this set so selecting a chip never makes other chips vanish.
    var scopedItems: [MediaItem] {
        var base: [MediaItem]
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

        if showFlaggedOnly {
            base = base.filter { flaggedItems.contains($0.id) }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            base = base.filter {
                $0.name.localizedCaseInsensitiveContains(query)
            }
        }
        return base
    }

    /// Items displayed in the grid: the scoped set with the active type and
    /// extension chip filters applied, then sorted.
    var displayedItems: [MediaItem] {
        sorted(scopedItems.filter { passesChipFilters($0) })
    }

    private func passesChipFilters(_ item: MediaItem) -> Bool {
        if !selectedKinds.isEmpty, !selectedKinds.contains(item.kind) {
            return false
        }
        if !selectedExtensions.isEmpty,
           !selectedExtensions.contains(item.url.pathExtension.lowercased()) {
            return false
        }
        return true
    }

    // MARK: - Filter chips

    struct KindChip: Identifiable, Hashable {
        let kind: MediaKind
        let count: Int
        var id: MediaKind { kind }
    }

    struct ExtensionChip: Identifiable, Hashable {
        let ext: String        // lowercased, no dot
        let count: Int
        var id: String { ext }
    }

    /// Media-type chips available in the current scope, with counts, ordered by
    /// a stable kind order. Derived from `scopedItems` so chips are stable.
    var availableKindChips: [KindChip] {
        var counts: [MediaKind: Int] = [:]
        for item in scopedItems { counts[item.kind, default: 0] += 1 }
        let order: [MediaKind] = [.image, .video, .pdf, .audio, .markdown, .text, .other]
        return order.compactMap { kind in
            guard let c = counts[kind], c > 0 else { return nil }
            return KindChip(kind: kind, count: c)
        }
    }

    /// Extension chips available in the current scope, with counts, ordered by
    /// descending count then alphabetically.
    var availableExtensionChips: [ExtensionChip] {
        var counts: [String: Int] = [:]
        for item in scopedItems {
            let ext = item.url.pathExtension.lowercased()
            guard !ext.isEmpty else { continue }
            counts[ext, default: 0] += 1
        }
        return counts
            .map { ExtensionChip(ext: $0.key, count: $0.value) }
            .sorted {
                $0.count != $1.count ? $0.count > $1.count : $0.ext < $1.ext
            }
    }

    var hasActiveChipFilters: Bool {
        !selectedKinds.isEmpty || !selectedExtensions.isEmpty
    }

    /// Click a type chip. A plain click replaces the whole chip filter with
    /// just this type (clicking the only active chip clears it). An additive
    /// click (Shift/Command) toggles this type within the current selection.
    func selectKind(_ kind: MediaKind, additive: Bool) {
        if additive {
            if selectedKinds.contains(kind) {
                selectedKinds.remove(kind)
            } else {
                selectedKinds.insert(kind)
            }
        } else {
            let isOnlyThis = selectedKinds == [kind] && selectedExtensions.isEmpty
            selectedExtensions = []
            selectedKinds = isOnlyThis ? [] : [kind]
        }
    }

    /// Click an extension chip. Mirrors `selectKind`.
    func selectExtension(_ ext: String, additive: Bool) {
        let key = ext.lowercased()
        if additive {
            if selectedExtensions.contains(key) {
                selectedExtensions.remove(key)
            } else {
                selectedExtensions.insert(key)
            }
        } else {
            let isOnlyThis = selectedExtensions == [key] && selectedKinds.isEmpty
            selectedKinds = []
            selectedExtensions = isOnlyThis ? [] : [key]
        }
    }

    func clearChipFilters() {
        selectedKinds = []
        selectedExtensions = []
    }

    /// Human-readable description of where search is scoped right now.
    var searchScopeName: String {
        if showFlaggedOnly {
            return "Flagged"
        }
        if mode == .folders, let folder = selectedFolder {
            return folder.lastPathComponent
        }
        return "All Media"
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

    /// Drops any selected ids that are no longer in the displayed set (e.g.
    /// after a mode switch, folder change, or search filter).
    private func clampSelection() {
        let valid = Set(displayedItems.map(\.id))
        // Only prune ids that are no longer visible — never force a fallback
        // selection, so an empty selection is a valid state.
        selectedItems.formIntersection(valid)
        if let sel = selectedItem, !valid.contains(sel) {
            // Keep the anchor within the surviving selection if any remains,
            // otherwise clear it.
            selectedItem = selectedItems.first
        }
        if let anchor = rangeAnchor, !valid.contains(anchor) {
            rangeAnchor = selectedItem
        }
    }

    /// Clear the entire selection (Escape / click on empty space).
    func clearSelection() {
        selectedItems = []
        selectedItem = nil
        rangeAnchor = nil
    }

    // MARK: - Grid zoom

    static let minThumbnailSize: Double = 90
    static let maxThumbnailSize: Double = 320
    private static let thumbnailStep: Double = 40

    func zoomGridIn() {
        thumbnailSize = min(Self.maxThumbnailSize, thumbnailSize + Self.thumbnailStep)
    }

    func zoomGridOut() {
        thumbnailSize = max(Self.minThumbnailSize, thumbnailSize - Self.thumbnailStep)
    }

    /// The primary selected item, resolved against the full item list so it is
    /// available regardless of the current browse mode / folder.
    var primarySelectedItem: MediaItem? {
        guard let id = selectedItem else { return nil }
        return allItems.first { $0.id == id }
    }

    /// The single primary item (used by the viewer when only one is selected).
    var selectedMediaItem: MediaItem? {
        guard let id = selectedItem else { return nil }
        return displayedItems.first { $0.id == id }
    }

    /// All selected items in display order (used by the multi-item viewer).
    var selectedMediaItems: [MediaItem] {
        displayedItems.filter { selectedItems.contains($0.id) }
    }

    func selectFirstIfNeeded() {
        if selectedItem == nil || selectedItems.isEmpty {
            if let first = displayedItems.first?.id {
                selectOnly(first)
            }
        }
    }

    /// Replace the selection with an explicit set of ids (used by rubber-band
    /// marquee selection). Items are ordered by their position in the grid so
    /// the primary/anchor stays sensible.
    func setSelection(_ ids: [MediaItem.ID]) {
        let set = Set(ids)
        if set.isEmpty {
            selectedItems = []
            selectedItem = nil
            return
        }
        selectedItems = set
        // Keep the anchor/primary within the new set, in display order.
        let ordered = displayedItems.map(\.id).filter { set.contains($0) }
        selectedItem = ordered.last
        if rangeAnchor == nil || !set.contains(rangeAnchor!) {
            rangeAnchor = ordered.first
        }
    }

    /// Select every item currently shown in the grid (Cmd+A).
    func selectAll() {
        let items = displayedItems
        guard !items.isEmpty else { return }
        selectedItems = Set(items.map(\.id))
        selectedItem = items.last?.id
        rangeAnchor = items.first?.id
    }

    // MARK: Selection mutations (driven by clicks)

    /// Replace the selection with a single item (plain click).
    func selectOnly(_ id: MediaItem.ID) {
        selectedItem = id
        rangeAnchor = id
        selectedItems = [id]
    }

    /// Toggle an item in/out of the selection (Command-click).
    func toggleSelection(_ id: MediaItem.ID) {
        if selectedItems.contains(id) {
            selectedItems.remove(id)
            if selectedItem == id {
                selectedItem = selectedItems.first
            }
        } else {
            selectedItems.insert(id)
            selectedItem = id
        }
        rangeAnchor = selectedItem
    }

    /// Select the contiguous range from the anchor to `id` (Shift-click).
    func extendSelection(to id: MediaItem.ID) {
        let items = displayedItems
        guard let anchor = rangeAnchor ?? selectedItem ?? selectedItems.first,
              let a = items.firstIndex(where: { $0.id == anchor }),
              let b = items.firstIndex(where: { $0.id == id }) else {
            selectOnly(id)
            return
        }
        if rangeAnchor == nil { rangeAnchor = anchor }
        let range = min(a, b)...max(a, b)
        selectedItems = Set(items[range].map(\.id))
        selectedItem = id
    }

    func moveSelection(by offset: Int) {
        let items = displayedItems
        guard !items.isEmpty else { return }
        guard let current = selectedItem,
              let idx = items.firstIndex(where: { $0.id == current }) else {
            selectOnly(items[0].id)
            return
        }
        let next = (idx + offset).clamped(to: 0...(items.count - 1))
        selectOnly(items[next].id)
    }

    /// Direction for grid keyboard navigation.
    enum MoveDirection { case left, right, up, down }

    /// Moves the grid selection in a direction, treating the grid as `columns`
    /// wide so Up/Down jump a full row.
    ///
    /// With `extend: false` this sets a single selection. With `extend: true`
    /// (Shift+arrow) it keeps the range anchor fixed and selects everything
    /// between the anchor and the moved cursor, so the selection grows and
    /// shrinks like a standard range selection.
    func moveSelection(_ direction: MoveDirection, columns: Int, extend: Bool = false) {
        let items = displayedItems
        guard !items.isEmpty else { return }
        let cols = max(1, columns)

        guard let current = selectedItem,
              let idx = items.firstIndex(where: { $0.id == current }) else {
            selectOnly(items[0].id)
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

        if extend {
            // Establish an anchor the first time we start extending.
            let anchorID = rangeAnchor ?? current
            rangeAnchor = anchorID
            let anchorIdx = items.firstIndex { $0.id == anchorID } ?? idx
            let range = min(anchorIdx, target)...max(anchorIdx, target)
            selectedItems = Set(items[range].map(\.id))
            selectedItem = items[target].id
        } else {
            selectOnly(items[target].id)
        }
    }

    func toggleViewer() {
        if isViewerPresented {
            isViewerPresented = false
        } else {
            selectFirstIfNeeded()
            if !selectedItems.isEmpty {
                isViewerPresented = true
            }
        }
    }

    // MARK: - Flagging

    func isFlagged(_ id: MediaItem.ID) -> Bool {
        flaggedItems.contains(id)
    }

    /// Toggle the flag on the given item, or on the whole current selection.
    /// If any target is unflagged, flag them all; otherwise unflag them all.
    func toggleFlag(_ item: MediaItem? = nil) {
        let targets: [MediaItem.ID]
        if let item, !selectedItems.contains(item.id) {
            targets = [item.id]
        } else if !selectedItems.isEmpty {
            targets = Array(selectedItems)
        } else if let item {
            targets = [item.id]
        } else {
            return
        }

        let anyUnflagged = targets.contains { !flaggedItems.contains($0) }
        if anyUnflagged {
            flaggedItems.formUnion(targets)
        } else {
            flaggedItems.subtract(targets)
        }
        clampSelection()
    }

    func clearFlags() {
        flaggedItems = []
        clampSelection()
    }

    var flaggedCount: Int { flaggedItems.count }

    // MARK: - File actions

    /// URLs for the current selection, falling back to a specific item when the
    /// action is invoked on an unselected row (e.g. a right-click).
    func actionURLs(preferring item: MediaItem? = nil) -> [URL] {
        if let item, !selectedItems.contains(item.id) {
            return [item.url]
        }
        let selected = selectedMediaItems.map(\.url)
        if !selected.isEmpty { return selected }
        if let item { return [item.url] }
        return []
    }

    /// Open the given items (or the current selection) in their default apps.
    func openInDefaultApp(_ item: MediaItem? = nil) {
        for url in actionURLs(preferring: item) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reveal the given items (or the current selection) in Finder.
    func revealInFinder(_ item: MediaItem? = nil) {
        let urls = actionURLs(preferring: item)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Folder (sidebar) navigation

    /// Folders in sidebar display order (depth-first pre-order from the root),
    /// matching how `FolderSidebar` renders its disclosure tree.
    var flatFolderOrder: [URL] {
        var out: [URL] = []
        func visit(_ node: FolderNode) {
            out.append(node.url)
            for child in node.children { visit(child) }
        }
        trees.forEach(visit)
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
        var base: String
        if showFlaggedOnly {
            base = "\(count) flagged \(noun)"
        } else if mode == .folders, let folder = selectedFolder {
            base = "\(count) \(noun) in \(folder.lastPathComponent)"
        } else {
            base = "\(count) \(noun)"
        }
        if selectedItems.count > 1 {
            base += " · \(selectedItems.count) selected"
        }
        // Avoid a redundant "flagged" mention when already in the flagged view.
        if flaggedCount > 0, !showFlaggedOnly {
            base += " · \(flaggedCount) flagged"
        }
        return base
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
