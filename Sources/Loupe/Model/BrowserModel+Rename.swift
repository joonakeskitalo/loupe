import AppKit

/// Bulk file rename, built on the same selection-resolution + in-place model
/// update pattern as `moveToTrash`. The public surface lives here; the actual
/// in-place re-keying of the model's private state (`applyRenameMapping`) lives
/// in `BrowserModel.swift` since it touches private storage.
///
/// Renaming changes a file's URL, which is its identity here
/// (`MediaItem.id == url`), so the heavy lifting is re-keying every URL-keyed
/// structure — the scan results, the merged lists, the in-session annotations,
/// the codec cache, and the selection — from each old URL to its new one, then
/// re-sorting (a rename changes the name sort key) and reselecting the renamed
/// files by their new URLs.
extension BrowserModel {
    /// Whether a rename action currently has any target, for enabling the
    /// sidebar controls.
    var canRenameSelection: Bool { !selectedItems.isEmpty }

    /// The targets a rename would act on, in display order, resolved exactly
    /// like every other file action (`item` overrides the selection only when
    /// it isn't part of it). Exposed so the sidebar can build a live preview
    /// off the same set the rename will use.
    func renameTargets(preferring item: MediaItem? = nil) -> [URL] {
        // Preserve on-screen order so the number sequence follows what the user
        // sees, not an arbitrary set order.
        let urls = actionURLs(preferring: item)
        let targetSet = Set(urls.map { $0.standardizedFileURL })
        guard !targetSet.isEmpty else { return [] }
        let ordered = visualOrderItems
            .map { $0.url }
            .filter { targetSet.contains($0.standardizedFileURL) }
        // Fall back to the raw list if nothing matched the display order (e.g. a
        // right-click on an item outside the current scope).
        return ordered.isEmpty ? urls : ordered
    }

    /// Computes the rename plan the given config would produce for the current
    /// targets, without touching disk. Drives the sidebar preview.
    func renamePreview(
        using config: BulkRenameConfig,
        item: MediaItem? = nil,
        now date: Date = Date()
    ) -> [BulkRenamer.Plan] {
        BulkRenamer.plans(for: renameTargets(preferring: item), config: config, now: date)
    }

    /// Renames the selected files (or `item`) on disk per `config`, then updates
    /// the in-memory model in place so the grid/list/sidebar reflect the new
    /// names without a full rescan.
    ///
    /// Like `moveToTrash`, the blocking filesystem work (`FileManager.moveItem`)
    /// runs off the main actor; only the model mutation runs here. Per-file
    /// failures are logged and skipped so one locked/clashing file doesn't abort
    /// the rest. Returns the number of files actually renamed.
    @discardableResult
    func renameSelection(
        using config: BulkRenameConfig,
        item: MediaItem? = nil
    ) async -> Int {
        guard config.hasAnyComponent else { return 0 }
        let plans = renamePreview(using: config, item: item).filter { $0.isChange }
        guard !plans.isEmpty else { return 0 }

        // Perform the moves off the main actor; come back with the old→new URL
        // pairs that actually succeeded (standardized, to match model keys).
        let renamed: [(old: URL, new: URL)] = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var done: [(URL, URL)] = []
            for plan in plans {
                let src = plan.source
                let dst = plan.destination
                // Guard against a last-moment collision the plan couldn't see
                // (a file created between preview and apply). Skip rather than
                // overwrite.
                guard !fm.fileExists(atPath: dst.path) else {
                    NSLog("Loupe: skipped rename of \(src.lastPathComponent) — \(dst.lastPathComponent) already exists")
                    continue
                }
                do {
                    try fm.moveItem(at: src, to: dst)
                    done.append((src.standardizedFileURL, dst.standardizedFileURL))
                } catch {
                    NSLog("Loupe: failed to rename \(src.path) → \(dst.lastPathComponent): \(error.localizedDescription)")
                }
            }
            return done
        }.value

        guard !renamed.isEmpty else { return 0 }

        var mapping: [URL: URL] = [:]
        for pair in renamed { mapping[pair.old] = pair.new }
        applyRenameMapping(mapping)
        return renamed.count
    }
}
