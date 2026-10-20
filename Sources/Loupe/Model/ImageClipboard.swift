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
    case max512 = "Fit 512 px"
    case max256 = "Fit 256 px"
    case max128 = "Fit 128 px"

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
        case .max512: return min(sourceLongestEdge, 512)
        case .max256: return min(sourceLongestEdge, 256)
        case .max128: return min(sourceLongestEdge, 128)
        }
    }
}

/// Encoding format for a copied image. Independent of the metadata toggle:
/// JPEG can carry or omit EXIF, and PNG never has an EXIF container, so the
/// two choices compose.
enum ImageCopyFormat: String, CaseIterable, Sendable {
    case jpeg = "JPEG"
    case png = "PNG"

    var displayName: String { rawValue }

    /// The uniform type the bytes are encoded as.
    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        }
    }

    /// File extension for the temp files used in the multi-image copy path.
    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        }
    }

    /// Whether this format can embed EXIF/GPS metadata at all. PNG cannot, so a
    /// PNG copy is always metadata-free regardless of the strip toggle.
    var canCarryMetadata: Bool { self == .jpeg }

    /// The default: JPEG — compact, universally pasteable, and able to carry
    /// metadata when the user wants it.
    static let defaultFormat: ImageCopyFormat = .jpeg
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
    /// Copies the image(s) in `urls`, rendered at `scale` and optionally with
    /// metadata stripped. Returns the number of images copied, 0 if none could
    /// be rendered.
    ///
    /// Encoding: `stripMetadata` true → PNG (lossless, no EXIF/GPS container);
    /// false → JPEG carrying the source file's EXIF/GPS/maker notes. Orientation
    /// is baked into the pixels by the decoder, so the result is upright either
    /// way.
    ///
    /// Everything stays in memory — nothing is written to disk. Each image
    /// becomes one `NSPasteboardItem` whose encoded bytes are supplied lazily
    /// by an in-memory data provider when a receiver asks for them. Each item
    /// advertises the encoded image type (PNG or JPEG) plus TIFF, so:
    ///
    ///   * A single image pastes its pixels into image editors / documents.
    ///   * A multi-selection writes one item per image; apps that accept
    ///     several (Finder, Mail, Keynote, …) receive them all, while
    ///     single-image targets take the first.
    @discardableResult
    @MainActor
    static func copy(
        urls: [URL],
        scale: ImageCopyScale,
        format: ImageCopyFormat,
        stripMetadata: Bool
    ) -> Int {
        let rendered = renderAllSync(
            urls: urls, scale: scale, format: format, stripMetadata: stripMetadata
        )
        return write(rendered)
    }

    /// Renders every image in `urls` off the main thread, reporting progress as
    /// each finishes, then writes the results to the pasteboard on the main
    /// actor and returns the number copied.
    ///
    /// The decode + re-encode is CPU-heavy (especially many large or RAW images
    /// at Original size), so it runs on a detached task to keep the UI
    /// responsive; `progress` is called on the main actor after each image with
    /// the running count so a progress indicator can advance. The pasteboard
    /// write happens last, on the main actor.
    @discardableResult
    @MainActor
    static func copy(
        urls: [URL],
        scale: ImageCopyScale,
        format: ImageCopyFormat,
        stripMetadata: Bool,
        progress: @escaping @MainActor (_ completed: Int, _ total: Int) -> Void
    ) async -> Int {
        let total = urls.count
        progress(0, total)

        let rendered = await Task.detached(priority: .userInitiated) {
            var out: [ImageRenderer.Rendered] = []
            out.reserveCapacity(urls.count)
            for (index, url) in urls.enumerated() {
                if let r = ImageRenderer.render(url: url, scale: scale, format: format, stripMetadata: stripMetadata) {
                    out.append(r)
                }
                let completed = index + 1
                await MainActor.run { progress(completed, total) }
            }
            return out
        }.value

        return write(rendered)
    }

    /// Synchronous render of all images on the current actor (used by the
    /// non-progress `copy`). Kept for callers that don't need progress.
    @MainActor
    private static func renderAllSync(
        urls: [URL],
        scale: ImageCopyScale,
        format: ImageCopyFormat,
        stripMetadata: Bool
    ) -> [ImageRenderer.Rendered] {
        urls.compactMap { ImageRenderer.render(url: $0, scale: scale, format: format, stripMetadata: stripMetadata) }
    }

    /// Writes already-rendered image data to the pasteboard. Returns the number
    /// written.
    ///
    /// Transfer strategy depends on count:
    ///
    ///   * **One image**: inline pixel data (PNG/JPEG + TIFF) so it pastes into
    ///     image editors / documents, plus a file URL so it also pastes into
    ///     Finder.
    ///   * **Multiple images**: file URLs. macOS has no reliable way to paste
    ///     several *in-memory* images — plain multi-item image data pastes only
    ///     the first, and `NSFilePromiseProvider` only materializes on *drag*,
    ///     not on ⌘V — so the only transfer every receiver honors is real file
    ///     URLs. The rendered bytes are therefore written to temp files (the
    ///     rendering itself stays in memory; only the final scaled outputs
    ///     touch disk) and their URLs go on the pasteboard, exactly like
    ///     copying several real files.
    @MainActor
    private static func write(_ rendered: [ImageRenderer.Rendered]) -> Int {
        guard !rendered.isEmpty else { return 0 }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if rendered.count == 1 {
            let r = rendered[0]
            let item = NSPasteboardItem()
            item.setData(r.data, forType: .init(r.imageType.identifier))
            if let tiff = r.tiff { item.setData(tiff, forType: .tiff) }
            // Also back it with a temp file so Finder/Files targets accept it.
            if let fileURL = writeTempFile(r) {
                item.setString(fileURL.absoluteString, forType: .fileURL)
            }
            return pasteboard.writeObjects([item]) ? 1 : 0
        }

        // Multiple images: write temp files and copy their URLs.
        let fileURLs = rendered.compactMap { writeTempFile($0) }
        guard !fileURLs.isEmpty else { return 0 }
        return pasteboard.writeObjects(fileURLs as [NSURL]) ? fileURLs.count : 0
    }

    /// Writes one rendered image to a uniquely-named temp file and returns its
    /// URL. Files land in a per-launch directory under the system temp folder
    /// (which the OS reclaims); each file's name comes from its source so a
    /// paste into Finder keeps recognizable names, de-duped within the batch.
    @MainActor
    private static func writeTempFile(_ r: ImageRenderer.Rendered) -> URL? {
        let ext = r.imageType == .png ? "png" : "jpg"
        var name = "\(r.baseName).\(ext)"
        var n = 2
        while usedTempNames.contains(name) {
            name = "\(r.baseName) \(n).\(ext)"
            n += 1
        }
        usedTempNames.insert(name)

        let dest = tempDirectory.appendingPathComponent(name)
        do {
            try r.data.write(to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// Per-launch scratch directory for copied-image temp files, created once.
    @MainActor private static let tempDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoupeImageCopy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Names already used in `tempDirectory`, so repeated copies don't clobber
    /// each other and in-batch duplicates get a suffix.
    @MainActor private static var usedTempNames = Set<String>()
}
