import SwiftUI
import Observation
import UniformTypeIdentifiers

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

/// How the grid/list break their items into sections, if at all. The two AI
/// features each contribute a dimension: the scene classifier groups by
/// category, face recognition groups by person. `.folder` sections by the
/// containing directory. `.none` is a flat list.
enum GroupingDimension: String, CaseIterable {
    case none = "None"
    case category = "Category"
    case person = "Person"
    case folder = "Folder"
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

    /// Whether the right-hand info sidebar (file info + metadata for the
    /// selection) is shown. Window-scoped and in-session only.
    var showInfoSidebar = false

    /// Whether the right-hand preview sidebar (a live preview of the single
    /// selected image / video / document) is shown. Window-scoped and
    /// in-session only, matching `showInfoSidebar`.
    var showPreviewSidebar = false

    /// The preview sidebar's width in points. A preference persisted across
    /// windows and launches (like `thumbnailMethod`), so resizing it in one
    /// window carries over. Clamped to `minPreviewSidebarWidth ...
    /// maxPreviewSidebarWidth` on write.
    var previewSidebarWidth: Double = {
        let stored = UserDefaults.standard.double(forKey: BrowserModel.previewSidebarWidthKey)
        guard stored > 0 else { return BrowserModel.defaultPreviewSidebarWidth }
        return min(max(stored, BrowserModel.minPreviewSidebarWidth),
                   BrowserModel.maxPreviewSidebarWidth)
    }() {
        didSet {
            let clamped = min(max(previewSidebarWidth, Self.minPreviewSidebarWidth),
                              Self.maxPreviewSidebarWidth)
            if clamped != previewSidebarWidth {
                previewSidebarWidth = clamped
                return
            }
            UserDefaults.standard.set(previewSidebarWidth, forKey: Self.previewSidebarWidthKey)
        }
    }

    static let minPreviewSidebarWidth: Double = 220
    static let maxPreviewSidebarWidth: Double = 900
    static let defaultPreviewSidebarWidth: Double = 420
    private static let previewSidebarWidthKey = "previewSidebarWidth"

    /// Whether the free-text tag-input overlay (opened with `y`) is showing.
    /// Lives on the model so both the grid and the fullscreen viewer can open
    /// it, and so each surface can suspend its single-key hotkeys while it's up.
    var showTagInput = false

    /// Opens the tag-input overlay if there's something selected to tag.
    func beginTagging() {
        guard !selectedItems.isEmpty || primarySelectedItem != nil else { return }
        showTagInput = true
    }

    /// Toggles the info sidebar on/off (⌥⌘I / toolbar button).
    func toggleInfoSidebar() { showInfoSidebar.toggle() }

    /// Toggles the preview sidebar on/off (⌥⌘P / toolbar button).
    func togglePreviewSidebar() { showPreviewSidebar.toggle() }

    /// When true, the grid hides the filename caption under each thumbnail for
    /// a denser, image-only layout.
    var hideFilenames = false

    /// Toggles the grid filename captions on/off.
    func toggleHideFilenames() { hideFilenames.toggle() }

    /// When true, grid thumbnails are scaled to fill their square cell and
    /// cropped (center) rather than fitted whole with letterboxing. Gives a
    /// uniform, edge-to-edge grid at the cost of cropping off-square images.
    /// Window-scoped and in-session only, like `hideFilenames`.
    var fillGridCells = false

    /// Toggles between fit (letterboxed) and fill (zoomed/cropped) thumbnails.
    func toggleFillGridCells() { fillGridCells.toggle() }

    /// How thumbnails are generated (per-type `.hybrid`, QuickLook-everywhere
    /// `.nativeMacOS`, or in-app-decoders-only `.custom`). A preference, not
    /// per-folder data, so it's persisted across windows and launches like
    /// `faceEngine`. Switching it re-renders thumbnails on next request — the
    /// provider keys its cache by method, so a method change never serves a
    /// thumbnail built the old way (which is the point: `.nativeMacOS` is how a
    /// user escapes black `.mp4` thumbnails).
    var thumbnailMethod: ThumbnailMethod = {
        let raw = UserDefaults.standard.string(forKey: thumbnailMethodKey)
        return raw.flatMap(ThumbnailMethod.init(rawValue:)) ?? .hybrid
    }() {
        didSet {
            guard thumbnailMethod != oldValue else { return }
            UserDefaults.standard.set(thumbnailMethod.rawValue, forKey: Self.thumbnailMethodKey)
        }
    }

    private static let thumbnailMethodKey = "thumbnailMethod"

    /// Where in a video its thumbnail frame is taken, as a fraction of the
    /// clip's duration. A preference persisted across windows and launches, like
    /// `thumbnailMethod`. Only the custom decode paths (AVFoundation / FFmpeg)
    /// honor it; QuickLook picks its own poster frame. Changing it re-renders
    /// video thumbnails on next request (the provider keys its cache by it).
    var videoThumbnailPosition: VideoThumbnailPosition = {
        let raw = UserDefaults.standard.string(forKey: videoThumbnailPositionKey)
        return raw.flatMap(VideoThumbnailPosition.init(rawValue:)) ?? .defaultPosition
    }() {
        didSet {
            guard videoThumbnailPosition != oldValue else { return }
            UserDefaults.standard.set(videoThumbnailPosition.rawValue, forKey: Self.videoThumbnailPositionKey)
        }
    }

    private static let videoThumbnailPositionKey = "videoThumbnailPosition"

    /// Whether the "Copy Image" actions strip EXIF/metadata from the copied
    /// pixels. Window-scoped and in-session only — NOT persisted, so each new
    /// window and each launch starts from the default. Defaults to `true`
    /// (strip metadata) so a copied image doesn't carry camera/GPS data unless
    /// the user opts in within that window.
    var imageCopyStripsMetadata = true

    /// The encoding format for "Copy Image" (JPEG or PNG). Window-scoped and
    /// in-session only — NOT persisted. Independent of the metadata toggle: PNG
    /// is always metadata-free, while JPEG carries metadata unless stripping is
    /// on. Defaults to JPEG.
    var imageCopyFormat: ImageCopyFormat = .defaultFormat

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

    /// When true, the grid shows only flagged items. Mutually exclusive with
    /// `colorTagFilter` — the Library section shows one view at a time, so
    /// turning this on clears any active color-tag filter.
    var showFlaggedOnly = false {
        didSet {
            if showFlaggedOnly {
                if showHiddenOnly { showHiddenOnly = false }
                if showUnmarkedOnly { showUnmarkedOnly = false }
                if colorTagFilter != nil { colorTagFilter = nil }
                if aiCategoryFilter != nil { aiCategoryFilter = nil }
                if personFilter != nil { personFilter = nil }
                if textTagFilter != nil { textTagFilter = nil }
            }
            clampSelection()
        }
    }

    /// When true, the grid shows only "unmarked" items — those with no flag, no
    /// color tag, and no text tag. A quick way to see what still needs triage.
    /// Mutually exclusive with the other Library views.
    var showUnmarkedOnly = false {
        didSet {
            if showUnmarkedOnly {
                if showFlaggedOnly { showFlaggedOnly = false }
                if showHiddenOnly { showHiddenOnly = false }
                if colorTagFilter != nil { colorTagFilter = nil }
                if aiCategoryFilter != nil { aiCategoryFilter = nil }
                if personFilter != nil { personFilter = nil }
                if textTagFilter != nil { textTagFilter = nil }
            }
            clampSelection()
        }
    }

    /// Items the user has hidden, keyed by item ID. In-session only, exactly
    /// like `flaggedItems`: cleared when a new folder is opened and gone when
    /// the window closes (the model is per-window).
    ///
    /// Unlike `flaggedItems` (an opt-in display: `showFlaggedOnly` reveals
    /// them), hidden items are opt-out: they're filtered OUT of the grid, list
    /// and thumbnail views by default. The "Hidden" Library view
    /// (`showHiddenOnly`) is the one place they reappear, so the user can
    /// unhide them.
    var hiddenItems: Set<MediaItem.ID> = []

    /// When true, the grid shows ONLY hidden items (the "Hidden" Library view),
    /// so the user can review and unhide them. When false (the normal case),
    /// hidden items are excluded from every view. Mutually exclusive with the
    /// other Library filters, like `showFlaggedOnly`.
    var showHiddenOnly = false {
        didSet {
            if showHiddenOnly {
                if showFlaggedOnly { showFlaggedOnly = false }
                if showUnmarkedOnly { showUnmarkedOnly = false }
                if colorTagFilter != nil { colorTagFilter = nil }
                if aiCategoryFilter != nil { aiCategoryFilter = nil }
                if personFilter != nil { personFilter = nil }
                if textTagFilter != nil { textTagFilter = nil }
            }
            clampSelection()
        }
    }

    /// Color tags attached to files, keyed by item ID. In-session only, exactly
    /// like `flaggedItems`: cleared when a new folder is opened and gone when
    /// the window closes (the model is per-window). An item has at most one tag.
    var colorTags: [MediaItem.ID: ColorTag] = [:]

    /// Free-text tags attached to files, keyed by item ID. Unlike `colorTags`
    /// (at most one), an item can carry several. In-session only, like the
    /// other annotations: pruned to present items on rescan, gone when the
    /// window closes. Driven by the `y` tag-input overlay.
    var textTags: [MediaItem.ID: Set<String>] = [:]

    // MARK: - Annotation hide filters
    //
    // Independent "hide" toggles that exclude annotated items from the normal
    // grid/list, so the user can clear out things they've already triaged. Each
    // is additive and applies in every view EXCEPT the matching "show only"
    // Library view (hiding flagged items while viewing the Flagged library, for
    // instance, would leave it empty — so the toggle yields there).

    /// When true, flagged items are hidden from the grid/list.
    var hideFlaggedItems = false { didSet { clampSelection() } }

    /// When true, text-tagged items are hidden from the grid/list.
    var hideTaggedItems = false { didSet { clampSelection() } }

    /// When true, color-coded (color-tagged) items are hidden from the
    /// grid/list.
    var hideColorCodedItems = false { didSet { clampSelection() } }

    /// Distinct text tags in the order they were first created this session, so
    /// the overlay and sidebar list them in creation order rather than by
    /// frequency. A tag is appended the first time it's assigned and removed
    /// only when it no longer applies to any item.
    private(set) var textTagOrder: [String] = []

    /// When set, the grid shows only items carrying this color tag. `nil` means
    /// no color filter is active. Mutually exclusive with `showFlaggedOnly`.
    var colorTagFilter: ColorTag? {
        didSet {
            if colorTagFilter != nil {
                if showFlaggedOnly { showFlaggedOnly = false }
                if showHiddenOnly { showHiddenOnly = false }
                if showUnmarkedOnly { showUnmarkedOnly = false }
                if aiCategoryFilter != nil { aiCategoryFilter = nil }
                if personFilter != nil { personFilter = nil }
                if textTagFilter != nil { textTagFilter = nil }
            }
            clampSelection()
        }
    }

    /// When set, the grid shows only items carrying this free-text tag. `nil`
    /// means no text-tag filter is active. Mutually exclusive with the other
    /// Library filters.
    var textTagFilter: String? {
        didSet {
            if textTagFilter != nil {
                if showFlaggedOnly { showFlaggedOnly = false }
                if showHiddenOnly { showHiddenOnly = false }
                if showUnmarkedOnly { showUnmarkedOnly = false }
                if colorTagFilter != nil { colorTagFilter = nil }
                if aiCategoryFilter != nil { aiCategoryFilter = nil }
                if personFilter != nil { personFilter = nil }
            }
            clampSelection()
        }
    }

    // MARK: - AI categories

    /// AI-assigned categories keyed by item ID, produced on-device by
    /// `ImageClassifier` (Apple's Vision classifier, refined by the Foundation
    /// Models LLM when Apple Intelligence is available). In-session only, just
    /// like `flaggedItems`/`colorTags`: cleared when a new folder is opened and
    /// gone when the window closes. An item has at most one category.
    private(set) var aiCategories: [MediaItem.ID: String] = [:]

    /// When set, the grid shows only items the classifier placed in this
    /// category. `nil` means no category filter is active. Mutually exclusive
    /// with the person filter and the flagged/color-tag Library views.
    var aiCategoryFilter: String? {
        didSet {
            if aiCategoryFilter != nil {
                if showFlaggedOnly { showFlaggedOnly = false }
                if showHiddenOnly { showHiddenOnly = false }
                if showUnmarkedOnly { showUnmarkedOnly = false }
                if colorTagFilter != nil { colorTagFilter = nil }
                if personFilter != nil { personFilter = nil }
                if textTagFilter != nil { textTagFilter = nil }
            }
            clampSelection()
        }
    }

    /// How the grid/list are sectioned: flat, by AI category, or by recognized
    /// person. Changing it only re-sections the already-filtered list.
    var grouping: GroupingDimension = .none {
        didSet { invalidateDisplayCache() }
    }

    /// Back-compat shim for the original category-only toggle: reads/writes the
    /// `.category` dimension so existing menu bindings keep working.
    var groupByCategory: Bool {
        get { grouping == .category }
        set { grouping = newValue ? .category : .none }
    }

    // MARK: - Face recognition

    /// Recognized people per item, as identity-free cluster IDs produced
    /// on-device by `FaceRecognizer` + `FaceClusterer`. A photo can contain
    /// several people, so each item maps to a *set* of person IDs. In-session
    /// only, like the other annotations.
    private(set) var facePersons: [MediaItem.ID: Set<Int>] = [:]

    /// The engine used to embed faces for clustering. Persisted across windows
    /// and launches (a preference, not per-folder data). Changing it invalidates
    /// any existing people, since embeddings from different engines aren't
    /// comparable — the user must re-run "Find Faces".
    var faceEngine: FaceRecognitionEngine = {
        let raw = UserDefaults.standard.string(forKey: faceEngineKey)
        let stored = raw.flatMap(FaceRecognitionEngine.init(rawValue:)) ?? .visionFeaturePrint
        // Don't start on an engine that's currently disabled (e.g. a stale
        // Core ML preference from before it was turned off).
        return FaceRecognitionEngine.selectableCases.contains(stored) ? stored : .visionFeaturePrint
    }() {
        didSet {
            guard faceEngine != oldValue else { return }
            UserDefaults.standard.set(faceEngine.rawValue, forKey: Self.faceEngineKey)
            // Reset the clustering threshold to the new engine's default scale.
            faceClusterThreshold = faceEngine.defaultThreshold
            // Embeddings from the two engines aren't comparable, so any existing
            // people are meaningless under the new engine. Clear them; the user
            // re-runs "Find Faces" to recompute with the new engine.
            if !facePersons.isEmpty { clearFaces() }
        }
    }

    /// Clustering distance threshold for the current engine. Persisted. Lower =
    /// stricter (more, purer people); higher = looser (fewer, risk of merging).
    var faceClusterThreshold: Double = {
        if UserDefaults.standard.object(forKey: faceThresholdKey) != nil {
            return UserDefaults.standard.double(forKey: faceThresholdKey)
        }
        let raw = UserDefaults.standard.string(forKey: faceEngineKey)
        let engine = raw.flatMap(FaceRecognitionEngine.init(rawValue:)) ?? .visionFeaturePrint
        return engine.defaultThreshold
    }() {
        didSet {
            UserDefaults.standard.set(faceClusterThreshold, forKey: Self.faceThresholdKey)
        }
    }

    /// Whether a Core ML face model is installed (so the UI can offer that
    /// engine). Resolved once on the first query and cached.
    private(set) var coreMLFaceModelAvailable = false

    /// A human-readable note shown after a face run that produced nothing,
    /// explaining why (e.g. the Core ML model's output couldn't be read). `nil`
    /// when the last run was fine.
    private(set) var faceRecognitionNote: String?

    private static let faceEngineKey = "faceRecognitionEngine"
    private static let faceThresholdKey = "faceClusterThreshold"

    /// When set, the grid shows only items containing this person. `nil` means
    /// no person filter is active. Mutually exclusive with the category filter
    /// and the flagged/color-tag Library views.
    var personFilter: Int? {
        didSet {
            if personFilter != nil {
                if showFlaggedOnly { showFlaggedOnly = false }
                if showHiddenOnly { showHiddenOnly = false }
                if showUnmarkedOnly { showUnmarkedOnly = false }
                if colorTagFilter != nil { colorTagFilter = nil }
                if aiCategoryFilter != nil { aiCategoryFilter = nil }
                if textTagFilter != nil { textTagFilter = nil }
            }
            clampSelection()
        }
    }

    /// True while a classification OR face-recognition pass is running, so the
    /// UI can show progress and disable a second trigger. Both passes share one
    /// progress channel since only one runs at a time.
    private(set) var isClassifying = false

    /// Items processed so far in the running pass, and the total the pass set
    /// out to process. Both reset when a pass starts; the view reads them to
    /// render a progress indicator.
    private(set) var classifyProgress = 0
    private(set) var classifyTotal = 0

    /// A short label for the running pass ("Classifying" / "Finding Faces"),
    /// shown next to the progress indicator.
    private(set) var classifyActivity = ""

    /// Guards against launching more than one classification/recognition pass
    /// at a time.
    private var isRunningClassification = false

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

    /// True while the preview sidebar is being drag-resized. The grid reads
    /// this to freeze its column layout for the duration of the drag: an
    /// adaptive `LazyVGrid` otherwise re-flows every visible cell on each tick
    /// as the grid's available width changes, which looks stuttery. In-session,
    /// window-scoped, and never persisted.
    var isResizingPreviewSidebar = false

    // Security-scoped access is kept alive per root for the lifetime of the
    // window; stopped when a root is removed. The OS reclaims the rest on exit.
    private var scopedURLs: Set<URL> = []
    /// Roots assembled from individually dropped files rather than a folder
    /// scan, keyed by the files' shared parent directory. Their item list is
    /// built by hand and must not be rescanned (that would turn them into the
    /// full folder), so refresh/merge treat them specially.
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

    /// Adds a single dropped file. Shows just that file — not the folder it
    /// came from — under a sidebar entry for its parent directory, and selects
    /// it. A second file dropped from the same folder merges into that entry.
    func openFile(_ fileURL: URL) {
        let file = fileURL.standardizedFileURL
        // Finder grants per-file sandbox access on a drop.
        if scopeAccess(file) { scopedURLs.insert(file) }
        addSingleFileRoot(file)
    }

    /// Adds a batch of dropped files. The dropped files themselves are shown —
    /// never the whole folder they came from. Files sharing a parent directory
    /// are grouped under a single sidebar entry for that directory (rather than
    /// one duplicate entry per file), and all of them end up selected. Files
    /// from different directories each get their own grouped entry. Order is
    /// preserved for a stable selection anchor.
    func openFiles(_ fileURLs: [URL]) {
        guard !fileURLs.isEmpty else { return }
        if fileURLs.count == 1 { openFile(fileURLs[0]); return }

        // De-duplicate while preserving first-seen order.
        var seen = Set<URL>()
        let files = fileURLs
            .map { $0.standardizedFileURL }
            .filter { seen.insert($0).inserted }

        // Group by parent directory, keeping both the parents and the files
        // within each in first-seen (drop) order.
        var parentOrder: [URL] = []
        var byParent: [URL: [URL]] = [:]
        for file in files {
            let parent = file.deletingLastPathComponent()
            if byParent[parent] == nil { parentOrder.append(parent) }
            byParent[parent, default: []].append(file)
        }

        // Finder grants per-file sandbox access on a drop, so scope each file.
        for file in files where scopeAccess(file) { scopedURLs.insert(file) }

        var toSelect: [URL] = []
        for parent in parentOrder {
            let groupFiles = byParent[parent] ?? []
            addFileGroupRoot(parent: parent, files: groupFiles)
            toSelect.append(contentsOf: groupFiles)
        }
        selectItems(toSelect)
    }

    private func addSingleFileRoot(_ file: URL) {
        let parent = file.deletingLastPathComponent()
        addFileGroupRoot(parent: parent, files: [file])
        selectOnly(file)
    }

    /// Adds a root that shows only the given files from one directory — not the
    /// directory's full contents. The sidebar node represents the PARENT
    /// directory (so selecting its row in Folders mode finds the files), and
    /// the items are keyed under that directory. The root is keyed by the
    /// parent directory URL so a second drop from the same folder merges into
    /// the existing entry instead of creating a duplicate.
    ///
    /// If the parent directory is already open as a normal (fully scanned)
    /// root, the files are already present, so this only (re)selects them. If
    /// it's already a grouped file root, any newly dropped files are merged in.
    private func addFileGroupRoot(parent: URL, files: [URL]) {
        guard !files.isEmpty else { return }
        let parent = parent.standardizedFileURL

        // Parent already open as a normal root: its files are all present.
        if roots.contains(parent), !singleFileRoots.contains(parent) {
            return
        }

        // Merge with any files already shown for this grouped root, preserving
        // order and de-duplicating.
        let existing = resultsByRoot[parent]?.allItems ?? []
        var seen = Set(existing.map(\.id))
        var items = existing
        for file in files where seen.insert(file).inserted {
            items.append(MediaItem(url: file))
        }

        let node = FolderNode(url: parent, children: [], directMediaCount: items.count)
        let result = ScanResult(
            root: parent,
            allItems: items,
            itemsByDirectory: [parent: items],
            tree: node
        )
        if !roots.contains(parent) { roots.append(parent) }
        singleFileRoots.insert(parent)
        resultsByRoot[parent] = result
        rebuildMerged()
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

    /// Removes every root folder from the window, releasing each one's security
    /// scope. Leaves the window empty (showing the drop zone) but keeps
    /// preferences. Annotations for the now-absent files are pruned by the
    /// rebuild; `resetAll()` additionally clears any lingering filter state.
    func removeAllRoots() {
        guard !roots.isEmpty else { return }
        for root in scopedURLs {
            root.stopAccessingSecurityScopedResource()
        }
        scopedURLs.removeAll()
        roots.removeAll()
        resultsByRoot.removeAll()
        singleFileRoots.removeAll()
        selectedFolders = []
        folderAnchor = nil
        rebuildMerged()
    }

    /// Clears every in-session annotation (flags, hidden marks, color tags,
    /// free-text tags, AI categories, recognized people) and the filters/
    /// groupings that depend on them, returning the window's marks to a clean
    /// slate. Does not touch the open folders.
    func clearAllAnnotations() {
        flaggedItems = []
        hiddenItems = []
        colorTags = [:]
        textTags = [:]
        textTagOrder = []
        aiCategories = [:]
        facePersons = [:]

        // Drop every filter / Library view that keyed off those annotations.
        showFlaggedOnly = false
        showHiddenOnly = false
        showUnmarkedOnly = false
        colorTagFilter = nil
        textTagFilter = nil
        aiCategoryFilter = nil
        personFilter = nil
        hideFlaggedItems = false
        hideTaggedItems = false
        hideColorCodedItems = false
        if grouping == .person || grouping == .category { grouping = .none }

        clampSelection()
    }

    /// Removes all folders AND clears every annotation/filter, giving a
    /// completely fresh, empty window. Backs the sidebar's "Remove All &
    /// Reset" action.
    func resetAll() {
        clearAllAnnotations()
        removeAllRoots()
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
    /// identity used for removal; `tree` is the folder node to render. For a
    /// grouped file-drop root both are the dropped files' shared parent
    /// directory, and the tree lists only those files.
    struct RootEntry: Identifiable {
        let key: URL
        let tree: FolderNode
        var id: URL { key }
    }

    var rootEntries: [RootEntry] {
        roots.compactMap { root in
            guard let result = resultsByRoot[root] else { return nil }
            return RootEntry(key: root, tree: result.tree)
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
        pruneMissingMarks()
        clampSelection()
        // Keep codec data current for a codec sort as folders are added/rescanned.
        if sortOrder == .codec { prefetchCodecs() }
    }

    /// Drops flags and color tags whose underlying file is no longer present
    /// after the merged item list is rebuilt — e.g. the file was deleted on
    /// disk and the folder refreshed, or the containing root was removed. This
    /// keeps the Library "Flagged"/tag views and their sidebar counts from
    /// listing items that have vanished. Flags/tags for files that still exist
    /// (including in other roots) are preserved.
    private func pruneMissingMarks() {
        let present = Set(allItems.map(\.id))
        flaggedItems.formIntersection(present)
        hiddenItems.formIntersection(present)
        colorTags = colorTags.filter { present.contains($0.key) }
        textTags = textTags.filter { present.contains($0.key) }
        // Note: tag names in `textTagOrder` are intentionally kept even when no
        // present item carries them, so "empty" tags persist in the sidebar.
        aiCategories = aiCategories.filter { present.contains($0.key) }
        facePersons = facePersons.filter { present.contains($0.key) }
        // Drop a category filter that no longer matches anything.
        if let filter = aiCategoryFilter, !aiCategories.values.contains(filter) {
            aiCategoryFilter = nil
        }
        // Drop a person filter whose person no longer appears anywhere.
        if let person = personFilter, !facePersons.values.contains(where: { $0.contains(person) }) {
            personFilter = nil
        }
        // Drop a text-tag filter whose tag no longer exists (was deleted). An
        // "empty" tag that still exists but currently matches nothing keeps the
        // filter active (the grid just shows no items), so the filter only
        // clears on an actual delete, not on a rescan.
        if let filter = textTagFilter, !textTagOrder.contains(filter) {
            textTagFilter = nil
        }
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

        // Hidden items are opt-out: excluded from every normal view. The one
        // exception is the "Hidden" Library view (`showHiddenOnly`), which
        // flips the polarity to show only hidden items so they can be unhidden.
        if showHiddenOnly {
            base = base.filter { hiddenItems.contains($0.id) }
        } else if !hiddenItems.isEmpty {
            base = base.filter { !hiddenItems.contains($0.id) }
        }

        if showFlaggedOnly {
            base = base.filter { flaggedItems.contains($0.id) }
        }

        if showUnmarkedOnly {
            // Items with no flag, no color tag, and no text tag.
            base = base.filter { isUnmarked($0.id) }
        }

        if let colorTagFilter {
            base = base.filter { colorTags[$0.id] == colorTagFilter }
        }

        if let textTagFilter {
            base = base.filter { textTags[$0.id]?.contains(textTagFilter) ?? false }
        }

        if let aiCategoryFilter {
            base = base.filter { aiCategories[$0.id] == aiCategoryFilter }
        }

        if let personFilter {
            base = base.filter { facePersons[$0.id]?.contains(personFilter) ?? false }
        }

        // Annotation hide filters: drop flagged / tagged / color-coded items
        // from view. Each yields in the matching "show only" Library view so it
        // doesn't blank it out (e.g. don't hide flagged items while showing the
        // Flagged library, or color-coded items while filtering to a color tag).
        if hideFlaggedItems, !showFlaggedOnly {
            base = base.filter { !flaggedItems.contains($0.id) }
        }
        if hideTaggedItems, textTagFilter == nil {
            base = base.filter { (textTags[$0.id]?.isEmpty ?? true) }
        }
        if hideColorCodedItems, colorTagFilter == nil {
            base = base.filter { colorTags[$0.id] == nil }
        }

        // Split the query into terms on commas and whitespace so "beach sunset"
        // or "beach, sunset" both match names containing every term (AND), in
        // any order. Empty terms (from runs of separators) are dropped.
        //
        // A term prefixed with "-" is a negation: items whose name contains the
        // text after the minus are excluded. So "beach -sunset" keeps names with
        // "beach" but drops any that also contain "sunset". A bare "-" (nothing
        // after it) is ignored.
        var includeTerms: [String] = []
        var excludeTerms: [String] = []
        for rawTerm in searchText.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            if rawTerm.first == "-" {
                let term = String(rawTerm.dropFirst())
                if !term.isEmpty { excludeTerms.append(term) }
            } else {
                includeTerms.append(String(rawTerm))
            }
        }
        if !includeTerms.isEmpty {
            base = base.filter { item in
                includeTerms.allSatisfy { item.name.localizedCaseInsensitiveContains($0) }
            }
        }
        if !excludeTerms.isEmpty {
            base = base.filter { item in
                !excludeTerms.contains { item.name.localizedCaseInsensitiveContains($0) }
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

    /// Each displayed item's position in `displayedItems`, keyed by item ID.
    /// The grouped grid uses this to drive thumbnail prefetch off a cell's
    /// position in the full display order rather than its index within a
    /// section. Memoized off `displayRevision` so it's built once per display
    /// change instead of once per rendered cell (the grid reads it per cell).
    var displayedItemIndex: [MediaItem.ID: Int] {
        _ = displayRevision
        if cachedIndexRevision == displayRevision, let cachedDisplayedItemIndex {
            return cachedDisplayedItemIndex
        }
        var map: [MediaItem.ID: Int] = [:]
        for (i, item) in displayedItems.enumerated() { map[item.id] = i }
        cachedDisplayedItemIndex = map
        cachedIndexRevision = displayRevision
        return map
    }

    /// Memoized result of `groupedDisplayedItems` and the flattened
    /// `visualOrderItems`, keyed off `cachedGroupRevision`. Both are O(n) to
    /// build when grouping is active (bucketing every item, a key sort for
    /// folders, and a flatten+dedupe pass), and they're read repeatedly per
    /// selection change — every selection setter reads `visualOrderItems`, and
    /// the grid body re-reads `groupedDisplayedItems` on each re-render. Without
    /// a cache that rebuild ran on every keystroke under grouping, which is the
    /// slowdown. The caches depend on the same inputs as `displayedItems` plus
    /// the grouping dimension and the category/person maps — all of which bump
    /// `displayRevision` via `invalidateDisplayCache` when they change, so we
    /// reuse that token to decide when the group caches are stale.
    @ObservationIgnored private var cachedGroupedDisplayedItems: [CategoryGroup]?
    @ObservationIgnored private var cachedVisualOrderItems: [MediaItem]?
    /// The `displayRevision` value the group caches were built against. A
    /// mismatch means the inputs changed and the caches must be rebuilt.
    @ObservationIgnored private var cachedGroupRevision: Int?

    /// Memoized `displayedItemIndex`, keyed off `cachedIndexRevision` against
    /// `displayRevision` (same scheme as the group caches).
    @ObservationIgnored private var cachedDisplayedItemIndex: [MediaItem.ID: Int]?
    @ObservationIgnored private var cachedIndexRevision: Int?

    /// Clears the memoized `displayedItems` (and the derived group caches) so
    /// the next read rebuilds them, and bumps the observed revision so views
    /// re-render. Called whenever anything the sort/filter/scope/grouping
    /// depends on changes.
    private func invalidateDisplayCache() {
        cachedDisplayedItems = nil
        cachedGroupedDisplayedItems = nil
        cachedVisualOrderItems = nil
        cachedGroupRevision = nil
        cachedDisplayedItemIndex = nil
        cachedIndexRevision = nil
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
        if showUnmarkedOnly {
            return "Unmarked"
        }
        if showHiddenOnly {
            return "Hidden"
        }
        if let colorTagFilter {
            return "\(colorTagFilter.displayName) Tag"
        }
        if let textTagFilter {
            return textTagFilter
        }
        if let aiCategoryFilter {
            return aiCategoryFilter
        }
        if let personFilter {
            return personName(personFilter)
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

    /// Combined on-disk size, in bytes, of every selected item. Zero when
    /// nothing is selected. Used by the bottom size indicator and the info
    /// sidebar.
    var selectedItemsByteCount: Int64 {
        selectedMediaItems.reduce(Int64(0)) { $0 + $1.fileSize }
    }

    func selectFirstIfNeeded() {
        if selectedItem == nil || selectedItems.isEmpty {
            if let first = visualOrderItems.first?.id {
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

    /// Replace the selection with a set of items, anchoring on the first. Used
    /// when a batch of files (e.g. a multi-file Finder drop) should all end up
    /// selected together. Items not present in the model are ignored; if none
    /// remain, the selection is cleared.
    func selectItems(_ ids: [MediaItem.ID]) {
        let present = Set(allItems.map(\.id))
        let valid = ids.filter(present.contains)
        guard let anchor = valid.first else {
            selectedItem = nil
            rangeAnchor = nil
            selectedItems = []
            return
        }
        selectedItem = anchor
        rangeAnchor = anchor
        selectedItems = Set(valid)
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
        let items = visualOrderItems
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
        let items = visualOrderItems
        guard !items.isEmpty else { return }
        guard let current = selectedItem,
              let idx = items.firstIndex(where: { $0.id == current }) else {
            selectOnly(items[0].id)
            return
        }
        let next = (idx + offset).clamped(to: 0...(items.count - 1))
        selectOnly(items[next].id)
    }

    /// Shifts a multi-item selection by whole blocks of its own size, keeping
    /// the number of selected items constant. With N items selected, moving by
    /// +1 selects the next N items in display order and -1 the previous N, so
    /// the fullscreen viewer's arrow keys page through the folder a screenful
    /// at a time. The block is clamped to the list bounds (so it never shrinks
    /// below N when there's room), and the primary/anchor is set to the block's
    /// leading item. Falls back to a single-step move when fewer than two items
    /// are selected.
    func moveSelectionBlock(by offset: Int) {
        let items = visualOrderItems
        guard !items.isEmpty else { return }

        // Page by exactly the number of items currently shown. Driving this off
        // the live selection count (rather than a persisted page size) keeps a
        // plain arrow a pure navigation: it can never grow the selection, even
        // after a deletion changed how many items are on screen.
        let pageSize = selectedItems.count
        guard pageSize > 1 else {
            moveSelection(by: offset)
            return
        }

        // Find the current block's leading position in display order.
        let order = items.map(\.id)
        guard let first = order.firstIndex(where: { selectedItems.contains($0) }) else {
            moveSelection(by: offset)
            return
        }

        // Page by the block size, then clamp so a full block stays on-screen
        // (don't run off either end).
        let blockSize = min(pageSize, items.count)
        let maxStart = items.count - blockSize
        let newStart = (first + offset * blockSize).clamped(to: 0...max(0, maxStart))
        let range = newStart..<(newStart + blockSize)
        let newIDs = Array(order[range])

        selectedItems = Set(newIDs)
        rangeAnchor = newIDs.first
        selectedItem = newIDs.first
    }

    /// Grows or shrinks the fullscreen viewer's selection from its RIGHT edge.
    /// The left edge of the current selection stays pinned as the anchor and
    /// the right edge moves:
    ///   - Shift+Right (offset +1) extends the right edge outward, adding the
    ///     next item.
    ///   - Shift+Left (offset -1) pulls the right edge back in, removing the
    ///     rightmost item (never shrinking below the single anchor item).
    /// Used to build up or trim a side-by-side multi-image view from the
    /// keyboard.
    func extendViewerSelection(by offset: Int) {
        let items = visualOrderItems
        guard !items.isEmpty else { return }

        let order = items.map(\.id)
        // Current selection span in display order. With nothing selected yet,
        // start a single selection at the focused item (or the first item).
        let selectedIndices = order.enumerated()
            .filter { selectedItems.contains($0.element) }
            .map(\.offset)
        guard let leftEdge = selectedIndices.min(),
              let rightEdge = selectedIndices.max() else {
            let startID = selectedItem ?? order.first
            if let startID { selectOnly(startID) }
            return
        }

        // Pin the anchor to the left edge and move only the right edge. Clamp
        // so the right edge never crosses the left edge (keeps ≥1 item) or runs
        // off the end of the list.
        let anchorID = order[leftEdge]
        rangeAnchor = anchorID
        let newRight = (rightEdge + offset).clamped(to: leftEdge...(order.count - 1))

        let ids = Array(order[leftEdge...newRight])
        selectedItems = Set(ids)
        // Keep the moving right edge as the primary/cursor so paging resumes
        // from the trailing item.
        selectedItem = order[newRight]
    }

    /// URLs of the next `count` image items that follow the current selection
    /// in display order. Used by the fullscreen viewer to warm the preloader
    /// cache so forward navigation swaps instantly. Non-image items (video,
    /// PDF, …) are skipped since only images use the preloader.
    ///
    /// Scanning starts after the LAST selected item so a multi-selection warms
    /// the next block (the images Right-arrow will reveal) rather than files
    /// already on screen. For a single selection this is the item right after
    /// the current one.
    func upcomingImageURLs(count: Int) -> [URL] {
        let items = visualOrderItems
        guard !items.isEmpty, !selectedItems.isEmpty else { return [] }

        // Resume from just past the end of the current selection block.
        guard let lastSelectedIdx = items.lastIndex(where: { selectedItems.contains($0.id) }) else {
            return []
        }

        var out: [URL] = []
        var i = lastSelectedIdx + 1
        while i < items.count && out.count < count {
            if items[i].kind == .image { out.append(items[i].url) }
            i += 1
        }
        return out
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
        let items = visualOrderItems
        guard !items.isEmpty else { return }
        let cols = max(1, columns)

        guard let current = selectedItem,
              let idx = items.firstIndex(where: { $0.id == current }) else {
            selectOnly(items[0].id)
            return
        }

        guard let target = navigationTarget(from: idx, direction: direction, cols: cols) else {
            return
        }

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

    /// Computes the destination index for an arrow-key move, expressed as an
    /// index into `visualOrderItems`.
    ///
    /// Left/Right step one item in reading order and may cross section
    /// boundaries, matching the flat visual order. Up/Down move a full row, but
    /// stay *within the item's own section* when grouping is active: each
    /// section wraps into its own rows (its last row is usually partial, and
    /// the next section restarts at column 0), so a flat `idx ± cols` jump
    /// would skip across section edges and land on the wrong tile. Vertical
    /// moves preserve the current column, clamp to the last item on a shorter
    /// destination row, and return `nil` when there's no row to move to.
    private func navigationTarget(from idx: Int, direction: MoveDirection, cols: Int) -> Int? {
        let count = visualOrderItems.count
        switch direction {
        case .left:
            return idx - 1 >= 0 ? idx - 1 : nil
        case .right:
            return idx + 1 < count ? idx + 1 : nil
        case .up, .down:
            // Resolve the section the current item lives in, then move by one
            // row within that section only.
            let (sectionStart, sectionCount) = sectionBounds(containing: idx)
            let offsetInSection = idx - sectionStart
            let column = offsetInSection % cols
            let row = offsetInSection / cols
            let targetRow = direction == .up ? row - 1 : row + 1
            guard targetRow >= 0 else { return nil }
            let rowStart = targetRow * cols
            guard rowStart < sectionCount else { return nil }
            // Clamp to the last item on the destination row (partial last row).
            let lastOnRow = min(rowStart + cols, sectionCount) - 1
            let targetInSection = min(rowStart + column, lastOnRow)
            return sectionStart + targetInSection
        }
    }

    /// The `(start, count)` of the section in `visualOrderItems` that contains
    /// the item at `idx`. With no grouping the whole flat list is one section;
    /// with grouping active each on-screen group is a section, measured against
    /// the same de-duplicated order `visualOrderItems` uses.
    private func sectionBounds(containing idx: Int) -> (start: Int, count: Int) {
        let items = visualOrderItems
        guard grouping != .none else { return (0, items.count) }
        var start = 0
        var seen: Set<MediaItem.ID> = []
        for group in groupedDisplayedItems {
            // Count this group's items the same way `visualOrderItems` flattens
            // them: each item once, at its first on-screen position.
            var groupCount = 0
            for item in group.items where seen.insert(item.id).inserted {
                groupCount += 1
            }
            if idx < start + groupCount { return (start, groupCount) }
            start += groupCount
        }
        // Fallback: treat the whole list as one section.
        return (0, items.count)
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
        // If flagging will push the current item out of view (the "Hide
        // Flagged" filter is on), remember where the cursor should land so
        // keyboard navigation keeps flowing instead of losing its anchor.
        let successor = anyUnflagged ? successorAfterHiding(targets) : nil
        if anyUnflagged {
            flaggedItems.formUnion(targets)
        } else {
            flaggedItems.subtract(targets)
        }
        clampSelection()
        advanceAfterAnnotating(successor)
    }

    /// Toggle the flag on exactly one item, regardless of the current
    /// selection. Used by the multi-image viewer's number hotkeys, where each
    /// key targets a specific tile even though every shown item is selected.
    func toggleFlag(id: MediaItem.ID) {
        if flaggedItems.contains(id) {
            flaggedItems.remove(id)
        } else {
            flaggedItems.insert(id)
        }
        clampSelection()
    }

    func clearFlags() {
        flaggedItems = []
        clampSelection()
    }

    var flaggedCount: Int { flaggedItems.count }

    // MARK: - Hidden items

    func isHidden(_ id: MediaItem.ID) -> Bool {
        hiddenItems.contains(id)
    }

    /// Toggle the hidden state on the given item, or on the whole current
    /// selection. Mirrors `toggleFlag`'s targeting: a specific unselected
    /// `item` acts on just that item; otherwise the action covers the
    /// selection. If any target is visible, hide them all; otherwise unhide
    /// them all.
    func toggleHidden(_ item: MediaItem? = nil) {
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

        let anyVisible = targets.contains { !hiddenItems.contains($0) }
        if anyVisible {
            // Remember where the hidden block sat so we can land the cursor on
            // the item that follows it, keeping keyboard navigation flowing.
            let successor = successorAfterHiding(targets)
            hiddenItems.formUnion(targets)
            clampSelection()
            selectAfterHiding(successor)
        } else {
            hiddenItems.subtract(targets)
            clampSelection()
        }
    }

    /// Toggle the hidden state on exactly one item, regardless of the current
    /// selection. Parallels `toggleFlag(id:)`.
    func toggleHidden(id: MediaItem.ID) {
        if hiddenItems.contains(id) {
            hiddenItems.remove(id)
            clampSelection()
        } else {
            let successor = successorAfterHiding([id])
            hiddenItems.insert(id)
            clampSelection()
            selectAfterHiding(successor)
        }
    }

    /// The item that should receive the selection after `targets` are hidden:
    /// the first still-visible item that comes after the hidden block in
    /// visual order, or the last surviving item when the block sat at the end.
    /// Returns `nil` when nothing visible remains. Must be called *before*
    /// `hiddenItems` is updated so the ordering still reflects the targets.
    private func successorAfterHiding(_ targets: [MediaItem.ID]) -> MediaItem.ID? {
        let order = visualOrderItems
        let hiding = Set(targets)
        guard let firstHiddenIdx = order.firstIndex(where: { hiding.contains($0.id) }) else {
            return nil
        }
        // Walk forward from the first hidden item to the next survivor.
        if let next = order[firstHiddenIdx...].first(where: { !hiding.contains($0.id) }) {
            return next.id
        }
        // The hidden block ran to the end; fall back to the last survivor.
        return order[..<firstHiddenIdx].last(where: { !hiding.contains($0.id) })?.id
    }

    /// Applies the selection computed by `successorAfterHiding` once the items
    /// are hidden, but only when the hide actually cleared the selection — if
    /// something survived (e.g. a multi-selection where not everything was
    /// hidden) we leave the user's selection intact.
    private func selectAfterHiding(_ id: MediaItem.ID?) {
        guard selectedItems.isEmpty, let id else { return }
        selectOnly(id)
    }

    /// Unhide every item, and leave the "Hidden" Library view if it's active
    /// (it would otherwise show an empty list).
    func clearHidden() {
        hiddenItems = []
        if showHiddenOnly { showHiddenOnly = false }
        clampSelection()
    }

    var hiddenCount: Int { hiddenItems.count }

    // MARK: - Color tags

    /// The color tag on the given item, or `nil` if untagged.
    func colorTag(_ id: MediaItem.ID) -> ColorTag? {
        colorTags[id]
    }

    /// Apply (or toggle off) a color tag on the given item, or on the whole
    /// current selection. Mirrors `toggleFlag`'s targeting: a specific unselected
    /// `item` acts on just that item; otherwise the action covers the selection.
    ///
    /// Toggle semantics: if every target already carries `tag`, the tag is
    /// removed from them all; otherwise `tag` is applied to them all (replacing
    /// any different tag they had).
    func toggleColorTag(_ tag: ColorTag, item: MediaItem? = nil) {
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

        let allTagged = targets.allSatisfy { colorTags[$0] == tag }
        if allTagged {
            for id in targets { colorTags[id] = nil }
            clampSelection()
        } else {
            // Remember where the cursor should land before the tag is applied,
            // so that if a color-tag filter is active (which drops the newly
            // tagged item out of view) we can still follow the list forward.
            let successor = successorAfterTagging(targets)
            for id in targets { colorTags[id] = tag }
            clampSelection()
            advanceAfterTagging(successor)
        }
    }

    /// The item the selection should move to after `targets` are color-tagged:
    /// the next item in visual order following the single tagged item. Mirrors
    /// the "mark as hidden" flow so tagging one item after another walks the
    /// list without extra navigation. Returns `nil` for multi-item actions (we
    /// leave those selections intact) or when there's nothing to advance to.
    /// Must be called *before* `colorTags` is updated so the current filtered
    /// order still reflects the targets.
    private func successorAfterTagging(_ targets: [MediaItem.ID]) -> MediaItem.ID? {
        guard targets.count == 1, let tagged = targets.first else { return nil }
        let order = visualOrderItems
        guard let idx = order.firstIndex(where: { $0.id == tagged }) else { return nil }
        // Prefer the next item in order; fall back to the previous one when the
        // tagged item is the last, so a trailing item still advances somewhere.
        if idx + 1 < order.count { return order[idx + 1].id }
        if idx - 1 >= 0 { return order[idx - 1].id }
        return nil
    }

    /// Moves the selection onto the item computed by `successorAfterTagging`,
    /// but only for a single-item selection — multi-selection tagging keeps the
    /// user's selection intact.
    private func advanceAfterTagging(_ id: MediaItem.ID?) {
        advanceAfterAnnotating(id)
    }

    /// Lands the cursor on a successor computed before an annotation, but only
    /// when the annotation actually emptied the selection — i.e. the annotated
    /// item dropped out of view because a "Hide Flagged/Tagged/Color-Coded" or
    /// a Library tag filter is active. When items survive (a partial multi-
    /// selection, or no hide filter was in effect) the user's selection is left
    /// intact. This keeps next/previous navigation working after annotating the
    /// current item in a filtered view.
    private func advanceAfterAnnotating(_ id: MediaItem.ID?) {
        guard selectedItems.isEmpty, let id else { return }
        selectOnly(id)
    }

    /// Remove any color tag from the given item(s) or the current selection.
    func clearColorTag(item: MediaItem? = nil) {
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
        for id in targets { colorTags[id] = nil }
        clampSelection()
    }

    /// Remove every color tag in the window.
    func clearColorTags() {
        colorTags = [:]
        clampSelection()
    }

    /// Number of items carrying the given color tag.
    func colorTagCount(_ tag: ColorTag) -> Int {
        colorTags.values.reduce(0) { $0 + ($1 == tag ? 1 : 0) }
    }

    /// Total number of tagged items (any color).
    var taggedCount: Int { colorTags.count }

    // MARK: - Text tags

    /// The free-text tags on the given item, sorted alphabetically for stable
    /// display. Empty when untagged.
    func textTags(_ id: MediaItem.ID) -> [String] {
        (textTags[id] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Every text tag created this session, in creation order — including
    /// "empty" tags that no item currently carries, so they stay visible in the
    /// sidebar and overlay until explicitly deleted. Drives the tag-input
    /// overlay's existing-tags list (and its 1–9 quick-assign keys) and the
    /// sidebar's Tags section.
    var allTextTags: [String] { textTagOrder }

    /// Whether every target (the selection, or `item`) already carries `tag` —
    /// used so the overlay can show which existing tags are already applied.
    func allTargetsHaveTextTag(_ tag: String, item: MediaItem? = nil) -> Bool {
        let targets = textTagTargets(item)
        guard !targets.isEmpty else { return false }
        return targets.allSatisfy { (textTags[$0] ?? []).contains(tag) }
    }

    /// Resolves the items a text-tag action should affect, using the same
    /// "specific unselected item, else the whole selection, else the item"
    /// rule as `toggleColorTag`/`toggleFlag`.
    private func textTagTargets(_ item: MediaItem?) -> [MediaItem.ID] {
        if let item, !selectedItems.contains(item.id) {
            return [item.id]
        } else if !selectedItems.isEmpty {
            return Array(selectedItems)
        } else if let item {
            return [item.id]
        }
        return []
    }

    /// Adds `tag` to the target item(s) (the selection, or `item`). Whitespace
    /// is trimmed; empty names are ignored.
    func addTextTag(_ tag: String, item: MediaItem? = nil) {
        let name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let targets = textTagTargets(item)
        guard !targets.isEmpty else { return }
        // Tagging may push the current item out of view when "Hide Tagged" or a
        // tag filter is active; remember the successor so navigation continues.
        let successor = successorAfterHiding(targets)
        for id in targets { textTags[id, default: []].insert(name) }
        // Record first-seen order so the overlay/sidebar list tags as created.
        if !textTagOrder.contains(name) { textTagOrder.append(name) }
        clampSelection()
        advanceAfterAnnotating(successor)
    }

    /// Removes `tag` from the target item(s) (the selection, or `item`),
    /// dropping now-empty entries so `textTags` stays tidy.
    func removeTextTag(_ tag: String, item: MediaItem? = nil) {
        let targets = textTagTargets(item)
        guard !targets.isEmpty else { return }
        for id in targets {
            textTags[id]?.remove(tag)
            if textTags[id]?.isEmpty == true { textTags[id] = nil }
        }
        // The tag itself stays in `textTagOrder` even when no item carries it
        // anymore — it becomes an "empty" tag, still shown in the sidebar until
        // explicitly deleted via `deleteTextTag`.
    }

    /// Toggles `tag` across the target item(s): if every target already has it,
    /// remove it from them all; otherwise add it to them all. Used by the
    /// overlay's 1–9 quick-assign keys.
    func toggleTextTag(_ tag: String, item: MediaItem? = nil) {
        let name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if allTargetsHaveTextTag(name, item: item) {
            removeTextTag(name, item: item)
        } else {
            addTextTag(name, item: item)
        }
    }

    /// Number of distinct items carrying any text tag.
    var textTaggedCount: Int { textTags.count }

    // MARK: - Unmarked

    /// Whether an item has no flag, no color tag, and no text tag — i.e. it
    /// hasn't been triaged yet.
    func isUnmarked(_ id: MediaItem.ID) -> Bool {
        !flaggedItems.contains(id)
            && colorTags[id] == nil
            && (textTags[id]?.isEmpty ?? true)
    }

    /// Number of unmarked items in the whole library (ignoring the current
    /// scope/search), for the sidebar badge.
    var unmarkedCount: Int {
        allItems.reduce(0) { $0 + (isUnmarked($1.id) ? 1 : 0) }
    }

    /// Number of items carrying the given text tag.
    func textTagCount(_ tag: String) -> Int {
        textTags.values.reduce(0) { $0 + ($1.contains(tag) ? 1 : 0) }
    }

    /// Removes a text tag from every item (and drops the sidebar filter if it
    /// pointed at it).
    func deleteTextTag(_ tag: String) {
        for (id, tags) in textTags where tags.contains(tag) {
            var updated = tags
            updated.remove(tag)
            textTags[id] = updated.isEmpty ? nil : updated
        }
        textTagOrder.removeAll { $0 == tag }
        if textTagFilter == tag { textTagFilter = nil }
        clampSelection()
    }

    /// Removes every text tag in the window.
    func clearTextTags() {
        textTags = [:]
        textTagOrder = []
        textTagFilter = nil
        clampSelection()
    }

    // MARK: - AI classification

    /// The AI category for the given item, or `nil` if it hasn't been
    /// classified (or was classified with no usable result).
    func aiCategory(_ id: MediaItem.ID) -> String? {
        guard let category = aiCategories[id], !category.isEmpty else { return nil }
        return category
    }

    /// Distinct categories currently assigned, sorted by descending item count
    /// then alphabetically. Drives the category filter chips and the sidebar.
    var aiCategoryList: [String] {
        var counts: [String: Int] = [:]
        for category in aiCategories.values where !category.isEmpty {
            counts[category, default: 0] += 1
        }
        return counts.keys.sorted { lhs, rhs in
            let (l, r) = (counts[lhs] ?? 0, counts[rhs] ?? 0)
            if l != r { return l > r }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    /// Number of items the classifier placed in `category`.
    func aiCategoryCount(_ category: String) -> Int {
        aiCategories.values.reduce(0) { $0 + ($1 == category ? 1 : 0) }
    }

    /// Total number of classified items (across all categories).
    var classifiedCount: Int {
        aiCategories.values.reduce(0) { $0 + ($1.isEmpty ? 0 : 1) }
    }

    /// Whether there are any image items in the current scope that could be
    /// classified — used to enable/disable the "Classify" action.
    var hasClassifiableImages: Bool {
        scopedItems.contains { $0.kind == .image }
    }

    /// A section for grouped rendering: a header title plus the items in it.
    /// Used for both the category and person grouping dimensions. `symbol`
    /// drives the header icon; `isResidual` marks the trailing catch-all bucket
    /// ("Unclassified" / "No People") so the header can read differently.
    struct CategoryGroup: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let items: [MediaItem]
        var isResidual: Bool = false

        /// An item scoped to this group, so a photo that appears under several
        /// people has a distinct SwiftUI identity in each section (the same
        /// URL would otherwise collide within one lazy container).
        struct Entry: Identifiable {
            let groupID: String
            let item: MediaItem
            var id: String { "\(groupID)\u{1}\(item.id.absoluteString)" }
        }

        var entries: [Entry] { items.map { Entry(groupID: id, item: $0) } }
    }

    /// The displayed items split into sections per the active `grouping`
    /// dimension. Items within a section keep the active sort order. Views read
    /// this only when `grouping != .none`. A `.person` grouping can list the
    /// same photo under several people (it may contain several); the other
    /// dimensions place each item in exactly one bucket.
    var groupedDisplayedItems: [CategoryGroup] {
        // Establish the observation dependency and reuse the cache when the
        // revision still matches (see `cachedGroupedDisplayedItems`).
        _ = displayRevision
        if cachedGroupRevision == displayRevision,
           let cachedGroupedDisplayedItems {
            return cachedGroupedDisplayedItems
        }
        let result: [CategoryGroup]
        switch grouping {
        case .person:   result = groupedByPerson
        case .folder:   result = groupedByFolder
        case .category, .none: result = groupedByCategoryGroups
        }
        cacheGroups(result, at: displayRevision)
        return result
    }

    /// The items in the exact order the grid/list draws them. With no grouping
    /// this is the flat `displayedItems`; with grouping active it's the items
    /// flattened across sections in `groupedDisplayedItems` order. Keyboard
    /// navigation and Shift-click range selection run against this so they
    /// follow what the user sees rather than the underlying flat sort.
    ///
    /// A `.person` grouping can show the same photo under several people; here
    /// each item is kept once, at its first on-screen position, so ranges and
    /// stepping stay well defined (selection is keyed by item regardless).
    var visualOrderItems: [MediaItem] {
        guard grouping != .none else { return displayedItems }
        // Reuse the flattened order when the group cache is current. Reading
        // `groupedDisplayedItems` below fills/validates the shared revision, so
        // check the flattened cache against the same token afterward.
        if cachedGroupRevision == displayRevision,
           let cachedVisualOrderItems {
            return cachedVisualOrderItems
        }
        let groups = groupedDisplayedItems
        var seen: Set<MediaItem.ID> = []
        var out: [MediaItem] = []
        for group in groups {
            for item in group.items where seen.insert(item.id).inserted {
                out.append(item)
            }
        }
        cachedVisualOrderItems = out
        return out
    }

    /// Stores a freshly built `groupedDisplayedItems` result and records the
    /// revision it was built against, dropping any stale flattened order so
    /// `visualOrderItems` rebuilds it lazily on its next read.
    private func cacheGroups(_ groups: [CategoryGroup], at revision: Int) {
        cachedGroupedDisplayedItems = groups
        cachedGroupRevision = revision
        cachedVisualOrderItems = nil
    }

    private var groupedByCategoryGroups: [CategoryGroup] {
        let items = displayedItems
        var buckets: [String: [MediaItem]] = [:]
        for item in items {
            let key = aiCategory(item.id) ?? ""
            buckets[key, default: []].append(item)
        }
        var groups: [CategoryGroup] = []
        for category in aiCategoryList where buckets[category] != nil {
            groups.append(CategoryGroup(
                id: category, title: category, symbol: "sparkles",
                items: buckets[category]!))
        }
        if let unclassified = buckets[""], !unclassified.isEmpty {
            groups.append(CategoryGroup(
                id: "\u{0}unclassified", title: "Unclassified",
                symbol: "questionmark.circle", items: unclassified, isResidual: true))
        }
        return groups
    }

    private var groupedByPerson: [CategoryGroup] {
        let items = displayedItems
        var buckets: [Int: [MediaItem]] = [:]
        var noPeople: [MediaItem] = []
        for item in items {
            let persons = facePersons[item.id] ?? []
            if persons.isEmpty {
                noPeople.append(item)
            } else {
                // A photo with several people appears under each of them.
                for person in persons { buckets[person, default: []].append(item) }
            }
        }
        var groups: [CategoryGroup] = []
        for person in personList where buckets[person] != nil {
            groups.append(CategoryGroup(
                id: "person-\(person)", title: personName(person),
                symbol: "person.crop.circle", items: buckets[person]!))
        }
        if !noPeople.isEmpty {
            groups.append(CategoryGroup(
                id: "\u{0}nopeople", title: "No People",
                symbol: "person.slash", items: noPeople, isResidual: true))
        }
        return groups
    }

    /// Sections the displayed items by their containing directory. Each item
    /// lands in exactly one bucket (its parent folder). Folders are ordered by
    /// their path so sibling directories read in a stable, natural order, and
    /// the header shows the folder's own name.
    private var groupedByFolder: [CategoryGroup] {
        let items = displayedItems
        var buckets: [URL: [MediaItem]] = [:]
        var order: [URL] = []
        for item in items {
            let dir = item.parentDirectory
            if buckets[dir] == nil { order.append(dir) }
            buckets[dir, default: []].append(item)
        }
        let sorted = order.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        return sorted.map { dir in
            CategoryGroup(
                id: "folder-\(dir.path)",
                title: dir.lastPathComponent,
                symbol: "folder",
                items: buckets[dir] ?? [])
        }
    }

    /// Classify the current selection (or a specific right-clicked item) with
    /// the on-device models. Non-image items are skipped. Results stream into
    /// `aiCategories` as each image finishes so the UI fills in progressively.
    func classifySelection(_ item: MediaItem? = nil) {
        let urls = Set(actionURLs(preferring: item))
        let targets = (item.map { [$0] } ?? selectedMediaItems)
            .filter { $0.kind == .image && urls.contains($0.url) }
        classify(items: targets.isEmpty ? imageTargets(from: urls) : targets)
    }

    /// Classify every image in the current scope that hasn't been classified
    /// yet. The common entry point for a "Classify All" / toolbar action.
    func classifyAllImages() {
        let pending = scopedItems.filter {
            $0.kind == .image && aiCategories[$0.id] == nil
        }
        classify(items: pending)
    }

    /// Images matching the given URL set (used when a right-click targets an
    /// unselected item or a multi-selection).
    private func imageTargets(from urls: Set<URL>) -> [MediaItem] {
        allItems.filter { $0.kind == .image && urls.contains($0.url) }
    }

    /// Runs a bounded, concurrent classification pass over `items`, publishing
    /// each result to the observable `aiCategories` map as it lands. Mirrors
    /// `prefetchCodecs`: a single pass runs at a time, work is windowed so we
    /// don't spawn thousands of tasks at once, and results are written on the
    /// main actor so the grid re-sorts/re-groups progressively.
    private func classify(items: [MediaItem]) {
        guard !isRunningClassification else { return }
        // Only images, and only ones not already done.
        let pending = items.filter { $0.kind == .image && aiCategories[$0.id] == nil }
        guard !pending.isEmpty else { return }

        isRunningClassification = true
        isClassifying = true
        classifyActivity = "Classifying"
        classifyProgress = 0
        classifyTotal = pending.count

        Task { @MainActor in
            let maxConcurrent = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
            var iterator = pending.makeIterator()

            await withTaskGroup(of: (MediaItem.ID, String?).self) { group in
                var inFlight = 0

                func addNext() {
                    guard let item = iterator.next() else { return }
                    inFlight += 1
                    group.addTask {
                        let category = await ImageClassifier.shared.category(for: item.url)
                        return (item.id, category)
                    }
                }

                // Prime the window.
                for _ in 0..<maxConcurrent { addNext() }

                while inFlight > 0, let (id, category) = await group.next() {
                    inFlight -= 1
                    self.storeCategory(category, for: id)
                    addNext()
                }
            }

            self.isClassifying = false
            self.isRunningClassification = false
        }
    }

    /// Writes one classification result into the observable map and bumps the
    /// progress counter. Called on the main actor as each image resolves.
    private func storeCategory(_ category: String?, for id: MediaItem.ID) {
        aiCategories[id] = category ?? ""
        classifyProgress += 1
        // Grouping and the category filter both depend on this map, so the
        // memoized displayed list may now be stale.
        if grouping == .category || aiCategoryFilter != nil {
            invalidateDisplayCache()
        }
    }

    /// Clear every AI category in the window and drop any active category
    /// filter/grouping so the grid returns to a flat, unfiltered view.
    func clearAICategories() {
        aiCategories = [:]
        aiCategoryFilter = nil
        if grouping == .category { grouping = .none }
        clampSelection()
    }

    // MARK: - AI category editing (manual corrections)

    /// The item IDs a category/person edit should act on: the clicked `item`
    /// when it isn't part of the selection, otherwise the whole selection (or
    /// just the clicked item when there's no selection). Mirrors how flag/tag
    /// actions resolve their targets.
    private func editTargets(for item: MediaItem?) -> [MediaItem.ID] {
        if let item, !selectedItems.contains(item.id) {
            return [item.id]
        }
        if !selectedItems.isEmpty {
            return Array(selectedItems)
        }
        if let item {
            return [item.id]
        }
        return []
    }

    /// Merge one category into another: every item labeled `source` is
    /// relabeled `destination`. Used to fix the classifier splitting one real
    /// group into two ("Dogs" + "Puppies" → "Dogs"). No-op if they're equal.
    func mergeCategory(_ source: String, into destination: String) {
        guard source != destination, !destination.isEmpty else { return }
        for (id, category) in aiCategories where category == source {
            aiCategories[id] = destination
        }
        if aiCategoryFilter == source { aiCategoryFilter = destination }
        invalidateDisplayCache()
        clampSelection()
    }

    /// Rename a category in place (relabels every item carrying it).
    func renameCategory(_ source: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != source else { return }
        mergeCategory(source, into: trimmed)
    }

    /// Move the target files (the clicked item or the current selection) into
    /// `category`, replacing whatever category they had. Creating a brand-new
    /// category is just passing a name nothing else uses yet.
    func assignCategory(_ category: String, item: MediaItem? = nil) {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let targets = editTargets(for: item)
        guard !targets.isEmpty else { return }
        for id in targets { aiCategories[id] = trimmed }
        invalidateDisplayCache()
        clampSelection()
    }

    /// Remove the target files from their category (they become Unclassified).
    func removeFromCategory(item: MediaItem? = nil) {
        let targets = editTargets(for: item)
        guard !targets.isEmpty else { return }
        for id in targets { aiCategories[id] = "" }
        invalidateDisplayCache()
        clampSelection()
    }

    /// Whether any target file currently carries an AI category — used to
    /// enable "Remove from Category" in menus.
    func canRemoveFromCategory(item: MediaItem? = nil) -> Bool {
        editTargets(for: item).contains { aiCategory($0) != nil }
    }

    /// Delete a whole category: every item carrying it becomes Unclassified.
    func deleteCategory(_ category: String) {
        guard !category.isEmpty else { return }
        for (id, value) in aiCategories where value == category {
            aiCategories[id] = ""
        }
        if aiCategoryFilter == category { aiCategoryFilter = nil }
        invalidateDisplayCache()
        clampSelection()
    }

    // MARK: - Face recognition

    /// The recognized people in the given item, as person IDs. Empty if the
    /// item hasn't been processed or no face was found.
    func persons(_ id: MediaItem.ID) -> Set<Int> {
        facePersons[id] ?? []
    }

    /// Distinct person IDs found so far, sorted by descending photo count then
    /// by ID (so the most-photographed person is "Person 1"-ish at the front).
    var personList: [Int] {
        var counts: [Int: Int] = [:]
        for persons in facePersons.values {
            for person in persons { counts[person, default: 0] += 1 }
        }
        return counts.keys.sorted { lhs, rhs in
            let (l, r) = (counts[lhs] ?? 0, counts[rhs] ?? 0)
            if l != r { return l > r }
            return lhs < rhs
        }
    }

    /// Display name for a person cluster. Identity-free, so it's just the
    /// cluster number ("Person 3").
    func personName(_ id: Int) -> String { "Person \(id)" }

    /// Number of photos containing the given person.
    func personCount(_ id: Int) -> Int {
        facePersons.values.reduce(0) { $0 + ($1.contains(id) ? 1 : 0) }
    }

    /// Number of items in which at least one face was recognized.
    var withFacesCount: Int {
        facePersons.values.reduce(0) { $0 + ($1.isEmpty ? 0 : 1) }
    }

    /// Recognize faces in the current selection (or a specific right-clicked
    /// item). Non-image items are skipped.
    func recognizeFacesInSelection(_ item: MediaItem? = nil) {
        let urls = Set(actionURLs(preferring: item))
        let targets = (item.map { [$0] } ?? selectedMediaItems)
            .filter { $0.kind == .image && urls.contains($0.url) }
        recognizeFaces(items: targets.isEmpty ? imageTargets(from: urls) : targets)
    }

    /// Recognize faces across every image in the current scope not yet
    /// processed. The common entry point for a "Find Faces" toolbar action.
    func recognizeAllFaces() {
        let pending = scopedItems.filter {
            $0.kind == .image && facePersons[$0.id] == nil
        }
        recognizeFaces(items: pending)
    }

    /// Runs a face-detection + feature-print pass over `items`, then clusters
    /// the faces into people. Detection/feature-print extraction is concurrent
    /// (bounded, off the main actor); clustering is applied on the main actor
    /// in a stable item order so person IDs are deterministic.
    ///
    /// To keep person IDs stable when re-running after adding photos, the
    /// clusterer is primed with the faces already assigned, so new faces extend
    /// the existing people rather than renumbering them.
    private func recognizeFaces(items: [MediaItem]) {
        guard !isRunningClassification else { return }
        let pending = items.filter { $0.kind == .image && facePersons[$0.id] == nil }
        guard !pending.isEmpty else { return }

        isRunningClassification = true
        isClassifying = true
        classifyActivity = "Finding Faces"
        classifyProgress = 0
        classifyTotal = pending.count

        // Continue person numbering past any people already found so a second
        // pass doesn't reuse IDs. (Representatives from the prior pass aren't
        // retained, so this is a fresh clusterer seeded only with the next ID.)
        let startID = (personList.max() ?? 0) + 1

        let engine = faceEngine
        let threshold = faceClusterThreshold

        Task { @MainActor in
            var clusterer = FaceClusterer(threshold: threshold)
            clusterer.seedNextID(startID)

            let maxConcurrent = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

            // Extract face prints concurrently, but cluster in the fixed
            // `pending` order (not completion order) so IDs are deterministic.
            // We gather results into a dictionary keyed by item, then walk
            // `pending` sequentially to assign clusters.
            var printsByItem: [MediaItem.ID: [FaceFeaturePrint]] = [:]
            var iterator = pending.makeIterator()

            await withTaskGroup(of: (MediaItem.ID, [FaceFeaturePrint]).self) { group in
                var inFlight = 0
                func addNext() {
                    guard let item = iterator.next() else { return }
                    inFlight += 1
                    group.addTask {
                        let faces = await FaceRecognizer.shared.faces(for: item.url, engine: engine)
                        return (item.id, faces)
                    }
                }
                for _ in 0..<maxConcurrent { addNext() }
                while inFlight > 0, let (id, faces) = await group.next() {
                    inFlight -= 1
                    printsByItem[id] = faces
                    // Progress tracks extraction (the slow part); clustering
                    // below is near-instant.
                    self.classifyProgress += 1
                    addNext()
                }
            }

            // Order the gathered prints by display order so clustering (and
            // thus person IDs) is deterministic, then run the shared pass.
            let ordered = pending.map { (id: $0.id, faces: printsByItem[$0.id] ?? []) }

            // Diagnostics: how many images yielded at least one embedding, and
            // the total embedding count + dimension. This pins down whether the
            // problem is detection, embedding, or clustering.
            let embeddedFaceCount = printsByItem.values.reduce(0) { $0 + $1.count }
            let imagesWithEmbeddings = printsByItem.values.filter { !$0.isEmpty }.count
            let dim = printsByItem.values.lazy.flatMap { $0 }.first.map { face -> Int in
                if case let .vector(v) = face.embedding { return v.count }
                return -1
            } ?? 0
            print("[FaceRecognition] engine=\(engine.rawValue) images=\(pending.count) " +
                  "imagesWithFaces=\(imagesWithEmbeddings) faces=\(embeddedFaceCount) dim=\(dim) " +
                  "threshold=\(threshold)")

            self.applyClustering(ordered, into: &clusterer)

            // Explain a Core ML run that produced no useful grouping.
            if engine == .coreMLEmbedding {
                if embeddedFaceCount == 0 {
                    // Nothing embedded: either the request failed or the output
                    // couldn't be read as a vector.
                    self.faceRecognitionNote = await FaceRecognizer.shared.coreMLFailureReason()
                        ?? "The Core ML model ran but returned no face embeddings. "
                           + "Check the model's output is a float multi-array (embedding)."
                } else {
                    // Embeddings exist. If almost every face became its own
                    // "person", the threshold is too strict for this model's
                    // distance scale — nudge the user toward a looser setting.
                    let people = self.personList.count
                    print("[FaceRecognition] produced \(people) people from \(embeddedFaceCount) faces")
                    if people >= embeddedFaceCount, embeddedFaceCount > 1 {
                        self.faceRecognitionNote =
                            "Each face became its own person — the sensitivity is too strict "
                            + "for this model. Move the slider toward 'Looser'."
                    } else {
                        self.faceRecognitionNote = nil
                    }
                }
            } else {
                self.faceRecognitionNote = nil
            }

            if self.grouping == .person || self.personFilter != nil {
                self.invalidateDisplayCache()
            }
            self.isClassifying = false
            self.isRunningClassification = false
        }
    }

    /// Runs the online clustering pass over `ordered` prints, then the
    /// agglomerative merge pass, and writes the resulting per-item person sets
    /// into `facePersons`. Shared by the initial recognition and re-clustering
    /// (threshold change) so both produce identical grouping logic.
    private func applyClustering(
        _ ordered: [(id: MediaItem.ID, faces: [FaceFeaturePrint])],
        into clusterer: inout FaceClusterer
    ) {
        var assigned: [MediaItem.ID: Set<Int>] = [:]
        for entry in ordered {
            var people = Set<Int>()
            for face in entry.faces {
                if let person = clusterer.assign(face) { people.insert(person) }
            }
            assigned[entry.id] = people
        }
        let remap = clusterer.finalizeMerges()
        for (id, people) in assigned {
            facePersons[id] = Set(people.map { remap[$0] ?? $0 })
        }
    }

    /// Re-cluster the faces already extracted — at the current threshold —
    /// without re-detecting or re-embedding. Fast (the embeddings are cached in
    /// `FaceRecognizer`), so the threshold slider can re-group live. No-op if
    /// nothing has been recognized yet.
    func reclusterFaces() {
        guard !isRunningClassification, !facePersons.isEmpty else { return }
        let targets = allItems.filter { $0.kind == .image && facePersons[$0.id] != nil }
        guard !targets.isEmpty else { return }

        let engine = faceEngine
        let threshold = faceClusterThreshold

        isRunningClassification = true
        Task { @MainActor in
            // Pull cached embeddings back (cache hits — no detection work).
            var byItem: [MediaItem.ID: [FaceFeaturePrint]] = [:]
            for item in targets {
                byItem[item.id] = await FaceRecognizer.shared.faces(for: item.url, engine: engine)
            }
            let ordered = targets.map { (id: $0.id, faces: byItem[$0.id] ?? []) }

            var clusterer = FaceClusterer(threshold: threshold)
            self.applyClustering(ordered, into: &clusterer)

            if self.grouping == .person || self.personFilter != nil {
                self.invalidateDisplayCache()
            }
            self.isRunningClassification = false
        }
    }

    /// Resolve whether a Core ML face model is installed, updating the
    /// observable flag the UI reads. Call once when the People controls appear.
    func refreshCoreMLFaceAvailability() {
        Task { @MainActor in
            self.coreMLFaceModelAvailable = await FaceRecognizer.shared.coreMLAvailable()
        }
    }

    /// Present an open panel to pick a Core ML face-embedding model, store a
    /// security-scoped bookmark to it (so it loads under the app sandbox on
    /// future launches), and refresh availability. The bookmark — not a raw
    /// path — is what the sandbox honors.
    func chooseFaceModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true   // .mlmodelc / .mlpackage are directories
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Core ML face-embedding model (.mlmodel, .mlmodelc, or .mlpackage)"
        panel.prompt = "Use Model"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "mlmodel"),
            UTType(filenameExtension: "mlmodelc"),
            UTType(filenameExtension: "mlpackage")
        ].compactMap { $0 }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Create an app-scoped bookmark the sandbox will restore later.
        if let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(
                bookmark, forKey: CoreMLFaceEmbedder.modelBookmarkDefaultsKey
            )
        }

        // Reload the store with the new model, switch to the Core ML engine,
        // and recompute availability.
        Task { @MainActor in
            await FaceModelStore.shared.invalidate()
            self.faceEngine = .coreMLEmbedding
            self.refreshCoreMLFaceAvailability()
        }
    }

    /// Forget the chosen Core ML model (clears the bookmark) and fall back to
    /// the Vision engine.
    func clearFaceModel() {
        UserDefaults.standard.removeObject(forKey: CoreMLFaceEmbedder.modelBookmarkDefaultsKey)
        if faceEngine == .coreMLEmbedding { faceEngine = .visionFeaturePrint }
        Task { @MainActor in
            await FaceModelStore.shared.invalidate()
            self.refreshCoreMLFaceAvailability()
        }
    }

    /// Clear all recognized people and drop any person filter/grouping.
    func clearFaces() {
        facePersons = [:]
        personFilter = nil
        if grouping == .person { grouping = .none }
        clampSelection()
    }

    // MARK: - People editing (manual corrections)

    /// Merge one person into another: `source` is replaced by `destination`
    /// everywhere it appears, so photos of the same person the clusterer split
    /// across two IDs collapse into one. A photo that had both ends up with
    /// just `destination` (sets dedupe). No-op if they're equal.
    func mergePerson(_ source: Int, into destination: Int) {
        guard source != destination else { return }
        for (id, people) in facePersons where people.contains(source) {
            var updated = people
            updated.remove(source)
            updated.insert(destination)
            facePersons[id] = updated
        }
        if personFilter == source { personFilter = destination }
        invalidateDisplayCache()
        clampSelection()
    }

    /// Move the target files (clicked item or selection) to `person`: the
    /// person is added, and if `replacing` is given that person is removed from
    /// those files first — i.e. "move these photos from Person A to Person B".
    func assignPerson(_ person: Int, replacing: Int? = nil, item: MediaItem? = nil) {
        let targets = editTargets(for: item)
        guard !targets.isEmpty else { return }
        for id in targets {
            var people = facePersons[id] ?? []
            if let replacing { people.remove(replacing) }
            people.insert(person)
            facePersons[id] = people
        }
        invalidateDisplayCache()
        clampSelection()
    }

    /// Remove `person` from the target files (clicked item or selection). Used
    /// to correct a false match without deleting the person entirely.
    func removePerson(_ person: Int, item: MediaItem? = nil) {
        let targets = editTargets(for: item)
        guard !targets.isEmpty else { return }
        for id in targets {
            guard var people = facePersons[id], people.contains(person) else { continue }
            people.remove(person)
            facePersons[id] = people
        }
        if let filter = personFilter,
           !facePersons.values.contains(where: { $0.contains(filter) }) {
            personFilter = nil
        }
        invalidateDisplayCache()
        clampSelection()
    }

    /// Whether any target file is currently tagged with `person` — used to
    /// enable "Remove from Person" in menus.
    func targetsContainPerson(_ person: Int, item: MediaItem? = nil) -> Bool {
        let targets = editTargets(for: item)
        return targets.contains { facePersons[$0]?.contains(person) ?? false }
    }

    /// Assign the given image files (by URL — from a drag-and-drop) to `person`.
    /// When `movingFrom` is set, those files are first removed from that person,
    /// turning the drop into a *move* from one person to another (used when the
    /// grid is currently filtered to a person). Non-image files are ignored.
    /// Returns the number of files actually assigned.
    @discardableResult
    func assignPerson(_ person: Int, toURLs urls: [URL], movingFrom: Int? = nil) -> Int {
        let present = Set(allItems.lazy.filter { $0.kind == .image }.map(\.id))
        let ids = urls.map { $0.standardizedFileURL }.filter { present.contains($0) }
        guard !ids.isEmpty else { return 0 }

        for id in ids {
            var people = facePersons[id] ?? []
            if let movingFrom { people.remove(movingFrom) }
            people.insert(person)
            facePersons[id] = people
        }
        // A move may have emptied the source person; drop a stale filter.
        if let filter = personFilter,
           !facePersons.values.contains(where: { $0.contains(filter) }) {
            personFilter = nil
        }
        invalidateDisplayCache()
        clampSelection()
        return ids.count
    }

    /// Delete a whole person: remove that ID from every photo it appears in.
    func deletePerson(_ person: Int) {
        for (id, people) in facePersons where people.contains(person) {
            var updated = people
            updated.remove(person)
            facePersons[id] = updated
        }
        if personFilter == person { personFilter = nil }
        invalidateDisplayCache()
        clampSelection()
    }

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

    /// Whether a copy action currently has any target (used to enable/disable
    /// the menu item and keyboard shortcut).
    var canCopySelection: Bool { !selectedItems.isEmpty }

    /// Copies the given items (or the current selection) to the general
    /// pasteboard as file references, so they can be pasted into Finder or any
    /// app that accepts files (⌘C → ⌘V copies the actual files). Writing the
    /// `URL`s as pasteboard objects advertises them as `public.file-url`, which
    /// Finder reads as a file copy. The absolute-path string is also added so
    /// plain-text targets (editors, terminals) receive the paths.
    @discardableResult
    func copyToClipboard(_ item: MediaItem? = nil) -> Int {
        let urls = actionURLs(preferring: item)
        guard !urls.isEmpty else { return 0 }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        // Tab-separated paths as a plain-text fallback for non-file targets.
        let paths = urls.map(\.path).joined(separator: "\n")
        pasteboard.setString(paths, forType: .string)
        return urls.count
    }

    /// Image URLs among the given items (or the current selection), in display
    /// order. Used by the "Copy Image" actions, which only operate on images.
    func imageURLs(preferring item: MediaItem? = nil) -> [URL] {
        let candidates: [MediaItem]
        if let item, !selectedItems.contains(item.id) {
            candidates = [item]
        } else {
            let selected = selectedMediaItems
            candidates = selected.isEmpty ? (item.map { [$0] } ?? []) : selected
        }
        return candidates.filter { $0.kind == .image }.map(\.url)
    }

    /// Whether the current selection (or `item`) contains at least one image,
    /// so the "Copy Image" menu items can enable/disable themselves.
    var canCopyImageSelection: Bool {
        selectedMediaItems.contains { $0.kind == .image }
    }

    /// Copies the selected image(s) to the clipboard as rendered pixel data —
    /// at `scale`, optionally with EXIF/metadata stripped — rather than as file
    /// references. Pasting drops in the actual picture (resized / de-tagged as
    /// chosen). Returns the number of images copied. No-op if nothing in the
    /// selection is an image.
    @discardableResult
    func copyImageToClipboard(
        _ item: MediaItem? = nil,
        scale: ImageCopyScale = .original,
        format: ImageCopyFormat? = nil,
        stripMetadata: Bool? = nil
    ) -> Int {
        let urls = imageURLs(preferring: item)
        guard !urls.isEmpty else { return 0 }

        // Fall back to the persisted preferences when the caller doesn't
        // override them (menus pass explicit values; some call sites rely on
        // the current settings).
        let fmt = format ?? imageCopyFormat
        let strip = stripMetadata ?? imageCopyStripsMetadata

        // A single small image copies effectively instantly, so skip the async
        // progress machinery and copy synchronously.
        if urls.count == 1 {
            return ImageClipboard.copy(urls: urls, scale: scale, format: fmt, stripMetadata: strip)
        }

        // Multiple images: render in the background with a progress indicator,
        // since decoding/encoding many (large or RAW) images can take a moment.
        guard !isCopyingImages else { return urls.count }
        isCopyingImages = true
        copyProgress = 0
        copyTotal = urls.count

        Task { @MainActor in
            defer { isCopyingImages = false }
            await ImageClipboard.copy(
                urls: urls,
                scale: scale,
                format: fmt,
                stripMetadata: strip
            ) { [weak self] completed, total in
                self?.copyProgress = completed
                self?.copyTotal = total
            }
        }
        return urls.count
    }

    // MARK: - Image-copy progress

    /// True while a multi-image "Copy Image" render is in flight, so the UI can
    /// show a progress indicator. A single-image copy is synchronous and never
    /// flips this.
    private(set) var isCopyingImages = false
    /// Images rendered so far in the running copy, and the total requested.
    private(set) var copyProgress = 0
    private(set) var copyTotal = 0

    // MARK: - Image export

    /// The scale applied to exported images. Window-scoped and in-session only,
    /// like the copy prefs. Defaults to the original resolution.
    var exportScale: ImageCopyScale = .original

    /// The encoding format for exported images (JPEG or PNG). Defaults to JPEG,
    /// matching the copy default.
    var exportFormat: ImageCopyFormat = .defaultFormat

    /// Whether exported images drop their EXIF/GPS metadata. Mirrors the copy
    /// toggle; only meaningful for formats that can carry metadata (JPEG).
    var exportStripsMetadata = true

    /// JPEG compression quality for image export, on a 0...100 scale (higher =
    /// better quality, larger file). Only applies when the export format is
    /// JPEG. Defaults to 95, a high-quality near-transparent setting.
    var exportJPEGQuality = 95

    /// When true, a manually-entered long-edge pixel width (`exportCustomLongEdge`)
    /// overrides `exportScale`. Lets the user cap the output to an exact size
    /// instead of a preset percentage / fit option.
    var exportUseCustomLongEdge = false

    /// The user-entered longest-edge cap, in pixels, used when
    /// `exportUseCustomLongEdge` is on. Never upscales a smaller source.
    var exportCustomLongEdge = 1920

    /// The last folder an export was sent to, remembered so "Quick Export" can
    /// reuse it without prompting again. Window-scoped and in-session only.
    private(set) var lastExportDirectory: URL?

    /// True while an export render is running, so the UI can show progress.
    private(set) var isExportingImages = false
    /// Images written so far in the running export, and the total requested.
    private(set) var exportProgress = 0
    private(set) var exportTotal = 0

    /// The custom long-edge value to apply to an export, or `nil` when the
    /// custom cap is off or not a usable positive number (so the scale preset
    /// is used instead).
    private var activeCustomLongEdge: Int? {
        guard exportUseCustomLongEdge, exportCustomLongEdge > 0 else { return nil }
        return exportCustomLongEdge
    }

    /// The JPEG quality to apply to an export as a 0...1 value, or `nil` when
    /// the format isn't JPEG (PNG is lossless, so quality doesn't apply).
    private var activeJPEGQuality: Double? {
        guard exportFormat == .jpeg else { return nil }
        return Double(max(0, min(100, exportJPEGQuality))) / 100.0
    }

    /// Whether a quick re-export is possible: there's a remembered destination
    /// and the target contains at least one image.
    func canQuickExport(_ item: MediaItem? = nil) -> Bool {
        lastExportDirectory != nil && !imageURLs(preferring: item).isEmpty
    }

    /// Whether the current selection (or `item`) contains at least one image,
    /// so the "Export Images" menu can enable/disable itself. Export only
    /// operates on images, exactly like "Copy Image".
    var canExportSelection: Bool { canCopyImageSelection }

    /// Exports the selected image(s) (or `item`) into `directory`, re-encoded
    /// at `scale` in `format`, optionally stripping metadata. Non-image items
    /// are ignored. Returns immediately; the render runs in the background and
    /// drives `isExportingImages`/`exportProgress`/`exportTotal` so the toolbar
    /// can show progress.
    ///
    /// Falls back to the persisted export prefs when the caller doesn't pass an
    /// override. Output files are named after the source (de-duped within the
    /// destination so an export never clobbers an existing file).
    func exportImages(
        toDirectory directory: URL,
        item: MediaItem? = nil,
        scale: ImageCopyScale? = nil,
        format: ImageCopyFormat? = nil,
        stripMetadata: Bool? = nil
    ) {
        let urls = imageURLs(preferring: item)
        guard !urls.isEmpty, !isExportingImages else { return }

        let resolvedScale = scale ?? exportScale
        let fmt = format ?? exportFormat
        let strip = stripMetadata ?? exportStripsMetadata
        let longEdge = activeCustomLongEdge
        let quality = (fmt == .jpeg) ? activeJPEGQuality : nil

        // Remember the destination so "Quick Export" can reuse it this session.
        lastExportDirectory = directory

        isExportingImages = true
        exportProgress = 0
        exportTotal = urls.count

        Task { @MainActor in
            defer { isExportingImages = false }
            await ImageExporter.export(
                urls: urls,
                toDirectory: directory,
                scale: resolvedScale,
                format: fmt,
                stripMetadata: strip,
                maxLongEdge: longEdge,
                jpegQuality: quality
            ) { [weak self] completed, total in
                self?.exportProgress = completed
                self?.exportTotal = total
            }
        }
    }

    /// Re-exports the selected image(s) (or `item`) into the previously-chosen
    /// folder without prompting again. No-op if no folder has been chosen yet
    /// this session or there's nothing exportable. Uses the current export
    /// prefs, exactly like a full export.
    func quickExport(_ item: MediaItem? = nil) {
        guard let directory = lastExportDirectory else { return }
        exportImages(toDirectory: directory, item: item)
    }

    /// Prompts for a destination folder with an `NSOpenPanel`, then exports the
    /// selected image(s) (or `item`) into it using the current export prefs.
    /// No-op if nothing exportable is targeted or the user cancels. Shared by
    /// the menu-bar command and the grid/list context menus.
    func exportImagesToChosenFolder(_ item: MediaItem? = nil) {
        guard !imageURLs(preferring: item).isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Choose a folder to export the selected image(s) into."

        guard panel.runModal() == .OK, let directory = panel.url else { return }
        exportImages(toDirectory: directory, item: item)
    }

    // MARK: - Video export (transcode)

    /// The output resolution for a video export (1080p / 720p). Window-scoped
    /// and in-session only, like the image export prefs.
    var exportVideoResolution: VideoTranscoder.Resolution = .p1080

    /// The encoder used for a video export — software H.264 (max compatibility)
    /// or hardware H.265 via VideoToolbox (much faster, smaller files).
    var exportVideoCodec: VideoTranscoder.Codec = .h264

    /// When true, a video export targets a fixed perceptual quality
    /// (`exportVideoConstantQuality`) rather than an automatic bitrate. On by
    /// default.
    var exportVideoUseConstantQuality = true

    /// The constant-quality (CQ) value for a video export, on a 0...100 scale
    /// (higher = better quality, larger file). Defaults to 70.
    var exportVideoConstantQuality = 70

    /// The rate-control mode derived from the two prefs above, passed to the
    /// transcoder.
    var exportVideoRateControl: VideoTranscoder.RateControl {
        exportVideoUseConstantQuality
            ? .constantQuality(exportVideoConstantQuality)
            : .automaticBitrate
    }

    // MARK: Video export queue

    /// A single queued/running/finished video transcode. Each selected video
    /// becomes one job; the queue processes them one at a time so the machine
    /// isn't swamped and the UI can report exactly which file is encoding.
    struct VideoExportJob: Identifiable, Sendable {
        enum Status: Sendable, Equatable {
            case queued
            case transcoding(fraction: Double)
            case completed
            case failed

            var isActive: Bool {
                if case .transcoding = self { return true }
                return false
            }
            var isFinished: Bool { self == .completed || self == .failed }
        }

        let id = UUID()
        let sourceURL: URL
        let destinationDirectory: URL
        let resolution: VideoTranscoder.Resolution
        let codec: VideoTranscoder.Codec
        let rateControl: VideoTranscoder.RateControl
        var status: Status = .queued

        /// The source file's display name (for the queue list).
        var name: String { sourceURL.lastPathComponent }
    }

    /// The transcode queue, in processing order. Jobs are appended by the
    /// export actions and drained one at a time by `drainVideoExportQueue`.
    /// Finished jobs stay in the list (so the user sees results) until cleared.
    private(set) var videoExportQueue: [VideoExportJob] = []

    /// True while the queue worker is actively draining jobs.
    private(set) var isDrainingVideoQueue = false

    /// Cancellation flag for the job currently transcoding, so an active job
    /// can be aborted. The detached transcode worker polls it. Nil between jobs.
    @ObservationIgnored private var activeVideoExportCancellation: CancellationFlag?

    /// Jobs the user asked to cancel while they were mid-transcode. The drain
    /// loop removes (rather than marks failed) any job in this set when its
    /// transcode returns.
    @ObservationIgnored private var cancelledVideoExportJobs: Set<VideoExportJob.ID> = []

    /// Whether anything in the queue is still queued or transcoding.
    var hasPendingVideoExports: Bool {
        videoExportQueue.contains { !$0.status.isFinished }
    }

    /// The job currently being transcoded, if any.
    var activeVideoExportJob: VideoExportJob? {
        videoExportQueue.first { $0.status.isActive }
    }

    /// Number of jobs still waiting (not yet started).
    var queuedVideoExportCount: Int {
        videoExportQueue.filter { $0.status == .queued }.count
    }

    /// Video URLs among the given items (or the current selection), in display
    /// order. The video counterpart to `imageURLs`.
    func videoURLs(preferring item: MediaItem? = nil) -> [URL] {
        let candidates: [MediaItem]
        if let item, !selectedItems.contains(item.id) {
            candidates = [item]
        } else {
            let selected = selectedMediaItems
            candidates = selected.isEmpty ? (item.map { [$0] } ?? []) : selected
        }
        return candidates.filter { $0.kind == .video }.map(\.url)
    }

    /// Whether the current selection (or `item`) contains at least one video,
    /// so the video export UI can enable/disable itself.
    var canExportVideoSelection: Bool {
        selectedMediaItems.contains { $0.kind == .video }
    }

    /// Whether a quick video re-export is possible: a remembered destination
    /// plus at least one video in the target.
    func canQuickExportVideo(_ item: MediaItem? = nil) -> Bool {
        lastExportDirectory != nil && !videoURLs(preferring: item).isEmpty
    }

    /// Enqueues the selected video(s) (or `item`) for transcoding into
    /// `directory` at the current resolution/codec/quality prefs, copying the
    /// audio stream. Non-video items are ignored. One job is added per video;
    /// the queue drains them one at a time in the background, so this returns
    /// immediately and multiple exports can be queued up.
    ///
    /// Output files are MP4s named after the source, de-duped against the
    /// destination so an export never clobbers an existing file.
    func exportVideos(toDirectory directory: URL, item: MediaItem? = nil) {
        let urls = videoURLs(preferring: item)
        guard !urls.isEmpty else { return }

        let resolution = exportVideoResolution
        let codec = exportVideoCodec
        let rateControl = exportVideoRateControl

        // Remember the destination so "Quick Export" can reuse it this session.
        lastExportDirectory = directory

        for url in urls {
            videoExportQueue.append(
                VideoExportJob(
                    sourceURL: url,
                    destinationDirectory: directory,
                    resolution: resolution,
                    codec: codec,
                    rateControl: rateControl
                )
            )
        }

        startVideoExportQueueIfNeeded()
    }

    /// Starts the serial queue worker if it isn't already running. The worker
    /// processes jobs in order, transcoding each on a detached task and
    /// publishing per-job progress back onto the queue so the UI updates.
    private func startVideoExportQueueIfNeeded() {
        guard !isDrainingVideoQueue else { return }
        isDrainingVideoQueue = true

        Task { @MainActor in
            defer { isDrainingVideoQueue = false }
            await drainVideoExportQueue()
        }
    }

    /// Processes every still-queued job in order, one at a time. Each job's
    /// transcode runs in its own cancellable task (stored in
    /// `activeVideoExportTask`) so `removeVideoExportJob` can abort it.
    private func drainVideoExportQueue() async {
        while let index = videoExportQueue.firstIndex(where: { $0.status == .queued }) {
            let job = videoExportQueue[index]
            videoExportQueue[index].status = .transcoding(fraction: 0)
            let jobID = job.id

            let cancellation = CancellationFlag()
            activeVideoExportCancellation = cancellation

            let succeeded = await VideoExporter.transcodeOne(
                sourceURL: job.sourceURL,
                destinationDirectory: job.destinationDirectory,
                resolution: job.resolution,
                codec: job.codec,
                rateControl: job.rateControl,
                cancellation: cancellation
            ) { [weak self] fraction in
                guard let self else { return }
                if let i = self.videoExportQueue.firstIndex(where: { $0.id == jobID }) {
                    self.videoExportQueue[i].status = .transcoding(fraction: fraction)
                }
            }
            activeVideoExportCancellation = nil

            // If the user cancelled this job mid-transcode, drop it from the
            // queue entirely rather than leaving a "failed" row behind.
            if cancelledVideoExportJobs.remove(jobID) != nil {
                videoExportQueue.removeAll { $0.id == jobID }
            } else if let i = videoExportQueue.firstIndex(where: { $0.id == jobID }) {
                videoExportQueue[i].status = succeeded ? .completed : .failed
            }
        }
    }

    /// Removes a job from the queue. A queued or finished job is dropped
    /// immediately; a job that's currently transcoding is cancelled (its
    /// in-flight transcode aborts promptly and the partial output is deleted),
    /// then the drain loop removes it.
    func removeVideoExportJob(_ id: VideoExportJob.ID) {
        guard let index = videoExportQueue.firstIndex(where: { $0.id == id }) else { return }

        if videoExportQueue[index].status.isActive {
            // Mark it for removal and signal the running transcode to stop; the
            // drain loop finishes the cleanup when the transcode returns.
            cancelledVideoExportJobs.insert(id)
            activeVideoExportCancellation?.cancel()
        } else {
            videoExportQueue.remove(at: index)
        }
    }

    /// Clears all finished (completed/failed) jobs from the queue, leaving any
    /// queued or in-flight ones.
    func clearFinishedVideoExports() {
        videoExportQueue.removeAll { $0.status.isFinished }
    }

    /// Removes every job: cancels an in-flight transcode and drops all queued
    /// and finished entries.
    func clearVideoExportQueue() {
        if let active = activeVideoExportJob {
            cancelledVideoExportJobs.insert(active.id)
            activeVideoExportCancellation?.cancel()
        }
        // Drop everything that isn't the active job (that one is removed by the
        // drain loop once its cancelled transcode returns).
        let activeID = activeVideoExportJob?.id
        videoExportQueue.removeAll { $0.id != activeID }
    }

    /// Re-transcodes the selected video(s) into the previously-chosen folder
    /// without prompting again. No-op if no folder has been chosen this session
    /// or there's nothing exportable.
    func quickExportVideo(_ item: MediaItem? = nil) {
        guard let directory = lastExportDirectory else { return }
        exportVideos(toDirectory: directory, item: item)
    }

    /// The hotkey target for queueing a video transcode: enqueues to the
    /// last-used folder when one is remembered (no prompt — the quick path),
    /// otherwise falls back to prompting for a destination the first time.
    /// No-op when the target has no video.
    func quickExportVideoOrPrompt(_ item: MediaItem? = nil) {
        guard !videoURLs(preferring: item).isEmpty else { return }
        if lastExportDirectory != nil {
            quickExportVideo(item)
        } else {
            exportVideosToChosenFolder(item)
        }
    }

    /// The image counterpart to `quickExportVideoOrPrompt`: exports the
    /// selected image(s) to the last-used folder without prompting when one is
    /// remembered, otherwise prompts the first time. No-op when the target has
    /// no image.
    func quickExportImagesOrPrompt(_ item: MediaItem? = nil) {
        guard !imageURLs(preferring: item).isEmpty else { return }
        if lastExportDirectory != nil {
            quickExport(item)
        } else {
            exportImagesToChosenFolder(item)
        }
    }

    /// Unified quick-export hotkey target (⇧⌘E): quick-exports whatever media
    /// the selection (or `item`) contains — images are written to the last-used
    /// folder and videos are queued for transcoding, prompting once for a
    /// destination if none is remembered yet. Handles a mixed selection by
    /// doing both.
    func quickExportSelection(_ item: MediaItem? = nil) {
        if !imageURLs(preferring: item).isEmpty {
            quickExportImagesOrPrompt(item)
        }
        if !videoURLs(preferring: item).isEmpty {
            quickExportVideoOrPrompt(item)
        }
    }

    /// Whether the selection (or `item`) has anything the quick-export hotkey
    /// can act on (an image or a video).
    func canQuickExportSelection(_ item: MediaItem? = nil) -> Bool {
        !imageURLs(preferring: item).isEmpty || !videoURLs(preferring: item).isEmpty
    }

    /// Prompts for a destination folder, then transcodes the selected video(s)
    /// (or `item`) into it at the current resolution preset. No-op if nothing
    /// exportable is targeted or the user cancels.
    func exportVideosToChosenFolder(_ item: MediaItem? = nil) {
        guard !videoURLs(preferring: item).isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Choose a folder to export the selected video(s) into."

        guard panel.runModal() == .OK, let directory = panel.url else { return }
        exportVideos(toDirectory: directory, item: item)
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
        // Use the on-screen (grouping-aware) order so the cursor advances to the
        // item that visually follows the deleted one, matching keyboard nav. The
        // flat `displayedItems` order would land on an unrelated item whenever a
        // grouping is active, since its index positions differ from what's drawn.
        let order = visualOrderItems.map(\.id)
        let trashedSet = Set(urls)
        let firstTrashedIndex = order.firstIndex { trashedSet.contains($0) }
        // How many items the viewer was showing before this trash, so a
        // multi-image view can be re-formed at the same size afterward.
        let selectedCountBeforeTrash = selectedItems.count

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
        // Index against the same visual order used to record `firstTrashedIndex`.
        let survivors = visualOrderItems.map(\.id)
        if survivors.isEmpty {
            clearSelection()
            isViewerPresented = false
        } else if let idx = firstTrashedIndex {
            let next = min(idx, survivors.count - 1)
            // In the fullscreen viewer's multi-item mode, keep showing a full
            // block the same size as what was open instead of collapsing to a
            // single image — so deleting a file and navigating past it keeps the
            // side-by-side count. The target size is the number of items still
            // selected after the deletion plus the ones we just removed, i.e.
            // how many were shown before the trash.
            let shownBeforeTrash = selectedCountBeforeTrash
            if isViewerPresented, shownBeforeTrash > 1 {
                reselectBlock(startingAt: next, size: shownBeforeTrash, in: survivors)
            } else {
                selectOnly(survivors[next])
            }
        } else {
            clampSelection()
        }

        return trashed.count
    }

    /// Selects a contiguous block of up to `size` items from `order`, with the
    /// block positioned so `start` is its leading item where possible and
    /// clamped to stay fully on-screen near the end of the list. Used to reform
    /// the viewer's multi-selection after a deletion without shrinking it.
    private func reselectBlock(startingAt start: Int, size: Int, in order: [MediaItem.ID]) {
        guard !order.isEmpty else {
            clearSelection()
            return
        }
        let blockSize = min(size, order.count)
        let maxStart = order.count - blockSize
        let clampedStart = min(max(0, start), max(0, maxStart))
        let ids = Array(order[clampedStart..<(clampedStart + blockSize)])
        selectedItems = Set(ids)
        selectedItem = ids.first
        rangeAnchor = ids.first
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
        for url in trashed { colorTags[url] = nil }
        for url in trashed { textTags[url] = nil }
        for url in trashed { aiCategories[url] = nil }
        for url in trashed { facePersons[url] = nil }
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
        } else if showUnmarkedOnly {
            base = "\(count) unmarked \(noun)"
        } else if let colorTagFilter {
            base = "\(count) \(colorTagFilter.displayName.lowercased())-tagged \(noun)"
        } else if let textTagFilter {
            base = "\(count) \(noun) tagged “\(textTagFilter)”"
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
