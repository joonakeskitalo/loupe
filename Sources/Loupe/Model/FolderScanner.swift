import Foundation

/// Result of scanning a root folder.
struct ScanResult: Sendable {
    let root: URL
    let allItems: [MediaItem]
    /// Items grouped by their containing directory.
    let itemsByDirectory: [URL: [MediaItem]]
    let tree: FolderNode
}

/// Scans a directory recursively, producing a flattened list of media items
/// and a folder tree for sidebar navigation. Runs off the main actor.
enum FolderScanner {

    static func scan(root: URL, showHiddenFiles: Bool = false) async -> ScanResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = performScan(root: root, showHiddenFiles: showHiddenFiles)
                continuation.resume(returning: result)
            }
        }
    }

    /// The macOS metadata file Finder drops in every browsed directory. Always
    /// filtered out — even when showing hidden files — since it's never content
    /// a user wants to see.
    private static let desktopServicesStore = ".DS_Store"

    private static func performScan(root: URL, showHiddenFiles: Bool) -> ScanResult {
        let fm = FileManager.default
        var allItems: [MediaItem] = []
        var itemsByDirectory: [URL: [MediaItem]] = [:]
        // Track which directories we've seen so the tree includes empty folders too.
        var directories: Set<URL> = [root.standardizedFileURL]

        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey]
        // When hidden files are shown we drop `.skipsHiddenFiles` so dotfiles and
        // files carrying the macOS hidden flag come through; otherwise it stays
        // on and the enumerator never surfaces them. `.DS_Store` is excluded by
        // name below regardless, since `.skipsHiddenFiles` would normally hide it
        // and we don't want it reappearing when hidden files are revealed.
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHiddenFiles { options.insert(.skipsHiddenFiles) }
        let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: options
        )

        while let obj = enumerator?.nextObject() {
            guard let url = obj as? URL else { continue }
            let standardized = url.standardizedFileURL
            let values = try? standardized.resourceValues(forKeys: Set(keys))

            if values?.isDirectory == true {
                directories.insert(standardized)
                continue
            }

            // Never show Finder's per-directory metadata store, even in the
            // "show hidden files" mode.
            if standardized.lastPathComponent == desktopServicesStore { continue }

            let item = MediaItem(url: standardized)
            guard item.isPreviewable else { continue }

            allItems.append(item)
            itemsByDirectory[item.parentDirectory, default: []].append(item)
            directories.insert(item.parentDirectory)
        }

        allItems.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for key in itemsByDirectory.keys {
            itemsByDirectory[key]?.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        let tree = buildTree(root: root.standardizedFileURL,
                             directories: directories,
                             itemsByDirectory: itemsByDirectory)

        return ScanResult(
            root: root.standardizedFileURL,
            allItems: allItems,
            itemsByDirectory: itemsByDirectory,
            tree: tree
        )
    }

    /// Builds a folder tree from the set of discovered directories.
    private static func buildTree(
        root: URL,
        directories: Set<URL>,
        itemsByDirectory: [URL: [MediaItem]]
    ) -> FolderNode {
        // Map every directory to its children directories.
        var childrenMap: [URL: [URL]] = [:]
        for dir in directories where dir != root {
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            childrenMap[parent, default: []].append(dir)
        }

        func makeNode(_ url: URL) -> FolderNode {
            let childURLs = (childrenMap[url] ?? []).sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            let childNodes = childURLs.map { makeNode($0) }
            let count = itemsByDirectory[url]?.count ?? 0
            return FolderNode(url: url, children: childNodes, directMediaCount: count)
        }

        return makeNode(root)
    }
}
