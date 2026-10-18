import AppKit
import CFFmpeg

/// Decodes a single representative frame from a video file using the official
/// FFmpeg libraries (libavformat / libavcodec / libavutil / libswscale).
///
/// This is Loupe's fallback for containers QuickLook and AVFoundation can't
/// handle — notably Matroska (`.mkv`) and WebM (`.webm`). It opens the file,
/// picks the best video stream, seeks past the intro, then decodes a handful
/// of candidate frames and keeps the brightest one — so videos that fade in
/// from black don't produce an all-black thumbnail. The chosen frame is
/// converted to RGBA and wrapped in an `NSImage`.
///
/// Everything here is synchronous C work with no shared mutable state, so it is
/// safe to call from a detached task off the main actor.
enum FFmpegThumbnailer {

    /// Produces a thumbnail no larger than `maxPixelSize` on its longest edge,
    /// preserving aspect ratio. Returns nil if the file can't be opened or no
    /// frame can be decoded.
    /// `position` is where to start sampling — a fraction of the clip's
    /// duration or a fixed offset in seconds. The brightness search below still
    /// runs forward from there, so a chosen position that lands on a black
    /// frame still yields a visible thumbnail.
    static func thumbnail(
        for url: URL,
        maxPixelSize: Int,
        position: VideoThumbnailPosition = .defaultPosition
    ) -> NSImage? {
        var formatCtx: UnsafeMutablePointer<AVFormatContext>? = nil

        // avformat_open_input takes ownership of the context pointer and frees
        // it on failure, so only close it when the open succeeded.
        guard avformat_open_input(&formatCtx, url.path, nil, nil) == 0 else {
            return nil
        }
        defer { avformat_close_input(&formatCtx) }

        guard avformat_find_stream_info(formatCtx, nil) >= 0 else {
            return nil
        }

        // Let FFmpeg pick the best video stream and matching decoder.
        var decoder: UnsafePointer<AVCodec>? = nil
        let streamIndex = av_find_best_stream(
            formatCtx, AVMEDIA_TYPE_VIDEO, -1, -1, &decoder, 0
        )
        guard streamIndex >= 0, let decoder,
              let stream = formatCtx?.pointee.streams[Int(streamIndex)]
        else {
            return nil
        }

        guard let codecCtx = avcodec_alloc_context3(decoder) else { return nil }
        var codecCtxOpt: UnsafeMutablePointer<AVCodecContext>? = codecCtx
        defer { avcodec_free_context(&codecCtxOpt) }

        guard avcodec_parameters_to_context(codecCtx, stream.pointee.codecpar) >= 0 else {
            return nil
        }

        // Let the decoder use multiple threads. `thread_count = 0` asks
        // libavcodec to pick a sensible count for the host, and allowing both
        // frame- and slice-level threading lets it use whatever the codec
        // supports. Decoding the handful of frames we sample is the dominant
        // cost for .mkv/.webm, so parallelizing it meaningfully cuts the time
        // for high-resolution clips. Set before avcodec_open2 so it takes hold.
        codecCtx.pointee.thread_count = 0
        codecCtx.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE

        guard avcodec_open2(codecCtx, decoder, nil) >= 0 else {
            return nil
        }

        // Seek to the requested position (best-effort; the brightness search
        // below handles whatever frame the seek lands on).
        seek(
            to: position,
            formatCtx: formatCtx, stream: stream, streamIndex: streamIndex
        )

        guard let frame = decodeBestFrame(
            formatCtx: formatCtx, codecCtx: codecCtx, streamIndex: streamIndex
        ) else {
            return nil
        }
        defer {
            var f: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&f)
        }

        return makeImage(from: frame, maxPixelSize: maxPixelSize)
    }

    // MARK: - Seeking

    /// Seeks to `position`, resolved against the clip's duration. `.start`
    /// leaves the demuxer at the beginning (no seek). For any other position
    /// the brightness search in `decodeBestFrame` still runs forward from the
    /// landing point, so a position that happens to hit a dark frame still
    /// produces a usable thumbnail. Best-effort: a stream with no known
    /// duration can still honor an absolute-seconds position (it just can't be
    /// clamped), while a fractional position with no duration stays at the
    /// start, where the search then begins.
    private static func seek(
        to position: VideoThumbnailPosition,
        formatCtx: UnsafeMutablePointer<AVFormatContext>?,
        stream: UnsafeMutablePointer<AVStream>,
        streamIndex: Int32
    ) {
        guard !position.isStart else { return }

        let durationTicks = formatCtx?.pointee.duration ?? 0
        let durationSeconds = durationTicks > 0 ? Double(durationTicks) / Double(AV_TIME_BASE) : 0

        let targetSeconds = position.resolvedSeconds(duration: durationSeconds)
        guard targetSeconds > 0 else { return }

        let timeBase = stream.pointee.time_base
        guard timeBase.den != 0 else { return }
        let targetTs = Int64(targetSeconds * Double(timeBase.den) / Double(timeBase.num))

        av_seek_frame(formatCtx, streamIndex, targetTs, AVSEEK_FLAG_BACKWARD)
    }

    // MARK: - Decoding

    /// A frame is "bright enough" to stop searching once its average luma (on a
    /// 0–255 scale) clears this threshold. Picked empirically: dark-but-visible
    /// night scenes still pass, while fade-from-black frames don't.
    private static let brightnessThreshold: Double = 50

    /// How many decoded frames to score before giving up and taking the
    /// best-so-far. Bounds the work for videos that are black/dark throughout.
    private static let maxFramesToSample = 20

    /// Score only every Nth decoded frame so our samples span more wall-clock
    /// time (a fade-in can last a couple of seconds = dozens of frames). We
    /// still decode every frame — codecs need the intermediate ones — but skip
    /// the brightness math and candidate-cloning on most of them.
    private static let sampleEveryNFrames = 4

    /// Decodes frames starting at the current (post-seek) position and returns
    /// the first one bright enough to be useful, or — if none clears the
    /// threshold — the brightest frame seen among the sampled candidates. This
    /// is what prevents all-black thumbnails on videos that fade in.
    private static func decodeBestFrame(
        formatCtx: UnsafeMutablePointer<AVFormatContext>?,
        codecCtx: UnsafeMutablePointer<AVCodecContext>,
        streamIndex: Int32
    ) -> UnsafeMutablePointer<AVFrame>? {
        guard let packet = av_packet_alloc() else { return nil }
        var packetOpt: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&packetOpt) }

        guard let frame = av_frame_alloc() else { return nil }
        var frameOpt: UnsafeMutablePointer<AVFrame>? = frame
        defer { av_frame_free(&frameOpt) }

        // Keep the brightest candidate in a separate frame we own, so it stays
        // valid while we keep reusing `frame` for subsequent decodes.
        var best: UnsafeMutablePointer<AVFrame>? = nil
        var bestScore = -1.0

        var framesSampled = 0
        var framesDecoded = 0
        var packetsTried = 0
        let maxPackets = 1200

        // Returns true when we've found a frame good enough to stop early.
        func handle(_ f: UnsafeMutablePointer<AVFrame>) -> Bool {
            framesDecoded += 1
            // Score only every Nth decoded frame so samples span more time.
            guard framesDecoded % sampleEveryNFrames == 1 || sampleEveryNFrames == 1 else {
                return false
            }

            framesSampled += 1
            let score = averageLuma(of: f)
            if score > bestScore {
                bestScore = score
                var old: UnsafeMutablePointer<AVFrame>? = best
                if old != nil { av_frame_free(&old) }
                best = av_frame_clone(f)
            }
            return score >= brightnessThreshold
        }

        while packetsTried < maxPackets, framesSampled < maxFramesToSample,
              av_read_frame(formatCtx, packet) >= 0 {
            defer { av_packet_unref(packet) }
            packetsTried += 1

            guard packet.pointee.stream_index == streamIndex else { continue }
            guard avcodec_send_packet(codecCtx, packet) >= 0 else { continue }

            // A packet may yield multiple frames; drain them.
            while avcodec_receive_frame(codecCtx, frame) == 0 {
                if handle(frame) {
                    return best
                }
            }
        }

        // Flush any buffered frames.
        avcodec_send_packet(codecCtx, nil)
        while framesSampled < maxFramesToSample,
              avcodec_receive_frame(codecCtx, frame) == 0 {
            if handle(frame) {
                return best
            }
        }

        return best
    }

    /// Average brightness of a frame on a 0–255 scale.
    ///
    /// Source frames arrive in many pixel formats (planar YUV at various bit
    /// depths, planar GBR for VP9, etc.), so rather than special-case each one
    /// we downscale the frame to a tiny 8-bit grayscale buffer with libswscale
    /// and average that. Correct for every format and cheap: the destination
    /// is only 32×32.
    private static func averageLuma(of frame: UnsafeMutablePointer<AVFrame>) -> Double {
        let srcW = Int(frame.pointee.width)
        let srcH = Int(frame.pointee.height)
        guard srcW > 0, srcH > 0 else { return 0 }

        let dstW = 32
        let dstH = 32
        let srcPixFmt = AVPixelFormat(frame.pointee.format)

        guard let sws = sws_getContext(
            Int32(srcW), Int32(srcH), srcPixFmt,
            Int32(dstW), Int32(dstH), AV_PIX_FMT_GRAY8,
            Int32(SWS_BILINEAR.rawValue), nil, nil, nil
        ) else {
            return 0
        }
        defer { sws_freeContext(sws) }

        // Tightly-packed GRAY8 destination: one byte per pixel.
        var buffer = [UInt8](repeating: 0, count: dstW * dstH)
        let avg: Double = buffer.withUnsafeMutableBufferPointer { buf -> Double in
            var dstData: [UnsafeMutablePointer<UInt8>?] = [buf.baseAddress, nil, nil, nil]
            var dstLinesize: [Int32] = [Int32(dstW), 0, 0, 0]

            withUnsafePointer(to: &frame.pointee.data.0) { srcDataPtr in
                withUnsafePointer(to: &frame.pointee.linesize.0) { srcLinePtr in
                    _ = srcDataPtr.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { src in
                        srcLinePtr.withMemoryRebound(to: Int32.self, capacity: 8) { lines in
                            sws_scale(sws, src, lines, 0, Int32(srcH), &dstData, &dstLinesize)
                        }
                    }
                }
            }

            var sum = 0
            for v in buf { sum += Int(v) }
            return Double(sum) / Double(buf.count)
        }

        return avg
    }

    // MARK: - Pixel conversion

    private static func makeImage(
        from frame: UnsafeMutablePointer<AVFrame>,
        maxPixelSize: Int
    ) -> NSImage? {
        let srcWidth = Int(frame.pointee.width)
        let srcHeight = Int(frame.pointee.height)
        guard srcWidth > 0, srcHeight > 0 else { return nil }

        // Scale the longest edge down to maxPixelSize, keeping aspect ratio.
        let scale = min(1.0, Double(maxPixelSize) / Double(max(srcWidth, srcHeight)))
        let dstWidth = max(1, Int((Double(srcWidth) * scale).rounded()))
        let dstHeight = max(1, Int((Double(srcHeight) * scale).rounded()))

        let srcPixFmt = AVPixelFormat(frame.pointee.format)
        let dstPixFmt = AV_PIX_FMT_RGBA

        guard let swsCtx = sws_getContext(
            Int32(srcWidth), Int32(srcHeight), srcPixFmt,
            Int32(dstWidth), Int32(dstHeight), dstPixFmt,
            Int32(SWS_BILINEAR.rawValue), nil, nil, nil
        ) else {
            return nil
        }
        defer { sws_freeContext(swsCtx) }

        // Allocate the destination RGBA buffer.
        var dstData = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: 4)
        var dstLinesize = [Int32](repeating: 0, count: 4)
        guard av_image_alloc(&dstData, &dstLinesize,
                             Int32(dstWidth), Int32(dstHeight), dstPixFmt, 1) >= 0
        else {
            return nil
        }
        defer { av_freep(&dstData[0]) }

        // Convert source planes -> packed RGBA.
        withUnsafePointer(to: &frame.pointee.data.0) { srcDataPtr in
            withUnsafePointer(to: &frame.pointee.linesize.0) { srcLineizePtr in
                _ = srcDataPtr.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { src in
                    srcLineizePtr.withMemoryRebound(to: Int32.self, capacity: 8) { lines in
                        sws_scale(swsCtx, src, lines, 0, Int32(srcHeight), &dstData, &dstLinesize)
                    }
                }
            }
        }

        guard let base = dstData[0] else { return nil }
        let bytesPerRow = Int(dstLinesize[0])

        // Wrap the RGBA buffer in a CGImage via a bitmap context. Copy into a
        // CGImage-owned buffer so it stays valid after we free the FFmpeg one.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(
            data: nil,
            width: dstWidth,
            height: dstHeight,
            bitsPerComponent: 8,
            bytesPerRow: dstWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        if let ctxData = ctx.data {
            // Copy row by row to account for FFmpeg's possibly larger linesize.
            let dstRow = dstWidth * 4
            for row in 0..<dstHeight {
                memcpy(
                    ctxData.advanced(by: row * dstRow),
                    base.advanced(by: row * bytesPerRow),
                    dstRow
                )
            }
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: dstWidth, height: dstHeight))
    }
}
