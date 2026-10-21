import ImageIO
import AppKit
import UniformTypeIdentifiers

/// Shared decode → scale → re-encode pipeline for images, used by both the
/// "Copy Image" clipboard path (`ImageClipboard`) and the "Export Images"
/// to-disk path (`BrowserModel.exportImages`).
///
/// The two features need the exact same primitive: load a source image, resize
/// its longest edge to a target, optionally keep/strip EXIF, and encode to
/// JPEG/PNG `Data`. Keeping that in one place means scaling, orientation, and
/// metadata handling stay consistent across copy and export.
enum ImageRenderer {
    /// Encoded result of rendering one image: the primary image bytes (PNG or
    /// JPEG), the UTI they're in, an optional TIFF bitmap, and the source's
    /// base name (no extension) for naming output files. All `Data`, so a batch
    /// can cross actor boundaries (rendered off-main, consumed on-main).
    struct Rendered: Sendable {
        let data: Data
        let imageType: UTType
        let tiff: Data?
        let baseName: String
    }

    /// Decodes `url`, applies `scale`, and encodes to `format`, keeping the
    /// source metadata only when the format can carry it and the caller didn't
    /// ask to strip it. EXIF orientation is baked into the pixels by the
    /// decoder, so the result is upright either way.
    ///
    /// `nonisolated` and only touches read-only image APIs, producing `Data`
    /// (which is `Sendable`), so the heavy decode/encode can run off the main
    /// actor from a detached task.
    /// When `maxLongEdge` is non-nil it overrides `scale`, capping the output's
    /// longest edge at that pixel count (never upscaling a smaller source) —
    /// used by the export UI's custom long-edge field.
    /// `jpegQuality` (0...1) sets the JPEG lossy compression quality; ignored
    /// for PNG (lossless). Nil uses the system default.
    nonisolated static func render(
        url: URL,
        scale: ImageCopyScale,
        format: ImageCopyFormat,
        stripMetadata: Bool,
        maxLongEdge: Int? = nil,
        jpegQuality: Double? = nil,
        includeTIFF: Bool = true
    ) -> Rendered? {
        // Find the source's pixel dimensions so percentage scales are relative
        // to the real image and "Fit N" never upscales.
        guard let sourceLongest = longestEdge(of: url) else { return nil }
        let target: Int
        if let maxLongEdge, maxLongEdge > 0 {
            // Custom cap: never upscale past the source's own longest edge.
            target = min(sourceLongest, maxLongEdge)
        } else {
            target = scale.targetLongestEdge(sourceLongestEdge: sourceLongest)
        }

        // Reuse the shared decoder (handles RAW/HEIF and bakes in orientation),
        // capping the longest edge to the requested target. For `.original`
        // this is the source's own longest edge, i.e. full resolution.
        guard let cg = ImageDecoding.decodeCGImage(
            url: url,
            maxPixelSize: target,
            alwaysDecodeFromFullImage: true
        ) else {
            return nil
        }

        let tiff = includeTIFF ? NSBitmapImageRep(cgImage: cg).tiffRepresentation : nil
        let baseName = url.deletingPathExtension().lastPathComponent
        let type = format.utType

        // JPEG lossy-compression quality (0...1), applied only when encoding
        // JPEG. Clamped to a valid range; nil leaves the system default.
        let quality: Double? = (format == .jpeg) ? jpegQuality.map { max(0, min(1, $0)) } : nil

        // Keep metadata only when the user didn't ask to strip it AND the chosen
        // format can actually hold it (PNG has no EXIF container).
        let keepMetadata = !stripMetadata && format.canCarryMetadata
        if keepMetadata {
            // Re-attach the source's EXIF/GPS/TIFF properties. Orientation was
            // baked into the pixels during decode, so reset the stored tag so a
            // viewer doesn't rotate the already-upright image a second time.
            var properties = sourceProperties(of: url) ?? [:]
            properties[kCGImagePropertyOrientation] = 1
            if let data = encode(cg, as: type, properties: properties, quality: quality) {
                return Rendered(data: data, imageType: type, tiff: tiff, baseName: baseName)
            }
            // Attaching properties failed — fall through to a plain encode.
        }

        guard let data = encode(cg, as: type, properties: nil, quality: quality) else { return nil }
        return Rendered(data: data, imageType: type, tiff: tiff, baseName: baseName)
    }

    /// Encodes a `CGImage` to the given type, optionally attaching metadata
    /// properties (EXIF/GPS/TIFF dictionaries) and a lossy-compression
    /// `quality` (0...1, used for JPEG). Returns nil if encoding fails.
    nonisolated static func encode(
        _ image: CGImage,
        as type: UTType,
        properties: [CFString: Any]?,
        quality: Double? = nil
    ) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, type.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        // Merge the compression quality into the per-image options. For JPEG
        // this controls the lossy quality/size tradeoff; it's a no-op for PNG.
        var options = properties ?? [:]
        if let quality {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, image, options.isEmpty ? nil : options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// The source file's full image properties (EXIF/GPS/TIFF dictionaries),
    /// read without decoding pixels, for re-attaching when metadata is kept.
    nonisolated static func sourceProperties(of url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return nil
        }
        return props
    }

    /// The longest edge, in pixels, of the image at `url` — read cheaply from
    /// the image source header without decoding the pixels.
    nonisolated static func longestEdge(of url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return nil
        }
        let width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let longest = max(width, height)
        return longest > 0 ? longest : nil
    }
}
