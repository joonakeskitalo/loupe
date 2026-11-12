import Foundation
import ImageIO

/// One titled group of metadata rows (e.g. "EXIF", "GPS") for the info
/// sidebar's EXIF tab.
struct MetadataGroup: Identifiable, Sendable, Equatable {
    struct Row: Identifiable, Sendable, Equatable {
        let label: String
        let value: String
        var id: String { label }
    }

    let title: String
    let rows: [Row]
    var id: String { title }
}

/// Reads every metadata property embedded in an image file — EXIF, TIFF, GPS,
/// IPTC, maker notes, embedded XMP — from the header via ImageIO, without
/// decoding pixels, and formats it into display groups. Read-only.
enum ImageMetadataReader {
    static func groups(for url: URL) -> [MetadataGroup] {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0 else { return [] }

        var groups: [MetadataGroup] = []
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            groups = propertyGroups(props)
        }
        if let xmp = embeddedXMPGroup(source) {
            groups.append(xmp)
        }
        return groups
    }

    /// Splits the ImageIO property dictionary into groups: top-level scalars
    /// become "Image", and each `{Dictionary}` (Exif, TIFF, GPS, maker notes…)
    /// its own group, ordered with the common ones first.
    private static func propertyGroups(_ props: [String: Any]) -> [MetadataGroup] {
        var image: [MetadataGroup.Row] = []
        var dictionaries: [(key: String, rows: [MetadataGroup.Row])] = []

        for (key, value) in props {
            if let dict = value as? [String: Any] {
                var rows: [MetadataGroup.Row] = []
                flatten(dict, prefix: "", into: &rows)
                if !rows.isEmpty { dictionaries.append((key, rows)) }
            } else if let text = format(value) {
                image.append(.init(label: humanize(key), value: text))
            }
        }

        let order = ["{Exif}", "{TIFF}", "{GPS}", "{ExifAux}", "{IPTC}"]
        dictionaries.sort { a, b in
            let ia = order.firstIndex(of: a.key) ?? order.count
            let ib = order.firstIndex(of: b.key) ?? order.count
            return ia != ib ? ia < ib : a.key < b.key
        }

        var groups: [MetadataGroup] = []
        if !image.isEmpty {
            groups.append(.init(title: "Image", rows: image.sorted { $0.label < $1.label }))
        }
        for (key, rows) in dictionaries {
            groups.append(.init(title: groupTitle(key), rows: rows.sorted { $0.label < $1.label }))
        }
        return groups
    }

    /// XMP embedded in the file itself (common for JPEG/HEIC/DNG), excluding
    /// the EXIF/TIFF namespaces already shown above.
    private static func embeddedXMPGroup(_ source: CGImageSource) -> MetadataGroup? {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return nil }
        let skip: Set<String> = ["exif", "exifEX", "tiff", "aux", "iio"]
        let rows: [MetadataGroup.Row] = tags.compactMap { tag in
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?, !skip.contains(prefix),
                  let name = CGImageMetadataTagCopyName(tag) as String? else { return nil }
            return .init(label: "\(prefix):\(name)",
                         value: xmpValue(tag).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return rows.isEmpty ? nil : .init(title: "Embedded XMP", rows: rows.sorted { $0.label < $1.label })
    }

    private static func xmpValue(_ tag: CGImageMetadataTag) -> String {
        guard let value = CGImageMetadataTagCopyValue(tag) else { return "" }
        if let items = value as? [CGImageMetadataTag] {
            return items.map(xmpValue).joined(separator: ", ")
        }
        if let dict = value as? [String: CGImageMetadataTag] {
            return dict.keys.sorted().map { "\($0)=\(xmpValue(dict[$0]!))" }.joined(separator: ", ")
        }
        return "\(value)"
    }

    private static func flatten(_ dict: [String: Any], prefix: String, into rows: inout [MetadataGroup.Row]) {
        for (key, value) in dict {
            let label = prefix.isEmpty ? humanize(key) : "\(prefix) › \(humanize(key))"
            if let nested = value as? [String: Any] {
                flatten(nested, prefix: label, into: &rows)
            } else if let text = format(value) {
                rows.append(.init(label: label, value: text))
            }
        }
    }

    /// Display string for a property value; nil for values not worth showing
    /// (empty strings, raw binary blobs).
    private static func format(_ value: Any) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "Yes" : "No" }
            let double = number.doubleValue
            return double.rounded() == double && abs(double) < 1e15
                ? String(Int64(double))
                : String(format: "%g", double)
        case let array as [Any]:
            let parts = array.compactMap(format)
            if parts.count > 16 { return "\(parts.prefix(16).joined(separator: ", ")), … (\(parts.count) values)" }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case let data as Data:
            return "\(data.count) bytes"
        default:
            return nil
        }
    }

    /// "{Exif}" → "EXIF", "{MakerFuji}" → "Maker Notes (Fuji)", etc.
    private static func groupTitle(_ key: String) -> String {
        let bare = key.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        switch bare {
        case "Exif": return "EXIF"
        case "TIFF": return "TIFF"
        case "GPS": return "GPS"
        case "ExifAux": return "EXIF Auxiliary"
        case "IPTC": return "IPTC"
        case "JFIF": return "JFIF"
        default:
            if bare.hasPrefix("Maker") {
                let vendor = bare.dropFirst("Maker".count)
                return vendor.isEmpty ? "Maker Notes" : "Maker Notes (\(vendor))"
            }
            return humanize(bare)
        }
    }

    /// "ExposureTime" → "Exposure Time"; leaves acronyms ("ISO", "GPS") intact.
    private static func humanize(_ key: String) -> String {
        var result = ""
        let chars = Array(key)
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase,
               chars[i - 1].isLowercase || (i + 1 < chars.count && chars[i + 1].isLowercase && chars[i - 1].isUppercase) {
                result.append(" ")
            }
            result.append(c)
        }
        return result
    }
}
