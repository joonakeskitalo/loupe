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
    /// decoding a large photo. When `alwaysDecodeFromFullImage` is false it
    /// reuses an embedded preview if one exists; when true it always downscales
    /// the full image.
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

        let thumbnailKey: CFString = alwaysDecodeFromFullImage
            ? kCGImageSourceCreateThumbnailFromImageAlways
            : kCGImageSourceCreateThumbnailFromImageIfAbsent
        let options: [CFString: Any] = [
            thumbnailKey: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // honor EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true          // decode now, off the main thread
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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
    /// 10-bit HEIF decode bug. Samples a coarse grid of pixels (not every one)
    /// so the check is cheap on the already-downscaled result; a single
    /// non-black sample is enough to accept the image.
    private static func isEffectivelyBlack(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return true }

        // Render into a known RGBA8 buffer so we read raw bytes directly rather
        // than paying NSBitmapImageRep.colorAt per sample.
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            // Can't inspect it — assume it's fine rather than forcing a fallback.
            return false
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Sample ~an 11x11 grid of pixels; any non-near-black one means the
        // image decoded with real content.
        let steps = 11
        let strideX = max(1, width / steps)
        let strideY = max(1, height / steps)
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let offset = y * bytesPerRow + x * 4
                let r = buffer[offset]
                let g = buffer[offset + 1]
                let b = buffer[offset + 2]
                if Int(r) + Int(g) + Int(b) > 12 { return false }
                x += strideX
            }
            y += strideY
        }
        return true
    }
}
