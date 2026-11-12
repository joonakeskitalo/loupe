import Foundation
import CryptoKit
import ImageIO
import CoreGraphics

/// How strictly images must match to count as duplicates.
enum DuplicateSensitivity: String, CaseIterable, Sendable, Identifiable {
    case exact = "Exact copies only"
    case strict = "Nearly identical"
    case normal = "Similar"
    case loose = "Loosely similar"

    var id: String { rawValue }

    /// Largest perceptual-hash Hamming distance (of 64 bits) that still counts
    /// as a match. `nil` disables perceptual matching entirely.
    var maxDistance: Int? {
        switch self {
        case .exact: return nil
        case .strict: return 3
        case .normal: return 7
        case .loose: return 12
        }
    }
}

/// A set of files that are the same or near-identical. `items` is ordered best
/// first, so `items[0]` is the suggested keeper.
struct DuplicateGroup: Identifiable, Sendable {
    enum Kind: Sendable {
        /// Byte-for-byte identical files.
        case exact
        /// Visually matching images that differ on disk (resized, re-encoded…).
        case similar
    }

    let id: Int
    let kind: Kind
    let items: [MediaItem]
    /// Pixel dimensions of the image members, for display and ranking.
    let pixelSizes: [URL: CGSize]

    /// Bytes freed by removing everything except the suggested keeper.
    var reclaimableBytes: Int64 {
        items.dropFirst().reduce(Int64(0)) { $0 + $1.fileSize }
    }
}

/// Finds duplicate files: byte-identical copies of any file type (size, then
/// SHA-256), plus visually similar images via a 64-bit difference hash (dHash)
/// compared by Hamming distance. Everything runs on-device.
enum DuplicateFinder {
    /// Aspect ratios further apart than this (relative) are never matched, which
    /// keeps flat/low-detail images with colliding hashes from grouping.
    private static let aspectTolerance = 0.05

    private struct Fingerprint: Sendable {
        let hash: UInt64
        let size: CGSize
    }

    /// Searches `items` and returns duplicate groups, largest savings first.
    /// `progress(done, total)` is called as files are processed. Honors task
    /// cancellation (returns whatever is finished so far as an empty result).
    static func find(
        items: [MediaItem],
        sensitivity: DuplicateSensitivity,
        progress: @MainActor @Sendable (Int, Int) -> Void
    ) async -> [DuplicateGroup] {
        let limit = max(2, ProcessInfo.processInfo.activeProcessorCount)

        // --- Exact: same size, then same content hash. ---
        var parent = Array(0..<items.count)
        func root(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { r = parent[r] }
            var c = i
            while parent[c] != r { let n = parent[c]; parent[c] = r; c = n }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = root(a), rb = root(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        let bySize = Dictionary(grouping: items.indices) { items[$0].fileSize }
        let hashCandidates = bySize.filter { $0.key > 0 && $0.value.count > 1 }
            .values.flatMap { $0 }.sorted()
        let imageCandidates = sensitivity.maxDistance == nil
            ? [] : items.indices.filter { items[$0].kind == .image }
        var total = hashCandidates.count
        var done = 0
        await progress(0, total)

        let urls = items.map(\.url)
        let hashes = await parallelMap(hashCandidates, limit: limit, onDone: {
            done += 1
            await progress(done, total)
        }, work: { contentHash(of: urls[$0]) })
        if Task.isCancelled { return [] }

        var seen: [String: Int] = [:]
        for (n, idx) in hashCandidates.enumerated() {
            guard let h = hashes[n] else { continue }
            let key = "\(items[idx].fileSize)-\(h)"
            if let first = seen[key] { union(first, idx) } else { seen[key] = idx }
        }
        let exactRoot = (0..<items.count).map { root($0) }

        // --- Similar images: greedy clustering on dHash. ---
        var sizes: [Int: CGSize] = [:]
        if let maxDistance = sensitivity.maxDistance {
            // Exact copies share a fingerprint; compute it once per class.
            let reps = imageCandidates.filter { root($0) == $0 }
            total += reps.count
            let prints = await parallelMap(reps, limit: limit, onDone: {
                done += 1
                await progress(done, total)
            }, work: { fingerprint(of: urls[$0]) })
            if Task.isCancelled { return [] }

            struct Cluster { var rep: Fingerprint; var index: Int }
            var clusters: [Cluster] = []
            for (n, idx) in reps.enumerated() {
                guard let fp = prints[n] else { continue }
                sizes[idx] = fp.size
                var matched = false
                for c in clusters where similar(fp, c.rep, maxDistance) {
                    union(c.index, idx)
                    matched = true
                    break
                }
                if !matched { clusters.append(Cluster(rep: fp, index: idx)) }
                if n % 256 == 0, Task.isCancelled { return [] }
            }
        }

        // --- Assemble groups. ---
        var members: [Int: [Int]] = [:]
        for i in items.indices { members[root(i), default: []].append(i) }

        var groups: [DuplicateGroup] = []
        for (_, indices) in members where indices.count > 1 {
            // Dimensions for every image member (exact copies share a size).
            var pixelSizes: [URL: CGSize] = [:]
            for i in indices where items[i].kind == .image {
                let size = sizes[exactRoot[i]] ?? pixelSize(of: items[i].url)
                if let size { pixelSizes[items[i].url] = size }
            }
            func pixels(_ item: MediaItem) -> CGFloat {
                guard let s = pixelSizes[item.url] else { return 0 }
                return s.width * s.height
            }
            let ordered = indices.map { items[$0] }.sorted { a, b in
                if pixels(a) != pixels(b) { return pixels(a) > pixels(b) }
                if a.fileSize != b.fileSize { return a.fileSize > b.fileSize }
                if a.modificationDate != b.modificationDate { return a.modificationDate < b.modificationDate }
                return a.url.path.localizedStandardCompare(b.url.path) == .orderedAscending
            }
            let isExact = Set(indices.map { exactRoot[$0] }).count == 1
            groups.append(DuplicateGroup(
                id: 0, kind: isExact ? .exact : .similar,
                items: ordered, pixelSizes: pixelSizes))
        }
        groups.sort {
            if $0.reclaimableBytes != $1.reclaimableBytes { return $0.reclaimableBytes > $1.reclaimableBytes }
            return $0.items[0].name.localizedStandardCompare($1.items[0].name) == .orderedAscending
        }
        // Stable ids assigned after sorting.
        return groups.enumerated().map {
            DuplicateGroup(id: $0.offset, kind: $0.element.kind,
                           items: $0.element.items, pixelSizes: $0.element.pixelSizes)
        }
    }

    // MARK: - Concurrency helper

    /// Maps `inputs` through blocking `work` with at most `limit` in flight,
    /// preserving order. A `nil` result means the work failed or was cancelled.
    private static func parallelMap<T: Sendable, R: Sendable>(
        _ inputs: [T],
        limit: Int,
        onDone: () async -> Void,
        work: @escaping @Sendable (T) -> R?
    ) async -> [R?] {
        var results = [R?](repeating: nil, count: inputs.count)
        await withTaskGroup(of: (Int, R?).self) { group in
            var next = 0
            func addNext() {
                guard next < inputs.count else { return }
                let i = next
                let input = inputs[i]
                next += 1
                group.addTask { (i, Task.isCancelled ? nil : work(input)) }
            }
            for _ in 0..<min(limit, inputs.count) { addNext() }
            while let (i, r) = await group.next() {
                results[i] = r
                await onDone()
                addNext()
            }
        }
        return results
    }

    // MARK: - Hashing

    /// SHA-256 of the file's bytes, streamed so large videos don't load fully.
    private static func contentHash(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if Task.isCancelled { return nil }
            let chunk: Data? = autoreleasepool {
                (try? handle.read(upToCount: 1 << 20)) ?? nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func similar(_ a: Fingerprint, _ b: Fingerprint, _ maxDistance: Int) -> Bool {
        guard (a.hash ^ b.hash).nonzeroBitCount <= maxDistance else { return false }
        guard a.size.height > 0, b.size.height > 0 else { return true }
        let ra = a.size.width / a.size.height
        let rb = b.size.width / b.size.height
        return abs(ra - rb) / max(ra, rb) <= aspectTolerance
    }

    // MARK: - Image fingerprint

    /// Pixel size with EXIF orientation applied, read from metadata only.
    private static func pixelSize(of url: URL) -> CGSize? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, opts),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// 64-bit difference hash: the image is shrunk to 9×8 grayscale and each bit
    /// records whether a pixel is brighter than its right neighbor. Robust to
    /// resizing, recompression and small color shifts.
    private static func fingerprint(of url: URL) -> Fingerprint? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let size = pixelSize(of: url)
        else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
        else { return nil }

        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        var hash: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                hash = (hash << 1) | (pixels[y * w + x] > pixels[y * w + x + 1] ? 1 : 0)
            }
        }
        return Fingerprint(hash: hash, size: size)
    }
}
