import Foundation

/// Transcodes videos to a user-chosen directory at a target resolution — the
/// video counterpart to `ImageExporter`. It drives `VideoTranscoder` (the
/// libav* transcode) once per file, bracketing the writes in security-scoped
/// access to the chosen folder (required under the sandbox, same as image
/// export), de-duping output names, and reporting progress.
enum VideoExporter {
    /// Transcodes a single video into `destinationDirectory` at `resolution` /
    /// `codec` / `rateControl`, writing an `.mp4` named after the source
    /// (de-duped against the folder). Runs the CPU-heavy transcode on a
    /// detached task; `progress` is called on the main actor with the file's
    /// 0...1 fraction. Returns true on success.
    ///
    /// This is the per-job primitive the model's video-export queue calls once
    /// for each queued video, so the queue controls ordering/concurrency.
    @MainActor
    static func transcodeOne(
        sourceURL: URL,
        destinationDirectory directory: URL,
        resolution: VideoTranscoder.Resolution,
        codec: VideoTranscoder.Codec,
        rateControl: VideoTranscoder.RateControl,
        progress: @escaping @MainActor (_ fraction: Double) -> Void
    ) async -> Bool {
        progress(0)

        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default

            // Claim security-scoped access to the chosen folder before writing,
            // exactly like ImageExporter — writes fail silently otherwise.
            let scoped = directory.startAccessingSecurityScopedResource()
            defer { if scoped { directory.stopAccessingSecurityScopedResource() } }

            let baseName = sourceURL.deletingPathExtension().lastPathComponent
            let dest = Self.uniqueDestination(
                directory: directory,
                baseName: baseName,
                ext: "mp4",
                fileManager: fm
            )

            do {
                try VideoTranscoder.transcode(
                    input: sourceURL,
                    output: dest,
                    resolution: resolution,
                    codec: codec,
                    rateControl: rateControl
                ) { fraction in
                    Task { @MainActor in progress(fraction) }
                }
                await MainActor.run { progress(1.0) }
                return true
            } catch {
                NSLog("Loupe: failed to transcode \(sourceURL.path) → \(dest.path): \(error)")
                // Remove any partial output so a failed export doesn't leave a
                // broken file behind.
                try? fm.removeItem(at: dest)
                return false
            }
        }.value
    }

    /// Builds a destination URL in `directory` for `baseName`.`ext`, appending
    /// a numeric suffix until it finds a name free on disk (matching
    /// ImageExporter). Since the queue runs jobs serially, a filesystem check
    /// alone keeps successive outputs from colliding.
    nonisolated private static func uniqueDestination(
        directory: URL,
        baseName: String,
        ext: String,
        fileManager fm: FileManager
    ) -> URL {
        var name = "\(baseName).\(ext)"
        var candidate = directory.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            name = "\(baseName) \(n).\(ext)"
            candidate = directory.appendingPathComponent(name)
            n += 1
        }
        return candidate
    }
}
