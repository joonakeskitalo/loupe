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
/// A decoded fullscreen image plus how it was produced, so the viewer can
/// show whether a RAW is its embedded preview or a real RAW development.
final class PreloadedImage: @unchecked Sendable {
    let image: NSImage
    let source: DecodedImageSource
    /// Pixel dimensions of the decoded bitmap.
    let pixelSize: CGSize

    init(image: NSImage, source: DecodedImageSource, pixelSize: CGSize) {
        self.image = image
        self.source = source
        self.pixelSize = pixelSize
    }
}

actor ImagePreloader {
    static let shared = ImagePreloader()

    /// Identifies one decode: the file plus whether a native-resolution RAW
    /// development was requested. `fullResolution` is only ever true for RAW
    /// files (normalized in `key(_:_:)`), so other images share one entry.
    private struct Key: Hashable {
        let url: URL
        let fullResolution: Bool
    }

    /// NSCache is internally thread-safe, so it can be read without hopping onto
    /// the actor. Marked `nonisolated(unsafe)` to allow the synchronous cache
    /// peek used by the viewer for an instant, flash-free image swap.
    nonisolated(unsafe) private let cache = NSCache<NSURL, PreloadedImage>()
    /// Native-resolution RAW developments, kept apart from `cache` because
    /// each is sensor-sized (~160 MB for 40 MP). Only the last couple are
    /// kept, so toggling back and forth on the image you're inspecting is
    /// instant without letting full RAWs accumulate.
    nonisolated(unsafe) private let fullResolutionCache = NSCache<NSURL, PreloadedImage>()
    private var inFlight: [Key: Task<PreloadedImage?, Never>] = [:]

    /// Byte budget for cached full images: 15% of physical RAM, but never more
    /// than 1 GB. A fraction of RAM alone scaled to several GB on large
    /// machines, and since each fullscreen image is tens of MB (a 49 MB RAF
    /// decoded to display size is ~80 MB of RGBA), browsing a big folder just
    /// kept filling the cache and read as a leak. A handful of neighbors is all
    /// the viewer needs for instant navigation.
    private static let cacheByteLimit: Int = {
        let fraction = 0.15
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return min(Int((total * fraction).rounded()), 1_024 * 1_024 * 1_024)
    }()
    /// Most decodes allowed to run at once. Rapid arrow-key browsing queues a
    /// decode per step; unbounded, they all ran in parallel, each holding
    /// sensor-sized RAW intermediates, which spiked memory.
    private static let maxConcurrentDecodes = 2
    private var activeDecodes = 0
    private var decodeWaiters: [CheckedContinuation<Void, Never>] = []
    private func acquireDecodeSlot() async {
        if activeDecodes < Self.maxConcurrentDecodes {
            activeDecodes += 1
            return
        }
        await withCheckedContinuation { decodeWaiters.append($0) }
    }
    private func releaseDecodeSlot() {
        if decodeWaiters.isEmpty {
            activeDecodes -= 1
        } else {
            decodeWaiters.removeFirst().resume()  // slot handed straight over
        }
    }

    init() {
        cache.totalCostLimit = Self.cacheByteLimit
        cache.countLimit = 12
        fullResolutionCache.countLimit = 2
    }

    nonisolated private static func key(_ url: URL, _ fullResolution: Bool) -> Key {
        Key(url: url, fullResolution: fullResolution && ImageDecoding.isRAW(url))
    }

    nonisolated private func cacheFor(_ key: Key) -> NSCache<NSURL, PreloadedImage> {
        key.fullResolution ? fullResolutionCache : cache
    }

    /// Returns the cached image for `url` if it's already decoded, without
    /// triggering any work or hopping onto the actor. Safe to call from the
    /// main thread for an instant swap because NSCache is thread-safe.
    /// `fullResolution` requests a native-resolution RAW development; it's
    /// ignored for non-RAW files.
    nonisolated func cachedImageSync(for url: URL, fullResolution: Bool = false) -> PreloadedImage? {
        let key = Self.key(url, fullResolution)
        return cacheFor(key).object(forKey: url as NSURL)
    }

    /// Returns the decoded image for `url`, decoding it in the background if it
    /// isn't cached yet. Concurrent callers for the same request share one
    /// decode.
    func image(for url: URL, fullResolution: Bool = false) async -> PreloadedImage? {
        let key = Self.key(url, fullResolution)
        if let cached = cacheFor(key).object(forKey: url as NSURL) {
            return cached
        }
        return await task(for: key).value
    }

    /// Kicks off a background decode for `url` (if not cached or in flight)
    /// without waiting for the result. Used to warm neighbors ahead of time.
    func prefetch(_ url: URL, fullResolution: Bool = false) {
        let key = Self.key(url, fullResolution)
        guard cacheFor(key).object(forKey: url as NSURL) == nil else { return }
        _ = task(for: key)
    }

    /// Warms the cache for a list of URLs (e.g. the next couple of images).
    func prefetch(_ urls: [URL], fullResolution: Bool = false) {
        for url in urls { prefetch(url, fullResolution: fullResolution) }
    }

    private func task(for key: Key) -> Task<PreloadedImage?, Never> {
        if let existing = inFlight[key] {
            return existing
        }
        let maxPixel = Self.maxDecodePixelSize
        let wrapper = Task<PreloadedImage?, Never> { [weak self] in
            guard let self else { return nil }
            await self.acquireDecodeSlot()
            let image = await Task<PreloadedImage?, Never>.detached(priority: .userInitiated) {
                // Decode at a display-sized cap rather than
                // `NSImage(contentsOf:)`: a camera-raw file decoded the old way
                // realized the ENTIRE sensor mosaic (~160 MB for 40 MP) and the
                // viewer rarely shows more than screen-many pixels. The
                // full-resolution path is the explicit exception. ImageIO /
                // Core Image report the true decoded size so the cache cost is
                // accurate, and the `autoreleasepool` drains the large CG
                // temporaries a RAW decode spins up on this worker thread.
                autoreleasepool {
                    key.fullResolution
                        ? Self.decodeFullResolution(url: key.url)
                        : Self.decode(url: key.url, maxPixelSize: maxPixel)
                }
            }.value
            await self.releaseDecodeSlot()
            await self.finish(key: key, image: image)
            return image
        }
        inFlight[key] = wrapper
        return wrapper
    }

    private func finish(key: Key, image: PreloadedImage?) {
        inFlight[key] = nil
        if let image {
            let cost = max(1, Int(image.pixelSize.width * image.pixelSize.height) * 4)
            cacheFor(key).setObject(image, forKey: key.url as NSURL, cost: cost)
        }
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
    nonisolated private static func decode(url: URL, maxPixelSize: Int) -> PreloadedImage? {
        guard let (cgImage, source) = ImageDecoding.decodeCGImageWithSource(
            url: url,
            maxPixelSize: maxPixelSize,
            alwaysDecodeFromFullImage: true
        ) else {
            return nil
        }
        return wrap(cgImage, source: source)
    }

    /// Develops a RAW at native sensor resolution (the explicit "Load Full
    /// Resolution RAW" request).
    nonisolated private static func decodeFullResolution(url: URL) -> PreloadedImage? {
        guard let cgImage = ImageDecoding.decodeFullResolutionRAW(url: url) else { return nil }
        return wrap(cgImage, source: .rawFullResolution)
    }

    /// Wraps a concrete `CGImage` in an `NSImage` whose reported size matches
    /// the real buffer.
    nonisolated private static func wrap(_ cgImage: CGImage, source: DecodedImageSource) -> PreloadedImage {
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        return PreloadedImage(image: NSImage(cgImage: cgImage, size: size), source: source, pixelSize: size)
    }
}
