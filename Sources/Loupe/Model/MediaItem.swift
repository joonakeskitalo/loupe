import Foundation
import UniformTypeIdentifiers

/// A classification for the kinds of files Loupe knows how to preview.
enum MediaKind: String, Sendable {
    case image
    case video
    case pdf
    case audio
    case other

    /// SF Symbol used when no thumbnail is available.
    var fallbackSymbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .pdf: return "doc.richtext"
        case .audio: return "music.note"
        case .other: return "doc"
        }
    }

    static func classify(url: URL) -> MediaKind {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return .other
        }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .audio) { return .audio }
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
    let modificationDate: Date
    /// The directory that directly contains this file.
    let parentDirectory: URL

    init(url: URL) {
        self.id = url
        self.url = url
        self.name = url.lastPathComponent
        self.kind = MediaKind.classify(url: url)
        self.parentDirectory = url.deletingLastPathComponent()

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        self.fileSize = Int64(values?.fileSize ?? 0)
        self.modificationDate = values?.contentModificationDate ?? .distantPast
    }

    var isPreviewable: Bool {
        kind != .other
    }
}
