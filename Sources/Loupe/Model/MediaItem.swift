import Foundation
import UniformTypeIdentifiers

/// A classification for the kinds of files Loupe shows. Known kinds get a
/// tailored viewer; `.other` covers every remaining file type via QuickLook.
enum MediaKind: String, Sendable {
    case image
    case video
    case pdf
    case audio
    case markdown
    case text
    case other

    /// SF Symbol used when no thumbnail is available.
    var fallbackSymbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .pdf: return "doc.richtext"
        case .audio: return "music.note"
        case .markdown: return "doc.text.image"
        case .text: return "doc.plaintext"
        case .other: return "doc"
        }
    }

    /// Human-readable plural name used for type filter chips.
    var displayName: String {
        switch self {
        case .image: return "Images"
        case .video: return "Videos"
        case .pdf: return "PDFs"
        case .audio: return "Audio"
        case .markdown: return "Markdown"
        case .text: return "Text"
        case .other: return "Other"
        }
    }

    /// Display order for "Group by Type" sections, so kinds read in a stable,
    /// sensible order (visual media first, `.other` last) regardless of which
    /// kinds a given folder happens to contain.
    var groupSortRank: Int {
        switch self {
        case .image: return 0
        case .video: return 1
        case .pdf: return 2
        case .audio: return 3
        case .markdown: return 4
        case .text: return 5
        case .other: return 6
        }
    }

    /// Extensions treated as Markdown regardless of how the system maps them.
    private static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mdx"
    ]

    /// Video containers the system doesn't reliably map to `.movie` (e.g. the
    /// Matroska `.mkv` type resolves to a dynamic UTI). Treating them as video
    /// explicitly lets AVFoundation handle playback and thumbnailing.
    static let videoExtensions: Set<String> = [
        "mkv", "webm"
    ]

    /// Camera-raw extensions. These still classify as `.image`, but they are
    /// far heavier to decode than an ordinary JPEG/PNG/HEIC — ImageIO (or the
    /// Core Image fallback) has to run a full sensor-demosaic pipeline — so the
    /// thumbnailer routes them through a tighter concurrency gate to keep a
    /// burst of RAW decodes from thrashing the machine while ordinary images
    /// keep the fast path. Covers the common vendor formats.
    static let rawImageExtensions: Set<String> = [
        "raf",            // Fujifilm
        "cr2", "cr3",     // Canon
        "nef", "nrw",     // Nikon
        "arw", "srf", "sr2", // Sony
        "orf",            // Olympus / OM System
        "rw2",            // Panasonic
        "dng",            // Adobe / generic
        "pef",            // Pentax
        "raw", "rwl",     // Leica / generic
        "x3f",            // Sigma
        "3fr", "fff",     // Hasselblad
        "iiq",            // Phase One
        "erf",            // Epson
        "mef", "mos",     // Mamiya / Leaf
        "gpr"             // GoPro
    ]

    /// Whether `url` is a camera-raw image by extension.
    static func isRawImage(url: URL) -> Bool {
        rawImageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Extensions that must never be classified as video, even though the
    /// system maps them to a movie UTI. `.ts` resolves to the MPEG-2 transport
    /// stream type (`public.mpeg-2-transport-stream`, which conforms to
    /// `.movie`), but in practice these are almost always TypeScript source
    /// files here — so they should fall through to text, not show up as videos.
    private static let nonVideoExtensions: Set<String> = [
        "ts"
    ]

    static func classify(url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return .markdown }
        if videoExtensions.contains(ext) { return .video }

        guard let type = UTType(filenameExtension: ext) else {
            return .other
        }
        if type.conforms(to: .image) { return .image }
        // Skip the video check for extensions we explicitly don't treat as
        // video (e.g. `.ts` TypeScript, which the system maps to a transport
        // stream movie type); let them fall through to text/other below.
        if !nonVideoExtensions.contains(ext),
           type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .audio) { return .audio }
        // Plain text and anything conforming to it (source code, config, etc.).
        if type.conforms(to: .plainText) || type.conforms(to: .text) { return .text }
        return .other
    }
}

/// A single file discovered while scanning a folder.
struct MediaItem: Identifiable, Hashable, Sendable {
    let id: URL
    let url: URL
    let name: String
    let kind: MediaKind
    let fileSize: Int64
    let creationDate: Date
    let modificationDate: Date
    /// The directory that directly contains this file.
    let parentDirectory: URL

    init(url: URL) {
        self.id = url
        self.url = url
        self.name = url.lastPathComponent
        self.kind = MediaKind.classify(url: url)
        self.parentDirectory = url.deletingLastPathComponent()

        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .creationDateKey, .contentModificationDateKey
        ])
        self.fileSize = Int64(values?.fileSize ?? 0)
        self.creationDate = values?.creationDate ?? .distantPast
        self.modificationDate = values?.contentModificationDate ?? .distantPast
    }

    /// Every discovered file is shown. Known kinds get a tailored viewer; any
    /// other file falls back to a QuickLook thumbnail and preview.
    var isPreviewable: Bool {
        true
    }
}
