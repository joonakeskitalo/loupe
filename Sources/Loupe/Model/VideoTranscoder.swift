import Foundation
import CFFmpeg

/// Transcodes a video to a target resolution using the official FFmpeg
/// libraries (libavformat / libavcodec / libavutil / libswscale), the same C
/// API the rest of Loupe uses for probing and thumbnailing. There is no bundled
/// `ffmpeg` command-line binary (only the dylibs), and the app is sandboxed, so
/// shelling out is not an option — this reimplements the relevant parts of
///
///     ffmpeg -i in -vf "scale=-2:HEIGHT" -c:v libx264 -c:a copy out.mp4
///
/// against the C API: the video stream is decoded, rescaled to the target
/// height (width computed from the source aspect ratio and rounded to an even
/// number, since H.264 requires even dimensions — the `trunc(ow/a/2)*2` in the
/// example), and re-encoded as H.264; the audio stream is remuxed untouched
/// (the `-c:a copy`). The output is always an MP4.
///
/// Everything is synchronous C work with no shared mutable state, so it is safe
/// to run from a detached task off the main actor.
/// FFmpeg integer constants that come from C macros and aren't imported into
/// Swift by the module map. Recreated here with the same definitions FFmpeg
/// uses.
private enum AVConst {
    /// `AVERROR(EAGAIN)` — more input/output needed. EAGAIN is 35 on Darwin.
    static let eagain: Int32 = -35
    /// `AVERROR_EOF` = `-MKTAG('E','O','F',' ')`.
    static let eof: Int32 = {
        func mkTag(_ a: Character, _ b: Character, _ c: Character, _ d: Character) -> Int32 {
            let av = Int32(a.asciiValue!)
            let bv = Int32(b.asciiValue!) << 8
            let cv = Int32(c.asciiValue!) << 16
            let dv = Int32(d.asciiValue!) << 24
            return av | bv | cv | dv
        }
        return -mkTag("E", "O", "F", " ")
    }()
    /// `AV_NOPTS_VALUE` — the "no timestamp" sentinel, `INT64_MIN`.
    static let noPTS: Int64 = Int64.min
}

enum VideoTranscoder {
    /// A target output height. The width is derived from the source aspect
    /// ratio (even-rounded), so only the height is fixed — matching how a
    /// "1080p" / "720p" preset is normally understood.
    enum Resolution: String, CaseIterable, Sendable {
        case p1080 = "1080p"
        case p720 = "720p"

        var displayName: String { rawValue }

        /// The fixed output height in pixels.
        var height: Int {
            switch self {
            case .p1080: return 1080
            case .p720: return 720
            }
        }
    }

    /// Which encoder to use for the output video stream.
    ///
    /// `.h264` is the software x264 encoder — maximum compatibility, slower.
    /// `.hevcVideoToolbox` is Apple's hardware H.265 encoder (VideoToolbox),
    /// which is dramatically faster (and more power-efficient) on Apple Silicon
    /// and recent Intel Macs, at a smaller file size for similar quality. Its
    /// output is tagged `hvc1` so QuickTime / Finder preview it correctly.
    enum Codec: String, CaseIterable, Sendable {
        case h264 = "H.264 (x264)"
        case hevcVideoToolbox = "H.265 (VideoToolbox)"

        var displayName: String { rawValue }

        /// The FFmpeg encoder's registered name, looked up with
        /// `avcodec_find_encoder_by_name`.
        var encoderName: String {
            switch self {
            case .h264: return "libx264"
            case .hevcVideoToolbox: return "hevc_videotoolbox"
            }
        }

        /// Whether this is a hardware VideoToolbox encoder (affects which
        /// quality options apply).
        var isVideoToolbox: Bool { self == .hevcVideoToolbox }
    }

    /// How the encoder decides bit allocation.
    ///
    /// `.constantQuality(cq)` targets a fixed perceptual quality rather than a
    /// fixed size — the encoder spends whatever bits each frame needs to hit
    /// that quality. The `cq` scale is 0...100 (higher = better quality, bigger
    /// file), matching VideoToolbox's quality scale; for the software x264
    /// encoder it's mapped onto CRF.
    ///
    /// `.automaticBitrate` targets a bitrate derived from the output resolution
    /// and frame rate (the original behavior).
    enum RateControl: Sendable, Equatable {
        case constantQuality(Int)
        case automaticBitrate

        /// The default: constant quality at CQ 70.
        static let `default`: RateControl = .constantQuality(70)
    }

    enum TranscodeError: Error {
        case openInput
        case streamInfo
        case noVideoStream
        case decoderInit
        case encoderUnavailable
        case encoderInit
        case openOutput
        case writeHeader
        case scaler
        case allocation
        case encode
    }

    /// Transcodes `input` to `output` (an MP4), scaling the video to
    /// `resolution`'s height, encoding with `codec`, and copying the audio
    /// stream unchanged. Throws on any failure. `progress` is called
    /// periodically with a 0...1 fraction based on decoded-frame timestamps vs.
    /// the clip duration (best-effort; may stay at 0 for streams with no known
    /// duration/PTS).
    ///
    /// Synchronous and `nonisolated`: run it from a detached task.
    nonisolated static func transcode(
        input: URL,
        output: URL,
        resolution: Resolution,
        codec: Codec = .h264,
        rateControl: RateControl = .default,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        // MARK: Open input
        var inputCtx: UnsafeMutablePointer<AVFormatContext>? = nil
        guard avformat_open_input(&inputCtx, input.path, nil, nil) == 0 else {
            throw TranscodeError.openInput
        }
        defer { avformat_close_input(&inputCtx) }

        guard avformat_find_stream_info(inputCtx, nil) >= 0 else {
            throw TranscodeError.streamInfo
        }

        // Best video stream + its decoder.
        var decoder: UnsafePointer<AVCodec>? = nil
        let videoIndex = av_find_best_stream(inputCtx, AVMEDIA_TYPE_VIDEO, -1, -1, &decoder, 0)
        guard videoIndex >= 0, let decoder,
              let inVideoStream = inputCtx?.pointee.streams[Int(videoIndex)]
        else {
            throw TranscodeError.noVideoStream
        }

        // The best audio stream, if any — remuxed as a straight copy.
        let audioIndex = av_find_best_stream(inputCtx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)

        // MARK: Decoder
        guard let decCtx = avcodec_alloc_context3(decoder) else { throw TranscodeError.decoderInit }
        var decCtxOpt: UnsafeMutablePointer<AVCodecContext>? = decCtx
        defer { avcodec_free_context(&decCtxOpt) }
        guard avcodec_parameters_to_context(decCtx, inVideoStream.pointee.codecpar) >= 0 else {
            throw TranscodeError.decoderInit
        }
        decCtx.pointee.thread_count = 0
        guard avcodec_open2(decCtx, decoder, nil) >= 0 else { throw TranscodeError.decoderInit }

        // MARK: Target geometry
        let srcW = Int(decCtx.pointee.width)
        let srcH = Int(decCtx.pointee.height)
        guard srcW > 0, srcH > 0 else { throw TranscodeError.decoderInit }

        // Fixed target height; width scaled by the source aspect, rounded to an
        // even number (H.264 needs even dimensions — the example's
        // `trunc(ow/a/2)*2`). Never upscale: if the source is already shorter
        // than the target, keep the source size (still even-rounded).
        let dstH = min(srcH, resolution.height)
        let scaledW = Int((Double(srcW) * Double(dstH) / Double(srcH)).rounded())
        let dstW = max(2, scaledW - (scaledW % 2))
        let evenDstH = max(2, dstH - (dstH % 2))

        // MARK: Encoder (selected codec)
        // Look up by name so we can pick the hardware VideoToolbox HEVC encoder
        // when requested. If an encoder isn't available (e.g. VideoToolbox
        // missing), fall back to software H.264 so an export never hard-fails.
        var chosenCodec = codec
        var encoder = avcodec_find_encoder_by_name(codec.encoderName)
        if encoder == nil {
            chosenCodec = .h264
            encoder = avcodec_find_encoder_by_name(Codec.h264.encoderName)
                ?? avcodec_find_encoder(AV_CODEC_ID_H264)
        }
        guard let encoder else { throw TranscodeError.encoderUnavailable }

        guard let encCtx = avcodec_alloc_context3(encoder) else { throw TranscodeError.encoderInit }
        var encCtxOpt: UnsafeMutablePointer<AVCodecContext>? = encCtx
        defer { avcodec_free_context(&encCtxOpt) }

        encCtx.pointee.width = Int32(dstW)
        encCtx.pointee.height = Int32(evenDstH)
        encCtx.pointee.pix_fmt = AV_PIX_FMT_YUV420P
        // Use the source stream's time base / frame rate so timestamps stay
        // sensible. Fall back to a 1/30 base if the source reports none.
        let srcFrameRate = inVideoStream.pointee.avg_frame_rate
        let frameRate = (srcFrameRate.num > 0 && srcFrameRate.den > 0) ? srcFrameRate : AVRational(num: 30, den: 1)
        encCtx.pointee.time_base = AVRational(num: frameRate.den, den: frameRate.num)
        encCtx.pointee.framerate = frameRate

        encCtx.pointee.gop_size = 12
        encCtx.pointee.max_b_frames = 2

        var opts: OpaquePointer? = nil // AVDictionary*
        defer { av_dict_free(&opts) }

        // Average bitrate used by `.automaticBitrate` (and as a VideoToolbox
        // ceiling in constant-quality mode): scaled to the output pixels/sec
        // for roughly visually-transparent HEVC (~0.07 bits per pixel/frame).
        let fps = frameRate.den > 0 ? Double(frameRate.num) / Double(frameRate.den) : 30
        let autoBitrate = Int64(max(1_000_000.0, Double(dstW * evenDstH) * fps * 0.07))

        if chosenCodec.isVideoToolbox {
            // Allow the software fallback so machines without the hardware path
            // still succeed.
            av_dict_set(&opts, "allow_sw", "1", 0)
            av_dict_set(&opts, "realtime", "0", 0)

            switch rateControl {
            case .constantQuality(let cq):
                // VideoToolbox constant quality. FFmpeg's `-q:v N` convention is
                // `global_quality = N * FF_QP2LAMBDA` with the QSCALE flag set;
                // the encoder reads it back on its 0...100 quality scale (higher
                // is better). Clamp to that range.
                let q = max(0, min(100, cq))
                encCtx.pointee.flags |= AV_CODEC_FLAG_QSCALE
                encCtx.pointee.global_quality = Int32(q) * FF_QP2LAMBDA
            case .automaticBitrate:
                encCtx.pointee.bit_rate = autoBitrate
            }
        } else {
            // Software x264.
            av_dict_set(&opts, "preset", "medium", 0)
            switch rateControl {
            case .constantQuality(let cq):
                // Map the 0...100 quality scale onto x264 CRF (0...51, lower is
                // better): CQ 100 → CRF 0 (near-lossless), CQ 0 → CRF 51.
                let q = max(0, min(100, cq))
                let crf = Int((Double(100 - q) / 100.0 * 51.0).rounded())
                av_dict_set(&opts, "crf", String(crf), 0)
            case .automaticBitrate:
                encCtx.pointee.bit_rate = autoBitrate
            }
        }

        // MARK: Output context (MP4)
        var outputCtx: UnsafeMutablePointer<AVFormatContext>? = nil
        avformat_alloc_output_context2(&outputCtx, nil, "mp4", output.path)
        guard let outputCtx else { throw TranscodeError.openOutput }
        defer {
            // Free the output context and (if opened) its IO.
            if let pb = outputCtx.pointee.pb, (outputCtx.pointee.oformat?.pointee.flags ?? 0) & AVFMT_NOFILE == 0 {
                var pbOpt: UnsafeMutablePointer<AVIOContext>? = pb
                avio_closep(&pbOpt)
            }
            var outOpt: UnsafeMutablePointer<AVFormatContext>? = outputCtx
            avformat_free_context(outOpt)
            outOpt = nil
        }

        // If the muxer wants a global header, set the encoder flag before open.
        if (outputCtx.pointee.oformat?.pointee.flags ?? 0) & AVFMT_GLOBALHEADER != 0 {
            encCtx.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
        }

        guard avcodec_open2(encCtx, encoder, &opts) >= 0 else { throw TranscodeError.encoderInit }

        // Output video stream.
        guard let outVideoStream = avformat_new_stream(outputCtx, nil) else {
            throw TranscodeError.openOutput
        }
        guard avcodec_parameters_from_context(outVideoStream.pointee.codecpar, encCtx) >= 0 else {
            throw TranscodeError.openOutput
        }
        outVideoStream.pointee.time_base = encCtx.pointee.time_base

        // Tag HEVC as `hvc1` (not the default `hev1`) so QuickTime, Finder
        // Quick Look, and AVFoundation recognize and play the MP4.
        if chosenCodec == .hevcVideoToolbox {
            func mkTag(_ a: Character, _ b: Character, _ c: Character, _ d: Character) -> UInt32 {
                UInt32(a.asciiValue!) | (UInt32(b.asciiValue!) << 8)
                    | (UInt32(c.asciiValue!) << 16) | (UInt32(d.asciiValue!) << 24)
            }
            outVideoStream.pointee.codecpar.pointee.codec_tag = mkTag("h", "v", "c", "1")
        }

        // Output audio stream (straight copy of the source's parameters), if a
        // source audio stream exists. We remux its packets without decoding.
        var outAudioStreamIndex: Int32 = -1
        var inAudioStream: UnsafeMutablePointer<AVStream>? = nil
        if audioIndex >= 0, let aStream = inputCtx?.pointee.streams[Int(audioIndex)] {
            if let outAudio = avformat_new_stream(outputCtx, nil),
               avcodec_parameters_copy(outAudio.pointee.codecpar, aStream.pointee.codecpar) >= 0 {
                outAudio.pointee.codecpar.pointee.codec_tag = 0
                outAudio.pointee.time_base = aStream.pointee.time_base
                outAudioStreamIndex = Int32(outputCtx.pointee.nb_streams - 1)
                inAudioStream = aStream
            }
        }

        // MARK: Open output file + write header
        if (outputCtx.pointee.oformat?.pointee.flags ?? 0) & AVFMT_NOFILE == 0 {
            guard avio_open(&outputCtx.pointee.pb, output.path, AVIO_FLAG_WRITE) >= 0 else {
                throw TranscodeError.openOutput
            }
        }
        guard avformat_write_header(outputCtx, nil) >= 0 else {
            throw TranscodeError.writeHeader
        }

        // MARK: Scaler (source pix fmt -> YUV420P at target size)
        guard let sws = sws_getContext(
            Int32(srcW), Int32(srcH), AVPixelFormat(decCtx.pointee.pix_fmt.rawValue),
            Int32(dstW), Int32(evenDstH), AV_PIX_FMT_YUV420P,
            Int32(SWS_BILINEAR.rawValue), nil, nil, nil
        ) else {
            throw TranscodeError.scaler
        }
        defer { sws_freeContext(sws) }

        // Reusable packet + frames.
        guard let packet = av_packet_alloc() else { throw TranscodeError.allocation }
        var packetOpt: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&packetOpt) }

        guard let decFrame = av_frame_alloc() else { throw TranscodeError.allocation }
        var decFrameOpt: UnsafeMutablePointer<AVFrame>? = decFrame
        defer { av_frame_free(&decFrameOpt) }

        guard let scaledFrame = av_frame_alloc() else { throw TranscodeError.allocation }
        var scaledFrameOpt: UnsafeMutablePointer<AVFrame>? = scaledFrame
        defer { av_frame_free(&scaledFrameOpt) }
        scaledFrame.pointee.format = Int32(AV_PIX_FMT_YUV420P.rawValue)
        scaledFrame.pointee.width = Int32(dstW)
        scaledFrame.pointee.height = Int32(evenDstH)
        guard av_frame_get_buffer(scaledFrame, 32) >= 0 else { throw TranscodeError.allocation }

        // Progress bookkeeping.
        let durationSeconds: Double = {
            let d = inputCtx?.pointee.duration ?? 0
            return d > 0 ? Double(d) / Double(AV_TIME_BASE) : 0
        }()
        let videoTimeBase = inVideoStream.pointee.time_base
        var nextOutputPTS: Int64 = 0

        // MARK: Encode one scaled frame
        func encodeAndWrite(_ frame: UnsafeMutablePointer<AVFrame>?) throws {
            guard avcodec_send_frame(encCtx, frame) >= 0 else { throw TranscodeError.encode }
            while true {
                let ret = avcodec_receive_packet(encCtx, packet)
                if ret == AVConst.eagain || ret == AVConst.eof { break }
                guard ret >= 0 else { throw TranscodeError.encode }
                packet.pointee.stream_index = 0
                av_packet_rescale_ts(packet, encCtx.pointee.time_base, outVideoStream.pointee.time_base)
                _ = av_interleaved_write_frame(outputCtx, packet)
                av_packet_unref(packet)
            }
        }

        // MARK: Demux loop
        while av_read_frame(inputCtx, packet) >= 0 {
            let streamIdx = packet.pointee.stream_index

            if streamIdx == videoIndex {
                // Decode -> scale -> encode.
                let sendRet = avcodec_send_packet(decCtx, packet)
                av_packet_unref(packet)
                guard sendRet >= 0 else { continue }

                while avcodec_receive_frame(decCtx, decFrame) == 0 {
                    guard av_frame_make_writable(scaledFrame) >= 0 else { continue }

                    // src planes -> scaled YUV420P
                    withUnsafePointer(to: &decFrame.pointee.data.0) { srcDataPtr in
                        withUnsafePointer(to: &decFrame.pointee.linesize.0) { srcLinePtr in
                            withUnsafeMutablePointer(to: &scaledFrame.pointee.data.0) { dstDataPtr in
                                withUnsafeMutablePointer(to: &scaledFrame.pointee.linesize.0) { dstLinePtr in
                                    _ = srcDataPtr.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { src in
                                        srcLinePtr.withMemoryRebound(to: Int32.self, capacity: 8) { srcLines in
                                            dstDataPtr.withMemoryRebound(to: UnsafeMutablePointer<UInt8>?.self, capacity: 8) { dst in
                                                dstLinePtr.withMemoryRebound(to: Int32.self, capacity: 8) { dstLines in
                                                    sws_scale(sws, src, srcLines, 0, Int32(srcH), dst, dstLines)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Monotonic output PTS in the encoder time base.
                    scaledFrame.pointee.pts = nextOutputPTS
                    nextOutputPTS += 1

                    // Report progress from the decoded frame's timestamp.
                    if let progress, durationSeconds > 0, videoTimeBase.den != 0 {
                        let framePTS = decFrame.pointee.best_effort_timestamp
                        if framePTS != AVConst.noPTS {
                            let seconds = Double(framePTS) * Double(videoTimeBase.num) / Double(videoTimeBase.den)
                            progress(min(1.0, max(0.0, seconds / durationSeconds)))
                        }
                    }

                    try encodeAndWrite(scaledFrame)
                }
            } else if streamIdx == audioIndex, outAudioStreamIndex >= 0,
                      let inAudioStream, let outAudio = outputCtx.pointee.streams[Int(outAudioStreamIndex)] {
                // Audio: straight copy. Rescale timestamps into the output
                // stream's time base, retag the stream index, and write.
                av_packet_rescale_ts(packet, inAudioStream.pointee.time_base, outAudio.pointee.time_base)
                packet.pointee.stream_index = outAudioStreamIndex
                _ = av_interleaved_write_frame(outputCtx, packet)
                av_packet_unref(packet)
            } else {
                av_packet_unref(packet)
            }
        }

        // MARK: Flush decoder, then encoder
        avcodec_send_packet(decCtx, nil)
        while avcodec_receive_frame(decCtx, decFrame) == 0 {
            guard av_frame_make_writable(scaledFrame) >= 0 else { continue }
            withUnsafePointer(to: &decFrame.pointee.data.0) { srcDataPtr in
                withUnsafePointer(to: &decFrame.pointee.linesize.0) { srcLinePtr in
                    withUnsafeMutablePointer(to: &scaledFrame.pointee.data.0) { dstDataPtr in
                        withUnsafeMutablePointer(to: &scaledFrame.pointee.linesize.0) { dstLinePtr in
                            _ = srcDataPtr.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { src in
                                srcLinePtr.withMemoryRebound(to: Int32.self, capacity: 8) { srcLines in
                                    dstDataPtr.withMemoryRebound(to: UnsafeMutablePointer<UInt8>?.self, capacity: 8) { dst in
                                        dstLinePtr.withMemoryRebound(to: Int32.self, capacity: 8) { dstLines in
                                            sws_scale(sws, src, srcLines, 0, Int32(srcH), dst, dstLines)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            scaledFrame.pointee.pts = nextOutputPTS
            nextOutputPTS += 1
            try encodeAndWrite(scaledFrame)
        }
        // Drain the encoder.
        try encodeAndWrite(nil)

        av_write_trailer(outputCtx)
        progress?(1.0)
    }
}
