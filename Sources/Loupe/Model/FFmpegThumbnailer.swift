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
    static func thumbnail(for url: URL, maxPixelSize: Int) -> NSImage? {
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

        guard avcodec_parameters_to_context(codecCtx, stream.pointee.codecpar) >= 0,
              avcodec_open2(codecCtx, decoder, nil) >= 0
        else {
            return nil
        }

        // Seek ~10% in (capped at 2s) to avoid black intro frames, when the
        // stream exposes a usable duration. Best-effort: ignore failures.
        seekPastIntro(formatCtx: formatCtx, stream: stream, streamIndex: streamIndex)

        guard let frame = decodeFirstFrame(
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

    private static func seekPastIntro(
        formatCtx: UnsafeMutablePointer<AVFormatContext>?,
        stream: UnsafeMutablePointer<AVStream>,
        streamIndex: Int32
    ) {
        let durationTicks = formatCtx?.pointee.duration ?? 0
        guard durationTicks > 0 else { return }
        let durationSeconds = Double(durationTicks) / Double(AV_TIME_BASE)
        guard durationSeconds > 0 else { return }

        let targetSeconds = min(2.0, durationSeconds * 0.1)
        let timeBase = stream.pointee.time_base
        guard timeBase.den != 0 else { return }
        let targetTs = Int64(targetSeconds * Double(timeBase.den) / Double(timeBase.num))

        av_seek_frame(formatCtx, streamIndex, targetTs, AVSEEK_FLAG_BACKWARD)
    }

    // MARK: - Decoding

    private static func decodeFirstFrame(
        formatCtx: UnsafeMutablePointer<AVFormatContext>?,
        codecCtx: UnsafeMutablePointer<AVCodecContext>,
        streamIndex: Int32
    ) -> UnsafeMutablePointer<AVFrame>? {
        guard let packet = av_packet_alloc() else { return nil }
        var packetOpt: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&packetOpt) }

        guard let frame = av_frame_alloc() else { return nil }

        // Read packets for our video stream and feed the decoder until a frame
        // comes out. Give up after a bounded number of packets so a corrupt or
        // audio-heavy file can't spin forever.
        var packetsTried = 0
        let maxPackets = 600

        while packetsTried < maxPackets, av_read_frame(formatCtx, packet) >= 0 {
            defer { av_packet_unref(packet) }
            packetsTried += 1

            guard packet.pointee.stream_index == streamIndex else { continue }

            guard avcodec_send_packet(codecCtx, packet) >= 0 else { continue }

            let ret = avcodec_receive_frame(codecCtx, frame)
            if ret == 0 {
                return frame
            }
            // EAGAIN: decoder needs more input — keep reading.
        }

        // Flush: some decoders buffer and only emit after a null packet.
        avcodec_send_packet(codecCtx, nil)
        if avcodec_receive_frame(codecCtx, frame) == 0 {
            return frame
        }

        var f: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&f)
        return nil
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
