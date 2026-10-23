import ImageIO
import ImageIO.CGImageProperties
import Foundation

/// A compact set of EXIF / camera metadata read from an image file's header,
/// shown in the info sidebar. Everything is optional — most fields are absent
/// on screenshots, exports, and non-photo images — and the whole struct is
/// `Sendable` so it can be produced off the main actor.
struct ImageEXIF: Sendable, Equatable {
    var cameraMake: String?
    var cameraModel: String?
    var lens: String?
    /// When the photo was captured (from EXIF DateTimeOriginal).
    var dateTaken: Date?
    /// Exposure time formatted as a shutter speed, e.g. "1/250 s" or "2 s".
    var shutterSpeed: String?
    /// Aperture f-number, e.g. "f/2.8".
    var aperture: String?
    /// ISO sensitivity, e.g. "ISO 400".
    var iso: String?
    /// Focal length in millimetres, e.g. "35 mm".
    var focalLength: String?
    /// Lens-corrected 35mm-equivalent focal length, e.g. "52 mm".
    var focalLength35mm: String?
    /// Exposure bias, e.g. "-0.7 EV".
    var exposureBias: String?
    /// Whether the flash fired.
    var flashFired: Bool?
    /// Color space / profile name, e.g. "sRGB".
    var colorSpace: String?

    static let empty = ImageEXIF()

    /// True when there's at least one field worth showing, so the sidebar can
    /// omit the whole EXIF section for images that carry none.
    var hasAny: Bool {
        cameraMake != nil || cameraModel != nil || lens != nil || dateTaken != nil
            || shutterSpeed != nil || aperture != nil || iso != nil
            || focalLength != nil || focalLength35mm != nil || exposureBias != nil
            || flashFired != nil || colorSpace != nil
    }
}

/// Reads `ImageEXIF` from an image file's header via ImageIO, without decoding
/// pixels. Lazily caches results (keyed by URL) so re-selecting an image is
/// instant. The actor only does cheap header reads off the main thread.
actor ImageEXIFProvider {
    static let shared = ImageEXIFProvider()

    private let cache = NSCache<NSURL, Box>()
    private var inFlight: [URL: Task<ImageEXIF, Never>] = [:]

    private final class Box {
        let value: ImageEXIF
        init(_ value: ImageEXIF) { self.value = value }
    }

    func exif(for url: URL) async -> ImageEXIF {
        if let cached = cache.object(forKey: url as NSURL)?.value { return cached }
        if let existing = inFlight[url] { return await existing.value }

        let task = Task<ImageEXIF, Never>.detached(priority: .utility) {
            Self.read(url: url)
        }
        inFlight[url] = task
        let value = await task.value
        cache.setObject(Box(value), forKey: url as NSURL)
        inFlight[url] = nil
        return value
    }

    /// Pulls the interesting EXIF/TIFF fields out of the ImageIO property
    /// dictionaries. Pure, synchronous header work — safe off the actor.
    nonisolated private static func read(url: URL) -> ImageEXIF {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return .empty
        }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exifAux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]

        var out = ImageEXIF()

        out.cameraMake = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmed
        out.cameraModel = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmed

        // Lens model can live in a few places depending on the camera.
        out.lens = (exif[kCGImagePropertyExifLensModel] as? String)?.trimmed
            ?? (exifAux[kCGImagePropertyExifAuxLensModel] as? String)?.trimmed

        // Capture date (EXIF stores "yyyy:MM:dd HH:mm:ss").
        if let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            out.dateTaken = Self.exifDateFormatter.date(from: raw)
        }

        // Shutter speed from exposure time (seconds).
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            if t >= 1 {
                out.shutterSpeed = String(format: "%g s", t)
            } else {
                out.shutterSpeed = "1/\(Int((1 / t).rounded())) s"
            }
        }

        if let f = exif[kCGImagePropertyExifFNumber] as? Double, f > 0 {
            out.aperture = String(format: "f/%g", f)
        }

        // ISO is an array of speed ratings; take the first.
        if let isoArray = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int],
           let iso = isoArray.first {
            out.iso = "ISO \(iso)"
        } else if let iso = exif[kCGImagePropertyExifISOSpeedRatings] as? Int {
            out.iso = "ISO \(iso)"
        }

        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double, fl > 0 {
            out.focalLength = String(format: "%g mm", fl)
        }
        if let fl35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Double, fl35 > 0 {
            out.focalLength35mm = String(format: "%g mm", fl35)
        }

        if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double {
            out.exposureBias = String(format: "%+.1f EV", bias)
        }

        // Flash: the low bit of the EXIF flash value indicates it fired.
        if let flash = exif[kCGImagePropertyExifFlash] as? Int {
            out.flashFired = (flash & 0x1) != 0
        }

        if let profile = props[kCGImagePropertyProfileName] as? String {
            out.colorSpace = profile.trimmed
        }

        return out
    }

    /// EXIF stores timestamps as "yyyy:MM:dd HH:mm:ss" in the camera's local
    /// time (no zone), so parse without converting.
    nonisolated private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

private extension String {
    /// Trimmed of whitespace, or nil if nothing remains (camera strings often
    /// carry trailing spaces/nulls).
    var trimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
