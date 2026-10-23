import Foundation

/// Writes images to a user-chosen directory, re-encoded at a target scale and
/// format with optional metadata stripping. The disk-writing counterpart to
/// `ImageClipboard` — both share the decode/scale/encode pipeline in
/// `ImageRenderer`; this one persists the result to a real folder instead of
/// the pasteboard.
enum ImageExporter {
    /// The outcome of an export run: how many files were written and how many
    /// sources were requested, so the caller can report partial success.
    struct Result: Sendable {
        let written: Int
        let total: Int
    }

    /// Renders every image in `urls` off the main thread and writes each to
    /// `directory`, reporting progress as it goes. Output files are named after
    /// the source with the format's extension, de-duped against the destination
    /// so an export never overwrites an existing file (a numeric suffix is
    /// added: "name 2.jpg", "name 3.jpg", …).
    ///
    /// The decode + re-encode is CPU-heavy (especially many large or RAW images
    /// at Original size), so the renders run concurrently across the machine's
    /// cores in a detached task to keep the UI responsive; `progress` is called
    /// on the main actor as each image finishes.
    ///
    /// Only the render/encode step is parallel. Name de-duping and the disk
    /// write stay serialized — `uniqueDestination` reads the destination and
    /// mutates shared state, and writing in input order keeps output names
    /// deterministic (the first source always claims the plain "name.ext",
    /// later duplicates get the numeric suffix) regardless of which render
    /// finishes first.
    @discardableResult
    @MainActor
    static func export(
        urls: [URL],
        toDirectory directory: URL,
        scale: ImageCopyScale,
        format: ImageCopyFormat,
        stripMetadata: Bool,
        maxLongEdge: Int? = nil,
        jpegQuality: Double? = nil,
        progress: @escaping @MainActor (_ completed: Int, _ total: Int) -> Void
    ) async -> Result {
        let total = urls.count
        progress(0, total)

        let written = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default

            // The destination comes from an NSOpenPanel, so under the sandbox
            // we must claim security-scoped access before writing into it and
            // relinquish it when done. Without this the writes silently fail
            // with a permissions error even with the read-write entitlement.
            let scoped = directory.startAccessingSecurityScopedResource()
            defer { if scoped { directory.stopAccessingSecurityScopedResource() } }

            // Render up to `maxConcurrent` images at once, keeping the pool
            // topped up as each finishes. Results are collected keyed by input
            // index so naming/writing can replay them in order, independent of
            // completion order.
            let maxConcurrent = max(1, ProcessInfo.processInfo.activeProcessorCount)
            var rendered = [Int: ImageRenderer.Rendered]()
            rendered.reserveCapacity(total)
            var completed = 0

            await withTaskGroup(of: (Int, ImageRenderer.Rendered?).self) { group in
                var next = 0

                func addTask(_ index: Int) {
                    let url = urls[index]
                    group.addTask(priority: .userInitiated) {
                        let result = ImageRenderer.render(
                            url: url,
                            scale: scale,
                            format: format,
                            stripMetadata: stripMetadata,
                            maxLongEdge: maxLongEdge,
                            jpegQuality: jpegQuality,
                            includeTIFF: false
                        )
                        return (index, result)
                    }
                }

                while next < total && next < maxConcurrent {
                    addTask(next)
                    next += 1
                }

                for await (index, result) in group {
                    if let result { rendered[index] = result }

                    completed += 1
                    let done = completed
                    Task { @MainActor in progress(done, total) }

                    if next < total {
                        addTask(next)
                        next += 1
                    }
                }
            }

            // Serialized tail: allocate unique names and write, in input order.
            var usedNames = Set<String>()
            var count = 0
            for index in 0..<total {
                guard let r = rendered[index] else { continue }

                let dest = Self.uniqueDestination(
                    directory: directory,
                    baseName: r.baseName,
                    ext: format.fileExtension,
                    usedNames: &usedNames,
                    fileManager: fm
                )

                do {
                    try r.data.write(to: dest)
                    count += 1
                } catch {
                    NSLog("Loupe: failed to export \(urls[index].path) → \(dest.path): \(error.localizedDescription)")
                }
            }
            return count
        }.value

        return Result(written: written, total: total)
    }

    /// Builds a destination URL in `directory` for `baseName`.`ext`, appending
    /// a numeric suffix until it finds a name that neither exists on disk nor
    /// has been used earlier in this batch.
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
