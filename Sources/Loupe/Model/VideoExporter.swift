import Foundation

/// Transcodes videos to a user-chosen directory at a target resolution — the
/// video counterpart to `ImageExporter`. It drives `VideoTranscoder` (the
/// libav* transcode) once per file, bracketing the writes in security-scoped
/// access to the chosen folder (required under the sandbox, same as image
/// export), de-duping output names, and reporting progress.
enum VideoExporter {
    struct Result: Sendable {
        let written: Int
        let total: Int
    }

    /// Transcodes every video in `urls` into `directory` at `resolution`,
    /// writing `.mp4` outputs. `progress` is called on the main actor with the
    /// number completed, the total, and the current file's 0...1 fraction so a
    /// combined progress bar can advance smoothly within and across files.
    ///
    /// The transcode is CPU-heavy, so it runs on a detached task to keep the UI
    /// responsive.
    @discardableResult
    @MainActor
    static func export(
        urls: [URL],
        toDirectory directory: URL,
        resolution: VideoTranscoder.Resolution,
        progress: @escaping @MainActor (_ completed: Int, _ total: Int, _ fraction: Double) -> Void
    ) async -> Result {
        let total = urls.count
        progress(0, total, 0)

        let written = await Task.detached(priority: .userInitiated) {
            var usedNames = Set<String>()
            var count = 0
            let fm = FileManager.default

            // Claim security-scoped access to the chosen folder before writing,
            // exactly like ImageExporter — writes fail silently otherwise.
            let scoped = directory.startAccessingSecurityScopedResource()
            defer { if scoped { directory.stopAccessingSecurityScopedResource() } }

            for (index, url) in urls.enumerated() {
                let baseName = url.deletingPathExtension().lastPathComponent
                let dest = Self.uniqueDestination(
                    directory: directory,
                    baseName: baseName,
                    ext: "mp4",
                    usedNames: &usedNames,
                    fileManager: fm
                )

                let completedBefore = index
                do {
                    try VideoTranscoder.transcode(
                        input: url,
                        output: dest,
                        resolution: resolution
                    ) { fraction in
                        Task { @MainActor in progress(completedBefore, total, fraction) }
                    }
                    count += 1
                } catch {
                    NSLog("Loupe: failed to transcode \(url.path) → \(dest.path): \(error)")
                    // Remove any partial output so a failed export doesn't leave
                    // a broken file behind.
                    try? fm.removeItem(at: dest)
                }

                let completed = index + 1
                await MainActor.run { progress(completed, total, 1.0) }
            }
            return count
        }.value

        return Result(written: written, total: total)
    }

    /// Builds a destination URL in `directory` for `baseName`.`ext`, appending
    /// a numeric suffix until it finds a free name (matching ImageExporter).
    nonisolated private static func uniqueDestination(
        directory: URL,
        baseName: String,
        ext: String,
        usedNames: inout Set<String>,
        fileManager fm: FileManager
    ) -> URL {
        var name = "\(baseName).\(ext)"
        var candidate = directory.appendingPathComponent(name)
        var n = 2
        while usedNames.contains(name) || fm.fileExists(atPath: candidate.path) {
            name = "\(baseName) \(n).\(ext)"
            candidate = directory.appendingPathComponent(name)
            n += 1
        }
        usedNames.insert(name)
        return candidate
    }
}
