import AVFoundation
import ImageIO
import AppKit
import UniformTypeIdentifiers

/// Grabs a single still frame from a video at a given playback position and
/// writes it to disk as a PNG. The capture counterpart to `ThumbnailProvider`'s
/// `avFoundationFrame` — but where a thumbnail wants the nearest cheap keyframe
/// at a small size, a screenshot wants the *exact* frame the user is looking at,
/// at full resolution. So this asks `AVAssetImageGenerator` for zero tolerance
/// and sets no `maximumSize`.
///
/// AVFoundation can only decode the containers the system demuxes. The `.mkv` /
/// `.webm` files Loupe plays through libmpv have no AVFoundation-reachable frame
/// API, so `canCapture(url:)` reports them unsupported and the UI gates the
/// command out rather than silently failing.
enum VideoStillCapturer {
    enum CaptureError: Error {
        /// The container isn't one AVFoundation can decode (mkv/webm → mpv).
        case unsupportedContainer
        /// No decodable video track (e.g. an audio-only file).
        case noVideoTrack
        /// The generator couldn't produce a frame at the requested time.
        case frameUnavailable
        /// The frame decoded but couldn't be PNG-encoded or written.
        case writeFailed
    }

    /// Whether a still can be captured from `url` via AVFoundation. False for
    /// the mpv-only containers, which have no reachable frame API here.
    static func canCapture(url: URL) -> Bool {
        !MediaKind.videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// Captures the frame at `seconds` from the video at `url` and writes it as
    /// a PNG into `directory`, returning the file it wrote. The output is named
    /// after the source with the timestamp appended — e.g.
    /// "clip_00-01-23-400.png" — and de-duped so a capture never overwrites an
    /// existing file.
    ///
    /// Runs the decode off the main thread; the exact-frame seek can take a
    /// moment on long-GOP footage since the generator must decode forward from
    /// the preceding keyframe to hit `seconds` precisely.
    static func capture(
        url: URL,
        at seconds: Double,
        toDirectory directory: URL
    ) async throws -> URL {
        guard canCapture(url: url) else { throw CaptureError.unsupportedContainer }

        return try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)

            guard let tracks = try? await asset.loadTracks(withMediaType: .video),
                  !tracks.isEmpty else {
                throw CaptureError.noVideoTrack
            }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            // Exact frame: unlike thumbnails, a screenshot must match the frame
            // on screen, so demand zero tolerance (decode forward to the precise
            // time) and leave `maximumSize` unset for full resolution.
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            let clamped = max(0, seconds)
            let time = CMTime(seconds: clamped, preferredTimescale: 600)

            let cgImage: CGImage
            do {
                cgImage = try await generator.image(at: time).image
            } catch {
                throw CaptureError.frameUnavailable
            }

            guard let data = Self.encodePNG(cgImage) else {
                throw CaptureError.writeFailed
            }

            // The destination comes from the caller (an NSOpenPanel folder or
            // the source's own directory). Under the sandbox we must claim
            // security-scoped access before writing into a user-chosen folder.
            let scoped = directory.startAccessingSecurityScopedResource()
            defer { if scoped { directory.stopAccessingSecurityScopedResource() } }

            let baseName = url.deletingPathExtension().lastPathComponent
            let stamp = Self.timestampToken(seconds: clamped)
            let dest = Self.uniqueDestination(
                directory: directory,
                baseName: "\(baseName)_\(stamp)",
                ext: "png"
            )

            do {
                try data.write(to: dest)
            } catch {
                NSLog("Loupe: failed to write video still \(dest.path): \(error.localizedDescription)")
                throw CaptureError.writeFailed
            }
            return dest
        }.value
    }

    /// Encodes a CGImage to PNG `Data`. Mirrors `ImageRenderer.encode` but is
    /// kept local so the capturer has no dependency on the export pipeline's
    /// scale/format options.
    private static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Renders a playback position as a filename-safe token — "HH-MM-SS-mmm",
    /// dropping the hour segment when it's zero (e.g. "00-01-23-400"). Colons
    /// and dots aren't filename-friendly, so the usual separators become
    /// hyphens.
    private static func timestampToken(seconds: Double) -> String {
        let totalMillis = Int((seconds * 1000).rounded())
        let millis = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let secs = totalSeconds % 60
        let mins = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        if hours > 0 {
            return String(format: "%02d-%02d-%02d-%03d", hours, mins, secs, millis)
        }
        return String(format: "%02d-%02d-%03d", mins, secs, millis)
    }

    /// Builds a destination URL in `directory` for `baseName`.`ext`, appending a
    /// numeric suffix until the name is free on disk. Mirrors
    /// `ImageExporter.uniqueDestination` (minus the in-batch used-name set,
    /// since a capture writes exactly one file).
    private static func uniqueDestination(
        directory: URL,
        baseName: String,
        ext: String
    ) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(baseName).\(ext)")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)_\(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
