import Foundation
import ImageIO

/// Writes Loupe's tags into XMP sidecar files next to camera RAW images.
///
/// RAW files (e.g. Fujifilm `.RAF`) are never modified in place: rewriting a
/// proprietary RAW container risks corrupting it, so — like Lightroom, Capture
/// One and Photo Mechanic — tags go into an Adobe-style sidecar named after the
/// image's base name (`DSCF0021.RAF` → `DSCF0021.xmp`).
///
/// Mapping:
///   * text tags → `dc:subject` (keywords)
///   * color tag → `xmp:Label` (e.g. "Red")
///
/// An existing sidecar is merged, not replaced: every other property (develop
/// settings, rating, …) is preserved, existing keywords are kept and Loupe's
/// are added, and the label is only set when the item has a color tag. Writes
/// happen only when the user explicitly asks to save; nothing is written
/// automatically.
enum XMPSidecar {
    /// What to write for one image.
    struct Entry: Sendable {
        let imageURL: URL
        let keywords: [String]
        let label: String?
    }

    enum WriteError: LocalizedError {
        case unreadableSidecar(URL)
        case serializationFailed

        var errorDescription: String? {
            switch self {
            case .unreadableSidecar(let url):
                return "The existing sidecar “\(url.lastPathComponent)” isn’t valid XMP."
            case .serializationFailed:
                return "The XMP data couldn’t be generated."
            }
        }
    }

    /// The sidecar location for `imageURL`. Reuses an existing sidecar in
    /// either common convention (`name.xmp`, or darktable's `name.RAF.xmp`),
    /// otherwise uses the Adobe convention `name.xmp`.
    static func sidecarURL(for imageURL: URL) -> URL {
        let directory = imageURL.deletingLastPathComponent()
        let adobe = directory.appendingPathComponent(
            imageURL.deletingPathExtension().lastPathComponent + ".xmp")
        let fullName = directory.appendingPathComponent(imageURL.lastPathComponent + ".xmp")
        let fm = FileManager.default
        if !fm.fileExists(atPath: adobe.path), fm.fileExists(atPath: fullName.path) {
            return fullName
        }
        return adobe
    }

    /// Writes (or merges into) the sidecar for `entry`. Returns the sidecar URL.
    @discardableResult
    static func write(_ entry: Entry) throws -> URL {
        let url = sidecarURL(for: entry.imageURL)
        let data = try xmpData(for: entry, existing: try? Data(contentsOf: url), existingURL: url)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Builds the merged XMP packet. Split out from `write` so it's testable
    /// without touching the file system.
    static func xmpData(for entry: Entry, existing: Data?, existingURL: URL? = nil) throws -> Data {
        let metadata: CGMutableImageMetadata
        if let existing, !existing.isEmpty {
            if let parsed = CGImageMetadataCreateFromXMPData(existing as CFData),
               let copy = CGImageMetadataCreateMutableCopy(parsed) {
                metadata = copy
            } else if !(String(data: existing, encoding: .utf8) ?? "").contains("rdf:Description") {
                // ImageIO rejects a packet with no properties at all (e.g. an
                // empty `<x:xmpmeta/>`); there's nothing to preserve, so start
                // fresh.
                metadata = CGImageMetadataCreateMutable()
            } else {
                // Real content we can't parse: refuse rather than overwrite it.
                throw WriteError.unreadableSidecar(existingURL ?? entry.imageURL)
            }
        } else {
            metadata = CGImageMetadataCreateMutable()
        }

        if !entry.keywords.isEmpty {
            let merged = mergedKeywords(existing: keywords(in: metadata), adding: entry.keywords)
            if let tag = CGImageMetadataTagCreate(
                kCGImageMetadataNamespaceDublinCore,
                kCGImageMetadataPrefixDublinCore,
                "subject" as CFString,
                .arrayUnordered,
                merged as CFArray
            ) {
                CGImageMetadataSetTagWithPath(metadata, nil, "dc:subject" as CFString, tag)
            }
        }
        if let label = entry.label {
            CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Label" as CFString, label as CFString)
        }

        guard let data = CGImageMetadataCreateXMPData(metadata, nil) else {
            throw WriteError.serializationFailed
        }
        return data as Data
    }

    /// The `dc:subject` keywords already present in `metadata`.
    static func keywords(in metadata: CGImageMetadata) -> [String] {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "dc:subject" as CFString),
              let value = CGImageMetadataTagCopyValue(tag) else { return [] }
        if let items = value as? [CGImageMetadataTag] {
            return items.compactMap { CGImageMetadataTagCopyValue($0) as? String }
        }
        if let items = value as? [String] { return items }
        if let single = value as? String { return [single] }
        return []
    }

    /// Existing keywords followed by the new ones not already present
    /// (case-insensitive), preserving order so the file diff stays minimal.
    static func mergedKeywords(existing: [String], adding new: [String]) -> [String] {
        var result = existing
        var seen = Set(existing.map { $0.lowercased() })
        for keyword in new where seen.insert(keyword.lowercased()).inserted {
            result.append(keyword)
        }
        return result
    }
}
