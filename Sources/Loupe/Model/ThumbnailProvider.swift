import AppKit
import AVFoundation
import QuickLookThumbnailing

/// Generates and caches thumbnails for media items using QuickLook, with an
/// AVFoundation frame-extraction fallback for video containers QuickLook can't
/// handle (notably .mkv and .webm).
///
/// Memory is bounded two ways: each image is capped at `maxPixelDimension` px
/// on its longest edge (so a cell at any zoom level decodes a small image), and
/// the cache evicts least-recently-used entries once the total decoded size
/// exceeds a byte budget scaled to the machine's RAM (`cacheByteLimit`). The
/// number of cached images is not capped — only their summed byte cost is.
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

    /// Hard cap on a thumbnail's longest edge, in pixels. Grid cells top out at
    /// 320 pt, so capping here (rather than honoring the full point-size ×
    /// backing-scale, which would be 640 px on Retina) matches the largest cell
    /// 1:1 while quartering the decoded size versus the old worst case. A
    /// 320²-RGBA image is ~400 KB versus ~1.6 MB at 640². Smaller cells end up
    /// well under the cap and cost proportionally less.
    private static let maxPixelDimension: CGFloat = 320

    /// Byte budget for cached thumbnails: 20% of physical RAM. NSCache evicts
    /// least-recently-used entries once the summed per-image cost exceeds this.
    /// Scaling to RAM lets memory-rich machines keep more thumbnails warm while
    /// staying conservative on smaller ones.
    private static let cacheByteLimit: Int = {
        let fraction = 0.2
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return Int((total * fraction).rounded())
    }()

    init() {
        cache.totalCostLimit = Self.cacheByteLimit
    }

    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        // Clamp the requested resolution so we never decode/store more pixels
        // than a thumbnail needs. We keep the aspect ratio of the requested
        // size but limit the longest edge to `maxPixelDimension` pixels.
        let pixelSize = Self.clampedPixelSize(pointSize: size, scale: scale)

        // Reuse or create the generation task, but DO NOT await it while the
        // actor is isolated — return the task's handle and await it outside, so
        // concurrent requests overlap instead of serializing.
        let task = taskForThumbnail(url: url, pixelSize: pixelSize)
        return await task.value
    }

    /// Converts a requested point size + backing scale into a pixel size whose
    /// longest edge is capped at `maxPixelDimension`.
    private static func clampedPixelSize(pointSize: CGSize, scale: CGFloat) -> CGSize {
        let requested = CGSize(
            width: max(1, pointSize.width * scale),
            height: max(1, pointSize.height * scale)
        )
        let longest = max(requested.width, requested.height)
        guard longest > maxPixelDimension else { return requested }
        let factor = maxPixelDimension / longest
        return CGSize(
            width: (requested.width * factor).rounded(),
            height: (requested.height * factor).rounded()
        )
    }

    /// Returns an existing in-flight task or starts a new one, recording it so
    /// duplicate requests for the same URL share one generation. `pixelSize`
    /// is already in pixels (clamped), so QuickLook runs at scale 1.
    private func taskForThumbnail(url: URL, pixelSize: CGSize) -> Task<NSImage?, Never> {
        if let existing = inFlight[url] {
            return existing
        }

        let task = Task<NSImage?, Never> { [weak self] in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: pixelSize,
                scale: 1,
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
                image = await Self.videoFrame(for: url, pixelSize: pixelSize)
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
            cache.setObject(image, forKey: url as NSURL, cost: Self.byteCost(of: image))
        }
    }

    /// Estimated decoded size of an image in bytes (RGBA, 4 bytes per pixel),
    /// used as the NSCache cost so eviction is driven by real memory use.
    private static func byteCost(of image: NSImage) -> Int {
        // Prefer the pixel dimensions of the backing bitmap; fall back to the
        // point size if there's no bitmap representation.
        let pixelWidth: Int
        let pixelHeight: Int
        if let rep = image.representations.first {
            pixelWidth = rep.pixelsWide
            pixelHeight = rep.pixelsHigh
        } else {
            pixelWidth = Int(image.size.width)
            pixelHeight = Int(image.size.height)
        }
        return max(1, pixelWidth * pixelHeight * 4)
    }

    /// Extracts a representative frame from a video. Tries AVFoundation first
    /// (hardware-accelerated, cheap for formats it supports) and falls back to
    /// the embedded FFmpeg libraries for containers it can't open — notably
    /// `.mkv` and `.webm`.
    ///
    /// `nonisolated` so it runs off the actor and never serializes other
    /// thumbnail work. Returns nil if no decoder can produce a frame.
    nonisolated private static func videoFrame(for url: URL, pixelSize: CGSize) async -> NSImage? {
        if let image = await avFoundationFrame(for: url, pixelSize: pixelSize) {
            return image
        }

        // AVFoundation couldn't decode this container. Decode a frame with the
        // bundled FFmpeg libraries on a background task so the demux/decode work
        // never touches the cooperative pool's forward-progress guarantees.
        let maxPixel = Int(max(pixelSize.width, pixelSize.height).rounded())
        return await Task.detached(priority: .utility) {
            FFmpegThumbnailer.thumbnail(for: url, maxPixelSize: max(1, maxPixel))
        }.value
    }

    /// Pulls a frame via AVFoundation. Returns nil for containers AVFoundation
    /// doesn't support (e.g. Matroska / WebM) so the caller can fall back.
    /// `pixelSize` is already in pixels, so it maps straight to `maximumSize`.
    nonisolated private static func avFoundationFrame(for url: URL, pixelSize: CGSize) async -> NSImage? {
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
        generator.maximumSize = pixelSize

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
