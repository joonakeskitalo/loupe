import Foundation
import UniformTypeIdentifiers

/// A classification for the kinds of files Loupe knows how to preview.
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

    /// Extensions treated as Markdown regardless of how the system maps them.
    private static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mdx"
    ]

    static func classify(url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return .markdown }

        guard let type = UTType(filenameExtension: ext) else {
            return .other
        }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
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

    var isPreviewable: Bool {
        kind != .other
    }
}
