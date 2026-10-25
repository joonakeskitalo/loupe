import Foundation
import ImageIO
import CFFmpeg

/// Lightweight media metadata resolved for a list row: the video codec name
/// (videos only) and the pixel dimensions (videos and images).
struct MediaMetadata: Sendable, Equatable {
    /// Video codec name, e.g. "h264", "hevc", "vp9". Nil for images or when it
    /// can't be determined.
    var codec: String?
    /// The container's sample-entry fourcc for the video stream, lowercased —
    /// e.g. "hvc1", "hev1", "avc1". This is the codec *tag*, distinct from the
    /// codec name (`codec`): HEVC can be carried as either `hvc1` or `hev1`, and
    /// the difference matters because AVFoundation only decodes `hvc1`-tagged
    /// HEVC (a `hev1`-tagged clip shows the QuickTime placeholder with audio
    /// only). Nil for images or when the tag is absent/zero.
    var codecTag: String?
    /// Pixel width/height. Nil when it can't be determined.
    var pixelSize: PixelSize?
    /// Clip length in seconds (videos only). Nil for images or when the
    /// container reports no usable duration.
    var duration: Double?
    /// Overall bitrate in bits per second (videos only). Nil for images or
    /// when the container reports no usable bitrate.
    var bitrate: Int64?

    static let empty = MediaMetadata(codec: nil, codecTag: nil, pixelSize: nil, duration: nil, bitrate: nil)

    /// Whether AVFoundation can be expected to decode this video's picture.
    /// HEVC carried with any tag other than `hvc1` (notably `hev1`) is the
    /// known failure: AVFoundation plays the audio but shows only the QuickTime
    /// logo. Everything else is assumed AVFoundation-playable (the backend
    /// falls back to libmpv when this is false). Conservative: an unknown tag on
    /// an HEVC stream is treated as NOT playable so it routes to mpv, which
    /// decodes HEVC regardless of the sample-entry tag.
    var isAVFoundationPlayableVideo: Bool {
        guard let codec, codec == "hevc" else { return true }
        return codecTag == "hvc1"
    }
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
        return MediaMetadata(codec: nil, pixelSize: PixelSize(width: width, height: height),
                             duration: nil, bitrate: nil)
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

        // The container's sample-entry fourcc (e.g. "hvc1"/"hev1"/"avc1"),
        // decoded from the little-endian `codec_tag`. Used to tell apart HEVC
        // variants AVFoundation can vs. can't decode. Zero means the container
        // carried no tag.
        let codecTag = Self.fourCC(codecpar.pointee.codec_tag)

        var pixelSize: PixelSize?
        var w = Int(codecpar.pointee.width)
        var h = Int(codecpar.pointee.height)
        // Phone videos are almost always stored in landscape and carry a
        // display-matrix rotation tag that a player applies at presentation.
        // The coded width/height alone therefore report a portrait clip as
        // landscape, which put it in the wrong orientation bucket. Honor the
        // rotation: a 90°/270° turn swaps the displayed dimensions.
        if Self.rotationSwapsDimensions(codecpar) { swap(&w, &h) }
        if w > 0, h > 0 { pixelSize = PixelSize(width: w, height: h) }

        // Container duration, in AV_TIME_BASE units (microseconds). Can be
        // AV_NOPTS_VALUE / 0 when unknown, so only report a positive value.
        var duration: Double?
        let durationTicks = formatCtx?.pointee.duration ?? 0
        if durationTicks > 0 {
            duration = Double(durationTicks) / Double(AV_TIME_BASE)
        }

        // Overall container bitrate in bits per second. FFmpeg reports 0 when
        // unknown (e.g. some streamed containers), so only surface a positive
        // value; fall back to deriving it from file size / duration when the
        // container doesn't carry one but we know both.
        var bitrate: Int64?
        let reportedBitrate = formatCtx?.pointee.bit_rate ?? 0
        if reportedBitrate > 0 {
            bitrate = Int64(reportedBitrate)
        } else if let duration, duration > 0,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0 {
            bitrate = Int64(Double(size) * 8 / duration)
        }

        return MediaMetadata(codec: codec, codecTag: codecTag,
                             pixelSize: pixelSize, duration: duration, bitrate: bitrate)
    }

    /// Decodes a little-endian fourcc (`codec_tag`) into a lowercased 4-char
    /// string, e.g. 0x31637668 → "hvc1". Returns nil when the tag is zero or
    /// contains non-printable bytes (so a garbage tag doesn't masquerade as a
    /// real fourcc).
    private static func fourCC(_ tag: UInt32) -> String? {
        guard tag != 0 else { return nil }
        var bytes: [UInt8] = [
            UInt8(tag & 0xFF),
            UInt8((tag >> 8) & 0xFF),
            UInt8((tag >> 16) & 0xFF),
            UInt8((tag >> 24) & 0xFF)
        ]
        // Trim trailing spaces/nulls some tags pad with, but reject control
        // bytes that signal this isn't a textual fourcc.
        guard bytes.allSatisfy({ $0 == 0 || $0 == 0x20 || ($0 >= 0x21 && $0 <= 0x7E) })
        else { return nil }
        while let last = bytes.last, last == 0 || last == 0x20 { bytes.removeLast() }
        guard !bytes.isEmpty else { return nil }
        return String(decoding: bytes, as: UTF8.self).lowercased()
    }

    /// Returns true when the stream's display-matrix side data rotates the
    /// picture by a quarter turn (±90°), which swaps displayed width/height.
    ///
    /// The rotation lives in the codec parameters' `coded_side_data` as an
    /// `AV_PKT_DATA_DISPLAYMATRIX` entry — a 3×3 affine matrix. FFmpeg's
    /// `av_display_rotation_get` decodes it to counter-clockwise degrees (or
    /// NaN when absent/degenerate). We only care whether the magnitude is near
    /// 90° (90 or 270 both swap the axes); 0° and 180° keep them.
    private static func rotationSwapsDimensions(
        _ codecpar: UnsafeMutablePointer<AVCodecParameters>
    ) -> Bool {
        guard let sideData = codecpar.pointee.coded_side_data else { return false }
        let count = codecpar.pointee.nb_coded_side_data
        guard let entry = av_packet_side_data_get(
            sideData, count, AV_PKT_DATA_DISPLAYMATRIX
        ) else { return false }
        guard let data = entry.pointee.data, entry.pointee.size >= 9 * MemoryLayout<Int32>.size
        else { return false }

        let degrees = data.withMemoryRebound(to: Int32.self, capacity: 9) {
            av_display_rotation_get($0)
        }
        guard degrees.isFinite else { return false }

        // Normalize to [0, 360) and test proximity to a quarter turn. Allow a
        // small tolerance for matrices that aren't perfectly axis-aligned.
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        return abs(positive - 90) < 1 || abs(positive - 270) < 1
    }
}
