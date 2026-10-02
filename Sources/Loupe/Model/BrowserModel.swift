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

/// Whether files are shown as a thumbnail grid or a detailed list.
enum ViewLayout: String, CaseIterable {
    case grid = "Grid"
    case list = "List"

    var symbol: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

enum SortOrder: String, CaseIterable {
    case name = "Name"
    case dateCreated = "Date Created"
    case dateModified = "Date Modified"
    case size = "Size"
    case kind = "Kind"
    case type = "File Type"
    case codec = "Video Codec"
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
            invalidateDisplayCache()
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
    var sortOrder: SortOrder = .name {
        didSet {
            invalidateDisplayCache()
            if sortOrder == .codec { prefetchCodecs() }
        }
    }
    var sortAscending = true {
        didSet { invalidateDisplayCache() }
    }

    /// Resolved video codec names keyed by file URL, used to sort by codec.
    /// Populated lazily in the background when a codec sort is active; items
    /// not yet resolved sort to the end. Observable so the grid/list re-sort as
    /// codecs arrive.
    private(set) var codecsByURL: [URL: String] = [:]

    /// Guards against launching more than one codec prefetch pass at a time.
    private var isPrefetchingCodecs = false

    /// Grid and list keep independent zoom levels. Grid starts at a comfortable
    /// mid size; list starts at the minimum so rows are compact by default.
    var gridThumbnailSize: Double = 160
    var listThumbnailSize: Double = BrowserModel.minThumbnailSize

    /// The zoom level for the active layout. Reads/writes the grid or list value
    /// depending on `viewLayout`, so the toolbar slider and zoom commands drive
    /// whichever view is currently shown.
    var thumbnailSize: Double {
        get { viewLayout == .grid ? gridThumbnailSize : listThumbnailSize }
        set {
            if viewLayout == .grid {
                gridThumbnailSize = newValue
            } else {
                listThumbnailSize = newValue
            }
        }
    }

    /// Whether files are shown as a thumbnail grid or a detailed list.
    var viewLayout: ViewLayout = .grid

    /// All folders selected in the sidebar (used in `.folders` mode). Supports
    /// multi-selection; the grid shows the union of every selected folder.
    var selectedFolders: Set<URL> = [] {
        didSet { clampSelection() }
    }

    /// The anchor/primary selected folder: the folder most recently clicked and
    /// the cursor for arrow-key navigation. Kept in sync with `selectedFolders`.
    private(set) var folderAnchor: URL?

    /// Backwards-compatible single-folder accessor. Reading returns the anchor
    /// (or any member); writing replaces the whole selection with one folder
    /// (or clears it when set to nil).
    var selectedFolder: URL? {
        get { folderAnchor ?? selectedFolders.first }
        set {
            if let newValue {
                selectedFolders = [newValue]
                folderAnchor = newValue
            } else {
                selectedFolders = []
                folderAnchor = nil
            }
        }
    }

    /// When true, a selected folder also shows media from all of its
    /// subdirectories; when false, only files directly inside it.
    var includeSubfolders = false {
        didSet { clampSelection() }
    }

    /// Selects a single folder, replacing any existing selection.
    func selectFolder(_ url: URL) {
        selectedFolders = [url]
        folderAnchor = url
    }

    /// Toggles a folder in/out of the current multi-selection (Cmd-click).
    func toggleFolderSelection(_ url: URL) {
        if selectedFolders.contains(url) {
            selectedFolders.remove(url)
            if folderAnchor == url { folderAnchor = selectedFolders.first }
        } else {
            selectedFolders.insert(url)
            folderAnchor = url
        }
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

    /// Whether the film strip of thumbnails is shown in the single-item viewer.
    var isFilmStripVisible = true

    /// Height of the film strip (its thumbnails scale to fill it). Clamped to
    /// `filmStripHeightRange` when set so a drag can't push it out of bounds.
    var filmStripHeight: Double = 96 {
        didSet {
            let clamped = min(max(filmStripHeight, Self.filmStripHeightRange.lowerBound),
                              Self.filmStripHeightRange.upperBound)
            if clamped != filmStripHeight { filmStripHeight = clamped }
        }
    }

    /// Allowed range for `filmStripHeight`, in points.
    static let filmStripHeightRange: ClosedRange<Double> = 64...240

    /// Toggles film strip visibility.
    func toggleFilmStrip() { isFilmStripVisible.toggle() }

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
        rebuildMerged()
        // Drop any selected folders that belonged to the removed root; if the
        // selection becomes empty, fall back to the first remaining root.
        let valid = allDirectories
        selectedFolders = selectedFolders.filter(valid.contains)
        if let anchor = folderAnchor, !valid.contains(anchor) {
            folderAnchor = selectedFolders.first
        }
        if selectedFolders.isEmpty, let first = roots.first {
            selectFolder(first)
        }
    }

    /// Re-scans every root, preserving the sidebar folder selection.
    func refresh() {
        guard !roots.isEmpty else { return }
        let foldersToKeep = selectedFolders
        let anchorToKeep = folderAnchor
        isScanning = true
        let currentRoots = roots
        Task {
            for root in currentRoots where !self.singleFileRoots.contains(root) {
                let result = await FolderScanner.scan(root: root)
                self.resultsByRoot[root] = result
            }
            self.rebuildMerged()
            let valid = self.allDirectories
            let kept = foldersToKeep.filter(valid.contains)
            if kept.isEmpty {
                if let first = self.roots.first { self.selectFolder(first) }
            } else {
                self.selectedFolders = kept
                if let anchor = anchorToKeep, valid.contains(anchor) {
                    self.folderAnchor = anchor
                } else {
                    self.folderAnchor = kept.first
                }
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
        pruneStaleChipFilters()
        clampSelection()
        // Keep codec data current for a codec sort as folders are added/rescanned.
        if sortOrder == .codec { prefetchCodecs() }
    }

    /// Drops any active type/extension chip filters that no longer have a
    /// matching file after a rescan (e.g. the last file of that type was
    /// deleted, then the folder was refreshed). Without this the grid gets
    /// stuck on a "No Matching Files" state filtered by a type that's gone.
    private func pruneStaleChipFilters() {
        let availableKinds = Set(allItems.map(\.kind))
        let availableExts = Set(allItems.map { $0.url.pathExtension.lowercased() })
        selectedKinds.formIntersection(availableKinds)
        selectedExtensions.formIntersection(availableExts)
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

    /// Directories whose direct contents should be shown for the current
    /// folder selection: every selected folder, plus (when `includeSubfolders`
    /// is on) all of their descendant directories.
    private func scopedDirectories() -> Set<URL> {
        guard !selectedFolders.isEmpty else { return [] }
        guard includeSubfolders else { return selectedFolders }

        // Walk the folder trees to collect each selected folder's subtree.
        var out: Set<URL> = []
        func collect(_ node: FolderNode) {
            out.insert(node.url)
            for child in node.children { collect(child) }
        }
        func find(_ node: FolderNode) {
            if selectedFolders.contains(node.url) {
                collect(node)
            } else {
                for child in node.children { find(child) }
            }
        }
        trees.forEach(find)
        // Fall back to the selected folders themselves if the tree lookup
        // somehow missed them (e.g. single-file roots).
        return out.union(selectedFolders)
    }

    /// The union of media items across every selected folder (and their
    /// subfolders when `includeSubfolders` is on), de-duplicated and sorted.
    private func itemsInSelectedFolders() -> [MediaItem] {
        let dirs = scopedDirectories()
        var seen = Set<MediaItem.ID>()
        var out: [MediaItem] = []
        for dir in dirs {
            for item in itemsByDirectory[dir] ?? [] where seen.insert(item.id).inserted {
                out.append(item)
            }
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
            if selectedFolders.isEmpty {
                base = allItems
            } else {
                base = itemsInSelectedFolders()
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

    /// Memoized result of `displayedItems`. `displayedItems` is read many times
    /// per UI update (toolbar enablement, status text, selection helpers, the
    /// grid/list body), and recomputing it each time means re-filtering and
    /// re-sorting the whole list on every read. That was cheap for Name/Size
    /// but expensive for the codec sort — and the codec prefetch invalidates
    /// repeatedly, so the cost multiplied into a visible freeze. We cache the
    /// result and rebuild it only when an input actually changes (see
    /// `invalidateDisplayCache`). Not observed, so filling it during a read
    /// doesn't itself trigger observation.
    @ObservationIgnored private var cachedDisplayedItems: [MediaItem]?

    /// Observed revision token. `invalidateDisplayCache` bumps it, and
    /// `displayedItems` reads it, so SwiftUI registers a dependency on the
    /// revision rather than on the (ignored) cache storage — views still
    /// re-render when the displayed list changes, even though the heavy inputs
    /// aren't read on a cache hit.
    private var displayRevision = 0

    /// Items displayed in the grid: the scoped set with the active type and
    /// extension chip filters applied, then sorted. Memoized.
    var displayedItems: [MediaItem] {
        // Establishes the observation dependency (see `displayRevision`).
        _ = displayRevision
        if let cachedDisplayedItems { return cachedDisplayedItems }
        let result = sorted(scopedItems.filter { passesChipFilters($0) })
        cachedDisplayedItems = result
        return result
    }

    /// Clears the memoized `displayedItems` so the next read rebuilds it, and
    /// bumps the observed revision so views re-render. Called whenever anything
    /// the sort/filter/scope depends on changes.
    private func invalidateDisplayCache() {
        cachedDisplayedItems = nil
        displayRevision &+= 1
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
    /// An actively-selected kind is always included (count 0 if the current
    /// scope has none) so the user can still see and clear it after changing
    /// to a folder that lacks that type.
    var availableKindChips: [KindChip] {
        var counts: [MediaKind: Int] = [:]
        for item in scopedItems { counts[item.kind, default: 0] += 1 }
        let order: [MediaKind] = [.image, .video, .pdf, .audio, .markdown, .text, .other]
        return order.compactMap { kind in
            let c = counts[kind] ?? 0
            guard c > 0 || selectedKinds.contains(kind) else { return nil }
            return KindChip(kind: kind, count: c)
        }
    }

    /// Extension chips available in the current scope, with counts, ordered by
    /// descending count then alphabetically. An actively-selected extension is
    /// always included (count 0 if the current scope has none) so the user can
    /// still see and clear it after changing to a folder that lacks it.
    var availableExtensionChips: [ExtensionChip] {
        var counts: [String: Int] = [:]
        for item in scopedItems {
            let ext = item.url.pathExtension.lowercased()
            guard !ext.isEmpty else { continue }
            counts[ext, default: 0] += 1
        }
        // Ensure selected extensions appear even with no matches in this scope.
        for ext in selectedExtensions where counts[ext] == nil {
            counts[ext] = 0
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
        if mode == .folders, !selectedFolders.isEmpty {
            if selectedFolders.count == 1, let folder = selectedFolders.first {
                return folder.lastPathComponent
            }
            return "\(selectedFolders.count) Folders"
        }
        return "All Media"
    }

    /// Resolves the video codec for every video item that isn't cached yet,
    /// used by the `.codec` sort.
    ///
    /// Two things keep this from making the list sluggish:
    ///  - Probes run concurrently (bounded), so codecs resolve quickly instead
    ///    of trickling in one `await` at a time.
    ///  - Results are published to the observable `codecsByURL` in batches, not
    ///    per item. Each publish re-runs the sort over the whole list, so
    ///    writing once per item would re-sort N times; batching collapses that
    ///    into a few re-sorts while still updating the view as data arrives.
    ///
    /// Safe to call repeatedly; a single pass runs at a time and already-cached
    /// items are skipped.
    func prefetchCodecs() {
        guard !isPrefetchingCodecs else { return }
        let pending = allItems.filter {
            $0.kind == .video && codecsByURL[$0.url] == nil
        }
        guard !pending.isEmpty else { return }

        isPrefetchingCodecs = true
        Task { @MainActor in
            // Probe concurrently with a bounded window so we don't open a
            // thousand files at once, collecting (url, codec) pairs as they
            // finish and publishing them to the observable map in batches.
            let maxConcurrent = 6
            var batch: [(URL, String)] = []

            await withTaskGroup(of: (URL, String).self) { group in
                var iterator = pending.makeIterator()

                func addNext() {
                    guard let item = iterator.next() else { return }
                    group.addTask {
                        let meta = await VideoMetadataProvider.shared.metadata(
                            for: item.url, kind: .video
                        )
                        // Empty string marks "probed, codec unknown" so the next
                        // pass skips it.
                        return (item.url, meta.codec ?? "")
                    }
                }

                for _ in 0..<maxConcurrent { addNext() }

                while let result = await group.next() {
                    batch.append(result)
                    // Publish a batch at a time so the view updates
                    // progressively without a full re-sort per probe.
                    if batch.count >= maxConcurrent {
                        self.storeCodecs(batch)
                        batch.removeAll(keepingCapacity: true)
                    }
                    addNext()
                }
            }
            self.storeCodecs(batch)
            self.isPrefetchingCodecs = false
        }
    }

    /// Publishes a batch of resolved codecs to the observable map in one go.
    /// Called on the main actor; a single call triggers at most one re-sort of
    /// the displayed list rather than one per probed file.
    private func storeCodecs(_ results: [(URL, String)]) {
        guard !results.isEmpty else { return }
        for (url, codec) in results { codecsByURL[url] = codec }
        // Codec order depends on this map, so the memoized list is now stale.
        // Only the codec sort cares; skip the churn otherwise.
        if sortOrder == .codec { invalidateDisplayCache() }
    }

    /// Applies a sort field and direction together. Used by the quick-sort
    /// buttons/hotkeys so one action sets both the field and whether it's
    /// ascending in a single step.
    func applySort(_ order: SortOrder, ascending: Bool) {
        sortOrder = order
        sortAscending = ascending
    }

    /// Quick sort: Name, A→Z.
    func sortByNameAscending() { applySort(.name, ascending: true) }

    /// Quick sort: Size, largest first.
    func sortBySizeDescending() { applySort(.size, ascending: false) }

    /// Quick sort: File Type, A→Z.
    func sortByTypeAscending() { applySort(.type, ascending: true) }

    /// Whether the current sort matches a quick-sort preset (for showing a
    /// checkmark on the matching menu item).
    func isSort(_ order: SortOrder, ascending: Bool) -> Bool {
        sortOrder == order && sortAscending == ascending
    }

    /// Handles a click on a sortable list column header. Clicking the column
    /// that's already active flips the direction; clicking a different column
    /// switches to it using a sensible default direction for that field (dates
    /// and size start descending — newest/largest first — everything else
    /// ascending).
    func toggleSort(_ order: SortOrder) {
        if sortOrder == order {
            sortAscending.toggle()
        } else {
            applySort(order, ascending: Self.defaultAscending(for: order))
        }
    }

    /// Default direction when a column is first selected.
    private static func defaultAscending(for order: SortOrder) -> Bool {
        switch order {
        case .dateCreated, .dateModified, .size:
            return false   // newest / largest first
        case .name, .kind, .type, .codec:
            return true    // A→Z
        }
    }

    private func sorted(_ items: [MediaItem]) -> [MediaItem] {
        let result: [MediaItem]
        switch sortOrder {
        case .name:
            result = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .dateCreated:
            result = items.sorted { $0.creationDate < $1.creationDate }
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
        case .type:
            // Decorate-sort-undecorate: build each item's key once (O(n))
            // rather than re-deriving it inside every comparison (O(n log n)).
            result = sortedByStringKey(items) { $0.url.pathExtension.lowercased() }
        case .codec:
            // Only videos have a codec. Group videos first, ordered by codec
            // name (unresolved/unknown codecs sort after named ones), then all
            // non-videos. Keys are built once per item.
            result = sortedByStringKey(items) { self.codecSortKey($0) }
        }
        return sortAscending ? result : result.reversed()
    }

    /// Sort key for the `.codec` order. Non-video files have no codec, so they
    /// sort after every video. Videos use their resolved codec name; a video
    /// whose codec hasn't resolved yet (or is unknown) sorts after named ones
    /// but still ahead of non-videos. Prefixes keep the three groups ordered:
    /// "0<codec>" < "1" (video, unknown) < "2" (non-video).
    private func codecSortKey(_ item: MediaItem) -> String {
        guard item.kind == .video else { return "2" }
        if let codec = codecsByURL[item.url], !codec.isEmpty {
            return "0" + codec.lowercased()
        }
        return "1"
    }

    /// Sorts `items` by a precomputed string key (ascending, with the filename
    /// as a tiebreak). The key closure runs once per item — O(n) — so sorting
    /// doesn't re-derive keys or allocate strings inside every comparison, which
    /// is what made a codec/type sort of a large folder stutter.
    private func sortedByStringKey(
        _ items: [MediaItem],
        key: (MediaItem) -> String
    ) -> [MediaItem] {
        items
            .map { (key: key($0), item: $0) }
            .sorted { lhs, rhs in
                switch lhs.key.localizedStandardCompare(rhs.key) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame:
                    return lhs.item.name.localizedStandardCompare(rhs.item.name) == .orderedAscending
                }
            }
            .map(\.item)
    }

    // MARK: - Selection helpers

    /// Drops any selected ids that are no longer in the displayed set (e.g.
    /// after a mode switch, folder change, or search filter).
    private func clampSelection() {
        // Any change that reclamps the selection (scope, search, flag, chip
        // filters, mode) also changes what's displayed, so drop the memoized
        // list first — before the read below rebuilds it.
        invalidateDisplayCache()
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

    /// Escape behavior in the grid: clear the selection if there is one,
    /// otherwise clear the active type/extension filters.
    func escape() {
        if !selectedItems.isEmpty {
            clearSelection()
        } else if hasActiveChipFilters {
            clearChipFilters()
        }
    }

    /// Whether Escape would do anything right now.
    var canEscape: Bool {
        !selectedItems.isEmpty || hasActiveChipFilters
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

    /// Opens the full viewer on the current selection (selecting the first item
    /// if nothing is selected yet). Used by the Space hotkey.
    func openViewer() {
        selectFirstIfNeeded()
        if !selectedItems.isEmpty {
            isViewerPresented = true
        }
    }

    /// Switches between the thumbnail grid and the detailed list.
    func toggleLayout() {
        viewLayout = viewLayout == .grid ? .list : .grid
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

    /// Whether a trash action currently has any target (used to enable/disable
    /// the menu item and keyboard shortcut).
    var canTrashSelection: Bool { !selectedItems.isEmpty }

    /// Moves the given items (or the current selection) to the Trash.
    ///
    /// Files are sent to the system Trash (recoverable), then removed from the
    /// in-memory model so the grid/list/viewer update immediately without a
    /// full rescan. The selection advances to the next surviving item in
    /// display order so keyboard-driven culling stays on a sensible cursor, and
    /// the viewer closes if nothing is left to show.
    @discardableResult
    func moveToTrash(_ item: MediaItem? = nil) -> Int {
        let urls = actionURLs(preferring: item)
        guard !urls.isEmpty else { return 0 }

        // Remember where the cursor was so we can land on the next item.
        let order = displayedItems.map(\.id)
        let trashedSet = Set(urls)
        let firstTrashedIndex = order.firstIndex { trashedSet.contains($0) }

        var trashed: Set<URL> = []
        let fm = FileManager.default
        for url in urls {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                trashed.insert(url.standardizedFileURL)
            } catch {
                // Skip files that can't be trashed (e.g. permissions); the rest
                // still go. The failed file simply stays in the view.
                NSLog("Loupe: failed to trash \(url.path): \(error.localizedDescription)")
            }
        }

        guard !trashed.isEmpty else { return 0 }

        removeItemsFromModel(trashed)

        // Choose a new primary selection: the item that now occupies the first
        // trashed slot, or the last surviving item if we trashed the tail.
        let survivors = displayedItems.map(\.id)
        if survivors.isEmpty {
            clearSelection()
            isViewerPresented = false
        } else if let idx = firstTrashedIndex {
            let next = min(idx, survivors.count - 1)
            selectOnly(survivors[next])
        } else {
            clampSelection()
        }

        return trashed.count
    }

    /// Removes a set of (standardized) file URLs from every per-root scan
    /// result and the flagged set, then rebuilds the merged state. Does not
    /// touch the folder trees — empty folders simply remain until the next
    /// refresh, which matches the existing refresh model.
    private func removeItemsFromModel(_ trashed: Set<URL>) {
        for (root, result) in resultsByRoot {
            let newAll = result.allItems.filter { !trashed.contains($0.id.standardizedFileURL) }
            if newAll.count == result.allItems.count { continue }   // nothing here

            var newByDir: [URL: [MediaItem]] = [:]
            for (dir, items) in result.itemsByDirectory {
                let kept = items.filter { !trashed.contains($0.id.standardizedFileURL) }
                if !kept.isEmpty { newByDir[dir] = kept }
            }
            resultsByRoot[root] = ScanResult(
                root: result.root,
                allItems: newAll,
                itemsByDirectory: newByDir,
                tree: result.tree
            )
        }
        flaggedItems.subtract(trashed)
        rebuildMerged()
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
        } else if mode == .folders, !selectedFolders.isEmpty {
            if selectedFolders.count == 1, let folder = selectedFolders.first {
                base = "\(count) \(noun) in \(folder.lastPathComponent)"
            } else {
                base = "\(count) \(noun) in \(selectedFolders.count) folders"
            }
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
