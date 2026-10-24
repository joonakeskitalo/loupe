import AppKit
import CoreImage
import ImageIO

/// Shared image-decoding helpers used by both the grid thumbnailer
/// (`ThumbnailProvider`) and the fullscreen preloader (`ImagePreloader`).
///
/// ImageIO's fast thumbnail path (`CGImageSourceCreateThumbnailAtIndex`) is the
/// right default: it reuses an embedded preview when one exists and otherwise
/// decodes straight to the requested size without realizing the full image.
/// But some camera HEIF/HIF files (notably 10-bit Fujifilm `.HIF`) decode to an
/// **all-black** 10-bit buffer through ImageIO's *full-image* path once the
/// requested size exceeds the embedded preview — a decoder bug, not bad data:
/// the same file decodes correctly through Core Image. The grid dodged this as
/// long as its 320 px cap stayed within the embedded preview, but the
/// fullscreen viewer (which decodes near screen resolution) showed a black
/// frame, and any file with a small/absent embedded preview would black out the
/// grid too.
///
/// `decodeCGImage` therefore runs the fast ImageIO path first and, only if that
/// yields a degenerate (effectively black) image, falls back to a Core Image
/// decode that handles these files correctly. The black check samples a small
/// grid of pixels on the already-downscaled result, so it costs essentially
/// nothing on the normal path.
enum ImageDecoding {
    /// Decodes `url` to a `CGImage` whose longest edge is capped at
    /// `maxPixelSize`, honoring EXIF orientation. Tries ImageIO's fast
    /// thumbnail path first and falls back to Core Image if ImageIO returns an
    /// all-black frame (the HEIF/HIF decoder bug described above). Returns nil
    /// only if neither decoder can produce an image.
    ///
    /// `alwaysDecodeFromFullImage` controls the embedded-preview tradeoff:
    ///   * `false` (grid thumbnails): reuse an embedded preview when present —
    ///     the cheapest path, and a grid cell never needs more than the cap.
    ///   * `true` (fullscreen preloader): always downscale the full image so a
    ///     large on-screen image isn't served from a small embedded preview.
    static func decodeCGImage(
        url: URL,
        maxPixelSize: Int,
        alwaysDecodeFromFullImage: Bool = false
    ) -> CGImage? {
        let maxPixel = max(1, maxPixelSize)

        if let cg = imageIOThumbnail(
            url: url,
            maxPixelSize: maxPixel,
            alwaysDecodeFromFullImage: alwaysDecodeFromFullImage
        ), !isEffectivelyBlack(cg) {
            return cg
        }

        // ImageIO failed or returned a black frame — fall back to Core Image,
        // which decodes these files correctly.
        return coreImageDownscaled(url: url, maxPixelSize: maxPixel)
    }

    /// ImageIO's fast thumbnail decode, capped at `maxPixelSize` on the longest
    /// edge and oriented via EXIF. Produces a small bitmap without fully
    /// decoding a large photo.
    ///
    /// Embedded-preview handling (the fix for blurry large JPEGs):
    /// `kCGImageSourceCreateThumbnailFromImageIfAbsent` reuses an embedded
    /// preview when the file has one — but it returns that preview *at its own
    /// size and silently ignores `kCGImageSourceThumbnailMaxPixelSize`*. Most
    /// camera/phone JPEGs embed a tiny EXIF preview (commonly 160×120), so the
    /// grid was handed a 160 px bitmap and upscaled it into the cell, which is
    /// the reported blur. So when `alwaysDecodeFromFullImage` is false we check
    /// the result: if the preview came back smaller than requested while the
    /// full image is actually larger, we redo the decode with
    /// `...FromImageAlways`, which honors the cap and downscales the full image.
    /// Files whose embedded preview is already big enough (or that have none)
    /// keep the cheap single-decode path.
    private static func imageIOThumbnail(
        url: URL,
        maxPixelSize: Int,
        alwaysDecodeFromFullImage: Bool
    ) -> CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }

        if alwaysDecodeFromFullImage {
            let fullLongest = fullImagePixelLongestEdge(source)
            return createThumbnail(
                from: source, maxPixelSize: maxPixelSize, fromFullImage: true,
                fullImageLongestEdge: fullLongest
            )
        }

        // Cheap path first: reuse an embedded preview if present.
        guard let preview = createThumbnail(from: source, maxPixelSize: maxPixelSize, fromFullImage: false) else {
            return nil
        }

        // If the longest edge is at the cap, ImageIO downscaled the full image
        // (or the embedded preview was large enough) — the result is as sharp
        // as requested, so keep it.
        let previewLongest = max(preview.width, preview.height)
        if previewLongest >= maxPixelSize {
            return preview
        }

        // The preview is smaller than requested. If the source image itself is
        // larger than the preview, that preview is a too-small embedded EXIF
        // thumbnail that would upscale blurrily — redecode from the full image.
        // Otherwise the source really is this small (a genuinely tiny image),
        // so the preview is already the best we can do.
        let fullLongest = fullImagePixelLongestEdge(source)
        if fullLongest > previewLongest {
            if let full = createThumbnail(
                from: source, maxPixelSize: maxPixelSize, fromFullImage: true,
                fullImageLongestEdge: fullLongest
            ) {
                return full
            }
        }
        return preview
    }

    /// Runs ImageIO's thumbnail decode on an already-opened source. `fromFullImage`
    /// selects between reusing an embedded preview (`false`) and always
    /// downscaling the full image (`true`).
    ///
    /// `fullImageLongestEdge` (0 if unknown) enables a *downscale-source hint*
    /// on the full-image path: for an image far larger than the target, ImageIO
    /// is told to subsample as it reads (`kCGImageSourceSubsampleFactor`), so it
    /// pulls and decodes a fraction of the pixels off disk instead of the whole
    /// full-resolution buffer before downscaling. The factor is the largest
    /// power of two (2/4/8) that still leaves the subsampled longest edge at or
    /// above the target, so the final thumbnail is bit-for-bit the size we want
    /// with no quality loss — just much less I/O and decode work on big photos.
    private static func createThumbnail(
        from source: CGImageSource,
        maxPixelSize: Int,
        fromFullImage: Bool,
        fullImageLongestEdge: Int = 0
    ) -> CGImage? {
        let thumbnailKey: CFString = fromFullImage
            ? kCGImageSourceCreateThumbnailFromImageAlways
            : kCGImageSourceCreateThumbnailFromImageIfAbsent
        var options: [CFString: Any] = [
            thumbnailKey: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // honor EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true          // decode now, off the main thread
        ]
        if fromFullImage,
           let factor = subsampleFactor(fullLongest: fullImageLongestEdge, target: maxPixelSize) {
            options[kCGImageSourceSubsampleFactor] = factor
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The largest power-of-two subsample factor (2, 4, or 8) that keeps the
    /// subsampled longest edge at or above `target`, or `nil` when subsampling
    /// would drop below the target (or the inputs are unknown). Subsampling by
    /// `f` reads ≈ `1/f²` of the pixels, so this is a large decode-cost win on
    /// images several times bigger than the thumbnail while never undershooting
    /// the requested size (ImageIO still does the final exact downscale).
    private static func subsampleFactor(fullLongest: Int, target: Int) -> Int? {
        guard fullLongest > 0, target > 0 else { return nil }
        // Keep a 2× safety margin so the subsampled image comfortably exceeds
        // the target before the final downscale (avoids any edge-case softening
        // from subsampling landing just at the target).
        for factor in [8, 4, 2] where fullLongest / factor >= target * 2 {
            return factor
        }
        return nil
    }

    /// Longest-edge pixel size of the source's full image, read from the
    /// container's header properties (`PixelWidth`/`PixelHeight`) without
    /// decoding any pixels. Returns 0 if the dimensions aren't available.
    private static func fullImagePixelLongestEdge(_ source: CGImageSource) -> Int {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return 0
        }
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return max(width, height)
    }

    /// Shared, sRGB working-space `CIContext` reused across every Core Image
    /// decode. A `CIContext` is a heavyweight object — it owns a Metal device,
    /// command queues, and internal caches — and is explicitly designed to be
    /// created once and reused. The previous code created a fresh one on every
    /// fallback decode; under the grid's concurrent load, browsing many camera
    /// RAWs (e.g. Fujifilm `.RAF`, which routes through this fallback) spun up
    /// hundreds of contexts and exhausted GPU/Metal resources, after which
    /// `createCGImage` began returning nil or all-black images — the "works for
    /// a while, then thumbnails go black / missing" failure. One shared context
    /// (safe for concurrent rendering) bounds that cost to a single allocation.
    nonisolated(unsafe) private static let sharedCIContext: CIContext = {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext(options: [
            .workingColorSpace: sRGB,
            // Don't let Core Image hold a growing cache of intermediate images
            // across decodes; each thumbnail is one-shot, so caching only piles
            // up memory while browsing a large folder.
            .cacheIntermediates: false
        ])
    }()

    /// Core Image fallback: decodes `url` correctly for files ImageIO's
    /// full-image path mishandles, applies EXIF orientation, downscales to
    /// `maxPixelSize`, and renders to a plain 8-bit sRGB bitmap (which is what
    /// a thumbnail / on-screen image needs and sidesteps the broken 10-bit
    /// output).
    ///
    /// The downscale is applied to the `CIImage` *before* rendering, and only
    /// the scaled extent is rasterized, so a 40MP RAW never materializes its
    /// full sensor mosaic here — Core Image folds the scale into the RAW
    /// pipeline and realizes just the small output. Rendering goes through the
    /// shared `CIContext` so repeated decodes don't each allocate a new one.
    private static func coreImageDownscaled(url: URL, maxPixelSize: Int) -> CGImage? {
        // `autoreleasepool` so the large transient CG/CI buffers a RAW decode
        // spins up are released as soon as this call returns rather than
        // lingering until the enclosing worker drains.
        autoreleasepool {
            let ciOptions: [CIImageOption: Any] = [.applyOrientationProperty: true]
            guard var image = CIImage(contentsOf: url, options: ciOptions) else {
                return nil
            }

            let longest = max(image.extent.width, image.extent.height)
            if longest > CGFloat(maxPixelSize), longest > 0 {
                let factor = CGFloat(maxPixelSize) / longest
                image = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            }

            let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
            return sharedCIContext.createCGImage(
                image,
                from: image.extent,
                format: .RGBA8,
                colorSpace: sRGB
            )
        }
    }

    /// True if `image` is effectively all black — the signature of the ImageIO
    /// 10-bit HEIF decode bug.
    ///
    /// Rather than re-rasterize the full-size thumbnail (a fresh buffer plus a
    /// `CGContext.draw` the size of the whole image, paid on *every* decode),
    /// this draws the image once into a tiny fixed `probeSize`×`probeSize` RGBA
    /// buffer and inspects every pixel of that. Downscaling to ~24² means the
    /// allocation and the draw are a few KB and a trivial blit no matter how
    /// large the thumbnail is, and averaging over the whole shrunk image is
    /// actually a more reliable "is there any content" test than sampling a
    /// sparse grid of the big one. A single non-near-black probe pixel means
    /// the image decoded with real content.
    private static func isEffectivelyBlack(_ image: CGImage) -> Bool {
        guard image.width > 0, image.height > 0 else { return true }

        let probe = 24
        let bytesPerRow = probe * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * probe)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: &buffer,
            width: probe,
            height: probe,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            // Can't inspect it — assume it's fine rather than forcing a fallback.
            return false
        }
        // Draw the whole image shrunk into the probe buffer; the GPU/CG blit of
        // an already-small thumbnail down to 24² is negligible.
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: probe, height: probe))

        for i in stride(from: 0, to: buffer.count, by: 4) {
            let sum = Int(buffer[i]) + Int(buffer[i + 1]) + Int(buffer[i + 2])
            if sum > 12 { return false }
        }
        return true
    }
}
