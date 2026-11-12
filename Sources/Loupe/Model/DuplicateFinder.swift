import Foundation
import CryptoKit
import ImageIO
import CoreGraphics
import AVFoundation
import PDFKit

/// How strictly images must match to count as duplicates.
enum DuplicateSensitivity: String, CaseIterable, Sendable, Identifiable {
    case exact = "Exact copies only"
    case strict = "Nearly identical"
    case normal = "Similar"
    case loose = "Loosely similar"

    var id: String { rawValue }

    /// One-line explanation shown when choosing a match type.
    var summary: String {
        switch self {
        case .exact:
            return "Byte-for-byte identical files of any type. Fastest, and never a false match."
        case .strict:
            return "Also matches re-saved or resized copies of images, videos, audio and documents that look or sound the same."
        case .normal:
            return "Balanced: catches edited exports, recompressed and re-encoded copies. Recommended."
        case .loose:
            return "Broadest: also catches lightly cropped or altered versions. May include false matches, so review the results."
        }
    }

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
        /// Matching content that differs on disk: images resized or re-encoded,
        /// videos or audio re-encoded, documents with edited whitespace, etc.
        case similar
    }

    let id: Int
    let kind: Kind
    let items: [MediaItem]
    /// Pixel dimensions of the image members, for display and ranking.
    let pixelSizes: [URL: CGSize]

    /// Plural noun for what a similar-match group contains.
    var similarNoun: String {
        switch items.first?.kind {
        case .image: return "images"
        case .video: return "videos"
        case .audio: return "audio files"
        default: return "documents"
        }
    }

    /// Bytes freed by removing everything except the suggested keeper.
    var reclaimableBytes: Int64 {
        items.dropFirst().reduce(Int64(0)) { $0 + $1.fileSize }
    }
}

/// Finds duplicate files, all on-device:
/// - Exact: byte-identical copies of any file type (size, then SHA-256).
/// - Similar images: 64-bit difference hash (dHash).
/// - Similar videos: dHashes of three frames, plus matching duration.
/// - Similar audio: a 64-bit loudness-envelope hash of the first minute, plus
///   matching duration (survives re-encoding to another format/bitrate).
/// - Similar documents (PDF, text, Markdown): a SimHash of the words, so
///   reformatted or lightly edited copies still match.
/// Fingerprints are compared by Hamming distance within the same family.
enum DuplicateFinder {
    /// Aspect ratios further apart than this (relative) are never matched, which
    /// keeps flat/low-detail images with colliding hashes from grouping.
    private static let aspectTolerance = 0.05

    private struct Fingerprint: Sendable {
        enum Family: Sendable { case image, video, audio, document }
        let family: Family
        /// One 64-bit hash (two or more for videos: one per sampled frame).
        let words: [UInt64]
        /// Width / height for images and videos.
        let aspect: Double?
        /// Duration in seconds (audio, video) or word count (documents).
        let scalar: Double?
        /// Pixel size for display and ranking (images, videos).
        let size: CGSize?
    }

    private static func family(of kind: MediaKind) -> Fingerprint.Family? {
        switch kind {
        case .image: return .image
        case .video: return .video
        case .audio: return .audio
        case .pdf, .markdown, .text: return .document
        case .other: return nil
        }
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

        let fuzzyCandidates = sensitivity.maxDistance == nil
            ? [] : items.indices.filter { family(of: items[$0].kind) != nil }
        let urls = items.map(\.url)

        // Exact matching narrows candidates in cheap stages so most files are
        // never read in full:
        //   1. size — free, from the scan;
        //   2. hard links to one file are dropped (they free no space);
        //   3. a "quick hash" of the first and last 64 KB, which separates
        //      nearly all same-size files that differ;
        //   4. a full SHA-256, only for files whose quick hashes still collide.
        // Small files (≤ 128 KB) get their full hash directly in stage 3.
        let bySize = Dictionary(grouping: items.indices) { items[$0].fileSize }
        var quickCandidates: [Int] = []
        for (size, indices) in bySize where size > 0 && indices.count > 1 {
            var seenFiles = Set<AnyHashable>()
            for i in indices.sorted() {
                if let id = fileIdentifier(of: urls[i]), !seenFiles.insert(id).inserted { continue }
                quickCandidates.append(i)
            }
        }
        quickCandidates.sort()
        // Disk-bound work: too many readers thrash spinning/network volumes.
        let hashLimit = min(limit, 6)
        var total = quickCandidates.count
        var done = 0
        await progress(0, total)

        let quick = await parallelMap(quickCandidates, limit: hashLimit, onDone: {
            done += 1
            await progress(done, total)
        }, work: { quickHash(of: urls[$0], size: items[$0].fileSize) })
        if Task.isCancelled { return [] }

        var byQuick: [HashKey: [Int]] = [:]
        for (n, idx) in quickCandidates.enumerated() {
            guard let q = quick[n] else { continue }
            byQuick[HashKey(size: items[idx].fileSize, digest: q.digest, complete: q.complete),
                    default: []].append(idx)
        }
        var needFull: [Int] = []
        for (key, indices) in byQuick where indices.count > 1 {
            if key.complete {
                // The quick hash already covered the whole file.
                for i in indices.dropFirst() { union(indices[0], i) }
            } else {
                needFull.append(contentsOf: indices)
            }
        }
        needFull.sort()
        total += needFull.count
        await progress(done, total)

        let full = await parallelMap(needFull, limit: hashLimit, onDone: {
            done += 1
            await progress(done, total)
        }, work: { contentHash(of: urls[$0]) })
        if Task.isCancelled { return [] }

        var seen: [HashKey: Int] = [:]
        for (n, idx) in needFull.enumerated() {
            guard let digest = full[n] else { continue }
            let key = HashKey(size: items[idx].fileSize, digest: digest, complete: true)
            if let first = seen[key] { union(first, idx) } else { seen[key] = idx }
        }
        let exactRoot = (0..<items.count).map { root($0) }

        // --- Similar content: greedy clustering on fingerprints. ---
        var sizes: [Int: CGSize] = [:]
        if let maxDistance = sensitivity.maxDistance {
            // Exact copies share a fingerprint; compute it once per class.
            let reps = fuzzyCandidates.filter { root($0) == $0 }
            total += reps.count

            // Videos decode frames and are heavy, so fewer run at once.
            let families: [(Fingerprint.Family, Int)] = [
                (.image, limit), (.video, min(max(2, limit), 4)), (.audio, max(2, limit / 2)), (.document, limit),
            ]
            for (fam, familyLimit) in families {
                let indices = reps.filter { family(of: items[$0].kind) == fam }
                guard !indices.isEmpty else { continue }
                let prints: [Fingerprint?]
                if fam == .video {
                    // Read durations first (metadata only). A video whose length
                    // matches no other video can't be a duplicate, so it never
                    // needs its frames decoded.
                    let durations = await parallelMap(indices, limit: limit, onDone: {}, work: {
                        await videoDuration(of: urls[$0])
                    })
                    if Task.isCancelled { return [] }
                    let candidate = durationCandidates(durations)
                    let skipped = indices.indices.filter { !candidate[$0] }
                    done += skipped.count
                    await progress(done, total)

                    // Skipped videos in exact-copy groups still want a pixel size
                    // for display; that only needs the track header.
                    var classCounts: [Int: Int] = [:]
                    for i in items.indices { classCounts[root(i), default: 0] += 1 }
                    let needSize = skipped.filter { (classCounts[indices[$0]] ?? 0) > 1 }
                    let skippedSizes = await parallelMap(needSize, limit: limit, onDone: {}, work: {
                        await videoSize(of: AVURLAsset(url: urls[indices[$0]]))
                    })
                    for (n, slot) in needSize.enumerated() {
                        if let size = skippedSizes[n] { sizes[indices[slot]] = size }
                    }
                    if Task.isCancelled { return [] }

                    let todo = indices.indices.filter { candidate[$0] }
                    let results = await parallelMap(todo, limit: familyLimit, onDone: {
                        done += 1
                        await progress(done, total)
                    }, work: {
                        await videoFingerprint(of: urls[indices[$0]], duration: durations[$0] ?? 0)
                    })
                    var merged = [Fingerprint?](repeating: nil, count: indices.count)
                    for (n, slot) in todo.enumerated() { merged[slot] = results[n] }
                    prints = merged
                } else {
                    prints = await parallelMap(indices, limit: familyLimit, onDone: {
                        done += 1
                        await progress(done, total)
                    }, work: { await fingerprint(of: items[$0], family: fam) })
                }
                if Task.isCancelled { return [] }

                // Clusters never span families, so each family gets its own set.
                var clusters = ClusterSet(maxDistance: maxDistance)
                for (n, idx) in indices.enumerated() {
                    guard let fp = prints[n] else { continue }
                    if let size = fp.size { sizes[idx] = size }
                    if let match = clusters.firstMatch(for: fp) {
                        union(match, idx)
                    } else {
                        clusters.add(fp, index: idx)
                    }
                    if n % 256 == 0, Task.isCancelled { return [] }
                }
            }
        }

        // --- Assemble groups. ---
        var members: [Int: [Int]] = [:]
        for i in items.indices { members[root(i), default: []].append(i) }

        var groups: [DuplicateGroup] = []
        for (_, indices) in members where indices.count > 1 {
            // Dimensions for every image member (exact copies share a size).
            var pixelSizes: [URL: CGSize] = [:]
            for i in indices where items[i].kind == .image || items[i].kind == .video {
                let size = sizes[exactRoot[i]]
                    ?? (items[i].kind == .image ? pixelSize(of: items[i].url) : nil)
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
        work: @escaping @Sendable (T) async -> R?
    ) async -> [R?] {
        var results = [R?](repeating: nil, count: inputs.count)
        await withTaskGroup(of: (Int, R?).self) { group in
            var next = 0
            func addNext() {
                guard next < inputs.count else { return }
                let i = next
                let input = inputs[i]
                next += 1
                group.addTask { (i, Task.isCancelled ? nil : await work(input)) }
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

    private struct HashKey: Hashable {
        let size: Int64
        let digest: Data
        /// Whether `digest` covers the entire file (vs. a head+tail sample).
        let complete: Bool
    }

    private static let sampleLength = 64 * 1024
    private static let readChunk = 4 << 20

    /// Identity of the underlying file, so hard links to one file compare equal.
    private static func fileIdentifier(of url: URL) -> AnyHashable? {
        guard let id = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey])
            .fileResourceIdentifier as? NSObject
        else { return nil }
        return AnyHashable(id)
    }

    /// SHA-256 of the first and last 64 KB. For files small enough that those
    /// overlap, it hashes the whole file and reports `complete`.
    private static func quickHash(of url: URL, size: Int64) -> (digest: Data, complete: Bool)? {
        if size <= Int64(sampleLength * 2) {
            guard let digest = contentHash(of: url) else { return nil }
            return (digest, true)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            guard let head = try handle.read(upToCount: sampleLength), head.count == sampleLength
            else { return nil }
            hasher.update(data: head)
            try handle.seek(toOffset: UInt64(size) - UInt64(sampleLength))
            guard let tail = try handle.read(upToCount: sampleLength), tail.count == sampleLength
            else { return nil }
            hasher.update(data: tail)
        } catch {
            return nil
        }
        return (Data(hasher.finalize()), false)
    }

    /// SHA-256 of the file's bytes, streamed in large chunks so big videos
    /// don't load fully into memory.
    private static func contentHash(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if Task.isCancelled { return nil }
            let chunk: Data? = autoreleasepool {
                (try? handle.read(upToCount: readChunk)) ?? nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    /// Cluster representatives for one family, with a multi-index over
    /// single-word hashes. A match within `d` bits must agree exactly on at
    /// least one of `d + 1` chunks (pigeonhole), so a lookup only scans
    /// clusters sharing a chunk instead of every cluster. Results are identical
    /// to a linear scan: the earliest-created matching cluster wins.
    private struct ClusterSet {
        let maxDistance: Int
        private var reps: [(fp: Fingerprint, index: Int)] = []
        private var buckets: [UInt64: [Int]] = [:]
        private let chunkCount: Int

        init(maxDistance: Int) {
            self.maxDistance = maxDistance
            self.chunkCount = maxDistance + 1
        }

        /// Bucket keys for a one-word hash: chunk number plus chunk value.
        private func keys(for word: UInt64) -> [UInt64] {
            (0..<chunkCount).map { c in
                let lo = c * 64 / chunkCount, hi = (c + 1) * 64 / chunkCount
                let width = hi - lo
                let mask: UInt64 = width >= 64 ? ~0 : (1 << UInt64(width)) - 1
                return (UInt64(c) << 48) | ((word >> UInt64(lo)) & mask)
            }
        }

        mutating func add(_ fp: Fingerprint, index: Int) {
            let position = reps.count
            reps.append((fp, index))
            if fp.words.count == 1 {
                for key in keys(for: fp.words[0]) { buckets[key, default: []].append(position) }
            }
        }

        func firstMatch(for fp: Fingerprint) -> Int? {
            guard fp.words.count == 1 else {
                // Multi-word (video) fingerprints are few; scan linearly.
                return reps.first { DuplicateFinder.similar(fp, $0.fp, maxDistance) }?.index
            }
            var best = Int.max
            for key in keys(for: fp.words[0]) {
                guard let positions = buckets[key] else { continue }
                for p in positions {
                    if p >= best { break }  // ascending: nothing earlier here
                    if DuplicateFinder.similar(fp, reps[p].fp, maxDistance) { best = p; break }
                }
            }
            return best == Int.max ? nil : reps[best].index
        }
    }

    private static func similar(_ a: Fingerprint, _ b: Fingerprint, _ maxDistance: Int) -> Bool {
        guard a.family == b.family, a.words.count == b.words.count else { return false }
        let bits = zip(a.words, b.words).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
        guard Double(bits) / Double(a.words.count) <= Double(maxDistance) else { return false }
        if let x = a.aspect, let y = b.aspect, x > 0, y > 0,
           abs(x - y) / max(x, y) > aspectTolerance {
            return false
        }
        if let x = a.scalar, let y = b.scalar {
            switch a.family {
            case .audio, .video:
                // Same recording should run the same length.
                if abs(x - y) > max(1.5, 0.03 * max(x, y)) { return false }
            case .document:
                if min(x, y) / max(x, y) < 0.5 { return false }
            case .image:
                break
            }
        }
        return true
    }

    private static func fingerprint(of item: MediaItem, family: Fingerprint.Family) async -> Fingerprint? {
        switch family {
        case .image: return imageFingerprint(of: item.url)
        case .video:
            guard let duration = await videoDuration(of: item.url) else { return nil }
            return await videoFingerprint(of: item.url, duration: duration)
        case .audio: return await audioFingerprint(of: item.url)
        case .document: return documentFingerprint(of: item)
        }
    }

    // MARK: - Image fingerprint

    /// Pixel size with EXIF orientation applied, read from metadata only.
    private static func pixelSize(of url: URL) -> CGSize? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, opts) else { return nil }
        return pixelSize(of: source)
    }

    private static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    private static func imageFingerprint(of url: URL) -> Fingerprint? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let size = pixelSize(of: source)
        else { return nil }
        // Shared decoder: for camera RAW it hashes the embedded preview rather
        // than running ImageIO's full RAW decode, which leaks ~130 MB per file.
        guard let image = autoreleasepool(invoking: {
                  ImageDecoding.decodeCGImage(url: url, maxPixelSize: 128, alwaysDecodeFromFullImage: true)
              }),
              let hash = differenceHash(of: image)
        else { return nil }
        return Fingerprint(
            family: .image, words: [hash],
            aspect: size.height > 0 ? size.width / size.height : nil,
            scalar: nil, size: size)
    }

    /// 64-bit difference hash: the image is shrunk to 9×8 grayscale and each bit
    /// records whether a pixel is brighter than its right neighbor. Robust to
    /// resizing, recompression and small color shifts.
    private static func differenceHash(of image: CGImage) -> UInt64? {
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
        return hash
    }

    // MARK: - Video fingerprint

    /// dHashes of frames at 15%, 50% and 85% of the runtime, plus the duration.
    /// Containers AVFoundation can't open (mkv/webm) return nil and are only
    /// matched as exact copies.
    private static func videoFingerprint(of url: URL, duration: Double) async -> Fingerprint? {
        let asset = AVURLAsset(url: url)
        guard duration.isFinite, duration > 0 else { return nil }

        // Read the track size while the frames decode.
        async let size = videoSize(of: asset)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 128, height: 128)
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        // One batched request lets AVFoundation schedule the seeks together.
        // Results can arrive in any order, so slot them by requested time.
        let times = [0.15, 0.5, 0.85].map { CMTime(seconds: duration * $0, preferredTimescale: 600) }
        var hashes = [UInt64?](repeating: nil, count: times.count)
        var aspect: Double?
        for await result in generator.images(for: times) {
            if Task.isCancelled { return nil }
            guard let frame = try? result.image,
                  let slot = times.firstIndex(of: result.requestedTime),
                  let hash = differenceHash(of: frame)
            else { return nil }
            hashes[slot] = hash
            if aspect == nil, frame.height > 0 { aspect = Double(frame.width) / Double(frame.height) }
        }
        let words = hashes.compactMap { $0 }
        guard words.count == times.count else { return nil }

        return Fingerprint(
            family: .video, words: words, aspect: aspect, scalar: duration, size: await size)
    }

    /// Runtime in seconds from container metadata, or nil if unreadable.
    private static func videoDuration(of url: URL) async -> Double? {
        guard let seconds = try? await AVURLAsset(url: url).load(.duration).seconds,
              seconds.isFinite, seconds > 0
        else { return nil }
        return seconds
    }

    /// Display size of the first video track, with its transform applied.
    private static func videoSize(of asset: AVURLAsset) async -> CGSize? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { return nil }
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// Flags videos whose duration is within `similar()`'s tolerance of at least
    /// one other video's. The rest can't match anything. Durations are sorted,
    /// and the tolerance only widens slowly, so once a later video is out of
    /// range every one after it is too.
    private static func durationCandidates(_ durations: [Double?]) -> [Bool] {
        var flags = [Bool](repeating: false, count: durations.count)
        let order = durations.indices.filter { durations[$0] != nil }
            .sorted { durations[$0]! < durations[$1]! }
        for (a, i) in order.enumerated() {
            let x = durations[i]!
            for j in order[(a + 1)...] {
                let y = durations[j]!
                if y - x > max(1.5, 0.03 * y) { break }
                flags[i] = true
                flags[j] = true
            }
        }
        return flags
    }

    // MARK: - Audio fingerprint

    /// Loudness-envelope hash of the first minute, decoded to 8 kHz mono: the
    /// signal is split into 65 slices and each bit says whether a slice is
    /// louder than the next. Independent of container, codec and bitrate.
    private static func audioFingerprint(of url: URL) async -> Fingerprint? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 1,
              let track = try? await asset.loadTracks(withMediaType: .audio).first
        else { return nil }
        guard let samples = readAudioSamples(asset: asset, track: track, seconds: min(duration, 60)),
              samples.count >= 65 * 16
        else { return nil }

        let slice = samples.count / 65
        var envelope = [Float](repeating: 0, count: 65)
        for i in 0..<65 {
            var sum: Float = 0
            for j in (i * slice)..<((i + 1) * slice) { sum += abs(samples[j]) }
            envelope[i] = sum / Float(slice)
        }
        var hash: UInt64 = 0
        for i in 0..<64 { hash = (hash << 1) | (envelope[i] > envelope[i + 1] ? 1 : 0) }
        return Fingerprint(family: .audio, words: [hash], aspect: nil, scalar: duration, size: nil)
    }

    /// Decodes up to `seconds` of the track to mono 8 kHz Float32. Synchronous
    /// on purpose: `copyNextSampleBuffer` blocks and must not run in an async
    /// context.
    private static func readAudioSamples(asset: AVAsset, track: AVAssetTrack, seconds: Double) -> [Float]? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 8000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        guard reader.startReading() else { return nil }

        var samples: [Float] = []
        samples.reserveCapacity(Int(seconds * 8000))
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return nil }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
                CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                    destination: raw.baseAddress! + start * MemoryLayout<Float>.size)
            }
            if status != kCMBlockBufferNoErr { return nil }
        }
        return reader.status == .completed ? samples : nil
    }

    // MARK: - Document fingerprint

    /// SimHash of word 3-grams. Case, punctuation and whitespace are ignored,
    /// so reflowed or lightly edited copies land close together. Scanned PDFs
    /// without a text layer return nil (exact matching only).
    private static func documentFingerprint(of item: MediaItem) -> Fingerprint? {
        let text: String
        if item.kind == .pdf {
            guard let s = PDFDocument(url: item.url)?.string else { return nil }
            text = String(s.prefix(400_000))
        } else {
            guard let handle = try? FileHandle(forReadingFrom: item.url) else { return nil }
            defer { try? handle.close() }
            guard let data = (try? handle.read(upToCount: 2 << 20)) ?? nil else { return nil }
            text = String(decoding: data, as: UTF8.self)
        }
        let tokens = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(50_000)
            .map(String.init)
        guard tokens.count >= 8 else { return nil }

        var weights = [Int32](repeating: 0, count: 64)
        for i in 0..<(tokens.count - 2) {
            // FNV-1a over the shingle's bytes.
            var h: UInt64 = 0xcbf29ce484222325
            for token in tokens[i...(i + 2)] {
                for byte in token.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
                h = (h ^ 0x20) &* 0x100000001b3
            }
            for bit in 0..<64 { weights[bit] += (h >> UInt64(bit)) & 1 == 1 ? 1 : -1 }
        }
        var hash: UInt64 = 0
        for bit in 0..<64 where weights[bit] > 0 { hash |= 1 << UInt64(bit) }
        return Fingerprint(
            family: .document, words: [hash], aspect: nil,
            scalar: Double(tokens.count), size: nil)
    }
}
