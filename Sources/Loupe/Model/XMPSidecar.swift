import Foundation
import ImageIO

/// Reads and writes Loupe's tags in XMP sidecar files next to camera RAW images.
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
/// Ownership: alongside the standard properties Loupe records what *it* wrote
/// in a private namespace (`loupe:Keywords`, `loupe:Label`). Saving syncs
/// exactly that set — a tag removed in Loupe is removed from the file — while
/// keywords and labels set by other apps are left alone. Every other property
/// (develop settings, rating, …) is always preserved.
///
/// Writes happen only on explicit user actions (save / remove); nothing is
/// written automatically.
enum XMPSidecar {
    /// What Loupe wants the sidecar to say for one image.
    struct Entry: Sendable {
        let imageURL: URL
        let keywords: [String]
        let label: String?
    }

    /// A sidecar as read from disk, for display and for importing tags.
    struct Contents: Sendable, Equatable {
        let sidecarURL: URL
        /// All `dc:subject` keywords, in file order.
        let keywords: [String]
        /// The `xmp:Label`, if any.
        let label: String?
        /// The subset of `keywords` Loupe wrote.
        let loupeKeywords: [String]
        /// The label Loupe wrote, if it's still the file's label.
        let loupeLabel: String?
        /// Every other top-level property as `prefix:name` → display value.
        let otherProperties: [(name: String, value: String)]

        static func == (a: Contents, b: Contents) -> Bool {
            a.sidecarURL == b.sidecarURL && a.keywords == b.keywords && a.label == b.label
                && a.loupeKeywords == b.loupeKeywords && a.loupeLabel == b.loupeLabel
                && a.otherProperties.map(\.name) == b.otherProperties.map(\.name)
                && a.otherProperties.map(\.value) == b.otherProperties.map(\.value)
        }
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

    static let loupeNamespace = "http://ns.loupe.app/xmp/1.0/"
    static let loupePrefix = "loupe"

    // MARK: - Locating

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

    /// The XMP sidecars that actually exist for a camera RAW (`name.xmp`
    /// and/or darktable's `name.RAF.xmp`), with their on-disk spelling (e.g.
    /// `.XMP`). Empty for non-RAW files, matching how Bulk Rename pairs them.
    /// Each directory is listed once per call.
    static func existingSidecars(forImages urls: [URL]) -> [URL: [URL]] {
        var listings: [URL: [String: String]] = [:]
        var result: [URL: [URL]] = [:]
        for url in urls where ImageDecoding.isRAW(url) {
            let directory = url.deletingLastPathComponent()
            if listings[directory] == nil {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
                listings[directory] = Dictionary(names.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
            }
            let names = listings[directory] ?? [:]
            let base = url.deletingPathExtension().lastPathComponent
            let found = ["\(base).xmp", "\(url.lastPathComponent).xmp"].compactMap { candidate in
                names[candidate.lowercased()].map { directory.appendingPathComponent($0) }
            }
            if !found.isEmpty { result[url] = found }
        }
        return result
    }

    /// `urls` with each RAW's existing sidecars inserted right after it, so
    /// copying or dragging a RAW carries its tags along. Order is preserved
    /// and nothing is listed twice (e.g. when the `.xmp` was also selected).
    static func addingSidecars(to urls: [URL]) -> [URL] {
        let sidecars = existingSidecars(forImages: urls)
        guard !sidecars.isEmpty else { return urls }
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            for candidate in [url] + (sidecars[url] ?? [])
            where seen.insert(candidate.standardizedFileURL.path.lowercased()).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    /// True when `url` is the sidecar of a RAW that's also in `urls`. Used to
    /// skip sidecars that arrive alongside their image (e.g. a drop), so they
    /// aren't opened as separate items.
    static func isSidecar(_ url: URL, ofAnyIn urls: [URL]) -> Bool {
        guard url.pathExtension.lowercased() == "xmp" else { return false }
        let paired = existingSidecars(forImages: urls).values.joined()
        let path = url.standardizedFileURL.path.lowercased()
        return paired.contains { $0.standardizedFileURL.path.lowercased() == path }
    }

    // MARK: - Reading

    /// Reads the sidecar for `imageURL`, or nil if there is none (or it can't
    /// be parsed).
    static func read(for imageURL: URL) -> Contents? {
        let url = sidecarURL(for: imageURL)
        guard let data = try? Data(contentsOf: url),
              let metadata = CGImageMetadataCreateFromXMPData(data as CFData) else { return nil }
        let keywords = keywords(in: metadata, path: "dc:subject")
        let label = string(in: metadata, path: "xmp:Label")
        let ownedKeywords = Set(self.keywords(in: metadata, path: "loupe:Keywords").map { $0.lowercased() })
        let ownedLabel = string(in: metadata, path: "loupe:Label")

        var others: [(String, String)] = []
        let skip: Set<String> = ["dc:subject", "xmp:Label", "loupe:Keywords", "loupe:Label"]
        for tag in realTags(in: metadata) {
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String? else { continue }
            let path = "\(prefix):\(name)"
            guard !skip.contains(path) else { continue }
            others.append((path, displayValue(of: tag)))
        }

        return Contents(
            sidecarURL: url,
            keywords: keywords,
            label: label,
            loupeKeywords: keywords.filter { ownedKeywords.contains($0.lowercased()) },
            loupeLabel: ownedLabel != nil && ownedLabel == label ? label : nil,
            otherProperties: others
        )
    }

    // MARK: - Writing

    /// Syncs the sidecar for `entry` to Loupe's current tags: keywords Loupe
    /// previously wrote but no longer has are removed, current ones are added,
    /// and the label is set — or removed if Loupe wrote it and the item no
    /// longer has a color tag. Other apps' keywords/labels are untouched.
    /// Returns the sidecar URL, or nil if the sidecar ended up empty and was
    /// deleted (or never needed creating).
    @discardableResult
    static func write(_ entry: Entry) throws -> URL? {
        try modify(imageURL: entry.imageURL) { metadata in
            apply(entry, to: metadata)
        }
    }

    /// Removes `keyword` from the sidecar (case-insensitive) regardless of
    /// which app wrote it. Explicit user action from the info sidebar.
    static func removeKeyword(_ keyword: String, imageURL: URL) throws {
        try modify(imageURL: imageURL) { metadata in
            let lower = keyword.lowercased()
            for path in ["dc:subject", "loupe:Keywords"] {
                let remaining = keywords(in: metadata, path: path).filter { $0.lowercased() != lower }
                setKeywords(remaining, path: path, in: metadata)
            }
        }
    }

    /// Removes the `xmp:Label` from the sidecar regardless of which app wrote
    /// it. Explicit user action from the info sidebar.
    static func removeLabel(imageURL: URL) throws {
        try modify(imageURL: imageURL) { metadata in
            CGImageMetadataRemoveTagWithPath(metadata, nil, "xmp:Label" as CFString)
            CGImageMetadataRemoveTagWithPath(metadata, nil, "loupe:Label" as CFString)
        }
    }

    /// Applies an entry to parsed metadata. Split out (with `xmpData`) so the
    /// sync logic is testable without touching the file system.
    static func apply(_ entry: Entry, to metadata: CGMutableImageMetadata) {
        // Keywords: drop what Loupe wrote last time, then add the current set.
        let previouslyOwned = Set(keywords(in: metadata, path: "loupe:Keywords").map { $0.lowercased() })
        let foreign = keywords(in: metadata, path: "dc:subject")
            .filter { !previouslyOwned.contains($0.lowercased()) }
        setKeywords(mergedKeywords(existing: foreign, adding: entry.keywords), path: "dc:subject", in: metadata)
        setKeywords(entry.keywords, path: "loupe:Keywords", in: metadata)

        // Label: set ours, or clear it only if it's still the one we wrote.
        let ownedLabel = string(in: metadata, path: "loupe:Label")
        if let label = entry.label {
            CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Label" as CFString, label as CFString)
            CGImageMetadataSetValueWithPath(metadata, nil, "loupe:Label" as CFString, label as CFString)
        } else {
            if let ownedLabel, string(in: metadata, path: "xmp:Label") == ownedLabel {
                CGImageMetadataRemoveTagWithPath(metadata, nil, "xmp:Label" as CFString)
            }
            CGImageMetadataRemoveTagWithPath(metadata, nil, "loupe:Label" as CFString)
        }
    }

    /// Builds the synced XMP packet for `entry` from `existing` sidecar data
    /// (nil = no sidecar). Returns nil when the result has no properties left.
    static func xmpData(for entry: Entry, existing: Data?, existingURL: URL? = nil) throws -> Data? {
        let metadata = try parse(existing, url: existingURL ?? entry.imageURL)
        apply(entry, to: metadata)
        return try serialize(metadata)
    }

    // MARK: - Internals

    /// Read-modify-write of the sidecar. Deletes the sidecar if the edit
    /// leaves it with no properties (so removing Loupe's last tag doesn't
    /// leave an empty file behind), and doesn't create one for a no-op.
    private static func modify(imageURL: URL, _ edit: (CGMutableImageMetadata) -> Void) throws -> URL? {
        let url = sidecarURL(for: imageURL)
        let existing = try? Data(contentsOf: url)
        let metadata = try parse(existing, url: url)
        edit(metadata)
        guard let data = try serialize(metadata) else {
            if existing != nil { try FileManager.default.removeItem(at: url) }
            return nil
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func parse(_ data: Data?, url: URL) throws -> CGMutableImageMetadata {
        let metadata: CGMutableImageMetadata
        if let data, !data.isEmpty {
            if let parsed = CGImageMetadataCreateFromXMPData(data as CFData),
               let copy = CGImageMetadataCreateMutableCopy(parsed) {
                metadata = copy
            } else if isEmptyPacket(data) {
                // ImageIO rejects a packet with no properties at all (e.g. an
                // empty `<x:xmpmeta/>` or a bare `<rdf:Description/>`, which
                // ImageIO itself writes for empty metadata); nothing to keep.
                metadata = CGImageMetadataCreateMutable()
            } else {
                // Real content we can't parse: refuse rather than overwrite it.
                throw WriteError.unreadableSidecar(url)
            }
        } else {
            metadata = CGImageMetadataCreateMutable()
        }
        CGImageMetadataRegisterNamespaceForPrefix(metadata, loupeNamespace as CFString, loupePrefix as CFString, nil)
        return metadata
    }

    /// Serialized XMP, or nil if no real properties remain.
    private static func serialize(_ metadata: CGImageMetadata) throws -> Data? {
        guard !realTags(in: metadata).isEmpty else { return nil }
        guard let data = CGImageMetadataCreateXMPData(metadata, nil) else {
            throw WriteError.serializationFailed
        }
        return data as Data
    }

    /// Top-level tags excluding ImageIO's synthetic `iio:` ones (e.g.
    /// `iio:hasXMP`, added on parse but never serialized).
    private static func realTags(in metadata: CGImageMetadata) -> [CGImageMetadataTag] {
        ((CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag]) ?? []).filter {
            (CGImageMetadataTagCopyPrefix($0) as String?) != "iio"
        }
    }

    /// True when `data` is only XMP wrapper markup with no properties: xpacket
    /// instructions, `x:xmpmeta`, `rdf:RDF`, and attribute-less (bar
    /// `rdf:about`) `rdf:Description` elements.
    static func isEmptyPacket(_ data: Data) -> Bool {
        guard var text = String(data: data, encoding: .utf8) else { return false }
        let wrappers = [
            #"<\?xpacket[^>]*\?>"#,
            #"<\?xml[^>]*\?>"#,
            #"</?x:xmpmeta[^>]*>"#,
            #"</?rdf:RDF[^>]*>"#,
            #"<rdf:Description\s+rdf:about="[^"]*"\s*/>"#,
            #"<rdf:Description\s+rdf:about="[^"]*"\s*>\s*</rdf:Description>"#,
        ]
        for pattern in wrappers {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\u{FEFF}"))).isEmpty
    }

    private static func setKeywords(_ keywords: [String], path: String, in metadata: CGMutableImageMetadata) {
        guard !keywords.isEmpty else {
            CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
            return
        }
        let parts = path.split(separator: ":")
        let (namespace, prefix): (CFString, CFString) = parts.first == "loupe"
            ? (loupeNamespace as CFString, loupePrefix as CFString)
            : (kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore)
        if let tag = CGImageMetadataTagCreate(
            namespace, prefix, String(parts.last ?? "") as CFString, .arrayUnordered, keywords as CFArray
        ) {
            CGImageMetadataSetTagWithPath(metadata, nil, path as CFString, tag)
        }
    }

    /// The array values at `path` (e.g. `dc:subject`).
    static func keywords(in metadata: CGImageMetadata, path: String = "dc:subject") -> [String] {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
              let value = CGImageMetadataTagCopyValue(tag) else { return [] }
        if let items = value as? [CGImageMetadataTag] {
            return items.compactMap { CGImageMetadataTagCopyValue($0) as? String }
        }
        if let items = value as? [String] { return items }
        if let single = value as? String { return [single] }
        return []
    }

    private static func string(in metadata: CGImageMetadata, path: String) -> String? {
        CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString) as String?
    }

    private static func displayValue(of tag: CGImageMetadataTag) -> String {
        guard let value = CGImageMetadataTagCopyValue(tag) else { return "" }
        if let items = value as? [CGImageMetadataTag] {
            return items.map { displayValue(of: $0) }.joined(separator: ", ")
        }
        if let dict = value as? [String: CGImageMetadataTag] {
            return dict.keys.sorted().map { "\($0)=\(displayValue(of: dict[$0]!))" }.joined(separator: ", ")
        }
        return "\(value)"
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
