import Foundation

/// A thread-safe one-way cancellation flag, shared between the main-actor queue
/// (which flips it) and the detached transcode worker (which polls it). Needed
/// because the transcode runs on `Task.detached`, which does NOT inherit Swift
/// task cancellation — so a plain `Task.isCancelled` check wouldn't see the
/// queue's cancel. A tiny locked bool bridges the two cleanly.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

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
        cancellation: CancellationFlag,
        progress: @escaping @MainActor (_ fraction: Double) -> Void
    ) async -> Bool {
        progress(0)

        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default

            // Claim security-scoped access to the chosen folder before writing,
            // exactly like ImageExporter — writes fail silently otherwise.
            let scoped = directory.startAccessingSecurityScopedResource()
            defer { if scoped { directory.stopAccessingSecurityScopedResource() } }

            // Append the chosen settings (resolution, codec, quality) to the
            // name so exports with different settings are distinguishable and
            // self-describing, e.g. "clip_1080p_h265_cq70.mp4". The whole base
            // is sanitized to stay filesystem-safe.
            let sourceBase = sourceURL.deletingPathExtension().lastPathComponent
            let settingsSuffix = [
                resolution.fileNameToken,
                codec.fileNameToken,
                rateControl.fileNameToken
            ].joined(separator: "_")
            let baseName = Self.sanitizedFileName("\(sourceBase)_\(settingsSuffix)")

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
                    rateControl: rateControl,
                    isCancelled: { cancellation.isCancelled }
                ) { fraction in
                    Task { @MainActor in progress(fraction) }
                }
                await MainActor.run { progress(1.0) }
                return true
            } catch VideoTranscoder.TranscodeError.cancelled {
                // Cancelled by the user — expected, not an error. Drop the
                // partial output and report failure (the queue removes the job).
                try? fm.removeItem(at: dest)
                return false
            } catch {
                NSLog("Loupe: failed to transcode \(sourceURL.path) → \(dest.path): \(error)")
                // Remove any partial output so a failed export doesn't leave a
                // broken file behind.
                try? fm.removeItem(at: dest)
                return false
            }
        }.value
    }

    /// Makes `name` safe to use as a filename component: replaces path
    /// separators, the colon (illegal on HFS+/APFS as shown in Finder), and
    /// other characters that commonly break tools with underscores, collapses
    /// runs of whitespace/underscores, and trims leading/trailing separators
    /// and dots. Falls back to "video" if nothing usable remains.
    nonisolated private static func sanitizedFileName(_ name: String) -> String {
        // Disallow anything outside a conservative, cross-platform-safe set.
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_. ")
        let replaced = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })

        // Collapse whitespace to single underscores and squeeze repeated
        // underscores so a messy source name doesn't produce "a___b".
        let underscored = replaced
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: "_")
        var collapsed = ""
        var lastWasUnderscore = false
        for ch in underscored {
            if ch == "_" {
                if lastWasUnderscore { continue }
                lastWasUnderscore = true
            } else {
                lastWasUnderscore = false
            }
            collapsed.append(ch)
        }

        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_.-"))
        return trimmed.isEmpty ? "video" : trimmed
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
