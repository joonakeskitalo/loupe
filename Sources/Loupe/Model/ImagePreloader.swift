import AppKit
import ImageIO

/// Decodes and caches full-resolution images off the main thread so the
/// fullscreen viewer can swap to the next/previous image instantly instead of
/// blocking on `NSImage(contentsOf:)` during navigation.
///
/// `ZoomableImageView` previously loaded each image synchronously on the main
/// thread the moment the URL changed, so stepping through a folder stuttered
/// while every image decoded. This actor warms a small LRU-ish cache in the
/// background; the viewer asks for an image and gets the already-decoded one
/// when it was prefetched, or triggers a decode that future reads reuse.
///
/// Only the fast bookkeeping (cache lookup + in-flight dedupe) runs isolated;
/// the slow decode happens inside a `Task` that isn't awaited while isolated,
/// so several prefetches overlap instead of serializing.
actor ImagePreloader {
    static let shared = ImagePreloader()

    /// NSCache is internally thread-safe, so it can be read without hopping onto
    /// the actor. Marked `nonisolated(unsafe)` to allow the synchronous cache
    /// peek used by the viewer for an instant, flash-free image swap.
    nonisolated(unsafe) private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    /// Byte budget for cached full images: 15% of physical RAM. Full images are
    /// much larger than thumbnails, so this stays modest while still keeping a
    /// handful of neighbors warm for smooth navigation. NSCache evicts the
    /// least-recently-used entries once the summed cost exceeds the budget.
    private static let cacheByteLimit: Int = {
        let fraction = 0.15
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return Int((total * fraction).rounded())
    }()

    init() {
        cache.totalCostLimit = Self.cacheByteLimit
    }

    /// Returns the cached image for `url` if it's already decoded, without
    /// triggering any work or hopping onto the actor. Safe to call from the
    /// main thread for an instant swap because NSCache is thread-safe.
    nonisolated func cachedImageSync(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Returns the decoded image for `url`, decoding it in the background if it
    /// isn't cached yet. Concurrent callers for the same URL share one decode.
    func image(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        return await task(for: url).value
    }

    /// Kicks off a background decode for `url` (if not cached or in flight)
    /// without waiting for the result. Used to warm neighbors ahead of time.
    func prefetch(_ url: URL) {
        guard cache.object(forKey: url as NSURL) == nil else { return }
        _ = task(for: url)
    }

    /// Warms the cache for a list of URLs (e.g. the next couple of images).
    func prefetch(_ urls: [URL]) {
        for url in urls { prefetch(url) }
    }

    private func task(for url: URL) -> Task<NSImage?, Never> {
        if let existing = inFlight[url] {
            return existing
        }
        let maxPixel = Self.maxDecodePixelSize
        let task = Task<NSImage?, Never>.detached(priority: .userInitiated) {
            // Decode with ImageIO at a display-sized cap rather than
            // `NSImage(contentsOf:)`. For ordinary photos the two are
            // equivalent, but a camera-raw file (e.g. Fujifilm `.raf`) decoded
            // the old way realized the ENTIRE sensor mosaic at native
            // resolution — a 40MP RAF is ~160 MB of RGBA — and the viewer never
            // shows more than screen-many pixels anyway. Capping the longest
            // edge to the largest screen dimension keeps full on-screen quality
            // (including room to zoom) while bounding the decoded buffer, and
            // ImageIO reports the true decoded size so the cache cost below is
            // accurate (an `NSImage` from a RAF reports a proxy size that made
            // the NSCache budget under-count and never evict — the apparent
            // "leak"). The `autoreleasepool` drains the large CG temporaries a
            // RAW decode spins up on this worker thread instead of letting them
            // accumulate.
            autoreleasepool {
                Self.decode(url: url, maxPixelSize: maxPixel)
            }
        }
        // Wrap the detached task so we can record completion on the actor.
        let wrapper = Task<NSImage?, Never> { [weak self] in
            let image = await task.value
            await self?.finish(url: url, image: image)
            return image
        }
        inFlight[url] = wrapper
        return wrapper
    }

    private func finish(url: URL, image: NSImage?) {
        inFlight[url] = nil
        if let image {
            cache.setObject(image, forKey: url as NSURL, cost: Self.byteCost(of: image))
        }
    }

    /// Estimated decoded size of an image in bytes (RGBA, 4 bytes per pixel),
    /// used as the NSCache cost so eviction tracks real memory use. Reads the
    /// backing bitmap's pixel dimensions, which — because we build the image
    /// from a concrete `CGImage` in `decode` — reflect the true decoded buffer.
    private static func byteCost(of image: NSImage) -> Int {
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

    /// Longest-edge cap, in pixels, for a decoded full image: the largest
    /// screen dimension across all connected displays, times the maximum
    /// backing scale, so a decoded image is still pixel-dense enough to fill
    /// (and zoom a little within) the biggest display at full quality without
    /// ever realizing a multi-hundred-megabyte camera-raw mosaic. Falls back to
    /// a sane default if no screen is available.
    private static let maxDecodePixelSize: Int = {
        let screens = NSScreen.screens
        let maxPoints = screens
            .map { max($0.frame.width, $0.frame.height) }
            .max() ?? 2560
        let maxScale = screens.map(\.backingScaleFactor).max() ?? 2
        return Int((maxPoints * maxScale).rounded())
    }()

    /// Decodes `url`, capping the longest edge to `maxPixelSize`. Routes
    /// through `ImageDecoding.decodeCGImage`, which produces a correctly
    /// oriented, downscaled bitmap straight from the full image via ImageIO
    /// (reusing an embedded preview when one is large enough), so for a huge
    /// RAW we never allocate the full sensor resolution — and transparently
    /// falls back to Core Image for files ImageIO decodes to an all-black frame
    /// (notably 10-bit `.HIF`), which previously showed a black fullscreen
    /// image. Returns an `NSImage` wrapping the concrete `CGImage` so its
    /// reported pixel size matches the real buffer.
    nonisolated private static func decode(url: URL, maxPixelSize: Int) -> NSImage? {
        guard let cgImage = ImageDecoding.decodeCGImage(
            url: url,
            maxPixelSize: maxPixelSize,
            alwaysDecodeFromFullImage: true
        ) else {
            return nil
        }
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: cgImage, size: size)
    }
}
