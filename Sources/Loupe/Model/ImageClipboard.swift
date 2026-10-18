import AppKit
import ImageIO
import UniformTypeIdentifiers

/// How large a copied image is, relative to its original pixel dimensions.
/// Scaling down is useful for pasting a lightweight copy into a document or
/// chat without shipping a full-resolution photo.
enum ImageCopyScale: String, CaseIterable, Sendable {
    case original = "Original Size"
    case half = "50%"
    case quarter = "25%"
    case max2048 = "Fit 2048 px"
    case max1024 = "Fit 1024 px"

    var displayName: String { rawValue }

    /// Resolves the target longest-edge pixel cap for a source whose longest
    /// edge is `sourceLongestEdge`. Returns the number of pixels the longest
    /// edge should become. Percentage scales are relative to the source; the
    /// "Fit N px" options cap the longest edge at N (never upscaling a smaller
    /// image).
    func targetLongestEdge(sourceLongestEdge: Int) -> Int {
        switch self {
        case .original: return sourceLongestEdge
        case .half: return max(1, sourceLongestEdge / 2)
        case .quarter: return max(1, sourceLongestEdge / 4)
        case .max2048: return min(sourceLongestEdge, 2048)
        case .max1024: return min(sourceLongestEdge, 1024)
        }
    }
}

/// Renders image files to pixel data on the pasteboard — as opposed to copying
/// the file reference (which `BrowserModel.copyToClipboard` does). Pasting the
/// result into an image editor, document, or chat drops in the actual pixels.
///
/// Two options the file-copy path can't offer:
///   * **Scaling** — downscale to a fraction or a max dimension so a paste
///     isn't a full-resolution photo.
///   * **Stripping metadata** — re-encode without the source's EXIF/GPS/maker
///     notes, so a shared copy doesn't carry camera settings or location.
///
/// The copy is written as PNG. PNG is lossless, universally pasteable, and —
/// crucially — carries none of the EXIF/GPS metadata a JPEG would, so the
/// "without EXIF" option is satisfied simply by encoding to PNG and not copying
/// any properties across. (When metadata is kept, the orientation is still
/// baked into the pixels during decode, so the pasted image is upright.)
enum ImageClipboard {
    /// Copies the first image in `urls` to the general pasteboard as rendered
    /// pixel data at `scale`.
    ///
    /// When `stripMetadata` is true the copy is written as PNG — lossless and
    /// with no EXIF/GPS container at all. When false, the copy is written as
    /// JPEG with the source file's metadata (EXIF, GPS, maker notes) carried
    /// across, so a consumer that reads JPEG metadata still sees the camera
    /// info. Either way a plain bitmap is also advertised so simple consumers
    /// can paste the pixels. Returns 1 on success, 0 if nothing could be
    /// rendered. Only the primary image is written (the pasteboard holds one
    /// image), which is the expected "copy this picture" behavior.
    @discardableResult
    @MainActor
    static func copy(urls: [URL], scale: ImageCopyScale, stripMetadata: Bool) -> Int {
        guard let url = urls.first,
              let rendered = renderedData(url: url, scale: scale, stripMetadata: stripMetadata)
        else {
            return 0
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(rendered.data, forType: rendered.type)
        // Also advertise a TIFF bitmap so apps that only read generic image
        // data (and not PNG/JPEG specifically) still paste the pixels. TIFF
        // carries no EXIF here either, so it never leaks stripped metadata.
        if let tiff = rendered.image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        return pasteboard.writeObjects([item]) ? 1 : 0
    }

    private struct Rendered {
        let data: Data
        let type: NSPasteboard.PasteboardType
        let image: NSImage
    }

    /// Decodes `url`, applies `scale`, and encodes to pasteboard data — PNG
    /// (metadata-free) when stripping, else JPEG carrying the source metadata.
    /// EXIF orientation is baked into the pixels by the decoder, so the result
    /// is always upright regardless of the metadata choice.
    @MainActor
    private static func renderedData(url: URL, scale: ImageCopyScale, stripMetadata: Bool) -> Rendered? {
        // Find the source's pixel dimensions so percentage scales are relative
        // to the real image and "Fit N" never upscales.
        guard let sourceLongest = longestEdge(of: url) else { return nil }
        let target = scale.targetLongestEdge(sourceLongestEdge: sourceLongest)

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

        let nsImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))

        if stripMetadata {
            guard let data = encode(cg, as: UTType.png, properties: nil) else { return nil }
            return Rendered(data: data, type: .png, image: nsImage)
        }

        // Keep metadata: pull the source's EXIF/GPS/TIFF properties and attach
        // them to a JPEG re-encode. If the orientation was baked into the
        // pixels above, drop the stored orientation tag so it isn't applied a
        // second time by a viewer.
        var properties = sourceProperties(of: url) ?? [:]
        properties[kCGImagePropertyOrientation] = 1  // already upright
        let type = UTType.jpeg
        guard let data = encode(cg, as: type, properties: properties) else {
            // Fall back to a plain JPEG if attaching properties failed.
            guard let plain = encode(cg, as: type, properties: nil) else { return nil }
            return Rendered(data: plain, type: .init(type.identifier), image: nsImage)
        }
        return Rendered(data: data, type: .init(type.identifier), image: nsImage)
    }

    /// Encodes a `CGImage` to the given type, optionally attaching metadata
    /// properties (EXIF/GPS/TIFF dictionaries). Returns nil if encoding fails.
    private static func encode(
        _ image: CGImage,
        as type: UTType,
        properties: [CFString: Any]?
    ) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, type.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary?)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// The source file's full image properties (EXIF/GPS/TIFF dictionaries),
    /// read without decoding pixels, for re-attaching when metadata is kept.
    private static func sourceProperties(of url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return nil
        }
        return props
    }

    /// The longest edge, in pixels, of the image at `url` — read cheaply from
    /// the image source header without decoding the pixels.
    private static func longestEdge(of url: URL) -> Int? {
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
