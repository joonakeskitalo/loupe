import AppKit
import AVFoundation
import QuickLookThumbnailing

/// Generates and caches thumbnails for media items using QuickLook, with an
/// AVFoundation frame-extraction fallback for video containers QuickLook can't
/// handle (notably .mkv and .webm).
///
/// The actor only does fast bookkeeping (cache lookup + deduping in-flight
/// requests) and never `await`s the slow QuickLook generation while isolated,
/// so many thumbnails generate concurrently. Awaiting inside the actor would
/// serialize every request behind the previous one — which made the first
/// folder load appear to freeze as hundreds of cells queued up.
actor ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    init() {
        cache.countLimit = 800
    }

    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        // Reuse or create the generation task, but DO NOT await it while the
        // actor is isolated — return the task's handle and await it outside, so
        // concurrent requests overlap instead of serializing.
        let task = taskForThumbnail(url: url, size: size, scale: scale)
        return await task.value
    }

    /// Returns an existing in-flight task or starts a new one, recording it so
    /// duplicate requests for the same URL share one generation.
    private func taskForThumbnail(url: URL, size: CGSize, scale: CGFloat) -> Task<NSImage?, Never> {
        if let existing = inFlight[url] {
            return existing
        }

        let task = Task<NSImage?, Never> { [weak self] in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: size,
                scale: scale,
                representationTypes: .thumbnail
            )
            request.iconMode = true

            var image: NSImage?
            do {
                let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                image = rep.nsImage
            } catch {
                image = nil
            }

            // QuickLook can't thumbnail some video containers (notably .mkv and
            // .webm, which neither QuickLook nor AVFoundation decode on macOS).
            // Fall back to decoding a frame with the embedded FFmpeg libraries
            // so these still show a preview instead of the generic film icon.
            if image == nil, MediaKind.classify(url: url) == .video {
                image = await Self.videoFrame(for: url, size: size, scale: scale)
            }

            await self?.finish(url: url, image: image)
            return image
        }

        inFlight[url] = task
        return task
    }

    private func finish(url: URL, image: NSImage?) {
        inFlight[url] = nil
        if let image {
            cache.setObject(image, forKey: url as NSURL)
        }
    }

    /// Extracts a representative frame from a video. Tries AVFoundation first
    /// (hardware-accelerated, cheap for formats it supports) and falls back to
    /// the embedded FFmpeg libraries for containers it can't open — notably
    /// `.mkv` and `.webm`.
    ///
    /// `nonisolated` so it runs off the actor and never serializes other
    /// thumbnail work. Returns nil if no decoder can produce a frame.
    nonisolated private static func videoFrame(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        if let image = await avFoundationFrame(for: url, size: size, scale: scale) {
            return image
        }

        // AVFoundation couldn't decode this container. Decode a frame with the
        // bundled FFmpeg libraries on a background task so the demux/decode work
        // never touches the cooperative pool's forward-progress guarantees.
        let maxPixel = Int((max(size.width, size.height) * scale).rounded())
        return await Task.detached(priority: .utility) {
            FFmpegThumbnailer.thumbnail(for: url, maxPixelSize: max(1, maxPixel))
        }.value
    }

    /// Pulls a frame via AVFoundation. Returns nil for containers AVFoundation
    /// doesn't support (e.g. Matroska / WebM) so the caller can fall back.
    nonisolated private static func avFoundationFrame(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        let asset = AVURLAsset(url: url)

        // If there's no decodable video track, don't bother — let the caller
        // fall back to FFmpeg.
        guard let hasVideo = try? await asset.loadTracks(withMediaType: .video),
              !hasVideo.isEmpty else {
            return nil
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: size.width * scale, height: size.height * scale)

        // Seek a little past the start to avoid black lead-in frames, but clamp
        // to the asset's duration so very short clips still produce a frame.
        let time: CMTime
        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 {
            let target = min(1.0, duration.seconds * 0.1)
            time = CMTime(seconds: target, preferredTimescale: 600)
        } else {
            time = CMTime(seconds: 1, preferredTimescale: 600)
        }

        do {
            let cgImage = try await generator.image(at: time).image
            return NSImage(cgImage: cgImage, size: .zero)
        } catch {
            return nil
        }
    }
}
