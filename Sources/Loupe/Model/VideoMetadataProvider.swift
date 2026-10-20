import Foundation
import ImageIO
import CFFmpeg

/// Lightweight media metadata resolved for a list row: the video codec name
/// (videos only) and the pixel dimensions (videos and images).
struct MediaMetadata: Sendable, Equatable {
    /// Video codec name, e.g. "h264", "hevc", "vp9". Nil for images or when it
    /// can't be determined.
    var codec: String?
    /// Pixel width/height. Nil when it can't be determined.
    var pixelSize: PixelSize?
    /// Clip length in seconds (videos only). Nil for images or when the
    /// container reports no usable duration.
    var duration: Double?

    static let empty = MediaMetadata(codec: nil, pixelSize: nil, duration: nil)
}

/// A main-actor snapshot of already-resolved metadata, so list rows can render
/// cached values synchronously on appear — no actor hop, no task, no transient
/// `.empty` flicker. The provider populates it as probes finish; the view reads
/// it directly during scrolling and only kicks off an async probe on a miss.
///
/// Backed by `NSCache` rather than a plain dictionary so it can't grow without
/// bound: a large library would otherwise keep one entry per file alive for the
/// whole process lifetime. The `countLimit` is generous (metadata is tiny) but
/// finite, and NSCache evicts least-recently-used entries past it, so scrolling
/// a huge folder re-probes a few off-screen rows on return instead of pinning
/// everything in memory forever. NSCache is internally thread-safe; the
/// `@MainActor` here just keeps the call sites hop-free, matching the old API.
@MainActor
enum MediaMetadataCache {
    private static let store: NSCache<NSURL, MediaMetadataBox> = {
        let cache = NSCache<NSURL, MediaMetadataBox>()
        cache.countLimit = 20_000
        return cache
    }()

    static func cached(for url: URL) -> MediaMetadata? {
        store.object(forKey: url as NSURL)?.value
    }

    static func set(_ value: MediaMetadata, for url: URL) {
        store.setObject(MediaMetadataBox(value), forKey: url as NSURL)
    }
}

/// Reference wrapper so `MediaMetadata` (a value type) can live in `NSCache`,
/// which only stores class instances.
private final class MediaMetadataBox {
    let value: MediaMetadata
    init(_ value: MediaMetadata) { self.value = value }
}

/// A pixel dimension pair, formatted as "W × H".
struct PixelSize: Sendable, Equatable {
    let width: Int
    let height: Int

    var displayString: String { "\(width) × \(height)" }
}

/// Probes and caches lightweight media metadata (video codec + pixel
/// dimensions for video, pixel dimensions for images).
///
/// Video metadata comes from the official FFmpeg libraries — rather than
/// AVFoundation — so it is reported consistently across every container Loupe
/// can show, including the ones AVFoundation can't open (notably Matroska
/// `.mkv` and WebM `.webm`). Probing only reads stream headers
/// (`avformat_find_stream_info`); no frames are decoded, so it is cheap.
///
/// Image dimensions come from `CGImageSource`, which reads just the header and
/// never decodes the pixels.
///
/// The actor does fast bookkeeping only (cache lookup + deduping in-flight
/// requests) and never `await`s the synchronous probe while isolated, so many
/// rows resolve concurrently instead of serializing.
actor VideoMetadataProvider {
    static let shared = VideoMetadataProvider()

    /// Cached metadata keyed by file URL. An entry of `.empty` means "probed,
    /// but nothing could be determined" so we don't probe the same file again.
    ///
    /// `NSCache` (not a plain dictionary) so it stays bounded: without a cap it
    /// would retain one entry per probed file for the whole process lifetime,
    /// which adds up over a large library. The limit is high (each entry is a
    /// codec string plus a size) but finite; past it, NSCache evicts
    /// least-recently-used entries and the rare off-screen row re-probes.
    private let cache: NSCache<NSURL, MediaMetadataBox> = {
        let cache = NSCache<NSURL, MediaMetadataBox>()
        cache.countLimit = 20_000
        return cache
    }()
    private var inFlight: [URL: Task<MediaMetadata, Never>] = [:]

    /// Returns metadata for `url`, treating it as the given `kind` so we pick
    /// the right probe (FFmpeg for video, ImageIO for images). Cached per URL.
    func metadata(for url: URL, kind: MediaKind) async -> MediaMetadata {
        if let cached = cache.object(forKey: url as NSURL)?.value {
            return cached
        }

        let task = taskForProbe(url: url, kind: kind)
        return await task.value
    }

    private func taskForProbe(url: URL, kind: MediaKind) -> Task<MediaMetadata, Never> {
        if let existing = inFlight[url] {
            return existing
        }

        let task = Task<MediaMetadata, Never>.detached(priority: .utility) {
            switch kind {
            case .video: return Self.probeVideo(url: url)
            case .image: return Self.probeImage(url: url)
            default:      return .empty
            }
        }
        inFlight[url] = task

        // Store the result and clear the in-flight entry once the probe lands.
        Task { [weak self] in
            let value = await task.value
            await self?.store(value, for: url)
        }
        return task
    }

    private func store(_ value: MediaMetadata, for url: URL) {
        cache.setObject(MediaMetadataBox(value), forKey: url as NSURL)
        inFlight[url] = nil
        // Publish to the synchronous main-actor snapshot so rows that mount
        // later can read it without hopping back onto this actor.
        Task { @MainActor in MediaMetadataCache.set(value, for: url) }
    }

    // MARK: - Image

    /// Reads image dimensions from the file header via ImageIO, without
    /// decoding the pixels.
    private static func probeImage(url: URL) -> MediaMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else {
            return .empty
        }
        return MediaMetadata(codec: nil, pixelSize: PixelSize(width: width, height: height), duration: nil)
    }

    // MARK: - Video

    /// Opens the file, reads stream headers, and returns the best video
    /// stream's codec name and coded dimensions. Pure synchronous C work with
    /// no shared state, so it is safe to run off the actor on a detached task.
    private static func probeVideo(url: URL) -> MediaMetadata {
        var formatCtx: UnsafeMutablePointer<AVFormatContext>? = nil

        // avformat_open_input frees the context on failure, so only close it
        // when the open succeeded.
        guard avformat_open_input(&formatCtx, url.path, nil, nil) == 0 else {
            return .empty
        }
        defer { avformat_close_input(&formatCtx) }

        guard avformat_find_stream_info(formatCtx, nil) >= 0 else {
            return .empty
        }

        let streamIndex = av_find_best_stream(
            formatCtx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0
        )
        guard streamIndex >= 0,
              let stream = formatCtx?.pointee.streams[Int(streamIndex)],
              let codecpar = stream.pointee.codecpar
        else {
            return .empty
        }

        var codec: String?
        if let namePtr = avcodec_get_name(codecpar.pointee.codec_id) {
            let name = String(cString: namePtr)
            // FFmpeg returns "none" for AV_CODEC_ID_NONE; treat that as unknown.
            if !name.isEmpty, name != "none" { codec = name }
        }

        var pixelSize: PixelSize?
        let w = Int(codecpar.pointee.width)
        let h = Int(codecpar.pointee.height)
        if w > 0, h > 0 { pixelSize = PixelSize(width: w, height: h) }

        // Container duration, in AV_TIME_BASE units (microseconds). Can be
        // AV_NOPTS_VALUE / 0 when unknown, so only report a positive value.
        var duration: Double?
        let durationTicks = formatCtx?.pointee.duration ?? 0
        if durationTicks > 0 {
            duration = Double(durationTicks) / Double(AV_TIME_BASE)
        }

        return MediaMetadata(codec: codec, pixelSize: pixelSize, duration: duration)
    }
}
