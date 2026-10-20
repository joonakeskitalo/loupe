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
    /// at Original size), so it runs on a detached task to keep the UI
    /// responsive; `progress` is called on the main actor after each image.
    @discardableResult
    @MainActor
    static func export(
        urls: [URL],
        toDirectory directory: URL,
        scale: ImageCopyScale,
        format: ImageCopyFormat,
        stripMetadata: Bool,
        progress: @escaping @MainActor (_ completed: Int, _ total: Int) -> Void
    ) async -> Result {
        let total = urls.count
        progress(0, total)

        let written = await Task.detached(priority: .userInitiated) {
            var usedNames = Set<String>()
            var count = 0
            let fm = FileManager.default

            // The destination comes from an NSOpenPanel, so under the sandbox
            // we must claim security-scoped access before writing into it and
            // relinquish it when done. Without this the writes silently fail
            // with a permissions error even with the read-write entitlement.
            let scoped = directory.startAccessingSecurityScopedResource()
            defer { if scoped { directory.stopAccessingSecurityScopedResource() } }

            for (index, url) in urls.enumerated() {
                defer {
                    let completed = index + 1
                    Task { @MainActor in progress(completed, total) }
                }

                guard let rendered = ImageRenderer.render(
                    url: url,
                    scale: scale,
                    format: format,
                    stripMetadata: stripMetadata,
                    includeTIFF: false
                ) else { continue }

                let dest = Self.uniqueDestination(
                    directory: directory,
                    baseName: rendered.baseName,
                    ext: format.fileExtension,
                    usedNames: &usedNames,
                    fileManager: fm
                )

                do {
                    try rendered.data.write(to: dest)
                    count += 1
                } catch {
                    NSLog("Loupe: failed to export \(url.path) → \(dest.path): \(error.localizedDescription)")
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
